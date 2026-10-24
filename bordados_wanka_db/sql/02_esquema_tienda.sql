-- =====================================================================
-- BORDADOS WANKA S.A.C. — 02_esquema_tienda.sql
-- ---------------------------------------------------------------------
-- Propósito : esquema de la TIENDA migrado de PostgreSQL a MySQL 8 y
--             completado: sistema, catálogo, inventario, insumos, envío,
--             carrito, cotizaciones, pedidos, devoluciones, pagos,
--             reembolsos, comprobantes, atención al cliente, colas y
--             bitácoras de APIs externas.
-- Requiere  : 01_esquema_acceso.sql (usuario, rol, auditoria).
-- Re-ejecutable: sí (CREATE TABLE IF NOT EXISTS).
-- COMPAT-MARIADB: mismos cambios que en 01 (REGEXP_LIKE 'c', colación); las columnas
--   generadas STORED con índice único funcionan; JSON es alias de LONGTEXT (agregar CHECK JSON_VALID).
-- Orden de creación pensado para que no haya FK circulares (no se usa
-- ALTER TABLE ... ADD CONSTRAINT).
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';

-- =====================================================================
-- 0. SISTEMA: configuración, numeración, errores, control de frecuencia
-- =====================================================================
CREATE TABLE IF NOT EXISTS configuracion (
  clave              VARCHAR(60)   NOT NULL COMMENT 'Clave única (snake_case)',
  valor              VARCHAR(500)  NOT NULL COMMENT 'Valor como texto; se valida por tipo y rango (trigger)',
  tipo               ENUM('entero','decimal','texto','booleano','opcion','ruc','correo') NOT NULL COMMENT 'Tipo de dato esperado',
  valor_minimo       DECIMAL(14,4) NULL COMMENT 'Mínimo permitido (numéricos)',
  valor_maximo       DECIMAL(14,4) NULL COMMENT 'Máximo permitido (numéricos)',
  opciones           VARCHAR(200)  NULL COMMENT 'Valores permitidos separados por coma (tipo opcion)',
  descripcion        VARCHAR(250)  NOT NULL COMMENT 'Para qué sirve',
  editable           BOOLEAN       NOT NULL DEFAULT 1 COMMENT '0 = solo DBA',
  por_verificar      BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = valor provisional, confirmar con SUNAT/INDECOPI/gerente',
  nota_verificacion  VARCHAR(250)  NULL COMMENT 'Con quién o qué hay que verificarlo',
  actualizado_en     DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  actualizado_por    BIGINT UNSIGNED NULL COMMENT 'Actor de la última modificación (FK usuario)',
  PRIMARY KEY (clave),
  CONSTRAINT fk_config_actualizado FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_config_clave  CHECK (REGEXP_LIKE(clave, '^[a-z][a-z0-9_]{2,59}$', 'c')),
  CONSTRAINT ck_config_rango  CHECK (valor_minimo IS NULL OR valor_maximo IS NULL OR valor_minimo <= valor_maximo),
  CONSTRAINT ck_config_opcion CHECK (tipo <> 'opcion' OR opciones IS NOT NULL),
  CONSTRAINT ck_config_bool   CHECK (editable IN (0,1) AND por_verificar IN (0,1))
) ENGINE=InnoDB COMMENT='Parámetros del negocio validados por tipo y rango (cambios auditados)';

CREATE TABLE IF NOT EXISTS secuencia_documento (
  prefijo  VARCHAR(12)      NOT NULL COMMENT 'Prefijo del correlativo (BW, BW-MAY, CT, TK, LR, DV, ARCO)',
  anio     SMALLINT UNSIGNED NOT NULL COMMENT 'Año (calendario de Lima)',
  ultimo   INT UNSIGNED     NOT NULL DEFAULT 0 COMMENT 'Último número entregado',
  PRIMARY KEY (prefijo, anio),
  CONSTRAINT ck_secuencia_anio CHECK (anio BETWEEN 2024 AND 2200)
) ENGINE=InnoDB COMMENT='Correlativos por año sin saltos (transaccionales, a diferencia de AUTO_INCREMENT)';

CREATE TABLE IF NOT EXISTS catalogo_error (
  codigo          SMALLINT UNSIGNED NOT NULL COMMENT 'MYSQL_ERRNO devuelto por SIGNAL (45001..45099)',
  nombre          VARCHAR(60)  NOT NULL COMMENT 'Nombre técnico',
  mensaje_usuario VARCHAR(200) NOT NULL COMMENT 'Mensaje sugerido para mostrar en la app (RNF 20)',
  http_sugerido   SMALLINT UNSIGNED NOT NULL DEFAULT 400 COMMENT 'Código HTTP sugerido para la API',
  PRIMARY KEY (codigo),
  UNIQUE KEY uq_error_nombre (nombre),
  CONSTRAINT ck_error_rango CHECK (codigo BETWEEN 45000 AND 45999)
) ENGINE=InnoDB COMMENT='Catálogo de errores propios para que Django los traduzca a mensajes claros';

CREATE TABLE IF NOT EXISTS control_frecuencia (
  ambito     VARCHAR(30)  NOT NULL COMMENT 'Qué se limita (contacto_ip, codigo_correo, reclamo_ip...)',
  clave      VARCHAR(254) NOT NULL COMMENT 'Sujeto limitado (IP en texto, correo...)',
  creado_en  DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Primera vez que se vio',
  PRIMARY KEY (ambito, clave)
) ENGINE=InnoDB COMMENT='Filas de bloqueo para serializar límites de frecuencia concurrentes (SELECT ... FOR UPDATE)';

-- =====================================================================
-- 1. CATÁLOGO
-- =====================================================================
CREATE TABLE IF NOT EXISTS categoria (
  id_categoria        SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_categoria_padre  SMALLINT UNSIGNED NULL COMMENT 'Categoría padre (subcategorías)',
  nombre              VARCHAR(60)  NOT NULL COMMENT 'Nombre visible (único, sin distinguir tildes/mayúsculas)',
  slug                VARCHAR(80)  NOT NULL COMMENT 'URL amigable: minúsculas, números y guiones',
  descripcion         VARCHAR(200) NULL COMMENT 'Descripción corta',
  icono               VARCHAR(40)  NULL COMMENT 'Nombre del ícono',
  orden               SMALLINT     NOT NULL DEFAULT 0 COMMENT 'Orden en el menú',
  activo              BOOLEAN      NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en     DATETIME(3)  NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por    BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en           DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en      DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por          BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por     BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_categoria),
  UNIQUE KEY uq_categoria_nombre (nombre),
  UNIQUE KEY uq_categoria_slug (slug),
  CONSTRAINT fk_categoria_padre        FOREIGN KEY (id_categoria_padre) REFERENCES categoria (id_categoria),
  CONSTRAINT fk_categoria_inhabilitado FOREIGN KEY (inhabilitado_por)   REFERENCES usuario (id_usuario),
  CONSTRAINT fk_categoria_creado       FOREIGN KEY (creado_por)         REFERENCES usuario (id_usuario),
  CONSTRAINT fk_categoria_actualizado  FOREIGN KEY (actualizado_por)    REFERENCES usuario (id_usuario),
  CONSTRAINT ck_categoria_slug   CHECK (REGEXP_LIKE(slug, '^[a-z0-9]+(-[a-z0-9]+)*$', 'c')),
  CONSTRAINT ck_categoria_nombre CHECK (CHAR_LENGTH(TRIM(nombre)) >= 2),
  CONSTRAINT ck_categoria_activo CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))) ENGINE=InnoDB COMMENT='Categorías de productos (polleras, fajas, chalecos)';

CREATE TABLE IF NOT EXISTS producto (
  id_producto            BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_categoria           SMALLINT UNSIGNED NOT NULL COMMENT 'Categoría (FK)',
  nombre                 VARCHAR(150)  NOT NULL COMMENT 'Nombre comercial',
  slug                   VARCHAR(180)  NOT NULL COMMENT 'URL amigable única',
  descripcion            TEXT          NULL COMMENT 'Descripción (búsqueda FULLTEXT)',
  precio_base            DECIMAL(10,2) NOT NULL COMMENT 'Precio de lista en PEN, IGV incluido',
  tipo_fabricacion       ENUM('stock','a_pedido') NOT NULL DEFAULT 'stock' COMMENT 'stock = se vende de inventario; a_pedido = se fabrica (no descuenta stock)',
  dias_produccion        SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Días de fabricación (a_pedido)',
  permite_personalizacion BOOLEAN      NOT NULL DEFAULT 0 COMMENT '1 = acepta texto/bordado personalizado',
  unidad_medida_sunat    CHAR(3)       NOT NULL DEFAULT 'NIU' COMMENT 'Unidad de medida SUNAT (catálogo 03): NIU = unidad (bienes)',
  codigo_afectacion_igv  CHAR(2)       NOT NULL DEFAULT '10' COMMENT 'Afectación IGV SUNAT (catálogo 07): 10 = gravado',
  destacado              BOOLEAN       NOT NULL DEFAULT 0 COMMENT 'Aparece en portada',
  estado                 ENUM('borrador','activo','archivado') NOT NULL DEFAULT 'borrador' COMMENT 'Solo "activo" se vende. Archivado = borrado lógico',
  valoracion_promedio    DECIMAL(2,1)  NOT NULL DEFAULT 0.0 COMMENT 'Promedio de reseñas publicadas (lo mantiene un trigger)',
  total_resenas          INT UNSIGNED  NOT NULL DEFAULT 0 COMMENT 'Reseñas publicadas (lo mantiene un trigger)',
  inhabilitado_en        DATETIME(3)   NULL COMMENT 'Cuándo se archivó',
  inhabilitado_por       BIGINT UNSIGNED NULL COMMENT 'Quién lo archivó',
  creado_en              DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por             BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_producto),
  UNIQUE KEY uq_producto_slug (slug),
  KEY idx_producto_catalogo (estado, id_categoria, destacado),
  FULLTEXT KEY ft_producto_busqueda (nombre, descripcion),
  CONSTRAINT fk_producto_categoria    FOREIGN KEY (id_categoria)     REFERENCES categoria (id_categoria),
  CONSTRAINT fk_producto_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_producto_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_producto_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_producto_nombre    CHECK (CHAR_LENGTH(TRIM(nombre)) >= 3),
  CONSTRAINT ck_producto_slug      CHECK (REGEXP_LIKE(slug, '^[a-z0-9]+(-[a-z0-9]+)*$', 'c')),
  CONSTRAINT ck_producto_precio    CHECK (precio_base > 0),
  CONSTRAINT ck_producto_dias      CHECK (tipo_fabricacion = 'stock' OR dias_produccion > 0),
  CONSTRAINT ck_producto_valor     CHECK (valoracion_promedio BETWEEN 0 AND 5),
  CONSTRAINT ck_producto_sunat     CHECK (REGEXP_LIKE(unidad_medida_sunat, '^[A-Z0-9]{2,3}$', 'c') AND REGEXP_LIKE(codigo_afectacion_igv, '^[0-9]{2}$', 'c')),
  CONSTRAINT ck_producto_bool      CHECK (destacado IN (0,1) AND permite_personalizacion IN (0,1)),
  CONSTRAINT ck_producto_archivado CHECK ((estado = 'archivado') = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Productos. Un producto con ventas se archiva, nunca se borra';

CREATE TABLE IF NOT EXISTS variante_producto (
  id_variante       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_producto       BIGINT UNSIGNED NOT NULL COMMENT 'Producto (FK)',
  sku               VARCHAR(40)   NOT NULL COMMENT 'Código interno único en MAYÚSCULAS (A-Z, 0-9, guion)',
  talla             VARCHAR(20)   NULL COMMENT 'Talla',
  color             VARCHAR(30)   NULL COMMENT 'Color',
  talla_clave       VARCHAR(20) AS (COALESCE(talla, '')) VIRTUAL COMMENT 'Talla normalizada para el índice único',
  color_clave       VARCHAR(30) AS (COALESCE(color, '')) VIRTUAL COMMENT 'Color normalizado para el índice único',
  precio            DECIMAL(10,2) NULL COMMENT 'Precio propio con IGV; NULL = usa precio_base del producto',
  stock_actual      INT           NOT NULL DEFAULT 0 COMMENT 'Unidades físicas (solo cambia vía procedimientos con kardex)',
  stock_reservado   INT           NOT NULL DEFAULT 0 COMMENT 'Unidades reservadas por pedidos sin pagar',
  stock_disponible  INT AS (stock_actual - stock_reservado) STORED COMMENT 'Disponible para vender',
  stock_minimo      INT           NOT NULL DEFAULT 0 COMMENT 'Umbral de alerta de stock bajo',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_variante),
  UNIQUE KEY uq_variante_sku (sku),
  UNIQUE KEY uq_variante_combinacion (id_producto, talla_clave, color_clave),
  UNIQUE KEY uq_variante_producto (id_variante, id_producto),
  KEY idx_variante_stock (activo, stock_actual, stock_minimo),
  CONSTRAINT fk_variante_producto     FOREIGN KEY (id_producto)      REFERENCES producto (id_producto),
  CONSTRAINT fk_variante_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_variante_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_variante_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_variante_sku       CHECK (REGEXP_LIKE(sku, '^[A-Z0-9][A-Z0-9-]{2,39}$', 'c')),
  CONSTRAINT ck_variante_precio    CHECK (precio IS NULL OR precio > 0),
  CONSTRAINT ck_variante_stock     CHECK (stock_actual >= 0 AND stock_reservado >= 0 AND stock_reservado <= stock_actual AND stock_minimo >= 0),
  CONSTRAINT ck_variante_activo    CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Variantes (talla/color) con stock y kardex. HU de catálogo e inventario';

CREATE TABLE IF NOT EXISTS imagen_producto (
  id_imagen         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_producto       BIGINT UNSIGNED NOT NULL COMMENT 'Producto (FK)',
  id_variante       BIGINT UNSIGNED NULL COMMENT 'Variante concreta (opcional; debe ser del mismo producto)',
  url               VARCHAR(500)  NOT NULL COMMENT 'Ruta /media/... o URL https',
  texto_alt         VARCHAR(150)  NULL COMMENT 'Texto alternativo (accesibilidad)',
  orden             SMALLINT      NOT NULL DEFAULT 0 COMMENT 'Orden en la galería',
  principal         BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = imagen principal (una por producto)',
  principal_clave   BIGINT UNSIGNED AS (IF(principal = 1 AND activo = 1, id_producto, NULL)) STORED COMMENT 'Índice único: una sola principal activa por producto',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_imagen),
  UNIQUE KEY uq_imagen_principal (principal_clave),
  KEY idx_imagen_producto (id_producto, activo, orden),
  CONSTRAINT fk_imagen_producto      FOREIGN KEY (id_producto)              REFERENCES producto (id_producto),
  CONSTRAINT fk_imagen_variante      FOREIGN KEY (id_variante, id_producto) REFERENCES variante_producto (id_variante, id_producto),
  CONSTRAINT fk_imagen_inhabilitado  FOREIGN KEY (inhabilitado_por)         REFERENCES usuario (id_usuario),
  CONSTRAINT fk_imagen_creado        FOREIGN KEY (creado_por)               REFERENCES usuario (id_usuario),
  CONSTRAINT fk_imagen_actualizado   FOREIGN KEY (actualizado_por)          REFERENCES usuario (id_usuario),
  CONSTRAINT ck_imagen_url    CHECK (REGEXP_LIKE(url, '^(https://|/)[^[:space:]]+$', 'c')),
  CONSTRAINT ck_imagen_activo CHECK (activo IN (0,1) AND principal IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Galería de imágenes por producto/variante';

CREATE TABLE IF NOT EXISTS precio_volumen (
  id_precio_volumen BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_producto       BIGINT UNSIGNED NOT NULL COMMENT 'Producto (FK)',
  cantidad_minima   INT UNSIGNED  NOT NULL COMMENT 'Desde cuántas unidades (por línea) aplica',
  precio_unitario   DECIMAL(10,2) NOT NULL COMMENT 'Precio unitario con IGV en ese tramo',
  cantidad_activa   INT UNSIGNED AS (IF(activo = 1, cantidad_minima, NULL)) STORED COMMENT 'Índice único solo para tramos activos',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién lo inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_precio_volumen),
  UNIQUE KEY uq_precio_volumen_tramo (id_producto, cantidad_activa),
  CONSTRAINT fk_pvol_producto     FOREIGN KEY (id_producto)      REFERENCES producto (id_producto),
  CONSTRAINT fk_pvol_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pvol_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pvol_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_pvol_cantidad CHECK (cantidad_minima >= 2),
  CONSTRAINT ck_pvol_precio   CHECK (precio_unitario > 0),
  CONSTRAINT ck_pvol_activo   CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Precios por volumen (venta al por mayor). Una línea que alcanza un tramo convierte el pedido en "mayor"';

CREATE TABLE IF NOT EXISTS favorito (
  id_usuario  BIGINT UNSIGNED NOT NULL COMMENT 'Cliente (FK)',
  id_producto BIGINT UNSIGNED NOT NULL COMMENT 'Producto (FK)',
  creado_en   DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Cuándo lo marcó',
  PRIMARY KEY (id_usuario, id_producto),
  KEY idx_favorito_producto (id_producto),
  CONSTRAINT fk_favorito_usuario  FOREIGN KEY (id_usuario)  REFERENCES usuario (id_usuario),
  CONSTRAINT fk_favorito_producto FOREIGN KEY (id_producto) REFERENCES producto (id_producto)
) ENGINE=InnoDB COMMENT='Lista de deseos (estado de interfaz: se quita con sp_alternar_favorito)';

-- =====================================================================
-- 2. INSUMOS (hilos, telas, bastidores) — HU-13
-- =====================================================================
CREATE TABLE IF NOT EXISTS insumo (
  id_insumo         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  nombre            VARCHAR(120)  NOT NULL COMMENT 'Nombre (único)',
  tipo              ENUM('hilo','tela','bastidor','otro') NOT NULL COMMENT 'Tipo de insumo',
  unidad            ENUM('unidad','metro','centimetro','cono','madeja','rollo','kilogramo','gramo','par') NOT NULL COMMENT 'Unidad de medida',
  stock_actual      DECIMAL(12,3) NOT NULL DEFAULT 0 COMMENT 'Existencia (solo cambia vía sp_ajustar_insumo con kardex)',
  stock_minimo      DECIMAL(12,3) NOT NULL DEFAULT 0 COMMENT 'Umbral de alerta',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién lo inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_insumo),
  UNIQUE KEY uq_insumo_nombre (nombre),
  CONSTRAINT fk_insumo_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_insumo_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_insumo_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_insumo_stock  CHECK (stock_actual >= 0 AND stock_minimo >= 0),
  CONSTRAINT ck_insumo_activo CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Insumos de producción con stock mínimo y alertas. HU-13';

CREATE TABLE IF NOT EXISTS receta_producto (
  id_producto        BIGINT UNSIGNED NOT NULL COMMENT 'Producto fabricado (FK)',
  id_insumo          BIGINT UNSIGNED NOT NULL COMMENT 'Insumo usado (FK)',
  cantidad_por_unidad DECIMAL(12,3)  NOT NULL COMMENT 'Cantidad de insumo por unidad producida',
  activo             BOOLEAN         NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  creado_en          DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por         BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por    BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_producto, id_insumo),
  KEY idx_receta_insumo (id_insumo),
  CONSTRAINT fk_receta_producto    FOREIGN KEY (id_producto)     REFERENCES producto (id_producto),
  CONSTRAINT fk_receta_insumo      FOREIGN KEY (id_insumo)       REFERENCES insumo (id_insumo),
  CONSTRAINT fk_receta_creado      FOREIGN KEY (creado_por)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_receta_actualizado FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_receta_cantidad CHECK (cantidad_por_unidad > 0 AND activo IN (0,1))
) ENGINE=InnoDB COMMENT='Receta: insumos por unidad producida (opcional; permite descontar insumos al producir)';

-- =====================================================================
-- 3. ENVÍO Y DIRECCIONES
-- =====================================================================
CREATE TABLE IF NOT EXISTS zona_envio (
  id_zona           SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  nombre            VARCHAR(80)   NOT NULL COMMENT 'Nombre de la zona (único)',
  costo             DECIMAL(8,2)  NOT NULL COMMENT 'Costo de envío en PEN con IGV (fuente única del costo de envío)',
  dias_estimados    SMALLINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Días hábiles estimados de entrega',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_zona),
  UNIQUE KEY uq_zona_nombre (nombre),
  CONSTRAINT fk_zona_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_zona_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_zona_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_zona_costo  CHECK (costo >= 0),
  CONSTRAINT ck_zona_activo CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Zonas de envío y su costo';

CREATE TABLE IF NOT EXISTS direccion (
  id_direccion          BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario            BIGINT UNSIGNED  NOT NULL COMMENT 'Cliente dueño (FK)',
  alias                 VARCHAR(40)   NOT NULL COMMENT 'Casa, trabajo...',
  nombre_receptor       VARCHAR(120)  NOT NULL COMMENT 'Quién recibe',
  telefono              VARCHAR(16)   NOT NULL COMMENT 'Teléfono de contacto',
  direccion             VARCHAR(200)  NOT NULL COMMENT 'Calle, número, interior',
  referencia            VARCHAR(200)  NULL COMMENT 'Referencia para el repartidor',
  distrito              VARCHAR(80)   NOT NULL COMMENT 'Distrito',
  provincia             VARCHAR(80)   NOT NULL COMMENT 'Provincia',
  departamento          VARCHAR(80)   NOT NULL COMMENT 'Departamento',
  ubigeo                CHAR(6)       NULL COMMENT 'Código UBIGEO INEI (útil para la API del courier)',
  id_zona               SMALLINT UNSIGNED NOT NULL COMMENT 'Zona de envío (define el costo)',
  predeterminada        BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = dirección por defecto',
  predeterminada_clave  BIGINT UNSIGNED AS (IF(predeterminada = 1 AND activo = 1, id_usuario, NULL)) STORED COMMENT 'Índice único: una sola predeterminada activa por cliente',
  activo                BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en       DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por      BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en             DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en        DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por            BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por       BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_direccion),
  UNIQUE KEY uq_direccion_predeterminada (predeterminada_clave),
  KEY idx_direccion_usuario (id_usuario, activo),
  CONSTRAINT fk_direccion_usuario      FOREIGN KEY (id_usuario)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_direccion_zona         FOREIGN KEY (id_zona)          REFERENCES zona_envio (id_zona),
  CONSTRAINT fk_direccion_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_direccion_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_direccion_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_direccion_telefono CHECK (REGEXP_LIKE(telefono, '^[+]?[0-9]{9,15}$', 'c')),
  CONSTRAINT ck_direccion_ubigeo   CHECK (ubigeo IS NULL OR REGEXP_LIKE(ubigeo, '^[0-9]{6}$', 'c')),
  CONSTRAINT ck_direccion_textos   CHECK (CHAR_LENGTH(TRIM(direccion)) >= 5 AND CHAR_LENGTH(TRIM(nombre_receptor)) >= 3),
  CONSTRAINT ck_direccion_activo   CHECK (activo IN (0,1) AND predeterminada IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Direcciones de entrega del cliente';

CREATE TABLE IF NOT EXISTS courier (
  id_courier        SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  nombre            VARCHAR(60)   NOT NULL COMMENT 'Empresa de transporte o "Reparto propio"',
  url_seguimiento   VARCHAR(300)  NULL COMMENT 'Plantilla de URL de rastreo con {guia}',
  tiene_api         BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = integrado por API (futuro)',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién lo inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_courier),
  UNIQUE KEY uq_courier_nombre (nombre),
  CONSTRAINT fk_courier_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_courier_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_courier_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_courier_url    CHECK (url_seguimiento IS NULL OR REGEXP_LIKE(url_seguimiento, '^https://', 'c')),
  CONSTRAINT ck_courier_activo CHECK (activo IN (0,1) AND tiene_api IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Empresas de transporte (courier y su API: decisión abierta)';

-- =====================================================================
-- 4. COTIZACIONES (por mayor y bordado personalizado) — HU-28 / HU-17 / HU-18
-- =====================================================================
CREATE TABLE IF NOT EXISTS cotizacion (
  id_cotizacion            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  numero                   VARCHAR(25)   NOT NULL COMMENT 'Correlativo anual CT-AAAA-NNNN',
  id_usuario               BIGINT UNSIGNED NOT NULL COMMENT 'Cliente que solicita (FK)',
  origen                   ENUM('mayor','personalizado') NOT NULL DEFAULT 'mayor' COMMENT 'Venta al por mayor o bordado personalizado',
  estado                   ENUM('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') NOT NULL DEFAULT 'solicitada' COMMENT 'Flujo: solicitada → en_revision → cotizada → aceptada → convertida',
  descripcion              TEXT          NOT NULL COMMENT 'Lo que pide el cliente',
  imagen_referencia_url    VARCHAR(500)  NULL COMMENT 'Imagen de referencia del diseño',
  fecha_entrega_solicitada DATE          NULL COMMENT 'Fecha deseada (día de Lima)',
  subtotal                 DECIMAL(12,2) NULL COMMENT 'Suma de ítems cotizados (con IGV)',
  costo_envio              DECIMAL(12,2) NULL COMMENT 'Envío cotizado; NULL = al aceptar se cobra la tarifa de la zona de la dirección elegida',
  total                    DECIMAL(12,2) NULL COMMENT 'Total cotizado',
  adelanto_porcentaje      DECIMAL(5,2)  NULL COMMENT 'Adelanto que se pedirá al convertir (editable; por defecto config)',
  vigencia_hasta           DATE          NULL COMMENT 'Último día de vigencia (día de Lima)',
  respuesta                TEXT          NULL COMMENT 'Respuesta del administrador',
  motivo_rechazo           VARCHAR(300)  NULL COMMENT 'Motivo si se rechaza',
  id_admin                 BIGINT UNSIGNED NULL COMMENT 'Administrador que cotizó (FK)',
  cotizado_en              DATETIME(3)   NULL COMMENT 'Cuándo se cotizó',
  aceptado_en              DATETIME(3)   NULL COMMENT 'Cuándo la aceptó el cliente',
  creado_en                DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en           DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por               BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por          BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_cotizacion),
  UNIQUE KEY uq_cotizacion_numero (numero),
  KEY idx_cotizacion_usuario (id_usuario, creado_en),
  KEY idx_cotizacion_estado (estado, vigencia_hasta),
  CONSTRAINT fk_cotizacion_usuario     FOREIGN KEY (id_usuario)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_cotizacion_admin       FOREIGN KEY (id_admin)        REFERENCES usuario (id_usuario),
  CONSTRAINT fk_cotizacion_creado      FOREIGN KEY (creado_por)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_cotizacion_actualizado FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_cotizacion_montos    CHECK (subtotal IS NULL OR (subtotal >= 0 AND COALESCE(costo_envio, 0) >= 0 AND total = subtotal + COALESCE(costo_envio, 0))),
  CONSTRAINT ck_cotizacion_adelanto  CHECK (adelanto_porcentaje IS NULL OR (adelanto_porcentaje > 0 AND adelanto_porcentaje <= 100)),
  CONSTRAINT ck_cotizacion_cotizada  CHECK (estado NOT IN ('cotizada','aceptada','convertida','vencida')
                                            OR (total IS NOT NULL AND vigencia_hasta IS NOT NULL AND adelanto_porcentaje IS NOT NULL AND cotizado_en IS NOT NULL)),
  CONSTRAINT ck_cotizacion_rechazo   CHECK (estado <> 'rechazada' OR motivo_rechazo IS NOT NULL),
  CONSTRAINT ck_cotizacion_desc      CHECK (CHAR_LENGTH(TRIM(descripcion)) >= 10),
  CONSTRAINT ck_cotizacion_imagen    CHECK (imagen_referencia_url IS NULL OR REGEXP_LIKE(imagen_referencia_url, '^(https://|/)[^[:space:]]+$', 'c'))
) ENGINE=InnoDB COMMENT='Cotizaciones (al por mayor y personalizadas) con vigencia y conversión a pedido';

CREATE TABLE IF NOT EXISTS item_cotizacion (
  id_item_cotizacion BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_cotizacion      BIGINT UNSIGNED NOT NULL COMMENT 'Cotización (FK)',
  id_variante        BIGINT UNSIGNED NULL COMMENT 'Variante del catálogo (NULL = pieza personalizada fuera de catálogo)',
  descripcion        VARCHAR(250)  NOT NULL COMMENT 'Descripción de la pieza',
  cantidad           INT UNSIGNED  NOT NULL COMMENT 'Unidades',
  precio_unitario    DECIMAL(10,2) NULL COMMENT 'Precio cotizado con IGV (lo fija el administrador)',
  subtotal           DECIMAL(12,2) AS (cantidad * precio_unitario) STORED COMMENT 'cantidad × precio',
  personalizacion    VARCHAR(500)  NULL COMMENT 'Detalle del bordado',
  creado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en     DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_item_cotizacion),
  KEY idx_item_cotizacion (id_cotizacion),
  CONSTRAINT fk_icot_cotizacion FOREIGN KEY (id_cotizacion) REFERENCES cotizacion (id_cotizacion),
  CONSTRAINT fk_icot_variante   FOREIGN KEY (id_variante)   REFERENCES variante_producto (id_variante),
  CONSTRAINT ck_icot_cantidad   CHECK (cantidad > 0 AND cantidad <= 100000),
  CONSTRAINT ck_icot_precio     CHECK (precio_unitario IS NULL OR precio_unitario > 0)
) ENGINE=InnoDB COMMENT='Ítems de una cotización';

CREATE TABLE IF NOT EXISTS transicion_estado_cotizacion (
  estado_origen  ENUM('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') NOT NULL COMMENT 'Desde',
  estado_destino ENUM('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') NOT NULL COMMENT 'Hacia',
  descripcion    VARCHAR(150) NULL COMMENT 'Explicación',
  PRIMARY KEY (estado_origen, estado_destino)
) ENGINE=InnoDB COMMENT='Transiciones permitidas de cotización (fuente única de verdad)';

-- =====================================================================
-- 5. PEDIDOS
-- =====================================================================
CREATE TABLE IF NOT EXISTS estado_pedido (
  codigo            VARCHAR(20)  NOT NULL COMMENT 'Código del estado',
  nombre            VARCHAR(40)  NOT NULL COMMENT 'Nombre visible para el cliente',
  grupo             ENUM('pendiente','en_proceso','terminado','cancelado','devuelto') NOT NULL COMMENT 'Agrupación para consultas (§2.5)',
  orden             TINYINT UNSIGNED NOT NULL COMMENT 'Orden en la línea de tiempo',
  es_final          BOOLEAN      NOT NULL DEFAULT 0 COMMENT '1 = no admite más cambios salvo devolución',
  notifica_cliente  BOOLEAN      NOT NULL DEFAULT 1 COMMENT '1 = genera correo + notificación al entrar',
  descripcion       VARCHAR(200) NULL COMMENT 'Qué significa',
  PRIMARY KEY (codigo),
  UNIQUE KEY uq_estado_pedido_orden (orden),
  CONSTRAINT ck_estado_pedido_codigo CHECK (REGEXP_LIKE(codigo, '^[a-z_]{3,20}$', 'c')),
  CONSTRAINT ck_estado_pedido_bool   CHECK (es_final IN (0,1) AND notifica_cliente IN (0,1))
) ENGINE=InnoDB COMMENT='Catálogo de estados del pedido con su grupo (pendiente, en proceso, terminado, cancelado, devuelto)';

CREATE TABLE IF NOT EXISTS transicion_estado_pedido (
  estado_origen          VARCHAR(20) NOT NULL COMMENT 'Desde (FK estado_pedido)',
  estado_destino         VARCHAR(20) NOT NULL COMMENT 'Hacia (FK estado_pedido)',
  tipo_entrega_aplicable ENUM('ambos','recojo','domicilio') NOT NULL DEFAULT 'ambos' COMMENT 'Recojo no pasa por enviado; domicilio debe pasar por enviado',
  automatica             BOOLEAN NOT NULL DEFAULT 0 COMMENT '1 = solo la hace el sistema (confirmación por pago)',
  permitido_cliente      BOOLEAN NOT NULL DEFAULT 0 COMMENT '1 = el propio cliente puede hacerla (cancelar su pedido sin pagar)',
  requiere_saldo_cero    BOOLEAN NOT NULL DEFAULT 0 COMMENT '1 = exige saldo 0 si config bloquear_envio_con_saldo = 1',
  descripcion            VARCHAR(150) NULL COMMENT 'Explicación',
  PRIMARY KEY (estado_origen, estado_destino),
  KEY idx_transicion_destino (estado_destino),
  CONSTRAINT fk_tep_origen  FOREIGN KEY (estado_origen)  REFERENCES estado_pedido (codigo),
  CONSTRAINT fk_tep_destino FOREIGN KEY (estado_destino) REFERENCES estado_pedido (codigo),
  CONSTRAINT ck_tep_bool    CHECK (automatica IN (0,1) AND permitido_cliente IN (0,1) AND requiere_saldo_cero IN (0,1))
) ENGINE=InnoDB COMMENT='Flujo de estados permitido (única fuente de verdad para cliente y administrador)';

CREATE TABLE IF NOT EXISTS pedido (
  id_pedido                BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  numero                   VARCHAR(25)   NOT NULL COMMENT 'Correlativo anual BW-AAAA-NNNNNN / BW-MAY-AAAA-NNNNNN',
  id_usuario               BIGINT UNSIGNED  NOT NULL COMMENT 'Cliente (FK)',
  id_pedido_origen         BIGINT UNSIGNED  NULL COMMENT 'Pedido original si es complementario (HU-29)',
  id_cotizacion            BIGINT UNSIGNED  NULL COMMENT 'Cotización de la que nace (una cotización = un pedido)',
  tipo_venta               ENUM('menor','mayor') NOT NULL DEFAULT 'menor' COMMENT 'mayor = alguna línea alcanzó precio por volumen o viene de cotización al por mayor',
  canal                    ENUM('web','presencial') NOT NULL DEFAULT 'web' COMMENT 'Canal de venta',
  estado                   VARCHAR(20)   NOT NULL DEFAULT 'pendiente_pago' COMMENT 'Estado (FK estado_pedido); solo cambia por transiciones permitidas',
  estado_pago              ENUM('pendiente','parcial','pagado','reembolsado') NOT NULL DEFAULT 'pendiente' COMMENT 'DERIVADO de los pagos (no se fija a mano)',
  modalidad_pago           ENUM('total','adelanto') NOT NULL DEFAULT 'total' COMMENT 'Elegida por el cliente: pago completo o adelanto',
  adelanto_porcentaje      DECIMAL(5,2)  NULL COMMENT 'Porcentaje de adelanto aplicado (NULL si total). Por defecto config adelanto_porcentaje (50) o el de la cotización',
  tipo_entrega             ENUM('recojo','domicilio') NOT NULL COMMENT 'Recojo en tienda o envío a domicilio',
  id_direccion             BIGINT UNSIGNED  NULL COMMENT 'Dirección de origen de la copia de entrega',
  id_zona                  SMALLINT UNSIGNED NULL COMMENT 'Zona de envío (define costo_envio)',
  entrega_nombre           VARCHAR(120)  NULL COMMENT 'Copia: quién recibe',
  entrega_telefono         VARCHAR(16)   NULL COMMENT 'Copia: teléfono',
  entrega_direccion        VARCHAR(200)  NULL COMMENT 'Copia: dirección',
  entrega_referencia       VARCHAR(200)  NULL COMMENT 'Copia: referencia',
  entrega_distrito         VARCHAR(80)   NULL COMMENT 'Copia: distrito',
  entrega_provincia        VARCHAR(80)   NULL COMMENT 'Copia: provincia',
  entrega_departamento     VARCHAR(80)   NULL COMMENT 'Copia: departamento',
  entrega_ubigeo           CHAR(6)       NULL COMMENT 'Copia: UBIGEO',
  comprobante_solicitado   ENUM('boleta','factura') NOT NULL DEFAULT 'boleta' COMMENT 'Comprobante que pidió el cliente',
  facturacion_tipo_doc     ENUM('DNI','RUC','CE') NULL COMMENT 'Documento para el comprobante (RUC obligatorio en factura)',
  facturacion_num_doc      VARCHAR(12)   NULL COMMENT 'Número de documento para el comprobante',
  facturacion_nombre       VARCHAR(200)  NULL COMMENT 'Nombre o razón social para el comprobante',
  facturacion_direccion    VARCHAR(250)  NULL COMMENT 'Domicilio fiscal / dirección para el comprobante',
  moneda                   CHAR(3)       NOT NULL DEFAULT 'PEN' COMMENT 'Moneda del pedido (PEN)',
  subtotal                 DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'Suma de ítems (IGV incluido)',
  descuento                DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'Descuento (reservado para cupones, HU-40 fuera de alcance)',
  costo_envio              DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'Costo de envío tomado de la zona (nunca del navegador)',
  total                    DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'subtotal − descuento + envío',
  monto_pagado             DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'DERIVADO: pagos confirmados aplicados',
  monto_reembolsado        DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'DERIVADO: reembolsos completados de esos pagos',
  monto_devuelto           DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'DERIVADO: valor de los productos devueltos (devoluciones registradas)',
  monto_ajustes            DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'DERIVADO: rebajas posteriores a la venta (nota de crédito de descuento/disminución o compensación reembolsada sin comprobante)',
  monto_neto_pagado        DECIMAL(12,2) AS (monto_pagado - monto_reembolsado) STORED COMMENT 'Pagado − reembolsado',
  saldo                    DECIMAL(12,2) AS (total - monto_devuelto - monto_ajustes - (monto_pagado - monto_reembolsado)) STORED COMMENT 'Lo que falta pagar; negativo = saldo a favor del cliente (reembolso pendiente)',
  monto_requerido          DECIMAL(12,2) AS (IF(modalidad_pago = 'total', total, ROUND(total * adelanto_porcentaje / 100, 2))) STORED COMMENT 'Monto que confirma el pedido según la modalidad',
  fecha_entrega_solicitada DATE          NULL COMMENT 'Fecha pedida por el cliente (obligatoria y con anticipación en mayor)',
  fecha_entrega_estimada   DATE          NULL COMMENT 'Fecha estimada por la tienda',
  notas                    VARCHAR(500)  NULL COMMENT 'Notas del cliente',
  expira_en                DATETIME(3)   NULL COMMENT 'Hasta cuándo se reserva el stock sin pago (UTC)',
  confirmado_en            DATETIME(3)   NULL COMMENT 'Cuándo se confirmó (pago requerido recibido)',
  entregado_en             DATETIME(3)   NULL COMMENT 'Cuándo se entregó',
  cancelado_en             DATETIME(3)   NULL COMMENT 'Cuándo se canceló',
  cancelado_por            BIGINT UNSIGNED NULL COMMENT 'Quién lo canceló (NULL = sistema)',
  motivo_cancelacion       VARCHAR(200)  NULL COMMENT 'Motivo de cancelación',
  creado_en                DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en           DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por               BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por          BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_pedido),
  UNIQUE KEY uq_pedido_numero (numero),
  UNIQUE KEY uq_pedido_cotizacion (id_cotizacion),
  KEY idx_pedido_usuario (id_usuario, creado_en),
  KEY idx_pedido_estado (estado, creado_en),
  KEY idx_pedido_expira (estado, expira_en),
  KEY idx_pedido_fecha (creado_en),
  KEY idx_pedido_origen (id_pedido_origen),
  CONSTRAINT fk_pedido_usuario     FOREIGN KEY (id_usuario)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pedido_origen      FOREIGN KEY (id_pedido_origen) REFERENCES pedido (id_pedido),
  CONSTRAINT fk_pedido_cotizacion  FOREIGN KEY (id_cotizacion)    REFERENCES cotizacion (id_cotizacion),
  CONSTRAINT fk_pedido_estado      FOREIGN KEY (estado)           REFERENCES estado_pedido (codigo),
  CONSTRAINT fk_pedido_direccion   FOREIGN KEY (id_direccion)     REFERENCES direccion (id_direccion),
  CONSTRAINT fk_pedido_zona        FOREIGN KEY (id_zona)          REFERENCES zona_envio (id_zona),
  CONSTRAINT fk_pedido_cancelado   FOREIGN KEY (cancelado_por)    REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pedido_creado      FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pedido_actualizado FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_pedido_moneda      CHECK (moneda IN ('PEN')),
  CONSTRAINT ck_pedido_montos      CHECK (subtotal >= 0 AND descuento >= 0 AND costo_envio >= 0 AND descuento <= subtotal),
  CONSTRAINT ck_pedido_total       CHECK (total = subtotal - descuento + costo_envio),
  CONSTRAINT ck_pedido_pagos       CHECK (monto_pagado >= 0 AND monto_reembolsado >= 0 AND monto_reembolsado <= monto_pagado
                                          AND (monto_pagado - monto_reembolsado) <= total
                                          AND monto_devuelto >= 0 AND monto_ajustes >= 0 AND monto_devuelto + monto_ajustes <= total),
  CONSTRAINT ck_pedido_no_vacio    CHECK (estado IN ('pendiente_pago','cancelado') OR subtotal > 0),
  CONSTRAINT ck_pedido_modalidad   CHECK ((modalidad_pago = 'total' AND adelanto_porcentaje IS NULL)
                                          OR (modalidad_pago = 'adelanto' AND adelanto_porcentaje > 0 AND adelanto_porcentaje < 100)),
  CONSTRAINT ck_pedido_cancelado   CHECK ((estado = 'cancelado') = (cancelado_en IS NOT NULL)),
  CONSTRAINT ck_pedido_entrega     CHECK (
        (tipo_entrega = 'recojo' AND costo_envio = 0)
     OR (tipo_entrega = 'domicilio' AND id_zona IS NOT NULL AND entrega_nombre IS NOT NULL AND entrega_telefono IS NOT NULL
         AND entrega_direccion IS NOT NULL AND entrega_distrito IS NOT NULL)),
  CONSTRAINT ck_pedido_telefono    CHECK (entrega_telefono IS NULL OR REGEXP_LIKE(entrega_telefono, '^[+]?[0-9]{9,15}$', 'c')),
  CONSTRAINT ck_pedido_factura     CHECK (comprobante_solicitado <> 'factura'
                                          OR (facturacion_tipo_doc = 'RUC' AND facturacion_num_doc IS NOT NULL AND facturacion_nombre IS NOT NULL)),
  CONSTRAINT ck_pedido_documento   CHECK (
        (facturacion_tipo_doc IS NULL AND facturacion_num_doc IS NULL)
     OR (facturacion_tipo_doc = 'DNI' AND REGEXP_LIKE(facturacion_num_doc, '^[0-9]{8}$', 'c'))
     OR (facturacion_tipo_doc = 'RUC' AND REGEXP_LIKE(facturacion_num_doc, '^(10|15|16|17|20)[0-9]{9}$', 'c'))
     OR (facturacion_tipo_doc = 'CE'  AND REGEXP_LIKE(facturacion_num_doc, '^[A-Z0-9]{6,12}$', 'c')))
) ENGINE=InnoDB COMMENT='Pedidos. Estado siempre consultable por grupo; montos de pago derivados de los pagos';

CREATE TABLE IF NOT EXISTS item_pedido (
  id_item_pedido    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido         BIGINT UNSIGNED NOT NULL COMMENT 'Pedido (FK)',
  id_variante       BIGINT UNSIGNED NULL COMMENT 'Variante vendida (NULL = pieza personalizada de cotización)',
  id_producto       BIGINT UNSIGNED NULL COMMENT 'Producto (para reportes)',
  nombre_producto   VARCHAR(150)  NOT NULL COMMENT 'Copia del nombre al comprar',
  sku               VARCHAR(40)   NULL COMMENT 'Copia del SKU',
  talla             VARCHAR(20)   NULL COMMENT 'Copia de la talla',
  color             VARCHAR(30)   NULL COMMENT 'Copia del color',
  tipo_fabricacion  ENUM('stock','a_pedido','personalizado') NOT NULL COMMENT 'Copia: define si reserva/descuenta/repone stock',
  cantidad          INT UNSIGNED  NOT NULL COMMENT 'Unidades',
  precio_lista      DECIMAL(10,2) NULL COMMENT 'Precio de lista al comprar (informativo)',
  precio_unitario   DECIMAL(10,2) NOT NULL COMMENT 'Precio aplicado con IGV (lista, volumen o cotizado; sale de la BD)',
  origen_precio     ENUM('lista','volumen','cotizacion') NOT NULL COMMENT 'De dónde salió el precio',
  subtotal          DECIMAL(12,2) AS (cantidad * precio_unitario) STORED COMMENT 'cantidad × precio',
  personalizacion   VARCHAR(500)  NULL COMMENT 'Texto del bordado personalizado',
  cantidad_devuelta INT UNSIGNED  NOT NULL DEFAULT 0 COMMENT 'Unidades devueltas/anuladas (impide devolver dos veces)',
  estado            ENUM('vigente','retirado') NOT NULL DEFAULT 'vigente' COMMENT 'retirado = el cliente lo quitó antes de pagar (borrado lógico; el kardex conserva la reserva y su liberación)',
  retirado_en       DATETIME(3)   NULL COMMENT 'Cuándo se retiró',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  PRIMARY KEY (id_item_pedido),
  KEY idx_item_pedido_estado (id_pedido, estado, id_variante),   -- una variante puede repetirse (cotización con distinta personalización)
  KEY idx_item_variante (id_variante),
  KEY idx_item_producto (id_producto),
  CONSTRAINT fk_item_pedido   FOREIGN KEY (id_pedido)   REFERENCES pedido (id_pedido),
  CONSTRAINT fk_item_variante FOREIGN KEY (id_variante) REFERENCES variante_producto (id_variante),
  CONSTRAINT fk_item_producto FOREIGN KEY (id_producto) REFERENCES producto (id_producto),
  CONSTRAINT ck_item_cantidad CHECK (cantidad > 0 AND cantidad <= 100000 AND cantidad_devuelta <= cantidad),
  CONSTRAINT ck_item_precio   CHECK (precio_unitario > 0 AND (precio_lista IS NULL OR precio_lista > 0)),
  CONSTRAINT ck_item_tipo     CHECK ((id_variante IS NULL) = (tipo_fabricacion = 'personalizado')),
  CONSTRAINT ck_item_retirado CHECK ((estado = 'retirado') = (retirado_en IS NOT NULL) AND (estado = 'vigente' OR cantidad_devuelta = 0))
) ENGINE=InnoDB COMMENT='Ítems del pedido con copia (snapshot) de nombre, SKU, talla, color, precio y personalización';

CREATE TABLE IF NOT EXISTS historial_estado_pedido (
  id_historial     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido        BIGINT UNSIGNED NOT NULL COMMENT 'Pedido (FK)',
  estado_anterior  VARCHAR(20)     NULL COMMENT 'Estado previo (NULL al crear)',
  estado_nuevo     VARCHAR(20)     NOT NULL COMMENT 'Estado nuevo',
  id_usuario       BIGINT UNSIGNED NULL COMMENT 'Quién lo cambió (NULL = sistema)',
  comentario       VARCHAR(200)    NULL COMMENT 'Comentario / motivo',
  creado_en        DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_historial),
  KEY idx_historial_pedido (id_pedido, creado_en),
  CONSTRAINT fk_hist_pedido   FOREIGN KEY (id_pedido)       REFERENCES pedido (id_pedido),
  CONSTRAINT fk_hist_usuario  FOREIGN KEY (id_usuario)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_hist_anterior FOREIGN KEY (estado_anterior) REFERENCES estado_pedido (codigo),
  CONSTRAINT fk_hist_nuevo    FOREIGN KEY (estado_nuevo)    REFERENCES estado_pedido (codigo)
) ENGINE=InnoDB COMMENT='Historial inmutable de cambios de estado con quién lo hizo';

-- =====================================================================
-- 6. DEVOLUCIONES
-- =====================================================================
CREATE TABLE IF NOT EXISTS devolucion (
  id_devolucion   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  numero          VARCHAR(25)   NOT NULL COMMENT 'Correlativo anual DV-AAAA-NNNNNN',
  id_pedido       BIGINT UNSIGNED NOT NULL COMMENT 'Pedido devuelto (FK)',
  tipo            ENUM('total','parcial') NOT NULL COMMENT 'Devolución de todo o parte del pedido',
  motivo          VARCHAR(300)  NOT NULL COMMENT 'Motivo',
  monto_total     DECIMAL(12,2) NOT NULL COMMENT 'Valor de lo devuelto (con IGV)',
  registrado_por  BIGINT UNSIGNED NULL COMMENT 'Administrador que la registró',
  creado_en       DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_devolucion),
  UNIQUE KEY uq_devolucion_numero (numero),
  KEY idx_devolucion_pedido (id_pedido),
  CONSTRAINT fk_devolucion_pedido     FOREIGN KEY (id_pedido)      REFERENCES pedido (id_pedido),
  CONSTRAINT fk_devolucion_registrado FOREIGN KEY (registrado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_devolucion_monto CHECK (monto_total >= 0),
  CONSTRAINT ck_devolucion_motivo CHECK (CHAR_LENGTH(TRIM(motivo)) >= 5)
) ENGINE=InnoDB COMMENT='Devoluciones de pedidos entregados/enviados (reponen stock y originan reembolso y nota de crédito)';

CREATE TABLE IF NOT EXISTS devolucion_item (
  id_devolucion_item BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_devolucion      BIGINT UNSIGNED NOT NULL COMMENT 'Devolución (FK)',
  id_item_pedido     BIGINT UNSIGNED NOT NULL COMMENT 'Ítem devuelto (FK)',
  cantidad           INT UNSIGNED  NOT NULL COMMENT 'Unidades devueltas',
  monto              DECIMAL(12,2) NOT NULL COMMENT 'cantidad × precio aplicado',
  repuso_stock       BOOLEAN       NOT NULL COMMENT '1 = se repuso stock (solo productos de tipo stock)',
  PRIMARY KEY (id_devolucion_item),
  UNIQUE KEY uq_devolucion_item (id_devolucion, id_item_pedido),
  KEY idx_devitem_item (id_item_pedido),
  CONSTRAINT fk_devitem_devolucion FOREIGN KEY (id_devolucion)  REFERENCES devolucion (id_devolucion),
  CONSTRAINT fk_devitem_item       FOREIGN KEY (id_item_pedido) REFERENCES item_pedido (id_item_pedido),
  CONSTRAINT ck_devitem_cantidad   CHECK (cantidad > 0 AND monto >= 0 AND repuso_stock IN (0,1))
) ENGINE=InnoDB COMMENT='Detalle de unidades devueltas';

-- =====================================================================
-- 7. INVENTARIO: reservas y kardex (solo inserción)
-- =====================================================================
CREATE TABLE IF NOT EXISTS reserva_stock (
  id_reserva      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido       BIGINT UNSIGNED NOT NULL COMMENT 'Pedido (FK)',
  id_item_pedido  BIGINT UNSIGNED NOT NULL COMMENT 'Ítem (FK, una reserva por ítem)',
  id_variante     BIGINT UNSIGNED NOT NULL COMMENT 'Variante reservada (FK)',
  cantidad        INT UNSIGNED    NOT NULL COMMENT 'Unidades reservadas',
  estado          ENUM('activa','consumida','liberada') NOT NULL DEFAULT 'activa' COMMENT 'activa → consumida (venta) o liberada (cancelación/expiración)',
  creado_en       DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  cerrada_en      DATETIME(3)     NULL COMMENT 'Cuándo se consumió o liberó',
  PRIMARY KEY (id_reserva),
  UNIQUE KEY uq_reserva_item (id_item_pedido),
  KEY idx_reserva_pedido (id_pedido, estado),
  KEY idx_reserva_variante (id_variante, estado),
  CONSTRAINT fk_reserva_pedido   FOREIGN KEY (id_pedido)      REFERENCES pedido (id_pedido),
  CONSTRAINT fk_reserva_item     FOREIGN KEY (id_item_pedido) REFERENCES item_pedido (id_item_pedido),
  CONSTRAINT fk_reserva_variante FOREIGN KEY (id_variante)    REFERENCES variante_producto (id_variante),
  CONSTRAINT ck_reserva_cantidad CHECK (cantidad > 0),
  CONSTRAINT ck_reserva_cierre   CHECK ((estado = 'activa') = (cerrada_en IS NULL))
) ENGINE=InnoDB COMMENT='Reservas de stock por ítem de pedido; la suma de activas = variante.stock_reservado';

CREATE TABLE IF NOT EXISTS movimiento_stock (
  id_movimiento              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_variante                BIGINT UNSIGNED NOT NULL COMMENT 'Variante (FK)',
  tipo                       ENUM('ingreso','reserva','liberacion_reserva','venta','devolucion','ajuste') NOT NULL COMMENT 'Tipo de movimiento',
  cantidad                   INT             NOT NULL COMMENT 'Unidades (positivas; en ajuste puede ser negativa)',
  stock_actual_resultante    INT             NOT NULL COMMENT 'Stock físico después del movimiento',
  stock_reservado_resultante INT             NOT NULL COMMENT 'Stock reservado después del movimiento',
  id_pedido                  BIGINT UNSIGNED NULL COMMENT 'Pedido relacionado (FK)',
  id_item_pedido             BIGINT UNSIGNED NULL COMMENT 'Ítem relacionado (FK)',
  id_devolucion              BIGINT UNSIGNED NULL COMMENT 'Devolución relacionada (FK)',
  id_usuario                 BIGINT UNSIGNED NULL COMMENT 'Actor (NULL = sistema)',
  motivo                     VARCHAR(200)    NULL COMMENT 'Motivo',
  creado_en                  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_movimiento),
  KEY idx_movstock_variante (id_variante, creado_en),
  KEY idx_movstock_pedido (id_pedido),
  KEY idx_movstock_fecha (creado_en),
  CONSTRAINT fk_movstock_variante   FOREIGN KEY (id_variante)    REFERENCES variante_producto (id_variante),
  CONSTRAINT fk_movstock_pedido     FOREIGN KEY (id_pedido)      REFERENCES pedido (id_pedido),
  CONSTRAINT fk_movstock_item       FOREIGN KEY (id_item_pedido) REFERENCES item_pedido (id_item_pedido),
  CONSTRAINT fk_movstock_devolucion FOREIGN KEY (id_devolucion)  REFERENCES devolucion (id_devolucion),
  CONSTRAINT fk_movstock_usuario    FOREIGN KEY (id_usuario)     REFERENCES usuario (id_usuario),
  CONSTRAINT ck_movstock_cantidad   CHECK (cantidad <> 0 AND (tipo = 'ajuste' OR cantidad > 0)),
  CONSTRAINT ck_movstock_resultado  CHECK (stock_actual_resultante >= 0 AND stock_reservado_resultante >= 0
                                           AND stock_reservado_resultante <= stock_actual_resultante)
) ENGINE=InnoDB COMMENT='Kardex de productos terminados (solo inserción)';

CREATE TABLE IF NOT EXISTS movimiento_insumo (
  id_movimiento     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_insumo         BIGINT UNSIGNED NOT NULL COMMENT 'Insumo (FK)',
  tipo              ENUM('ingreso','consumo','ajuste') NOT NULL COMMENT 'Tipo de movimiento',
  cantidad          DECIMAL(12,3)   NOT NULL COMMENT 'Cantidad (positiva; en ajuste puede ser negativa)',
  stock_resultante  DECIMAL(12,3)   NOT NULL COMMENT 'Existencia después del movimiento',
  id_pedido         BIGINT UNSIGNED NULL COMMENT 'Pedido que lo consumió (FK)',
  id_usuario        BIGINT UNSIGNED NULL COMMENT 'Actor (NULL = sistema)',
  motivo            VARCHAR(200)    NULL COMMENT 'Motivo',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_movimiento),
  KEY idx_movinsumo_insumo (id_insumo, creado_en),
  KEY idx_movinsumo_pedido (id_pedido),
  CONSTRAINT fk_movinsumo_insumo  FOREIGN KEY (id_insumo)  REFERENCES insumo (id_insumo),
  CONSTRAINT fk_movinsumo_pedido  FOREIGN KEY (id_pedido)  REFERENCES pedido (id_pedido),
  CONSTRAINT fk_movinsumo_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_movinsumo_cantidad CHECK (cantidad <> 0 AND (tipo = 'ajuste' OR cantidad > 0) AND stock_resultante >= 0)
) ENGINE=InnoDB COMMENT='Kardex de insumos (solo inserción). HU-13';

-- =====================================================================
-- 8. CARRITO (el precio NUNCA se guarda en el carrito)
-- =====================================================================
CREATE TABLE IF NOT EXISTS carrito (
  id_carrito      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario      BIGINT UNSIGNED NOT NULL COMMENT 'Cliente (FK)',
  estado          ENUM('activo','convertido','abandonado') NOT NULL DEFAULT 'activo' COMMENT 'Un solo carrito activo por cliente',
  activo_clave    BIGINT UNSIGNED AS (IF(estado = 'activo', id_usuario, NULL)) STORED COMMENT 'Índice único: un carrito activo por cliente',
  id_pedido       BIGINT UNSIGNED NULL COMMENT 'Pedido generado al convertir (FK)',
  creado_en       DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_carrito),
  UNIQUE KEY uq_carrito_activo (activo_clave),
  KEY idx_carrito_usuario (id_usuario, estado),
  KEY idx_carrito_abandono (estado, actualizado_en),
  CONSTRAINT fk_carrito_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_carrito_pedido  FOREIGN KEY (id_pedido)  REFERENCES pedido (id_pedido),
  CONSTRAINT ck_carrito_pedido  CHECK (estado <> 'convertido' OR id_pedido IS NOT NULL)
) ENGINE=InnoDB COMMENT='Carrito de compras (sin precios)';

CREATE TABLE IF NOT EXISTS item_carrito (
  id_item_carrito BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_carrito      BIGINT UNSIGNED NOT NULL COMMENT 'Carrito (FK)',
  id_variante     BIGINT UNSIGNED NOT NULL COMMENT 'Variante (FK)',
  cantidad        INT UNSIGNED    NOT NULL COMMENT 'Unidades',
  personalizacion VARCHAR(500)    NULL COMMENT 'Texto del bordado personalizado',
  agregado_en     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Cuándo se agregó (UTC)',
  actualizado_en  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_item_carrito),
  UNIQUE KEY uq_item_carrito (id_carrito, id_variante),
  KEY idx_item_carrito_variante (id_variante),
  CONSTRAINT fk_icar_carrito  FOREIGN KEY (id_carrito)  REFERENCES carrito (id_carrito),
  CONSTRAINT fk_icar_variante FOREIGN KEY (id_variante) REFERENCES variante_producto (id_variante),
  CONSTRAINT ck_icar_cantidad CHECK (cantidad > 0 AND cantidad <= 100000)
) ENGINE=InnoDB COMMENT='Ítems del carrito (estado de interfaz: se quitan con sp_quitar_item_carrito)';

-- =====================================================================
-- 9. ENVÍO Y SEGUIMIENTO — HU-12
-- =====================================================================
CREATE TABLE IF NOT EXISTS envio (
  id_envio                BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido               BIGINT UNSIGNED  NOT NULL COMMENT 'Pedido (FK)',
  id_courier              SMALLINT UNSIGNED NULL COMMENT 'Courier (FK)',
  numero_guia             VARCHAR(60)   NULL COMMENT 'Número de guía del courier',
  estado                  ENUM('preparando','despachado','en_transito','en_reparto','entregado','incidencia','devuelto') NOT NULL DEFAULT 'preparando' COMMENT 'Estado del envío',
  costo_real              DECIMAL(8,2)  NULL COMMENT 'Costo que cobró el courier (control interno)',
  fecha_entrega_estimada  DATE          NULL COMMENT 'Fecha estimada (día de Lima)',
  despachado_en           DATETIME(3)   NULL COMMENT 'Cuándo salió',
  entregado_en            DATETIME(3)   NULL COMMENT 'Cuándo se entregó',
  observaciones           VARCHAR(300)  NULL COMMENT 'Observaciones',
  creado_en               DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por              BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por         BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_envio),
  UNIQUE KEY uq_envio_guia (id_courier, numero_guia),
  KEY idx_envio_pedido (id_pedido),
  KEY idx_envio_estado (estado, actualizado_en),
  CONSTRAINT fk_envio_pedido      FOREIGN KEY (id_pedido)       REFERENCES pedido (id_pedido),
  CONSTRAINT fk_envio_courier     FOREIGN KEY (id_courier)      REFERENCES courier (id_courier),
  CONSTRAINT fk_envio_creado      FOREIGN KEY (creado_por)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_envio_actualizado FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_envio_costo   CHECK (costo_real IS NULL OR costo_real >= 0),
  CONSTRAINT ck_envio_entrega CHECK (estado <> 'entregado' OR entregado_en IS NOT NULL)
) ENGINE=InnoDB COMMENT='Envíos del pedido (preparado para la futura API del courier)';

CREATE TABLE IF NOT EXISTS seguimiento_envio (
  id_seguimiento    BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_envio          BIGINT UNSIGNED NOT NULL COMMENT 'Envío (FK)',
  estado            ENUM('preparando','despachado','en_transito','en_reparto','entregado','incidencia','devuelto') NOT NULL COMMENT 'Estado reportado',
  descripcion       VARCHAR(300)    NULL COMMENT 'Detalle del evento',
  ubicacion         VARCHAR(120)    NULL COMMENT 'Ciudad / agencia',
  ocurrido_en       DATETIME(3)     NOT NULL COMMENT 'Cuándo ocurrió (UTC)',
  origen            ENUM('admin','api_courier','sistema') NOT NULL DEFAULT 'admin' COMMENT 'Quién informó',
  id_evento_externo VARCHAR(100)    NULL COMMENT 'Id del evento en el courier (idempotencia)',
  registrado_por    BIGINT UNSIGNED NULL COMMENT 'Actor (FK)',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Registro (UTC)',
  PRIMARY KEY (id_seguimiento),
  UNIQUE KEY uq_seguimiento_externo (id_envio, id_evento_externo),
  KEY idx_seguimiento_envio (id_envio, ocurrido_en),
  CONSTRAINT fk_seguimiento_envio   FOREIGN KEY (id_envio)       REFERENCES envio (id_envio),
  CONSTRAINT fk_seguimiento_usuario FOREIGN KEY (registrado_por) REFERENCES usuario (id_usuario)
) ENGINE=InnoDB COMMENT='Eventos de seguimiento del envío (solo inserción). HU-12';

-- =====================================================================
-- 10. PAGOS Y REEMBOLSOS
-- =====================================================================
CREATE TABLE IF NOT EXISTS metodo_pago (
  codigo            VARCHAR(20)  NOT NULL COMMENT 'Código del método',
  nombre            VARCHAR(40)  NOT NULL COMMENT 'Nombre visible',
  tipo              ENUM('pasarela','manual') NOT NULL COMMENT 'pasarela = confirma webhook; manual = valida un administrador',
  requiere_comprobante BOOLEAN   NOT NULL DEFAULT 0 COMMENT '1 = exige voucher o N.º de operación (Yape, Plin, transferencia)',
  canal             ENUM('web','presencial','ambos') NOT NULL DEFAULT 'ambos' COMMENT 'Dónde se puede usar',
  orden             TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Orden en pantalla',
  activo            BOOLEAN      NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)  NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién lo inhabilitó',
  actualizado_en    DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (codigo),
  CONSTRAINT fk_metodo_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_metodo_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_metodo_codigo CHECK (REGEXP_LIKE(codigo, '^[a-z_]{3,20}$', 'c')),
  CONSTRAINT ck_metodo_activo CHECK (activo IN (0,1) AND requiere_comprobante IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Métodos de pago (Mercado Pago, PayPal, Yape, Plin, transferencia, efectivo)';

CREATE TABLE IF NOT EXISTS pago (
  id_pago             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido           BIGINT UNSIGNED NOT NULL COMMENT 'Pedido (FK)',
  metodo              VARCHAR(20)   NOT NULL COMMENT 'Método (FK metodo_pago)',
  tipo                ENUM('adelanto','saldo','total') NOT NULL COMMENT 'Adelanto (modalidad 50 %), saldo o pago total',
  monto               DECIMAL(12,2) NOT NULL COMMENT 'Monto aplicado al pedido en su moneda (PEN)',
  moneda              CHAR(3)       NOT NULL DEFAULT 'PEN' COMMENT 'Debe ser la moneda del pedido',
  moneda_cobro        CHAR(3)       NULL COMMENT 'Moneda que cobró la pasarela si difiere (p. ej. USD en PayPal)',
  monto_cobro         DECIMAL(12,2) NULL COMMENT 'Monto cobrado por la pasarela en moneda_cobro',
  tipo_cambio         DECIMAL(10,6) NULL COMMENT 'Tipo de cambio aplicado',
  estado              ENUM('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') NOT NULL DEFAULT 'pendiente' COMMENT 'Máquina de estados (transicion_estado_pago)',
  aplicado_al_pedido  BOOLEAN       NOT NULL DEFAULT 1 COMMENT '0 = pago huérfano: se confirmó con el pedido cancelado/expirado o excedía el total (por reembolsar)',
  motivo_no_aplicado  ENUM('pedido_cancelado','pedido_expirado','excede_total') NULL COMMENT 'Por qué no se aplicó al pedido',
  referencia_externa  VARCHAR(100)  NULL COMMENT 'Id de la pasarela o N.º de operación Yape/Plin/banco',
  idempotency_key     VARCHAR(100)  NOT NULL COMMENT 'Clave única por intento de cobro (evita doble cobro por doble clic o reintentos)',
  voucher_url         VARCHAR(500)  NULL COMMENT 'Captura del voucher (Yape/Plin/transferencia)',
  datos_pasarela      JSON          NULL COMMENT 'Respuesta filtrada de la pasarela. NUNCA número de tarjeta ni CVV',
  validado_por        BIGINT UNSIGNED NULL COMMENT 'Administrador que validó o rechazó (FK)',
  validado_en         DATETIME(3)   NULL COMMENT 'Cuándo se validó',
  motivo_rechazo      VARCHAR(300)  NULL COMMENT 'Motivo del rechazo',
  ip                  VARBINARY(16) NULL COMMENT 'IP del cliente',
  confirmado_en       DATETIME(3)   NULL COMMENT 'Cuándo se confirmó',
  monto_reembolsado   DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'DERIVADO: reembolsos completados',
  operacion_clave     VARCHAR(125)  AS (IF(referencia_externa IS NOT NULL AND estado IN ('pendiente','en_revision','confirmado','reembolsado'),
                                           CONCAT(metodo, ':', referencia_externa), NULL)) STORED COMMENT 'Índice único: una operación no se usa dos veces',
  creado_en           DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en      DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por          BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por     BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_pago),
  UNIQUE KEY uq_pago_idempotencia (idempotency_key),
  UNIQUE KEY uq_pago_operacion (operacion_clave),
  KEY idx_pago_pedido (id_pedido, estado),
  KEY idx_pago_estado (estado, creado_en),
  KEY idx_pago_confirmado (confirmado_en),
  CONSTRAINT fk_pago_pedido      FOREIGN KEY (id_pedido)       REFERENCES pedido (id_pedido),
  CONSTRAINT fk_pago_metodo      FOREIGN KEY (metodo)          REFERENCES metodo_pago (codigo),
  CONSTRAINT fk_pago_validado    FOREIGN KEY (validado_por)    REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pago_creado      FOREIGN KEY (creado_por)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_pago_actualizado FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_pago_monto        CHECK (monto > 0 AND monto_reembolsado >= 0 AND monto_reembolsado <= monto),
  CONSTRAINT ck_pago_moneda       CHECK (moneda IN ('PEN') AND (moneda_cobro IS NULL OR moneda_cobro IN ('PEN','USD'))),
  CONSTRAINT ck_pago_cobro        CHECK ((moneda_cobro IS NULL) = (monto_cobro IS NULL) AND (monto_cobro IS NULL OR monto_cobro > 0)
                                         AND (tipo_cambio IS NULL OR tipo_cambio > 0)),
  CONSTRAINT ck_pago_aplicado     CHECK (aplicado_al_pedido IN (0,1) AND (aplicado_al_pedido = 1) = (motivo_no_aplicado IS NULL)),
  CONSTRAINT ck_pago_rechazo      CHECK (estado <> 'rechazado' OR motivo_rechazo IS NOT NULL),
  CONSTRAINT ck_pago_confirmado   CHECK (estado NOT IN ('confirmado','reembolsado') OR confirmado_en IS NOT NULL),
  CONSTRAINT ck_pago_reembolsado  CHECK (estado <> 'reembolsado' OR monto_reembolsado = monto),
  CONSTRAINT ck_pago_idempotencia CHECK (CHAR_LENGTH(idempotency_key) >= 16 AND REGEXP_LIKE(idempotency_key, '^[A-Za-z0-9._:-]+$', 'c')),
  CONSTRAINT ck_pago_voucher      CHECK (voucher_url IS NULL OR REGEXP_LIKE(voucher_url, '^(https://|/)[^[:space:]]+$', 'c'))
) ENGINE=InnoDB COMMENT='Pagos con máquina de estados. Un pago confirmado no se modifica: se reembolsa';

CREATE TABLE IF NOT EXISTS transicion_estado_pago (
  estado_origen  ENUM('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') NOT NULL COMMENT 'Desde',
  estado_destino ENUM('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') NOT NULL COMMENT 'Hacia',
  descripcion    VARCHAR(150) NULL COMMENT 'Explicación',
  PRIMARY KEY (estado_origen, estado_destino)
) ENGINE=InnoDB COMMENT='Transiciones permitidas de un pago';

-- =====================================================================
-- 11. COMPROBANTES ELECTRÓNICOS (OSE/PSE autorizado por SUNAT)
-- =====================================================================
CREATE TABLE IF NOT EXISTS serie_comprobante (
  id_serie            SMALLINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  tipo                ENUM('boleta','factura','nota_credito') NOT NULL COMMENT 'Tipo de comprobante',
  serie               CHAR(4)      NOT NULL COMMENT 'Serie (B### boleta, F### factura; NC: B### si anula boletas, F### si anula facturas)',
  ultimo_correlativo  INT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Último correlativo usado',
  por_verificar       BOOLEAN      NOT NULL DEFAULT 1 COMMENT '1 = serie de ejemplo: reemplazar por la real del OSE',
  activo              BOOLEAN      NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en     DATETIME(3)  NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por    BIGINT UNSIGNED NULL COMMENT 'Quién la inhabilitó',
  creado_en           DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en      DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_serie),
  UNIQUE KEY uq_serie_tipo (tipo, serie),
  CONSTRAINT fk_serie_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_serie_formato CHECK (
        (tipo = 'boleta'       AND REGEXP_LIKE(serie, '^B[A-Z0-9]{3}$', 'c'))
     OR (tipo = 'factura'      AND REGEXP_LIKE(serie, '^F[A-Z0-9]{3}$', 'c'))
     OR (tipo = 'nota_credito' AND REGEXP_LIKE(serie, '^[BF][A-Z0-9]{3}$', 'c'))),
  CONSTRAINT ck_serie_correlativo CHECK (ultimo_correlativo <= 99999999),
  CONSTRAINT ck_serie_activo      CHECK (activo IN (0,1) AND por_verificar IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Series de comprobantes y su correlativo atómico';

CREATE TABLE IF NOT EXISTS motivo_nota_credito (
  codigo        CHAR(2)      NOT NULL COMMENT 'Código SUNAT (catálogo 09)',
  descripcion   VARCHAR(200) NOT NULL COMMENT 'Descripción SUNAT',
  es_total      BOOLEAN      NOT NULL DEFAULT 0 COMMENT '1 = la NC debe ser por el total pendiente del comprobante',
  repone_stock  BOOLEAN      NOT NULL DEFAULT 0 COMMENT '1 = corresponde a una devolución de mercadería',
  activo        BOOLEAN      NOT NULL DEFAULT 1 COMMENT 'Disponible para usar',
  PRIMARY KEY (codigo),
  CONSTRAINT ck_motivo_nc CHECK (REGEXP_LIKE(codigo, '^[0-9]{2}$', 'c') AND es_total IN (0,1) AND repone_stock IN (0,1) AND activo IN (0,1))
) ENGINE=InnoDB COMMENT='Catálogo SUNAT N.º 09: tipos de nota de crédito';

CREATE TABLE IF NOT EXISTS comprobante (
  id_comprobante          BIGINT UNSIGNED   NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pedido               BIGINT UNSIGNED   NOT NULL COMMENT 'Pedido (FK)',
  tipo                    ENUM('boleta','factura','nota_credito') NOT NULL COMMENT 'Tipo de comprobante',
  codigo_tipo_sunat       CHAR(2) AS (CASE tipo WHEN 'factura' THEN '01' WHEN 'boleta' THEN '03' ELSE '07' END) STORED COMMENT 'Catálogo 01 SUNAT: 01 factura, 03 boleta, 07 nota de crédito',
  id_serie                SMALLINT UNSIGNED NOT NULL COMMENT 'Serie usada (FK)',
  serie                   CHAR(4)       NOT NULL COMMENT 'Copia de la serie',
  correlativo             INT UNSIGNED  NOT NULL COMMENT 'Correlativo dentro de la serie',
  numero_completo         VARCHAR(13) AS (CONCAT(serie, '-', LPAD(correlativo, 8, '0'))) STORED COMMENT 'Serie-correlativo (F001-00000001)',
  id_comprobante_ref      BIGINT UNSIGNED NULL COMMENT 'Comprobante que corrige la nota de crédito (FK)',
  codigo_motivo_nc        CHAR(2)       NULL COMMENT 'Motivo de la NC (FK catálogo 09)',
  motivo_detalle          VARCHAR(250)  NULL COMMENT 'Sustento de la NC',
  id_devolucion           BIGINT UNSIGNED NULL COMMENT 'Devolución que originó la NC (FK)',
  fecha_emision           DATE          NOT NULL COMMENT 'Fecha de emisión (día de Lima)',
  emisor_ruc              CHAR(11)      NOT NULL COMMENT 'Copia: RUC del emisor',
  emisor_razon_social     VARCHAR(200)  NOT NULL COMMENT 'Copia: razón social del emisor',
  emisor_nombre_comercial VARCHAR(200)  NULL COMMENT 'Copia: nombre comercial',
  emisor_domicilio_fiscal VARCHAR(300)  NOT NULL COMMENT 'Copia: domicilio fiscal del emisor',
  cliente_tipo_doc        ENUM('DNI','RUC','CE') NULL COMMENT 'Copia: tipo de documento del cliente (NULL = sin documento, solo boleta bajo el umbral)',
  cliente_num_doc         VARCHAR(12)   NULL COMMENT 'Copia: número de documento',
  cliente_nombre          VARCHAR(200)  NOT NULL COMMENT 'Copia: nombre o razón social',
  cliente_direccion       VARCHAR(300)  NULL COMMENT 'Copia: dirección / domicilio fiscal',
  cliente_correo          VARCHAR(254)  NULL COMMENT 'Copia: correo de envío',
  moneda                  CHAR(3)       NOT NULL DEFAULT 'PEN' COMMENT 'Moneda',
  igv_porcentaje          DECIMAL(5,2)  NOT NULL COMMENT 'Tasa de IGV aplicada (copia)',
  op_gravada              DECIMAL(12,2) NOT NULL COMMENT 'Operaciones gravadas (sin IGV)',
  op_exonerada            DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'Operaciones exoneradas',
  op_inafecta             DECIMAL(12,2) NOT NULL DEFAULT 0 COMMENT 'Operaciones inafectas',
  igv                     DECIMAL(12,2) NOT NULL COMMENT 'IGV',
  total                   DECIMAL(12,2) NOT NULL COMMENT 'Importe total',
  estado_sunat            ENUM('pendiente','enviado','aceptado','observado','rechazado','anulado','error') NOT NULL DEFAULT 'pendiente' COMMENT 'Estado ante SUNAT/OSE',
  proveedor_ose           VARCHAR(40)   NULL COMMENT 'Proveedor OSE/PSE usado',
  id_externo              VARCHAR(100)  NULL COMMENT 'Id del comprobante en el OSE/PSE',
  hash_cpe                VARCHAR(100)  NULL COMMENT 'Hash / código de resumen del CPE',
  codigo_respuesta_sunat  VARCHAR(10)   NULL COMMENT 'Código de respuesta del CDR',
  mensaje_sunat           TEXT          NULL COMMENT 'Mensaje de SUNAT/OSE',
  url_pdf                 VARCHAR(500)  NULL COMMENT 'URL del PDF en el OSE',
  url_xml                 VARCHAR(500)  NULL COMMENT 'URL del XML firmado',
  url_cdr                 VARCHAR(500)  NULL COMMENT 'URL del CDR',
  payload_envio           JSON          NULL COMMENT 'JSON enviado al OSE (copia exacta)',
  payload_respuesta       JSON          NULL COMMENT 'Respuesta del OSE (copia exacta)',
  enviado_correo_en       DATETIME(3)   NULL COMMENT 'Cuándo se envió al cliente',
  aceptado_en             DATETIME(3)   NULL COMMENT 'Cuándo lo aceptó SUNAT/OSE',
  pedido_activo_clave     BIGINT UNSIGNED AS (IF(tipo IN ('boleta','factura') AND estado_sunat NOT IN ('rechazado','anulado'), id_pedido, NULL)) STORED COMMENT 'Índice único: una sola boleta/factura vigente por pedido (idempotencia de emisión)',
  emitido_en              DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Registro (UTC)',
  actualizado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por              BIGINT UNSIGNED NULL COMMENT 'Actor que emitió',
  PRIMARY KEY (id_comprobante),
  UNIQUE KEY uq_comprobante_numero (tipo, serie, correlativo),
  UNIQUE KEY uq_comprobante_pedido_activo (pedido_activo_clave),
  KEY idx_comprobante_pedido (id_pedido),
  KEY idx_comprobante_ref (id_comprobante_ref),
  KEY idx_comprobante_estado (estado_sunat, emitido_en),
  KEY idx_comprobante_fecha (fecha_emision),
  CONSTRAINT fk_comprobante_pedido     FOREIGN KEY (id_pedido)          REFERENCES pedido (id_pedido),
  CONSTRAINT fk_comprobante_serie      FOREIGN KEY (id_serie)           REFERENCES serie_comprobante (id_serie),
  CONSTRAINT fk_comprobante_ref        FOREIGN KEY (id_comprobante_ref) REFERENCES comprobante (id_comprobante),
  CONSTRAINT fk_comprobante_motivo     FOREIGN KEY (codigo_motivo_nc)   REFERENCES motivo_nota_credito (codigo),
  CONSTRAINT fk_comprobante_devolucion FOREIGN KEY (id_devolucion)      REFERENCES devolucion (id_devolucion),
  CONSTRAINT fk_comprobante_creado     FOREIGN KEY (creado_por)         REFERENCES usuario (id_usuario),
  CONSTRAINT ck_comprobante_cuadre     CHECK (op_gravada + op_exonerada + op_inafecta + igv = total),
  CONSTRAINT ck_comprobante_montos     CHECK (op_gravada >= 0 AND op_exonerada >= 0 AND op_inafecta >= 0 AND igv >= 0 AND total > 0),
  CONSTRAINT ck_comprobante_serie      CHECK ((tipo = 'boleta' AND serie LIKE 'B%') OR (tipo = 'factura' AND serie LIKE 'F%')
                                              OR (tipo = 'nota_credito' AND (serie LIKE 'B%' OR serie LIKE 'F%'))),
  CONSTRAINT ck_comprobante_factura    CHECK (tipo <> 'factura' OR (cliente_tipo_doc = 'RUC' AND cliente_num_doc IS NOT NULL)),
  CONSTRAINT ck_comprobante_nc         CHECK ((tipo = 'nota_credito') = (id_comprobante_ref IS NOT NULL)
                                              AND (tipo <> 'nota_credito' OR (codigo_motivo_nc IS NOT NULL AND motivo_detalle IS NOT NULL))),
  CONSTRAINT ck_comprobante_moneda     CHECK (moneda IN ('PEN')),
  CONSTRAINT ck_comprobante_ruc        CHECK (REGEXP_LIKE(emisor_ruc, '^(10|15|16|17|20)[0-9]{9}$', 'c')),
  CONSTRAINT ck_comprobante_documento  CHECK (
        (cliente_tipo_doc IS NULL AND cliente_num_doc IS NULL)
     OR (cliente_tipo_doc = 'DNI' AND REGEXP_LIKE(cliente_num_doc, '^[0-9]{8}$', 'c'))
     OR (cliente_tipo_doc = 'RUC' AND REGEXP_LIKE(cliente_num_doc, '^(10|15|16|17|20)[0-9]{9}$', 'c'))
     OR (cliente_tipo_doc = 'CE'  AND REGEXP_LIKE(cliente_num_doc, '^[A-Z0-9]{6,12}$', 'c'))),
  CONSTRAINT ck_comprobante_aceptado   CHECK (estado_sunat NOT IN ('aceptado','observado') OR aceptado_en IS NOT NULL),
  CONSTRAINT ck_comprobante_correlativo CHECK (correlativo BETWEEN 1 AND 99999999)
) ENGINE=InnoDB COMMENT='Comprobantes electrónicos con copia completa de lo emitido (emisor y cliente congelados, payloads del OSE)';

CREATE TABLE IF NOT EXISTS comprobante_item (
  id_comprobante_item   BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_comprobante        BIGINT UNSIGNED NOT NULL COMMENT 'Comprobante (FK)',
  orden                 SMALLINT UNSIGNED NOT NULL COMMENT 'N.º de línea',
  id_item_pedido        BIGINT UNSIGNED NULL COMMENT 'Ítem del pedido de origen (NULL en la línea de envío)',
  codigo_producto       VARCHAR(40)   NULL COMMENT 'SKU o código interno',
  descripcion           VARCHAR(250)  NOT NULL COMMENT 'Descripción impresa',
  unidad_medida         CHAR(3)       NOT NULL DEFAULT 'NIU' COMMENT 'Unidad SUNAT (NIU bienes, ZZ servicios)',
  cantidad              DECIMAL(12,3) NOT NULL COMMENT 'Cantidad',
  precio_unitario       DECIMAL(12,2) NOT NULL COMMENT 'Precio unitario con IGV',
  valor_unitario        DECIMAL(16,6) NOT NULL COMMENT 'Valor unitario sin IGV',
  valor_venta           DECIMAL(12,2) NOT NULL COMMENT 'Valor de venta de la línea (sin IGV)',
  igv                   DECIMAL(12,2) NOT NULL COMMENT 'IGV de la línea',
  total_linea           DECIMAL(12,2) NOT NULL COMMENT 'Total de la línea con IGV',
  codigo_afectacion_igv CHAR(2)       NOT NULL DEFAULT '10' COMMENT 'Tipo de afectación IGV (catálogo 07)',
  PRIMARY KEY (id_comprobante_item),
  UNIQUE KEY uq_comprobante_item_orden (id_comprobante, orden),
  KEY idx_comprobante_item_pedido (id_item_pedido),
  CONSTRAINT fk_citem_comprobante FOREIGN KEY (id_comprobante) REFERENCES comprobante (id_comprobante),
  CONSTRAINT fk_citem_item        FOREIGN KEY (id_item_pedido) REFERENCES item_pedido (id_item_pedido),
  CONSTRAINT ck_citem_cuadre      CHECK (valor_venta + igv = total_linea),
  CONSTRAINT ck_citem_montos      CHECK (cantidad > 0 AND precio_unitario > 0 AND valor_unitario > 0 AND valor_venta > 0 AND igv >= 0)
) ENGINE=InnoDB COMMENT='Líneas del comprobante tal como se emitieron (solo inserción)';

CREATE TABLE IF NOT EXISTS comprobante_archivo (
  id_archivo      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_comprobante  BIGINT UNSIGNED NOT NULL COMMENT 'Comprobante (FK)',
  tipo            ENUM('pdf','xml','cdr') NOT NULL COMMENT 'Tipo de archivo',
  mime            VARCHAR(60)   NOT NULL COMMENT 'Tipo MIME',
  contenido       LONGBLOB      NOT NULL COMMENT 'Copia binaria del archivo (respaldo si la URL del OSE deja de funcionar)',
  tamano_bytes    INT UNSIGNED  NOT NULL COMMENT 'Tamaño',
  sha256          CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'Huella del contenido (integridad)',
  creado_en       DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Registro (UTC)',
  PRIMARY KEY (id_archivo),
  UNIQUE KEY uq_archivo_tipo (id_comprobante, tipo),
  CONSTRAINT fk_archivo_comprobante FOREIGN KEY (id_comprobante) REFERENCES comprobante (id_comprobante),
  CONSTRAINT ck_archivo_tamano CHECK (tamano_bytes > 0 AND tamano_bytes <= 16777216),
  CONSTRAINT ck_archivo_sha    CHECK (REGEXP_LIKE(sha256, '^[0-9a-f]{64}$', 'c'))
) ENGINE=InnoDB COMMENT='PDF/XML/CDR del comprobante en BLOB, tabla aparte para no cargar la cabecera (solo inserción)';

CREATE TABLE IF NOT EXISTS cola_emision_comprobante (
  id_trabajo          BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_comprobante      BIGINT UNSIGNED  NOT NULL COMMENT 'Comprobante a emitir (FK, uno por comprobante)',
  estado              ENUM('pendiente','procesando','completado','error','descartado') NOT NULL DEFAULT 'pendiente' COMMENT 'Estado del trabajo',
  intentos            SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Intentos realizados',
  max_intentos        SMALLINT UNSIGNED NOT NULL DEFAULT 8 COMMENT 'Tope de intentos',
  proximo_intento_en  DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'No antes de (backoff exponencial)',
  ultimo_error        TEXT          NULL COMMENT 'Último error',
  tomado_por          VARCHAR(64)   NULL COMMENT 'Worker que lo tomó',
  tomado_en           DATETIME(3)   NULL COMMENT 'Cuándo lo tomó',
  creado_en           DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en      DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_trabajo),
  UNIQUE KEY uq_cola_emision_comprobante (id_comprobante),
  KEY idx_cola_emision (estado, proximo_intento_en),
  CONSTRAINT fk_cola_emision_comprobante FOREIGN KEY (id_comprobante) REFERENCES comprobante (id_comprobante),
  CONSTRAINT ck_cola_emision_intentos CHECK (intentos <= max_intentos AND max_intentos BETWEEN 1 AND 50)
) ENGINE=InnoDB COMMENT='Cola de emisión asíncrona y reintentable hacia el OSE/PSE';

CREATE TABLE IF NOT EXISTS reembolso (
  id_reembolso        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_pago             BIGINT UNSIGNED NOT NULL COMMENT 'Pago que se devuelve (FK)',
  id_pedido           BIGINT UNSIGNED NOT NULL COMMENT 'Pedido (FK, coherente con el pago)',
  monto               DECIMAL(12,2) NOT NULL COMMENT 'Monto a devolver (PEN)',
  motivo              ENUM('cancelacion','devolucion','pago_huerfano','excedente','error_cobro','ajuste_precio','otro') NOT NULL COMMENT 'Motivo (ajuste_precio = descuento o compensación posterior a la venta)',
  detalle             VARCHAR(300)  NULL COMMENT 'Detalle',
  estado              ENUM('solicitado','procesando','completado','fallido','anulado') NOT NULL DEFAULT 'solicitado' COMMENT 'Estado del reembolso',
  medio               ENUM('pasarela','yape','plin','transferencia','efectivo') NOT NULL COMMENT 'Por dónde se devuelve',
  referencia_externa  VARCHAR(100)  NULL COMMENT 'Id del reembolso en la pasarela o N.º de operación',
  id_nota_credito     BIGINT UNSIGNED NULL COMMENT 'Nota de crédito asociada (FK)',
  id_devolucion       BIGINT UNSIGNED NULL COMMENT 'Devolución asociada (FK)',
  solicitado_por      BIGINT UNSIGNED NULL COMMENT 'Quién lo solicitó',
  procesado_por       BIGINT UNSIGNED NULL COMMENT 'Quién lo completó',
  completado_en       DATETIME(3)   NULL COMMENT 'Cuándo se completó',
  error               VARCHAR(300)  NULL COMMENT 'Error si falló',
  creado_en           DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en      DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_reembolso),
  KEY idx_reembolso_pago (id_pago, estado),
  KEY idx_reembolso_pedido (id_pedido),
  KEY idx_reembolso_estado (estado, creado_en),
  CONSTRAINT fk_reembolso_pago       FOREIGN KEY (id_pago)         REFERENCES pago (id_pago),
  CONSTRAINT fk_reembolso_pedido     FOREIGN KEY (id_pedido)       REFERENCES pedido (id_pedido),
  CONSTRAINT fk_reembolso_nc         FOREIGN KEY (id_nota_credito) REFERENCES comprobante (id_comprobante),
  CONSTRAINT fk_reembolso_devolucion FOREIGN KEY (id_devolucion)   REFERENCES devolucion (id_devolucion),
  CONSTRAINT fk_reembolso_solicitado FOREIGN KEY (solicitado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT fk_reembolso_procesado  FOREIGN KEY (procesado_por)   REFERENCES usuario (id_usuario),
  CONSTRAINT ck_reembolso_monto      CHECK (monto > 0),
  CONSTRAINT ck_reembolso_completado CHECK ((estado = 'completado') = (completado_en IS NOT NULL)),
  CONSTRAINT ck_reembolso_fallido    CHECK (estado <> 'fallido' OR error IS NOT NULL)
) ENGINE=InnoDB COMMENT='Reembolsos: quién, cuánto, por qué y referencia de la pasarela';

CREATE TABLE IF NOT EXISTS evento_pasarela (
  id_evento       BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  proveedor       ENUM('mercadopago','paypal','ose','courier') NOT NULL COMMENT 'Quién envió el webhook',
  id_externo      VARCHAR(150)  NOT NULL COMMENT 'Id del evento en el proveedor (idempotencia)',
  tipo            VARCHAR(80)   NULL COMMENT 'Tipo de evento (payment.updated, ...)',
  payload         JSON          NOT NULL COMMENT 'Cuerpo recibido (sin datos de tarjeta)',
  firma_valida    BOOLEAN       NOT NULL COMMENT '1 = la app verificó la firma del webhook',
  estado          ENUM('recibido','procesado','ignorado','error') NOT NULL DEFAULT 'recibido' COMMENT 'Procesamiento',
  intentos        SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Veces que llegó/procesó',
  error           TEXT          NULL COMMENT 'Error de procesamiento',
  id_pago         BIGINT UNSIGNED NULL COMMENT 'Pago afectado (FK)',
  id_comprobante  BIGINT UNSIGNED NULL COMMENT 'Comprobante afectado (FK)',
  recibido_en     DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Recepción (UTC)',
  procesado_en    DATETIME(3)   NULL COMMENT 'Procesamiento (UTC)',
  PRIMARY KEY (id_evento),
  UNIQUE KEY uq_evento_proveedor (proveedor, id_externo),
  KEY idx_evento_estado (estado, recibido_en),
  CONSTRAINT fk_evento_pago        FOREIGN KEY (id_pago)        REFERENCES pago (id_pago),
  CONSTRAINT fk_evento_comprobante FOREIGN KEY (id_comprobante) REFERENCES comprobante (id_comprobante),
  CONSTRAINT ck_evento_firma       CHECK (firma_valida IN (0,1))
) ENGINE=InnoDB COMMENT='Webhooks recibidos (idempotentes: cada evento se procesa una sola vez)';

-- =====================================================================
-- 12. ATENCIÓN AL CLIENTE
-- =====================================================================
CREATE TABLE IF NOT EXISTS mensaje_contacto (
  id_mensaje      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  ticket          VARCHAR(25)   NOT NULL COMMENT 'Correlativo anual TK-AAAA-NNNNNN',
  id_usuario      BIGINT UNSIGNED NULL COMMENT 'Usuario si estaba logueado (FK)',
  nombre          VARCHAR(100)  NOT NULL COMMENT 'Nombre',
  correo          VARCHAR(254)  NOT NULL COMMENT 'Correo (normalizado)',
  celular         VARCHAR(16)   NULL COMMENT 'Celular',
  asunto          ENUM('producto','pedido','mayor','sugerencia','otro') NOT NULL COMMENT 'Asunto',
  id_pedido       BIGINT UNSIGNED NULL COMMENT 'Pedido relacionado (FK)',
  mensaje         VARCHAR(2000) NOT NULL COMMENT 'Mensaje (mín. 10 caracteres)',
  acepto_datos    BOOLEAN       NOT NULL COMMENT 'Aceptó la política de datos (obligatorio)',
  ip              VARBINARY(16) NULL COMMENT 'IP (límite 3 por hora)',
  estado          ENUM('nuevo','en_proceso','respondido','cerrado') NOT NULL DEFAULT 'nuevo' COMMENT 'Estado del ticket',
  atendido_por    BIGINT UNSIGNED NULL COMMENT 'Administrador asignado (FK)',
  creado_en       DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Recepción (UTC)',
  actualizado_en  DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_mensaje),
  UNIQUE KEY uq_mensaje_ticket (ticket),
  KEY idx_mensaje_estado (estado, creado_en),
  KEY idx_mensaje_ip (ip, creado_en),
  CONSTRAINT fk_mensaje_usuario  FOREIGN KEY (id_usuario)   REFERENCES usuario (id_usuario),
  CONSTRAINT fk_mensaje_pedido   FOREIGN KEY (id_pedido)    REFERENCES pedido (id_pedido),
  CONSTRAINT fk_mensaje_atendido FOREIGN KEY (atendido_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_mensaje_texto    CHECK (CHAR_LENGTH(TRIM(mensaje)) >= 10 AND CHAR_LENGTH(TRIM(nombre)) >= 2),
  CONSTRAINT ck_mensaje_datos    CHECK (acepto_datos = 1),
  CONSTRAINT ck_mensaje_correo   CHECK (REGEXP_LIKE(correo, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c')),
  CONSTRAINT ck_mensaje_celular  CHECK (celular IS NULL OR REGEXP_LIKE(celular, '^[+]?[0-9]{9,15}$', 'c'))
) ENGINE=InnoDB COMMENT='Mensajes de contacto como tickets (máx. 3 por hora por IP)';

CREATE TABLE IF NOT EXISTS reclamo (
  id_reclamo         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  numero             VARCHAR(25)   NOT NULL COMMENT 'Correlativo anual LR-AAAA-NNNNNN',
  id_usuario         BIGINT UNSIGNED NULL COMMENT 'Usuario si estaba logueado (FK)',
  nombres            VARCHAR(100)  NOT NULL COMMENT 'Nombres del consumidor',
  apellidos          VARCHAR(100)  NOT NULL COMMENT 'Apellidos del consumidor',
  tipo_doc           ENUM('DNI','RUC','CE') NOT NULL COMMENT 'Documento',
  num_doc            VARCHAR(12)   NOT NULL COMMENT 'Número de documento',
  domicilio          VARCHAR(200)  NOT NULL COMMENT 'Domicilio',
  correo             VARCHAR(254)  NOT NULL COMMENT 'Correo (normalizado)',
  celular            VARCHAR(16)   NOT NULL COMMENT 'Teléfono',
  es_menor_edad      BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = consumidor menor de edad',
  apoderado_nombre   VARCHAR(200)  NULL COMMENT 'Padre/madre/apoderado si es menor',
  tipo_bien          ENUM('producto','servicio') NOT NULL COMMENT 'Bien contratado',
  monto_reclamado    DECIMAL(12,2) NULL COMMENT 'Monto reclamado',
  descripcion_bien   VARCHAR(300)  NOT NULL COMMENT 'Descripción del bien',
  tipo               ENUM('reclamo','queja') NOT NULL COMMENT 'Reclamo o queja',
  detalle            TEXT          NOT NULL COMMENT 'Detalle',
  pedido_consumidor  TEXT          NOT NULL COMMENT 'Lo que pide el consumidor',
  id_pedido          BIGINT UNSIGNED NULL COMMENT 'Pedido relacionado (FK)',
  estado             ENUM('registrado','en_atencion','respondido','cerrado') NOT NULL DEFAULT 'registrado' COMMENT 'Estado',
  fecha_limite       DATE          NOT NULL COMMENT 'Fecha límite de respuesta (plazo configurable: verificar INDECOPI)',
  respondido_por     BIGINT UNSIGNED NULL COMMENT 'Quién respondió (FK)',
  respondido_en      DATETIME(3)   NULL COMMENT 'Cuándo respondió',
  acepto_datos       BOOLEAN       NOT NULL COMMENT 'Aceptó la política de datos',
  ip                 VARBINARY(16) NULL COMMENT 'IP',
  creado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Registro (UTC)',
  actualizado_en     DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_reclamo),
  UNIQUE KEY uq_reclamo_numero (numero),
  KEY idx_reclamo_estado (estado, fecha_limite),
  KEY idx_reclamo_ip (ip, creado_en),
  CONSTRAINT fk_reclamo_usuario    FOREIGN KEY (id_usuario)     REFERENCES usuario (id_usuario),
  CONSTRAINT fk_reclamo_pedido     FOREIGN KEY (id_pedido)      REFERENCES pedido (id_pedido),
  CONSTRAINT fk_reclamo_respondido FOREIGN KEY (respondido_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_reclamo_monto      CHECK (monto_reclamado IS NULL OR monto_reclamado >= 0),
  CONSTRAINT ck_reclamo_menor      CHECK (es_menor_edad IN (0,1) AND (es_menor_edad = 0 OR apoderado_nombre IS NOT NULL)),
  CONSTRAINT ck_reclamo_datos      CHECK (acepto_datos = 1),
  CONSTRAINT ck_reclamo_respuesta  CHECK (estado NOT IN ('respondido','cerrado') OR respondido_en IS NOT NULL),
  CONSTRAINT ck_reclamo_correo     CHECK (REGEXP_LIKE(correo, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c')),
  CONSTRAINT ck_reclamo_documento  CHECK (
        (tipo_doc = 'DNI' AND REGEXP_LIKE(num_doc, '^[0-9]{8}$', 'c'))
     OR (tipo_doc = 'RUC' AND REGEXP_LIKE(num_doc, '^(10|15|16|17|20)[0-9]{9}$', 'c'))
     OR (tipo_doc = 'CE'  AND REGEXP_LIKE(num_doc, '^[A-Z0-9]{6,12}$', 'c')))
) ENGINE=InnoDB COMMENT='Libro de Reclamaciones virtual (plazo configurable, verificar INDECOPI)';

CREATE TABLE IF NOT EXISTS respuesta_atencion (
  id_respuesta  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_mensaje    BIGINT UNSIGNED NULL COMMENT 'Ticket de contacto (FK) — exactamente uno de los dos',
  id_reclamo    BIGINT UNSIGNED NULL COMMENT 'Reclamo (FK) — exactamente uno de los dos',
  autor         ENUM('administrador','cliente') NOT NULL COMMENT 'Quién escribe',
  id_usuario    BIGINT UNSIGNED NULL COMMENT 'Usuario autor (FK)',
  mensaje       TEXT            NOT NULL COMMENT 'Texto de la respuesta',
  creado_en     DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_respuesta),
  KEY idx_respuesta_mensaje (id_mensaje, creado_en),
  KEY idx_respuesta_reclamo (id_reclamo, creado_en),
  CONSTRAINT fk_respuesta_mensaje FOREIGN KEY (id_mensaje) REFERENCES mensaje_contacto (id_mensaje),
  CONSTRAINT fk_respuesta_reclamo FOREIGN KEY (id_reclamo) REFERENCES reclamo (id_reclamo),
  CONSTRAINT fk_respuesta_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_respuesta_destino CHECK ((id_mensaje IS NULL) <> (id_reclamo IS NULL)),
  CONSTRAINT ck_respuesta_texto   CHECK (CHAR_LENGTH(TRIM(mensaje)) >= 2)
) ENGINE=InnoDB COMMENT='Historial de respuestas de tickets y reclamos (solo inserción)';

CREATE TABLE IF NOT EXISTS banner (
  id_banner         BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  titulo            VARCHAR(120)  NOT NULL COMMENT 'Título',
  subtitulo         VARCHAR(200)  NULL COMMENT 'Subtítulo',
  imagen_url        VARCHAR(500)  NOT NULL COMMENT 'Imagen',
  enlace            VARCHAR(300)  NULL COMMENT 'Enlace al hacer clic',
  texto_boton       VARCHAR(40)   NULL COMMENT 'Texto del botón',
  orden             SMALLINT      NOT NULL DEFAULT 0 COMMENT 'Orden',
  vigente_desde     DATETIME(3)   NULL COMMENT 'Desde (UTC)',
  vigente_hasta     DATETIME(3)   NULL COMMENT 'Hasta (UTC)',
  activo            BOOLEAN       NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  inhabilitado_en   DATETIME(3)   NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por  BIGINT UNSIGNED NULL COMMENT 'Quién lo inhabilitó',
  creado_en         DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por        BIGINT UNSIGNED NULL COMMENT 'Actor que creó',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor que modificó',
  PRIMARY KEY (id_banner),
  KEY idx_banner_vigencia (activo, vigente_desde, vigente_hasta),
  CONSTRAINT fk_banner_inhabilitado FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_banner_creado       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_banner_actualizado  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_banner_vigencia CHECK (vigente_hasta IS NULL OR vigente_desde IS NULL OR vigente_hasta > vigente_desde),
  CONSTRAINT ck_banner_url      CHECK (REGEXP_LIKE(imagen_url, '^(https://|/)[^[:space:]]+$', 'c')),
  CONSTRAINT ck_banner_activo   CHECK (activo IN (0,1) AND (activo = 0) = (inhabilitado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Banners de portada';

CREATE TABLE IF NOT EXISTS resena (
  id_resena          BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_producto        BIGINT UNSIGNED  NOT NULL COMMENT 'Producto (FK)',
  id_usuario         BIGINT UNSIGNED  NOT NULL COMMENT 'Cliente (FK)',
  id_pedido          BIGINT UNSIGNED  NOT NULL COMMENT 'Pedido entregado que lo habilita (FK)',
  calificacion       TINYINT UNSIGNED NOT NULL COMMENT 'Estrellas 1 a 5',
  titulo             VARCHAR(100)  NULL COMMENT 'Título',
  comentario         VARCHAR(1000) NULL COMMENT 'Comentario',
  estado             ENUM('pendiente','publicada','rechazada','oculta') NOT NULL DEFAULT 'pendiente' COMMENT 'Moderación del administrador',
  moderado_por       BIGINT UNSIGNED NULL COMMENT 'Administrador que moderó (FK)',
  moderado_en        DATETIME(3)   NULL COMMENT 'Cuándo se moderó',
  motivo_moderacion  VARCHAR(200)  NULL COMMENT 'Motivo de rechazo u ocultamiento',
  creado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en     DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_resena),
  UNIQUE KEY uq_resena_usuario_producto (id_producto, id_usuario),
  KEY idx_resena_producto (id_producto, estado),
  CONSTRAINT fk_resena_producto FOREIGN KEY (id_producto)  REFERENCES producto (id_producto),
  CONSTRAINT fk_resena_usuario  FOREIGN KEY (id_usuario)   REFERENCES usuario (id_usuario),
  CONSTRAINT fk_resena_pedido   FOREIGN KEY (id_pedido)    REFERENCES pedido (id_pedido),
  CONSTRAINT fk_resena_moderado FOREIGN KEY (moderado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_resena_calificacion CHECK (calificacion BETWEEN 1 AND 5),
  CONSTRAINT ck_resena_moderacion   CHECK (estado = 'pendiente' OR moderado_en IS NOT NULL),
  CONSTRAINT ck_resena_motivo       CHECK (estado NOT IN ('rechazada','oculta') OR motivo_moderacion IS NOT NULL)
) ENGINE=InnoDB COMMENT='Reseñas: solo quien compró y recibió; una por producto y usuario; moderadas';

-- =====================================================================
-- 13. COLAS, NOTIFICACIONES Y APIs EXTERNAS
-- =====================================================================
CREATE TABLE IF NOT EXISTS cola_correo (
  id_correo             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario            BIGINT UNSIGNED  NULL COMMENT 'Destinatario registrado (FK)',
  destinatario          VARCHAR(254)  NOT NULL COMMENT 'Correo destino (normalizado)',
  plantilla             VARCHAR(60)   NOT NULL COMMENT 'Plantilla de la app (pedido_confirmado, ...)',
  contexto              JSON          NULL COMMENT 'Datos para la plantilla. Nunca códigos de verificación ni contraseñas',
  prioridad             TINYINT UNSIGNED NOT NULL DEFAULT 5 COMMENT '1 = más urgente',
  estado                ENUM('pendiente','procesando','enviado','error','descartado') NOT NULL DEFAULT 'pendiente' COMMENT 'Estado',
  intentos              SMALLINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Intentos de envío',
  max_intentos          SMALLINT UNSIGNED NOT NULL DEFAULT 5 COMMENT 'Tope de intentos',
  proximo_intento_en    DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'No antes de (backoff)',
  ultimo_error          VARCHAR(500)  NULL COMMENT 'Último error SMTP/API',
  id_mensaje_proveedor  VARCHAR(150)  NULL COMMENT 'Id devuelto por el servidor de correo',
  tomado_por            VARCHAR(64)   NULL COMMENT 'Worker que lo tomó',
  enviado_en            DATETIME(3)   NULL COMMENT 'Envío (UTC)',
  creado_en             DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en        DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_correo),
  KEY idx_cola_correo (estado, prioridad, proximo_intento_en),
  KEY idx_cola_correo_usuario (id_usuario, creado_en),
  CONSTRAINT fk_cola_correo_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_cola_correo_intentos CHECK (intentos <= max_intentos AND prioridad BETWEEN 1 AND 9),
  CONSTRAINT ck_cola_correo_enviado  CHECK ((estado = 'enviado') = (enviado_en IS NOT NULL)),
  CONSTRAINT ck_cola_correo_destino  CHECK (REGEXP_LIKE(destinatario, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c'))
) ENGINE=InnoDB COMMENT='Cola de correos con reintentos (el envío lo hace la app por SMTP o servicio transaccional). RNF 18';

CREATE TABLE IF NOT EXISTS notificacion (
  id_notificacion BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario      BIGINT UNSIGNED NOT NULL COMMENT 'Destinatario (FK)',
  tipo            VARCHAR(40)   NOT NULL COMMENT 'Tipo (pedido_confirmado, stock_bajo, ...)',
  titulo          VARCHAR(120)  NOT NULL COMMENT 'Título',
  mensaje         VARCHAR(300)  NULL COMMENT 'Mensaje',
  enlace          VARCHAR(300)  NULL COMMENT 'Ruta dentro del sistema',
  id_pedido       BIGINT UNSIGNED NULL COMMENT 'Pedido relacionado (FK)',
  leida           BOOLEAN       NOT NULL DEFAULT 0 COMMENT '1 = leída',
  leida_en        DATETIME(3)   NULL COMMENT 'Cuándo se leyó',
  creado_en       DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  PRIMARY KEY (id_notificacion),
  KEY idx_notificacion_usuario (id_usuario, leida, creado_en),
  CONSTRAINT fk_notificacion_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_notificacion_pedido  FOREIGN KEY (id_pedido)  REFERENCES pedido (id_pedido),
  CONSTRAINT ck_notificacion_leida   CHECK (leida IN (0,1) AND (leida = 1) = (leida_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Notificaciones dentro del sistema';

-- Sin FK a propósito (bitácora técnica que puede sobrevivir a los datos y particionarse por fecha).
CREATE TABLE IF NOT EXISTS log_api_externa (
  id_log                BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  creado_en             DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento de la llamada (UTC)',
  proveedor             ENUM('ose','reniec','sunat_ruc','mercadopago','paypal','courier','correo','otro') NOT NULL COMMENT 'API externa',
  endpoint              VARCHAR(300)  NOT NULL COMMENT 'Ruta llamada (sin tokens en la URL)',
  metodo_http           ENUM('GET','POST','PUT','PATCH','DELETE') NOT NULL COMMENT 'Método HTTP',
  codigo_http           SMALLINT UNSIGNED NULL COMMENT 'Código HTTP (NULL = sin respuesta / timeout)',
  duracion_ms           INT UNSIGNED  NULL COMMENT 'Duración en milisegundos',
  exitoso               BOOLEAN       NOT NULL COMMENT '1 = respuesta exitosa',
  request_enmascarado   JSON          NULL COMMENT 'Petición con datos sensibles enmascarados',
  response_enmascarado  JSON          NULL COMMENT 'Respuesta con datos sensibles enmascarados',
  correlacion_id        VARCHAR(64)   NULL COMMENT 'Id de correlación (traza)',
  id_pedido             BIGINT UNSIGNED NULL COMMENT 'Pedido relacionado',
  id_comprobante        BIGINT UNSIGNED NULL COMMENT 'Comprobante relacionado',
  id_pago               BIGINT UNSIGNED NULL COMMENT 'Pago relacionado',
  error                 VARCHAR(500)  NULL COMMENT 'Error',
  PRIMARY KEY (id_log),
  KEY idx_log_api_fecha (creado_en),
  KEY idx_log_api_proveedor (proveedor, creado_en),
  KEY idx_log_api_pedido (id_pedido),
  KEY idx_log_api_comprobante (id_comprobante),
  KEY idx_log_api_correlacion (correlacion_id),
  CONSTRAINT ck_log_api_codigo  CHECK (codigo_http IS NULL OR codigo_http BETWEEN 100 AND 599),
  CONSTRAINT ck_log_api_exitoso CHECK (exitoso IN (0,1))
) ENGINE=InnoDB COMMENT='Bitácora de llamadas a APIs externas (solo inserción; retención configurable)';

CREATE TABLE IF NOT EXISTS consulta_documento (
  id_consulta            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  tipo_documento         ENUM('DNI','RUC') NOT NULL COMMENT 'Tipo consultado',
  numero                 VARCHAR(11)   NOT NULL COMMENT 'Número consultado',
  nombre_razon_social    VARCHAR(200)  NULL COMMENT 'Nombre (DNI) o razón social (RUC)',
  estado_contribuyente   VARCHAR(30)   NULL COMMENT 'RUC: ACTIVO, BAJA...',
  condicion_domicilio    VARCHAR(30)   NULL COMMENT 'RUC: HABIDO, NO HABIDO...',
  domicilio_fiscal       VARCHAR(300)  NULL COMMENT 'RUC: domicilio fiscal (no se guarda domicilio de personas por DNI)',
  fuente                 VARCHAR(40)   NOT NULL COMMENT 'Proveedor de la consulta',
  exitosa                BOOLEAN       NOT NULL COMMENT '1 = se encontró',
  consultado_en          DATETIME(3)   NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  vigente_hasta          DATETIME(3)   NOT NULL COMMENT 'Hasta cuándo se usa la caché (UTC)',
  PRIMARY KEY (id_consulta),
  UNIQUE KEY uq_consulta_documento (tipo_documento, numero),
  KEY idx_consulta_vigencia (vigente_hasta),
  CONSTRAINT ck_consulta_numero CHECK ((tipo_documento = 'DNI' AND REGEXP_LIKE(numero, '^[0-9]{8}$', 'c'))
                                    OR (tipo_documento = 'RUC' AND REGEXP_LIKE(numero, '^(10|15|16|17|20)[0-9]{9}$', 'c'))),
  CONSTRAINT ck_consulta_vigencia CHECK (vigente_hasta > consultado_en AND exitosa IN (0,1))
) ENGINE=InnoDB COMMENT='Caché de consultas DNI/RUC (RENIEC/SUNAT) para autocompletar nombre y razón social';

SELECT 'Esquema de tienda listo: continúa con 03_funciones_procedimientos.sql' AS siguiente_paso;
