
-- Roles del sistema: administrador y cliente (tabla rol del login).
-- =====================================================================
BEGIN;

CREATE EXTENSION IF NOT EXISTS unaccent;   -- búsqueda sin tildes
CREATE EXTENSION IF NOT EXISTS pg_trgm;    -- búsqueda tolerante a errores de tipeo

CREATE FUNCTION f_unaccent(text) RETURNS text
LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT AS
$$ SELECT public.unaccent('public.unaccent'::regdictionary, $1) $$;

-- ---------------------------------------------------------------------
-- 0. CONFIGURACIÓN Y NUMERACIÓN
-- ---------------------------------------------------------------------
CREATE TABLE configuracion (
    clave          VARCHAR(60) PRIMARY KEY,
    valor          TEXT        NOT NULL,
    descripcion    VARCHAR(200),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE secuencia_documento (
    prefijo VARCHAR(12) NOT NULL,
    anio    SMALLINT    NOT NULL,
    ultimo  INTEGER     NOT NULL DEFAULT 0,
    PRIMARY KEY (prefijo, anio)
);

-- Documento de identidad del cliente (opcional; se pide al emitir factura o boleta con DNI)
ALTER TABLE usuario
    ADD COLUMN tipo_documento   VARCHAR(3) CHECK (tipo_documento IN ('DNI','RUC','CE')),
    ADD COLUMN numero_documento VARCHAR(15),
    ADD CONSTRAINT ck_usuario_documento CHECK (
        (tipo_documento IS NULL AND numero_documento IS NULL)
        OR (tipo_documento = 'DNI' AND numero_documento ~ '^[0-9]{8}$')
        OR (tipo_documento = 'RUC' AND numero_documento ~ '^[0-9]{11}$')
        OR (tipo_documento = 'CE'  AND numero_documento ~ '^[A-Za-z0-9]{6,12}$'));

-- ---------------------------------------------------------------------
-- 1. CATÁLOGO
-- ---------------------------------------------------------------------
CREATE TABLE categoria (
    id_categoria       SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_categoria_padre SMALLINT REFERENCES categoria(id_categoria),
    nombre             VARCHAR(60) NOT NULL UNIQUE,
    slug               VARCHAR(80) NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    descripcion        VARCHAR(200),
    icono              VARCHAR(40),
    orden              SMALLINT    NOT NULL DEFAULT 0,
    activa             BOOLEAN     NOT NULL DEFAULT TRUE,
    creado_en          TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE producto (
    id_producto         BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_categoria        SMALLINT     NOT NULL REFERENCES categoria(id_categoria),  -- no se borra una categoría con productos
    nombre              VARCHAR(150) NOT NULL CHECK (length(btrim(nombre)) > 0),
    slug                VARCHAR(180) NOT NULL UNIQUE CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
    descripcion         TEXT,
    precio_base         NUMERIC(10,2) NOT NULL CHECK (precio_base >= 0),   -- incluye IGV
    tipo_fabricacion    VARCHAR(10)  NOT NULL DEFAULT 'stock' CHECK (tipo_fabricacion IN ('stock','a_pedido')),
    dias_produccion     SMALLINT     NOT NULL DEFAULT 0 CHECK (dias_produccion >= 0),
    destacado           BOOLEAN      NOT NULL DEFAULT FALSE,
    estado              VARCHAR(10)  NOT NULL DEFAULT 'borrador' CHECK (estado IN ('borrador','activo','archivado')),
    valoracion_promedio NUMERIC(2,1) NOT NULL DEFAULT 0,
    total_resenas       INTEGER      NOT NULL DEFAULT 0,
    busqueda            TSVECTOR GENERATED ALWAYS AS
        (to_tsvector('spanish', f_unaccent(nombre || ' ' || coalesce(descripcion, '')))) STORED,
    creado_en           TIMESTAMPTZ  NOT NULL DEFAULT now(),
    actualizado_en      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (tipo_fabricacion = 'stock' OR dias_produccion > 0)
);
CREATE INDEX idx_producto_categoria ON producto(id_categoria) WHERE estado = 'activo';
CREATE INDEX idx_producto_busqueda  ON producto USING gin (busqueda);
CREATE INDEX idx_producto_nombre_trgm ON producto USING gin (f_unaccent(nombre) gin_trgm_ops);

CREATE TABLE variante_producto (
    id_variante      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_producto      BIGINT       NOT NULL REFERENCES producto(id_producto),
    sku              VARCHAR(40)  NOT NULL UNIQUE,
    talla            VARCHAR(20),
    color            VARCHAR(30),
    precio           NUMERIC(10,2) CHECK (precio >= 0),            -- NULL = usa precio_base
    stock_actual     INTEGER      NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    stock_reservado  INTEGER      NOT NULL DEFAULT 0 CHECK (stock_reservado >= 0),
    stock_disponible INTEGER GENERATED ALWAYS AS (stock_actual - stock_reservado) STORED,
    stock_minimo     INTEGER      NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
    activo           BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en        TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (stock_reservado <= stock_actual)
);
CREATE UNIQUE INDEX uq_variante_combinacion
    ON variante_producto(id_producto, coalesce(talla, ''), coalesce(color, ''));

CREATE TABLE imagen_producto (
    id_imagen   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_producto BIGINT       NOT NULL REFERENCES producto(id_producto),
    id_variante BIGINT       REFERENCES variante_producto(id_variante),
    url         VARCHAR(300) NOT NULL,
    texto_alt   VARCHAR(150),
    orden       SMALLINT     NOT NULL DEFAULT 0,
    principal   BOOLEAN      NOT NULL DEFAULT FALSE,
    creado_en   TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_imagen_principal ON imagen_producto(id_producto) WHERE principal;

-- Precios por volumen (venta al por mayor)
CREATE TABLE precio_volumen (
    id_precio_volumen BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_producto       BIGINT        NOT NULL REFERENCES producto(id_producto),
    cantidad_minima   INTEGER       NOT NULL CHECK (cantidad_minima >= 2),
    precio_unitario   NUMERIC(10,2) NOT NULL CHECK (precio_unitario > 0),
    UNIQUE (id_producto, cantidad_minima)
);

-- Kardex de productos terminados (solo inserción)
CREATE TABLE movimiento_stock (
    id_movimiento               BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_variante                 BIGINT      NOT NULL REFERENCES variante_producto(id_variante),
    tipo                        VARCHAR(20) NOT NULL
        CHECK (tipo IN ('ingreso','reserva','liberacion_reserva','venta','devolucion','ajuste')),
    cantidad                    INTEGER     NOT NULL CHECK (cantidad <> 0),
    stock_actual_resultante     INTEGER     NOT NULL,
    stock_reservado_resultante  INTEGER     NOT NULL,
    id_pedido                   BIGINT,                                  -- FK más abajo
    id_usuario                  BIGINT REFERENCES usuario(id_usuario),
    motivo                      VARCHAR(200),
    creado_en                   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_mov_stock_variante ON movimiento_stock(id_variante, creado_en DESC);

-- ---------------------------------------------------------------------
-- 2. INSUMOS (hilos, telas, bastidores)  HU-13
-- ---------------------------------------------------------------------
CREATE TABLE insumo (
    id_insumo    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre       VARCHAR(120) NOT NULL UNIQUE,
    tipo         VARCHAR(15)  NOT NULL CHECK (tipo IN ('hilo','tela','bastidor','otro')),
    unidad       VARCHAR(15)  NOT NULL,
    stock_actual NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (stock_actual >= 0),
    stock_minimo NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (stock_minimo >= 0),
    activo       BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en    TIMESTAMPTZ  NOT NULL DEFAULT now()
);

CREATE TABLE movimiento_insumo (
    id_movimiento BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_insumo     BIGINT       NOT NULL REFERENCES insumo(id_insumo),
    tipo          VARCHAR(10)  NOT NULL CHECK (tipo IN ('ingreso','consumo','ajuste')),
    cantidad      NUMERIC(12,2) NOT NULL CHECK (cantidad <> 0),
    id_usuario    BIGINT REFERENCES usuario(id_usuario),
    motivo        VARCHAR(200),
    creado_en     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- 3. ENVÍO Y DIRECCIONES
-- ---------------------------------------------------------------------
CREATE TABLE zona_envio (
    id_zona        SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    nombre         VARCHAR(80)  NOT NULL UNIQUE,
    costo          NUMERIC(8,2) NOT NULL CHECK (costo >= 0),
    dias_estimados SMALLINT     NOT NULL DEFAULT 1 CHECK (dias_estimados >= 0),
    activa         BOOLEAN      NOT NULL DEFAULT TRUE
);

CREATE TABLE direccion (
    id_direccion    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario      BIGINT       NOT NULL REFERENCES usuario(id_usuario),
    alias           VARCHAR(40)  NOT NULL,
    nombre_receptor VARCHAR(120) NOT NULL,
    telefono        VARCHAR(16)  NOT NULL CHECK (telefono ~ '^\+?[0-9]{9,15}$'),
    direccion       VARCHAR(200) NOT NULL,
    distrito        VARCHAR(80)  NOT NULL,
    id_zona         SMALLINT     NOT NULL REFERENCES zona_envio(id_zona),
    referencia      VARCHAR(200),
    predeterminada  BOOLEAN      NOT NULL DEFAULT FALSE,
    activa          BOOLEAN      NOT NULL DEFAULT TRUE,
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_direccion_usuario ON direccion(id_usuario) WHERE activa;
CREATE UNIQUE INDEX uq_direccion_predeterminada ON direccion(id_usuario) WHERE predeterminada AND activa;

-- ---------------------------------------------------------------------
-- 4. CARRITO Y FAVORITOS  (el precio NUNCA se guarda en el carrito)
-- ---------------------------------------------------------------------
CREATE TABLE carrito (
    id_carrito     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario     BIGINT      NOT NULL REFERENCES usuario(id_usuario),
    estado         VARCHAR(12) NOT NULL DEFAULT 'activo' CHECK (estado IN ('activo','convertido','abandonado')),
    creado_en      TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX uq_carrito_activo ON carrito(id_usuario) WHERE estado = 'activo';

CREATE TABLE item_carrito (
    id_item     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_carrito  BIGINT      NOT NULL REFERENCES carrito(id_carrito) ON DELETE CASCADE,
    id_variante BIGINT      NOT NULL REFERENCES variante_producto(id_variante),
    cantidad    INTEGER     NOT NULL CHECK (cantidad > 0),
    agregado_en TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id_carrito, id_variante)
);

CREATE TABLE favorito (
    id_usuario  BIGINT      NOT NULL REFERENCES usuario(id_usuario),
    id_producto BIGINT      NOT NULL REFERENCES producto(id_producto),
    creado_en   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (id_usuario, id_producto)
);

-- ---------------------------------------------------------------------
-- 5. COTIZACIONES (venta por mayor y bordado personalizado)  HU-28 / HU-17 / HU-18
-- ---------------------------------------------------------------------
CREATE TABLE cotizacion (
    id_cotizacion            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero                   VARCHAR(25) NOT NULL UNIQUE,
    id_usuario               BIGINT      NOT NULL REFERENCES usuario(id_usuario),
    origen                   VARCHAR(15) NOT NULL DEFAULT 'mayor' CHECK (origen IN ('mayor','personalizado')),
    estado                   VARCHAR(12) NOT NULL DEFAULT 'solicitada'
        CHECK (estado IN ('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida')),
    descripcion              TEXT        NOT NULL,
    imagen_referencia_url    VARCHAR(300),
    fecha_entrega_solicitada DATE,
    subtotal                 NUMERIC(12,2) CHECK (subtotal >= 0),
    costo_envio              NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (costo_envio >= 0),
    total                    NUMERIC(12,2) CHECK (total >= 0),
    adelanto_porcentaje      NUMERIC(5,2)  CHECK (adelanto_porcentaje BETWEEN 0 AND 100),
    vigencia_hasta           DATE,
    respuesta                TEXT,
    id_admin                 BIGINT REFERENCES usuario(id_usuario),
    id_pedido                BIGINT,                                     -- FK más abajo
    creado_en                TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (estado NOT IN ('cotizada','aceptada','convertida') OR total IS NOT NULL)
);
CREATE INDEX idx_cotizacion_usuario ON cotizacion(id_usuario, creado_en DESC);
CREATE INDEX idx_cotizacion_estado  ON cotizacion(estado);

CREATE TABLE item_cotizacion (
    id_item_cotizacion BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_cotizacion      BIGINT       NOT NULL REFERENCES cotizacion(id_cotizacion) ON DELETE CASCADE,
    id_variante        BIGINT       REFERENCES variante_producto(id_variante),
    descripcion        VARCHAR(250) NOT NULL,
    cantidad           INTEGER      NOT NULL CHECK (cantidad > 0),
    precio_unitario    NUMERIC(10,2) CHECK (precio_unitario >= 0),
    subtotal           NUMERIC(12,2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED
);

-- ---------------------------------------------------------------------
-- 6. PEDIDOS
-- ---------------------------------------------------------------------
CREATE TABLE pedido (
    id_pedido                BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero                   VARCHAR(25) NOT NULL UNIQUE,
    id_usuario               BIGINT      NOT NULL REFERENCES usuario(id_usuario),
    id_pedido_origen         BIGINT      REFERENCES pedido(id_pedido),   -- pedido complementario (HU-29)
    id_cotizacion            BIGINT      REFERENCES cotizacion(id_cotizacion),
    tipo_venta               VARCHAR(5)  NOT NULL DEFAULT 'menor' CHECK (tipo_venta IN ('menor','mayor')),
    canal                    VARCHAR(10) NOT NULL DEFAULT 'web'   CHECK (canal IN ('web','presencial')),
    estado                   VARCHAR(15) NOT NULL DEFAULT 'pendiente_pago'
        CHECK (estado IN ('pendiente_pago','confirmado','en_preparacion','en_produccion','listo',
                          'enviado','entregado','cancelado','devuelto')),
    estado_pago              VARCHAR(12) NOT NULL DEFAULT 'pendiente'
        CHECK (estado_pago IN ('pendiente','parcial','pagado','reembolsado')),
    tipo_entrega             VARCHAR(10) NOT NULL CHECK (tipo_entrega IN ('recojo','domicilio')),
    -- Copia (snapshot) de la entrega: si el cliente edita su dirección, el pedido no cambia
    entrega_nombre           VARCHAR(120),
    entrega_telefono         VARCHAR(16),
    entrega_direccion        VARCHAR(200),
    entrega_distrito         VARCHAR(80),
    entrega_referencia       VARCHAR(200),
    id_zona                  SMALLINT    REFERENCES zona_envio(id_zona),
    subtotal                 NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    descuento                NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (descuento >= 0),
    costo_envio              NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (costo_envio >= 0),
    total                    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (total >= 0),
    monto_pagado             NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (monto_pagado >= 0),
    saldo                    NUMERIC(12,2) GENERATED ALWAYS AS (total - monto_pagado) STORED,
    moneda                   CHAR(3)     NOT NULL DEFAULT 'PEN',
    fecha_entrega_solicitada DATE,
    fecha_entrega_estimada   DATE,
    courier                  VARCHAR(40),
    numero_guia              VARCHAR(60),
    notas                    VARCHAR(500),
    motivo_cancelacion       VARCHAR(200),
    cancelado_en             TIMESTAMPTZ,
    creado_en                TIMESTAMPTZ NOT NULL DEFAULT now(),
    actualizado_en           TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK (descuento <= subtotal),
    CHECK (total = subtotal - descuento + costo_envio),
    CHECK (monto_pagado <= total),
    CHECK (estado IN ('pendiente_pago','cancelado') OR subtotal > 0),      -- no se cobra un carrito vacío
    CHECK (estado <> 'cancelado' OR cancelado_en IS NOT NULL),
    CHECK (tipo_entrega = 'recojo' OR (entrega_nombre IS NOT NULL AND entrega_telefono IS NOT NULL
                                       AND entrega_direccion IS NOT NULL AND id_zona IS NOT NULL))
);
CREATE INDEX idx_pedido_usuario ON pedido(id_usuario, creado_en DESC);
CREATE INDEX idx_pedido_estado  ON pedido(estado, creado_en DESC);
CREATE INDEX idx_pedido_fecha   ON pedido(creado_en DESC);

ALTER TABLE cotizacion ADD CONSTRAINT fk_cotizacion_pedido FOREIGN KEY (id_pedido) REFERENCES pedido(id_pedido);
ALTER TABLE movimiento_stock ADD CONSTRAINT fk_movstock_pedido FOREIGN KEY (id_pedido) REFERENCES pedido(id_pedido);

CREATE TABLE item_pedido (
    id_item_pedido  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido       BIGINT       NOT NULL REFERENCES pedido(id_pedido),
    id_variante     BIGINT       REFERENCES variante_producto(id_variante),
    nombre_producto VARCHAR(150) NOT NULL,                  -- copia del nombre y precio al momento de la compra
    sku             VARCHAR(40),
    talla           VARCHAR(20),
    color           VARCHAR(30),
    cantidad        INTEGER      NOT NULL CHECK (cantidad > 0),
    precio_unitario NUMERIC(10,2) NOT NULL CHECK (precio_unitario >= 0),
    subtotal        NUMERIC(12,2) GENERATED ALWAYS AS (cantidad * precio_unitario) STORED,
    personalizacion VARCHAR(500),
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_item_pedido ON item_pedido(id_pedido);
CREATE INDEX idx_item_variante ON item_pedido(id_variante);
CREATE UNIQUE INDEX uq_item_pedido_variante ON item_pedido(id_pedido, id_variante) WHERE id_variante IS NOT NULL;

-- Flujo de estados permitido (una sola fuente de verdad para cliente y administrador)
CREATE TABLE transicion_estado_pedido (
    de VARCHAR(15) NOT NULL,
    a  VARCHAR(15) NOT NULL,
    PRIMARY KEY (de, a)
);

CREATE TABLE historial_estado_pedido (
    id_historial    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido       BIGINT      NOT NULL REFERENCES pedido(id_pedido),
    estado_anterior VARCHAR(15),
    estado_nuevo    VARCHAR(15) NOT NULL,
    id_usuario      BIGINT REFERENCES usuario(id_usuario),
    comentario      VARCHAR(200),
    creado_en       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_hist_pedido ON historial_estado_pedido(id_pedido, creado_en);

-- ---------------------------------------------------------------------
-- 7. PAGOS
-- ---------------------------------------------------------------------
CREATE TABLE pago (
    id_pago            BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido          BIGINT        NOT NULL REFERENCES pedido(id_pedido),
    metodo             VARCHAR(15)   NOT NULL
        CHECK (metodo IN ('mercadopago','paypal','yape','plin','transferencia','efectivo')),
    tipo               VARCHAR(10)   NOT NULL CHECK (tipo IN ('adelanto','saldo','total')),
    monto              NUMERIC(12,2) NOT NULL CHECK (monto > 0),
    moneda             CHAR(3)       NOT NULL DEFAULT 'PEN',
    estado             VARCHAR(12)   NOT NULL DEFAULT 'pendiente'
        CHECK (estado IN ('pendiente','en_revision','confirmado','rechazado','fallido','reembolsado')),
    referencia_externa VARCHAR(100),                       -- id de la pasarela o N.º de operación Yape/Plin/banco
    idempotency_key    VARCHAR(100) UNIQUE,                -- evita cobros duplicados por reintentos
    voucher_url        VARCHAR(300),                       -- captura del Yape/Plin/transferencia
    datos_pasarela     JSONB         NOT NULL DEFAULT '{}'::jsonb,   -- nunca datos de tarjeta
    validado_por       BIGINT REFERENCES usuario(id_usuario),
    validado_en        TIMESTAMPTZ,
    motivo_rechazo     VARCHAR(200),
    ip                 INET,
    confirmado_en      TIMESTAMPTZ,
    creado_en          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    actualizado_en     TIMESTAMPTZ   NOT NULL DEFAULT now(),
    -- Yape, Plin, transferencia y efectivo solo los confirma un administrador
    CHECK (estado <> 'confirmado' OR metodo IN ('mercadopago','paypal') OR validado_por IS NOT NULL),
    CHECK (metodo NOT IN ('yape','plin','transferencia') OR estado IN ('pendiente','rechazado') OR voucher_url IS NOT NULL)
);
CREATE INDEX idx_pago_pedido ON pago(id_pedido);
CREATE INDEX idx_pago_estado ON pago(estado, creado_en DESC);
-- La misma operación Yape/Plin/banco no puede usarse dos veces
CREATE UNIQUE INDEX uq_pago_operacion ON pago(metodo, referencia_externa)
    WHERE referencia_externa IS NOT NULL AND estado IN ('pendiente','en_revision','confirmado');

-- Notificaciones entrantes (webhooks) de pasarelas y proveedor de comprobantes
CREATE TABLE evento_pasarela (
    id_evento   UUID PRIMARY KEY DEFAULT uuidv7(),
    proveedor   VARCHAR(20)  NOT NULL CHECK (proveedor IN ('mercadopago','paypal','ose')),
    id_externo  VARCHAR(100) NOT NULL,
    tipo        VARCHAR(60),
    payload     JSONB        NOT NULL,
    procesado   BOOLEAN      NOT NULL DEFAULT FALSE,
    error       TEXT,
    recibido_en TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (proveedor, id_externo)                          -- cada webhook se procesa una sola vez
);

-- ---------------------------------------------------------------------
-- 8. COMPROBANTES ELECTRÓNICOS (proveedor OSE/PSE autorizado por SUNAT)
-- ---------------------------------------------------------------------
CREATE TABLE serie_comprobante (
    id_serie           SMALLINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tipo               VARCHAR(15) NOT NULL CHECK (tipo IN ('boleta','factura','nota_credito')),
    serie              CHAR(4)     NOT NULL,
    ultimo_correlativo INTEGER     NOT NULL DEFAULT 0,
    activa             BOOLEAN     NOT NULL DEFAULT TRUE,
    UNIQUE (tipo, serie)
);

CREATE TABLE comprobante (
    id_comprobante     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_pedido          BIGINT       NOT NULL REFERENCES pedido(id_pedido),
    tipo               VARCHAR(15)  NOT NULL CHECK (tipo IN ('boleta','factura','nota_credito')),
    serie              CHAR(4)      NOT NULL,
    correlativo        INTEGER      NOT NULL CHECK (correlativo > 0),
    id_comprobante_ref BIGINT REFERENCES comprobante(id_comprobante),     -- la nota de crédito apunta al comprobante anulado
    motivo             VARCHAR(200),
    cliente_tipo_doc   VARCHAR(3)   CHECK (cliente_tipo_doc IN ('DNI','RUC','CE')),
    cliente_num_doc    VARCHAR(15),
    cliente_nombre     VARCHAR(200) NOT NULL,
    cliente_direccion  VARCHAR(250),
    op_gravada         NUMERIC(12,2) NOT NULL CHECK (op_gravada >= 0),
    igv                NUMERIC(12,2) NOT NULL CHECK (igv >= 0),
    total              NUMERIC(12,2) NOT NULL CHECK (total > 0),
    moneda             CHAR(3)      NOT NULL DEFAULT 'PEN',
    estado_sunat       VARCHAR(10)  NOT NULL DEFAULT 'pendiente'
        CHECK (estado_sunat IN ('pendiente','aceptado','rechazado','anulado','error')),
    proveedor          VARCHAR(30),
    id_externo         VARCHAR(100),
    hash_cpe           VARCHAR(100),
    url_pdf            VARCHAR(300),
    url_xml            VARCHAR(300),
    url_cdr            VARCHAR(300),
    mensaje_sunat      TEXT,
    enviado_correo_en  TIMESTAMPTZ,
    emitido_en         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (serie, correlativo),
    CHECK (op_gravada + igv = total),
    CHECK ((tipo = 'boleta' AND serie ~ '^B') OR (tipo = 'factura' AND serie ~ '^F') OR tipo = 'nota_credito'),
    CHECK (tipo <> 'factura' OR (cliente_tipo_doc = 'RUC' AND cliente_num_doc IS NOT NULL)),
    CHECK (tipo <> 'nota_credito' OR id_comprobante_ref IS NOT NULL)
);
CREATE INDEX idx_comprobante_pedido ON comprobante(id_pedido);

-- ---------------------------------------------------------------------
-- 9. ATENCIÓN AL CLIENTE: contacto, reclamos, banners, reseñas
-- ---------------------------------------------------------------------
CREATE TABLE mensaje_contacto (
    id_mensaje     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    ticket         VARCHAR(25)  NOT NULL UNIQUE,
    id_usuario     BIGINT REFERENCES usuario(id_usuario),
    nombre         VARCHAR(100) NOT NULL,
    correo         CITEXT       NOT NULL,
    celular        VARCHAR(16),
    asunto         VARCHAR(20)  NOT NULL
        CHECK (asunto IN ('producto','pedido','mayor','sugerencia','otro')),
    id_pedido      BIGINT REFERENCES pedido(id_pedido),
    mensaje        VARCHAR(2000) NOT NULL CHECK (length(btrim(mensaje)) >= 10),
    acepto_datos   BOOLEAN      NOT NULL CHECK (acepto_datos),
    ip             INET,
    estado         VARCHAR(12)  NOT NULL DEFAULT 'nuevo' CHECK (estado IN ('nuevo','en_proceso','respondido','cerrado')),
    respuesta      TEXT,
    respondido_por BIGINT REFERENCES usuario(id_usuario),
    respondido_en  TIMESTAMPTZ,
    creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_mensaje_estado ON mensaje_contacto(estado, creado_en DESC);
CREATE INDEX idx_mensaje_ip ON mensaje_contacto(ip, creado_en DESC);

-- Libro de Reclamaciones virtual
CREATE TABLE reclamo (
    id_reclamo     BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    numero         VARCHAR(25)  NOT NULL UNIQUE,
    id_usuario     BIGINT REFERENCES usuario(id_usuario),
    nombres        VARCHAR(100) NOT NULL,
    apellidos      VARCHAR(100) NOT NULL,
    tipo_doc       VARCHAR(3)   NOT NULL CHECK (tipo_doc IN ('DNI','RUC','CE')),
    num_doc        VARCHAR(15)  NOT NULL,
    direccion      VARCHAR(200) NOT NULL,
    correo         CITEXT       NOT NULL,
    celular        VARCHAR(16)  NOT NULL,
    tipo_bien      VARCHAR(10)  NOT NULL CHECK (tipo_bien IN ('producto','servicio')),
    monto_reclamado NUMERIC(12,2) CHECK (monto_reclamado >= 0),
    descripcion_bien VARCHAR(300) NOT NULL,
    tipo           VARCHAR(10)  NOT NULL CHECK (tipo IN ('reclamo','queja')),
    detalle        TEXT         NOT NULL,
    pedido_consumidor TEXT      NOT NULL,
    id_pedido      BIGINT REFERENCES pedido(id_pedido),
    estado         VARCHAR(12)  NOT NULL DEFAULT 'registrado' CHECK (estado IN ('registrado','en_atencion','respondido')),
    respuesta      TEXT,
    respondido_por BIGINT REFERENCES usuario(id_usuario),
    respondido_en  TIMESTAMPTZ,
    fecha_limite   DATE         NOT NULL DEFAULT ((now() AT TIME ZONE 'America/Lima')::date + 30),
    creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_reclamo_estado ON reclamo(estado, fecha_limite);

CREATE TABLE banner (
    id_banner      BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    titulo         VARCHAR(120) NOT NULL,
    subtitulo      VARCHAR(200),
    imagen_url     VARCHAR(300) NOT NULL,
    enlace         VARCHAR(200),
    texto_boton    VARCHAR(40),
    orden          SMALLINT     NOT NULL DEFAULT 0,
    activo         BOOLEAN      NOT NULL DEFAULT TRUE,
    vigente_desde  TIMESTAMPTZ,
    vigente_hasta  TIMESTAMPTZ,
    creado_en      TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CHECK (vigente_hasta IS NULL OR vigente_desde IS NULL OR vigente_hasta > vigente_desde)
);

CREATE TABLE resena (
    id_resena    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_producto  BIGINT      NOT NULL REFERENCES producto(id_producto),
    id_usuario   BIGINT      NOT NULL REFERENCES usuario(id_usuario),
    id_pedido    BIGINT      NOT NULL REFERENCES pedido(id_pedido),     -- solo reseña quien compró y recibió
    calificacion SMALLINT    NOT NULL CHECK (calificacion BETWEEN 1 AND 5),
    titulo       VARCHAR(100),
    comentario   VARCHAR(1000),
    estado       VARCHAR(10) NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','publicada','oculta')),
    creado_en    TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (id_producto, id_usuario)
);

-- ---------------------------------------------------------------------
-- 10. COLA DE CORREOS Y NOTIFICACIONES (envío desacoplado, RNF 18)
-- ---------------------------------------------------------------------
CREATE TABLE cola_correo (
    id_correo     UUID PRIMARY KEY DEFAULT uuidv7(),
    id_usuario    BIGINT REFERENCES usuario(id_usuario),
    destinatario  CITEXT       NOT NULL,
    plantilla     VARCHAR(60)  NOT NULL,
    contexto      JSONB        NOT NULL DEFAULT '{}'::jsonb,
    estado        VARCHAR(10)  NOT NULL DEFAULT 'pendiente' CHECK (estado IN ('pendiente','enviado','error')),
    intentos      SMALLINT     NOT NULL DEFAULT 0,
    error         TEXT,
    programado_en TIMESTAMPTZ  NOT NULL DEFAULT now(),
    enviado_en    TIMESTAMPTZ,
    creado_en     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_cola_pendiente ON cola_correo(programado_en) WHERE estado = 'pendiente';

CREATE TABLE notificacion (
    id_notificacion BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    id_usuario      BIGINT       NOT NULL REFERENCES usuario(id_usuario),
    tipo            VARCHAR(30)  NOT NULL,
    titulo          VARCHAR(120) NOT NULL,
    mensaje         VARCHAR(300),
    id_pedido       BIGINT REFERENCES pedido(id_pedido),
    leida           BOOLEAN      NOT NULL DEFAULT FALSE,
    creado_en       TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE INDEX idx_notif_usuario ON notificacion(id_usuario, leida, creado_en DESC);

-- =====================================================================
-- FUNCIONES
-- =====================================================================

-- Número correlativo por año, sin saltos: BW-2026-000001
CREATE FUNCTION fn_siguiente_numero(p_prefijo VARCHAR, p_ancho INTEGER DEFAULT 6)
RETURNS VARCHAR LANGUAGE plpgsql AS $$
DECLARE
    v_anio SMALLINT := EXTRACT(YEAR FROM (now() AT TIME ZONE 'America/Lima'))::SMALLINT;
    v_n    INTEGER;
BEGIN
    INSERT INTO secuencia_documento(prefijo, anio, ultimo) VALUES (p_prefijo, v_anio, 1)
    ON CONFLICT (prefijo, anio) DO UPDATE SET ultimo = secuencia_documento.ultimo + 1
    RETURNING ultimo INTO v_n;
    RETURN p_prefijo || '-' || v_anio || '-' || lpad(v_n::text, p_ancho, '0');
END $$;

-- Correlativo de comprobante (por serie)
CREATE FUNCTION fn_siguiente_correlativo(p_tipo VARCHAR, p_serie CHAR(4))
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v INTEGER;
BEGIN
    UPDATE serie_comprobante SET ultimo_correlativo = ultimo_correlativo + 1
     WHERE tipo = p_tipo AND serie = p_serie AND activa
    RETURNING ultimo_correlativo INTO v;
    IF v IS NULL THEN
        RAISE EXCEPTION 'La serie % (%) no existe o está inactiva', p_serie, p_tipo;
    END IF;
    RETURN v;
END $$;

-- IGV incluido en un total (tasa configurable)
CREATE FUNCTION fn_igv_incluido(p_total NUMERIC) RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT round(p_total - p_total / (1 + (SELECT valor::numeric FROM configuracion WHERE clave = 'igv_porcentaje') / 100), 2);
$$;

-- Movimiento de stock atómico (bloquea la fila: no hay sobreventa)
CREATE FUNCTION fn_ajustar_stock(p_id_variante BIGINT, p_tipo VARCHAR, p_cantidad INTEGER,
                                 p_id_pedido BIGINT DEFAULT NULL, p_id_usuario BIGINT DEFAULT NULL,
                                 p_motivo VARCHAR DEFAULT NULL)
RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE v variante_producto%ROWTYPE;
BEGIN
    SELECT * INTO v FROM variante_producto WHERE id_variante = p_id_variante FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La variante % no existe', p_id_variante;
    END IF;
    IF p_tipo <> 'ajuste' AND p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad debe ser positiva';
    END IF;

    IF p_tipo IN ('ingreso','devolucion') THEN
        v.stock_actual := v.stock_actual + p_cantidad;
    ELSIF p_tipo = 'reserva' THEN
        IF v.stock_actual - v.stock_reservado < p_cantidad THEN
            RAISE EXCEPTION 'Stock insuficiente para % (disponible: %)', v.sku, v.stock_actual - v.stock_reservado
                USING ERRCODE = '23514';
        END IF;
        v.stock_reservado := v.stock_reservado + p_cantidad;
    ELSIF p_tipo = 'liberacion_reserva' THEN
        IF v.stock_reservado < p_cantidad THEN
            RAISE EXCEPTION 'No hay tantas unidades reservadas de %', v.sku;
        END IF;
        v.stock_reservado := v.stock_reservado - p_cantidad;
    ELSIF p_tipo = 'venta' THEN
        IF v.stock_reservado < p_cantidad THEN
            RAISE EXCEPTION 'No hay tantas unidades reservadas de %', v.sku;
        END IF;
        v.stock_actual    := v.stock_actual    - p_cantidad;
        v.stock_reservado := v.stock_reservado - p_cantidad;
    ELSIF p_tipo = 'ajuste' THEN
        IF p_cantidad = 0 THEN RAISE EXCEPTION 'El ajuste no puede ser cero'; END IF;
        v.stock_actual := v.stock_actual + p_cantidad;
    ELSE
        RAISE EXCEPTION 'Tipo de movimiento inválido: %', p_tipo;
    END IF;

    UPDATE variante_producto SET stock_actual = v.stock_actual, stock_reservado = v.stock_reservado
     WHERE id_variante = p_id_variante;
    INSERT INTO movimiento_stock(id_variante, tipo, cantidad, stock_actual_resultante,
                                 stock_reservado_resultante, id_pedido, id_usuario, motivo)
    VALUES (p_id_variante, p_tipo, p_cantidad, v.stock_actual, v.stock_reservado,
            p_id_pedido, p_id_usuario, p_motivo);
    RETURN v.stock_actual;
END $$;

-- Movimiento de insumos
CREATE FUNCTION fn_ajustar_insumo(p_id_insumo BIGINT, p_tipo VARCHAR, p_cantidad NUMERIC,
                                  p_id_usuario BIGINT DEFAULT NULL, p_motivo VARCHAR DEFAULT NULL)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_nuevo NUMERIC;
BEGIN
    IF p_tipo = 'consumo' THEN
        UPDATE insumo SET stock_actual = stock_actual - p_cantidad WHERE id_insumo = p_id_insumo RETURNING stock_actual INTO v_nuevo;
    ELSE
        UPDATE insumo SET stock_actual = stock_actual + p_cantidad WHERE id_insumo = p_id_insumo RETURNING stock_actual INTO v_nuevo;
    END IF;
    IF v_nuevo IS NULL THEN RAISE EXCEPTION 'El insumo % no existe', p_id_insumo; END IF;
    INSERT INTO movimiento_insumo(id_insumo, tipo, cantidad, id_usuario, motivo)
    VALUES (p_id_insumo, p_tipo, p_cantidad, p_id_usuario, p_motivo);
    RETURN v_nuevo;
END $$;

-- Recalcula subtotal y total del pedido a partir de sus ítems
CREATE FUNCTION fn_recalcular_pedido(p_id_pedido BIGINT) RETURNS VOID LANGUAGE sql AS $$
    UPDATE pedido p
       SET subtotal  = s.sub,
           descuento = LEAST(p.descuento, s.sub),
           total     = s.sub - LEAST(p.descuento, s.sub) + p.costo_envio
      FROM (SELECT coalesce(sum(subtotal), 0) AS sub FROM item_pedido WHERE id_pedido = p_id_pedido) s
     WHERE p.id_pedido = p_id_pedido;
$$;

-- Cancela pedidos sin pago pasado el plazo de reserva (ejecutar cada pocos minutos)
CREATE FUNCTION fn_expirar_pedidos_pendientes() RETURNS INTEGER LANGUAGE plpgsql AS $$
DECLARE
    v_horas INTEGER := (SELECT valor::integer FROM configuracion WHERE clave = 'horas_reserva_pedido');
    n INTEGER;
BEGIN
    WITH x AS (
        UPDATE pedido SET estado = 'cancelado', motivo_cancelacion = 'Expirado por falta de pago'
         WHERE estado = 'pendiente_pago'
           AND creado_en < now() - make_interval(hours => v_horas)
           AND NOT EXISTS (SELECT 1 FROM pago pg WHERE pg.id_pedido = pedido.id_pedido AND pg.estado = 'en_revision')
        RETURNING 1)
    SELECT count(*) INTO n FROM x;
    RETURN n;
END $$;

-- Mantenimiento de colas y registros temporales
CREATE FUNCTION fn_limpiar_tienda() RETURNS VOID LANGUAGE sql AS $$
    UPDATE carrito SET estado = 'abandonado'
     WHERE estado = 'activo' AND actualizado_en < now() - interval '30 days';
    DELETE FROM cola_correo WHERE estado = 'enviado' AND enviado_en < now() - interval '30 days';
    DELETE FROM evento_pasarela WHERE procesado AND recibido_en < now() - interval '180 days';
$$;

-- =====================================================================
-- TRIGGERS
-- =====================================================================

-- Fecha de actualización (producto, carrito, cotización)
CREATE FUNCTION fn_tocar_actualizado() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN NEW.actualizado_en := now(); RETURN NEW; END $$;
CREATE TRIGGER trg_producto_upd  BEFORE UPDATE ON producto   FOR EACH ROW EXECUTE FUNCTION fn_tocar_actualizado();
CREATE TRIGGER trg_carrito_upd   BEFORE UPDATE ON carrito    FOR EACH ROW EXECUTE FUNCTION fn_tocar_actualizado();
CREATE TRIGGER trg_cotiz_upd     BEFORE UPDATE ON cotizacion FOR EACH ROW EXECUTE FUNCTION fn_tocar_actualizado();

-- Solo una dirección predeterminada por cliente
CREATE FUNCTION fn_direccion_unica() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.predeterminada AND NEW.activa THEN
        UPDATE direccion SET predeterminada = FALSE
         WHERE id_usuario = NEW.id_usuario AND predeterminada
           AND id_direccion <> coalesce(NEW.id_direccion, 0);
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_direccion_unica BEFORE INSERT OR UPDATE ON direccion
    FOR EACH ROW EXECUTE FUNCTION fn_direccion_unica();

-- Numeración automática
CREATE FUNCTION fn_numerar() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'pedido' THEN
        NEW.numero := fn_siguiente_numero(CASE WHEN NEW.tipo_venta = 'mayor' THEN 'BW-MAY' ELSE 'BW' END);
    ELSIF TG_TABLE_NAME = 'cotizacion' THEN
        NEW.numero := fn_siguiente_numero('CT', 4);
    ELSIF TG_TABLE_NAME = 'mensaje_contacto' THEN
        NEW.ticket := fn_siguiente_numero('TK');
    ELSIF TG_TABLE_NAME = 'reclamo' THEN
        NEW.numero := fn_siguiente_numero('LR');
    END IF;
    RETURN NEW;
END $$;

-- Pedido: validaciones, numeración y flujo de estados
CREATE FUNCTION fn_pedido_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_dias INTEGER; v_req NUMERIC;
BEGIN
    IF TG_OP = 'INSERT' THEN
        NEW.numero := fn_siguiente_numero(CASE WHEN NEW.tipo_venta = 'mayor' THEN 'BW-MAY' ELSE 'BW' END);
        IF NEW.tipo_venta = 'mayor' THEN
            v_dias := (SELECT valor::integer FROM configuracion WHERE clave = 'dias_minimos_mayor');
            IF NEW.fecha_entrega_solicitada IS NULL
               OR NEW.fecha_entrega_solicitada < (now() AT TIME ZONE 'America/Lima')::date + v_dias THEN
                RAISE EXCEPTION 'Los pedidos al por mayor requieren al menos % días de anticipación', v_dias
                    USING ERRCODE = '23514';
            END IF;
        END IF;
        -- el costo de envío siempre sale de la zona, no del navegador
        IF NEW.tipo_entrega = 'domicilio' THEN
            NEW.costo_envio := (SELECT costo FROM zona_envio WHERE id_zona = NEW.id_zona AND activa);
            IF NEW.costo_envio IS NULL THEN RAISE EXCEPTION 'Zona de envío inválida o inactiva'; END IF;
        ELSE
            NEW.costo_envio := 0;
        END IF;
        NEW.total := NEW.subtotal - NEW.descuento + NEW.costo_envio;
        RETURN NEW;
    END IF;

    -- UPDATE
    IF NEW.numero <> OLD.numero OR NEW.id_usuario <> OLD.id_usuario THEN
        RAISE EXCEPTION 'El número y el cliente de un pedido no se pueden modificar';
    END IF;
    NEW.actualizado_en := now();
    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        IF NOT EXISTS (SELECT 1 FROM transicion_estado_pedido WHERE de = OLD.estado AND a = NEW.estado) THEN
            RAISE EXCEPTION 'Cambio de estado no permitido: % -> %', OLD.estado, NEW.estado USING ERRCODE = '23514';
        END IF;
        IF NEW.estado = 'cancelado' AND NEW.cancelado_en IS NULL THEN
            NEW.cancelado_en := now();
        END IF;
        -- Un pedido solo se confirma con el pago (total, o adelanto en pedidos al por mayor)
        IF NEW.estado = 'confirmado' AND OLD.estado = 'pendiente_pago' THEN
            v_req := CASE WHEN NEW.tipo_venta = 'mayor'
                          THEN round(NEW.total * (SELECT valor::numeric FROM configuracion
                                                   WHERE clave = 'adelanto_mayor_porcentaje') / 100, 2)
                          ELSE NEW.total END;
            IF NEW.monto_pagado <= 0 OR NEW.monto_pagado < v_req THEN
                RAISE EXCEPTION 'No se puede confirmar el pedido sin el pago requerido (S/ %)', v_req
                    USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_pedido_before BEFORE INSERT OR UPDATE ON pedido
    FOR EACH ROW EXECUTE FUNCTION fn_pedido_before();

-- Pedido: historial, stock, auditoría, avisos
CREATE FUNCTION fn_pedido_after() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_actor  BIGINT := NULLIF(current_setting('app.actor_id', true), '')::BIGINT;
    r        RECORD;
    v_correo CITEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO historial_estado_pedido(id_pedido, estado_anterior, estado_nuevo, id_usuario)
        VALUES (NEW.id_pedido, NULL, NEW.estado, coalesce(v_actor, NEW.id_usuario));
        RETURN NULL;
    END IF;

    IF NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO historial_estado_pedido(id_pedido, estado_anterior, estado_nuevo, id_usuario, comentario)
        VALUES (NEW.id_pedido, OLD.estado, NEW.estado, v_actor, NEW.motivo_cancelacion);

        INSERT INTO auditoria(id_usuario_afectado, id_usuario_actor, evento, detalle)
        VALUES (NEW.id_usuario, v_actor, 'pedido_estado',
                jsonb_build_object('pedido', NEW.numero, 'de', OLD.estado, 'a', NEW.estado));

        -- Stock de productos terminados
        IF NEW.estado = 'confirmado' AND OLD.estado = 'pendiente_pago' THEN
            FOR r IN SELECT i.id_variante, i.cantidad
                       FROM item_pedido i
                       JOIN variante_producto v ON v.id_variante = i.id_variante
                       JOIN producto p ON p.id_producto = v.id_producto
                      WHERE i.id_pedido = NEW.id_pedido AND p.tipo_fabricacion = 'stock' LOOP
                PERFORM fn_ajustar_stock(r.id_variante, 'venta', r.cantidad, NEW.id_pedido, v_actor, 'Pedido confirmado');
            END LOOP;
        ELSIF NEW.estado = 'cancelado' THEN
            FOR r IN SELECT i.id_variante, i.cantidad
                       FROM item_pedido i
                       JOIN variante_producto v ON v.id_variante = i.id_variante
                       JOIN producto p ON p.id_producto = v.id_producto
                      WHERE i.id_pedido = NEW.id_pedido AND p.tipo_fabricacion = 'stock' LOOP
                IF OLD.estado = 'pendiente_pago' THEN
                    PERFORM fn_ajustar_stock(r.id_variante, 'liberacion_reserva', r.cantidad, NEW.id_pedido, v_actor, 'Pedido cancelado');
                ELSE
                    PERFORM fn_ajustar_stock(r.id_variante, 'devolucion', r.cantidad, NEW.id_pedido, v_actor, 'Pedido cancelado');
                END IF;
            END LOOP;
        END IF;

        -- Avisos al cliente (correo en cola + notificación en el sistema)
        IF NEW.estado IN ('confirmado','listo','enviado','entregado','cancelado') THEN
            SELECT correo INTO v_correo FROM usuario WHERE id_usuario = NEW.id_usuario;
            INSERT INTO cola_correo(id_usuario, destinatario, plantilla, contexto)
            VALUES (NEW.id_usuario, v_correo, 'pedido_' || NEW.estado,
                    jsonb_build_object('numero', NEW.numero, 'estado', NEW.estado, 'total', NEW.total));
            INSERT INTO notificacion(id_usuario, tipo, titulo, id_pedido)
            VALUES (NEW.id_usuario, 'pedido_' || NEW.estado, 'Tu pedido ' || NEW.numero || ': ' || replace(NEW.estado, '_', ' '), NEW.id_pedido);
        END IF;
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_pedido_after AFTER INSERT OR UPDATE ON pedido
    FOR EACH ROW EXECUTE FUNCTION fn_pedido_after();

-- Ítems: solo editables con el pedido pendiente de pago; reservan stock; recalculan totales
CREATE FUNCTION fn_item_pedido_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_estado VARCHAR;
BEGIN
    SELECT estado INTO v_estado FROM pedido WHERE id_pedido = coalesce(NEW.id_pedido, OLD.id_pedido) FOR UPDATE;
    IF v_estado <> 'pendiente_pago' THEN
        RAISE EXCEPTION 'Los productos de un pedido solo se modifican mientras está pendiente de pago';
    END IF;
    IF TG_OP = 'UPDATE' THEN
        RAISE EXCEPTION 'Los ítems no se editan: elimínelos y agréguelos de nuevo';
    END IF;
    RETURN coalesce(NEW, OLD);
END $$;
CREATE TRIGGER trg_item_pedido_before BEFORE INSERT OR UPDATE OR DELETE ON item_pedido
    FOR EACH ROW EXECUTE FUNCTION fn_item_pedido_before();

CREATE FUNCTION fn_item_pedido_after() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_fab    VARCHAR;
    v_actor  BIGINT := NULLIF(current_setting('app.actor_id', true), '')::BIGINT;
    v_id     BIGINT := coalesce(NEW.id_pedido, OLD.id_pedido);
    v_var    BIGINT := coalesce(NEW.id_variante, OLD.id_variante);
BEGIN
    IF v_var IS NOT NULL THEN
        SELECT p.tipo_fabricacion INTO v_fab
          FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
         WHERE v.id_variante = v_var;
        IF v_fab = 'stock' THEN
            IF TG_OP = 'INSERT' THEN
                PERFORM fn_ajustar_stock(v_var, 'reserva', NEW.cantidad, v_id, v_actor, 'Reserva por pedido');
            ELSE
                PERFORM fn_ajustar_stock(v_var, 'liberacion_reserva', OLD.cantidad, v_id, v_actor, 'Ítem eliminado del pedido');
            END IF;
        END IF;
    END IF;
    PERFORM fn_recalcular_pedido(v_id);
    RETURN NULL;
END $$;
CREATE TRIGGER trg_item_pedido_after AFTER INSERT OR DELETE ON item_pedido
    FOR EACH ROW EXECUTE FUNCTION fn_item_pedido_after();

-- Pagos: control de montos, confirmación y estado del pedido
CREATE FUNCTION fn_pago_before() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_total NUMERIC; v_estado VARCHAR; v_otros NUMERIC;
BEGIN
    NEW.actualizado_en := now();
    IF NEW.estado = 'confirmado' AND (TG_OP = 'INSERT' OR OLD.estado <> 'confirmado') THEN
        NEW.confirmado_en := now();
        SELECT total, estado INTO v_total, v_estado FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
        IF v_estado = 'cancelado' THEN
            RAISE EXCEPTION 'No se puede confirmar un pago de un pedido cancelado';
        END IF;
        SELECT coalesce(sum(monto), 0) INTO v_otros FROM pago
         WHERE id_pedido = NEW.id_pedido AND estado = 'confirmado'
           AND (TG_OP = 'INSERT' OR id_pago <> NEW.id_pago);
        IF v_otros + NEW.monto > v_total THEN
            RAISE EXCEPTION 'El pago (S/ %) excede el saldo del pedido (S/ %)', NEW.monto, v_total - v_otros
                USING ERRCODE = '23514';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_pago_before BEFORE INSERT OR UPDATE ON pago
    FOR EACH ROW EXECUTE FUNCTION fn_pago_before();

CREATE FUNCTION fn_pago_after() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    v_actor    BIGINT := coalesce(NULLIF(current_setting('app.actor_id', true), '')::BIGINT, NEW.validado_por);
    p          pedido%ROWTYPE;
    v_pagado   NUMERIC;
    v_reemb    BOOLEAN;
    v_pct      NUMERIC := (SELECT valor::numeric FROM configuracion WHERE clave = 'adelanto_mayor_porcentaje');
    v_req      NUMERIC;
    v_ep       VARCHAR;
BEGIN
    SELECT * INTO p FROM pedido WHERE id_pedido = NEW.id_pedido FOR UPDATE;
    SELECT coalesce(sum(monto), 0) INTO v_pagado FROM pago WHERE id_pedido = NEW.id_pedido AND estado = 'confirmado';
    SELECT EXISTS (SELECT 1 FROM pago WHERE id_pedido = NEW.id_pedido AND estado = 'reembolsado') INTO v_reemb;

    v_ep := CASE WHEN v_pagado = 0 AND v_reemb THEN 'reembolsado'
                 WHEN v_pagado = 0 THEN 'pendiente'
                 WHEN v_pagado < p.total THEN 'parcial'
                 ELSE 'pagado' END;
    v_req := CASE WHEN p.tipo_venta = 'mayor' THEN round(p.total * v_pct / 100, 2) ELSE p.total END;

    UPDATE pedido
       SET monto_pagado = v_pagado,
           estado_pago  = v_ep,
           estado       = CASE WHEN estado = 'pendiente_pago' AND v_pagado > 0 AND v_pagado >= v_req
                               THEN 'confirmado' ELSE estado END
     WHERE id_pedido = NEW.id_pedido;

    IF TG_OP = 'INSERT' OR NEW.estado IS DISTINCT FROM OLD.estado THEN
        INSERT INTO auditoria(id_usuario_afectado, id_usuario_actor, evento, detalle)
        VALUES (p.id_usuario, v_actor, 'pago_estado',
                jsonb_build_object('pedido', p.numero, 'id_pago', NEW.id_pago, 'metodo', NEW.metodo,
                                   'monto', NEW.monto, 'estado', NEW.estado));
    END IF;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_pago_after AFTER INSERT OR UPDATE ON pago
    FOR EACH ROW EXECUTE FUNCTION fn_pago_after();

-- Reseñas: solo quien compró y recibió; recalcula la valoración del producto
CREATE FUNCTION fn_resena_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM item_pedido i
          JOIN variante_producto v ON v.id_variante = i.id_variante
          JOIN pedido pe ON pe.id_pedido = i.id_pedido
         WHERE pe.id_pedido = NEW.id_pedido AND pe.id_usuario = NEW.id_usuario
           AND v.id_producto = NEW.id_producto AND pe.estado = 'entregado') THEN
        RAISE EXCEPTION 'Solo puede reseñar un producto que compró y recibió' USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER trg_resena_before BEFORE INSERT ON resena FOR EACH ROW EXECUTE FUNCTION fn_resena_before();

CREATE FUNCTION fn_resena_after() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE v_id BIGINT := coalesce(NEW.id_producto, OLD.id_producto);
BEGIN
    UPDATE producto SET
        total_resenas       = (SELECT count(*) FROM resena WHERE id_producto = v_id AND estado = 'publicada'),
        valoracion_promedio = coalesce((SELECT round(avg(calificacion), 1) FROM resena
                                         WHERE id_producto = v_id AND estado = 'publicada'), 0)
     WHERE id_producto = v_id;
    RETURN NULL;
END $$;
CREATE TRIGGER trg_resena_after AFTER INSERT OR UPDATE OR DELETE ON resena
    FOR EACH ROW EXECUTE FUNCTION fn_resena_after();

-- Contacto: ticket y límite de 3 mensajes por hora por IP
CREATE FUNCTION fn_mensaje_before() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.ip IS NOT NULL AND (SELECT count(*) FROM mensaje_contacto
                                WHERE ip = NEW.ip AND creado_en > now() - interval '1 hour') >= 3 THEN
        RAISE EXCEPTION 'Límite de mensajes por hora excedido' USING ERRCODE = '54000';
    END IF;
    NEW.ticket := fn_siguiente_numero('TK');
    RETURN NEW;
END $$;
CREATE TRIGGER trg_mensaje_before BEFORE INSERT ON mensaje_contacto
    FOR EACH ROW EXECUTE FUNCTION fn_mensaje_before();
CREATE TRIGGER trg_reclamo_num BEFORE INSERT ON reclamo FOR EACH ROW EXECUTE FUNCTION fn_numerar();
CREATE TRIGGER trg_cotiz_num   BEFORE INSERT ON cotizacion FOR EACH ROW EXECUTE FUNCTION fn_numerar();

-- Nada financiero ni de inventario se borra; los registros históricos son de solo inserción
CREATE TRIGGER trg_producto_no_delete   BEFORE DELETE ON producto          FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_variante_no_delete   BEFORE DELETE ON variante_producto FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_pedido_no_delete     BEFORE DELETE ON pedido            FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_pago_no_delete       BEFORE DELETE ON pago              FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_comprobante_no_delete BEFORE DELETE ON comprobante      FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_cotizacion_no_delete BEFORE DELETE ON cotizacion        FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_mensaje_no_delete    BEFORE DELETE ON mensaje_contacto  FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_reclamo_no_delete    BEFORE DELETE ON reclamo           FOR EACH ROW EXECUTE FUNCTION fn_prohibir_delete();
CREATE TRIGGER trg_mov_stock_inmutable  BEFORE UPDATE OR DELETE ON movimiento_stock        FOR EACH ROW EXECUTE FUNCTION fn_solo_insercion();
CREATE TRIGGER trg_mov_insumo_inmutable BEFORE UPDATE OR DELETE ON movimiento_insumo       FOR EACH ROW EXECUTE FUNCTION fn_solo_insercion();
CREATE TRIGGER trg_hist_pedido_inmutable BEFORE UPDATE OR DELETE ON historial_estado_pedido FOR EACH ROW EXECUTE FUNCTION fn_solo_insercion();

-- =====================================================================
-- VISTAS (dashboard, reportes e ingresos)
-- =====================================================================
CREATE VIEW v_ingresos_diarios AS
SELECT (timezone('America/Lima', confirmado_en))::date AS fecha, metodo,
       count(*) AS pagos, sum(monto) AS total
  FROM pago WHERE estado = 'confirmado' GROUP BY 1, 2;

CREATE VIEW v_ventas_por_categoria AS
SELECT c.id_categoria, c.nombre AS categoria, sum(i.cantidad) AS unidades, sum(i.subtotal) AS ingresos
  FROM item_pedido i
  JOIN pedido pe ON pe.id_pedido = i.id_pedido
  JOIN variante_producto v ON v.id_variante = i.id_variante
  JOIN producto p ON p.id_producto = v.id_producto
  JOIN categoria c ON c.id_categoria = p.id_categoria
 WHERE pe.estado NOT IN ('pendiente_pago','cancelado','devuelto')
 GROUP BY c.id_categoria, c.nombre;

CREATE VIEW v_productos_mas_vendidos AS
SELECT p.id_producto, p.nombre, sum(i.cantidad) AS unidades, sum(i.subtotal) AS ingresos
  FROM item_pedido i
  JOIN pedido pe ON pe.id_pedido = i.id_pedido
  JOIN variante_producto v ON v.id_variante = i.id_variante
  JOIN producto p ON p.id_producto = v.id_producto
 WHERE pe.estado NOT IN ('pendiente_pago','cancelado','devuelto')
 GROUP BY p.id_producto, p.nombre
 ORDER BY unidades DESC;

CREATE VIEW v_clientes_resumen AS
SELECT u.id_usuario, u.nombre_completo, u.correo, u.celular, u.tipo_documento, u.numero_documento, u.estado,
       count(pe.id_pedido) FILTER (WHERE pe.estado NOT IN ('pendiente_pago','cancelado')) AS pedidos,
       coalesce(sum(pe.total) FILTER (WHERE pe.estado NOT IN ('pendiente_pago','cancelado','devuelto')), 0) AS total_compras
  FROM usuario u
  JOIN rol r ON r.id_rol = u.id_rol AND r.nombre = 'cliente'
  LEFT JOIN pedido pe ON pe.id_usuario = u.id_usuario
 GROUP BY u.id_usuario;

CREATE VIEW v_stock_bajo AS
SELECT v.id_variante, p.nombre, v.sku, v.talla, v.color, v.stock_actual, v.stock_disponible, v.stock_minimo
  FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
 WHERE v.activo AND p.estado = 'activo' AND p.tipo_fabricacion = 'stock' AND v.stock_actual <= v.stock_minimo;

CREATE VIEW v_insumos_stock_bajo AS
SELECT id_insumo, nombre, tipo, unidad, stock_actual, stock_minimo
  FROM insumo WHERE activo AND stock_actual <= stock_minimo;

-- =====================================================================
-- DATOS INICIALES
-- =====================================================================
INSERT INTO categoria (nombre, slug, descripcion, icono, orden) VALUES
    ('Polleras', 'polleras', 'Diseños únicos bordados a mano', 'pollera', 1),
    ('Fajas',    'fajas',    'Tejido tradicional de alta calidad', 'faja', 2),
    ('Chalecos', 'chalecos', 'Elegancia folklórica', 'chaleco', 3);

INSERT INTO zona_envio (nombre, costo, dias_estimados) VALUES
    ('Huancayo Centro', 5.00, 1),
    ('Huancayo Distritos', 10.00, 2),
    ('Otras provincias de Junín', 20.00, 3),
    ('Lima y otras regiones', 35.00, 5);

INSERT INTO configuracion (clave, valor, descripcion) VALUES
    ('empresa_razon_social',   'BORDADOS WANKA S.A.C.', 'Razón social'),
    ('empresa_ruc',            '20615339386', 'RUC'),
    ('empresa_domicilio_fiscal','AV. SAN MARTIN NRO. S/N C.P. COCHARCAS JUNIN - HUANCAYO - SAPALLANGA', 'Domicilio fiscal (va en el comprobante)'),
    ('empresa_direccion_local','Av. Ferrocarril e Ica, Galería La Casona, Stand 240, Huancayo', 'Dirección del local (recojo y contacto)'),
    ('empresa_horario',        'Lun–Sáb 9am–7pm', 'Horario de atención'),
    ('igv_porcentaje',         '18', 'IGV + IPM incluido en los precios'),
    ('dias_minimos_mayor',     '10', 'Días mínimos de anticipación para pedidos al por mayor'),
    ('adelanto_mayor_porcentaje','50', 'Adelanto requerido para confirmar un pedido al por mayor (editable)'),
    ('horas_reserva_pedido',   '24', 'Horas que se reserva el stock de un pedido sin pagar');

INSERT INTO transicion_estado_pedido (de, a) VALUES
    ('pendiente_pago','confirmado'), ('pendiente_pago','cancelado'),
    ('confirmado','en_preparacion'), ('confirmado','en_produccion'), ('confirmado','cancelado'),
    ('en_preparacion','listo'), ('en_preparacion','cancelado'),
    ('en_produccion','listo'),   ('en_produccion','cancelado'),
    ('listo','enviado'), ('listo','entregado'), ('listo','cancelado'),
    ('enviado','entregado'), ('enviado','devuelto'),
    ('entregado','devuelto');

-- Series de ejemplo: las asigna el proveedor OSE/PSE; ajústalas a las reales
INSERT INTO serie_comprobante (tipo, serie) VALUES
    ('boleta','B001'), ('factura','F001'), ('nota_credito','BC01'), ('nota_credito','FC01');

COMMIT;
