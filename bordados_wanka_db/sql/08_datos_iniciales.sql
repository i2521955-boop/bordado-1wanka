-- =====================================================================
-- BORDADOS WANKA S.A.C. — 08_datos_iniciales.sql
-- ---------------------------------------------------------------------
-- Propósito : catálogos y parámetros iniciales. Todo lo marcado
--             por_verificar = 1 es PROVISIONAL (ver v_configuracion_por_verificar
--             y DECISIONES_ABIERTAS.md). No se inventan series ni credenciales:
--             las series son de EJEMPLO y deben reemplazarse por las del OSE.
-- No crea administradores: el primero se crea con sp_crear_administrador_inicial
-- (ver LEEME_INSTALACION.md), con un hash generado por Django.
-- Re-ejecutable: sí (INSERT ... ON DUPLICATE KEY UPDATE / INSERT IGNORE).
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';
SET @app_actor_id = NULL;

START TRANSACTION;

-- ---------------------------------------------------------------------
-- Roles del sistema
-- ---------------------------------------------------------------------
INSERT INTO rol (codigo, nombre, descripcion, requiere_2fa) VALUES
  ('administrador', 'Administrador', 'Superusuario del negocio: CRUD completo; eliminar = inhabilitar. Asume las funciones del vendedor', 1),
  ('cliente',       'Cliente',       'Compra en la tienda, cotiza, paga y sigue sus pedidos', 0)
ON DUPLICATE KEY UPDATE nombre = VALUES(nombre), descripcion = VALUES(descripcion), requiere_2fa = VALUES(requiere_2fa);

-- ---------------------------------------------------------------------
-- Catálogo de errores propios (MYSQL_ERRNO) para Django (RNF 20)
-- ---------------------------------------------------------------------
INSERT INTO catalogo_error (codigo, nombre, mensaje_usuario, http_sugerido) VALUES
  (45001, 'stock_insuficiente',        'No hay stock suficiente para uno de los productos.', 409),
  (45002, 'transicion_no_permitida',   'Ese cambio de estado no está permitido.', 409),
  (45003, 'pago_excede_saldo',         'El monto supera lo que falta pagar del pedido.', 422),
  (45004, 'registro_inmutable',        'Este registro ya no se puede modificar.', 409),
  (45005, 'borrado_prohibido',         'No se puede eliminar: use la opción de inhabilitar.', 403),
  (45006, 'dato_invalido',             'Algún dato tiene un formato inválido.', 422),
  (45007, 'pedido_no_editable',        'El pedido ya no se puede modificar.', 409),
  (45008, 'producto_no_disponible',    'El producto no está disponible para la venta.', 409),
  (45009, 'anticipacion_insuficiente', 'Los pedidos al por mayor requieren más días de anticipación.', 422),
  (45010, 'limite_frecuencia',         'Demasiadas solicitudes. Intente más tarde.', 429),
  (45011, 'codigo_invalido',           'El código no es válido o falta verificarlo.', 422),
  (45012, 'codigo_vencido',            'El código venció. Solicite uno nuevo.', 410),
  (45013, 'codigo_usado',              'El código ya fue usado.', 409),
  (45014, 'codigo_bloqueado',          'El código se bloqueó por demasiados intentos.', 423),
  (45015, 'comprobante_invalido',      'Faltan o son inválidos los datos para el comprobante.', 422),
  (45016, 'nota_credito_invalida',     'La nota de crédito no es válida.', 422),
  (45017, 'pago_invalido',             'El pago no es válido.', 422),
  (45018, 'cotizacion_invalida',       'La cotización no permite esta acción.', 409),
  (45019, 'devolucion_invalida',       'La devolución no es válida.', 422),
  (45020, 'configuracion_invalida',    'Valor de configuración inválido.', 422),
  (45021, 'cuenta_no_disponible',      'La cuenta no está activa.', 403),
  (45022, 'no_encontrado',             'No se encontró el registro.', 404),
  (45023, 'no_autorizado',             'No tiene permiso para esta operación.', 403),
  (45024, 'contrasena_reutilizada',    'No puede reutilizar una contraseña reciente.', 422),
  (45025, 'saldo_pendiente',           'El pedido tiene saldo pendiente.', 409),
  (45026, 'resena_no_permitida',       'Solo puede reseñar productos que compró y recibió.', 403),
  (45027, 'duplicado',                 'La operación ya fue registrada.', 409),
  (45028, 'entrega_invalida',          'Los datos de entrega no son válidos.', 422),
  (45029, 'reembolso_invalido',        'El reembolso no es válido.', 422),
  (45030, 'pedido_vacio',              'El pedido no tiene productos.', 422),
  (45031, 'datos_tarjeta_prohibidos',  'No se deben enviar datos de tarjeta ni credenciales (tokens, contraseñas).', 400),
  (45032, 'dependencias_activas',      'Tiene elementos activos que dependen de él.', 409),
  (45033, 'correo_registrado',         'El correo ya está registrado.', 409),
  (45034, 'concurrencia',              'Hubo mucha actividad simultánea. Intente nuevamente.', 503),
  (45035, 'modalidad_no_permitida',    'La modalidad de pago elegida no está permitida.', 422)
ON DUPLICATE KEY UPDATE nombre = VALUES(nombre), mensaje_usuario = VALUES(mensaje_usuario), http_sugerido = VALUES(http_sugerido);

-- ---------------------------------------------------------------------
-- Configuración (tipo, rango y marca "por verificar")
-- ---------------------------------------------------------------------
INSERT INTO configuracion (clave, valor, tipo, valor_minimo, valor_maximo, opciones, descripcion, editable, por_verificar, nota_verificacion) VALUES
  ('empresa_razon_social',     'BORDADOS WANKA S.A.C.', 'texto', NULL, NULL, NULL, 'Razón social del emisor (va en el comprobante)', 1, 0, NULL),
  ('empresa_ruc',              '20615339386', 'ruc', NULL, NULL, NULL, 'RUC del emisor', 0, 0, NULL),
  ('empresa_nombre_comercial', 'Bordados Wanka', 'texto', NULL, NULL, NULL, 'Nombre comercial', 1, 1, 'Confirmar el nombre comercial registrado en SUNAT'),
  ('empresa_domicilio_fiscal', 'AV. SAN MARTIN NRO. S/N C.P. COCHARCAS JUNIN - HUANCAYO - SAPALLANGA', 'texto', NULL, NULL, NULL, 'Domicilio fiscal (va en el comprobante)', 1, 1, 'Domicilio fiscal vs. local: confirmar con la ficha RUC'),
  ('empresa_direccion_local',  'Av. Ferrocarril e Ica, Galería La Casona, Stand 240, Huancayo', 'texto', NULL, NULL, NULL, 'Dirección del local (recojo y contacto)', 1, 0, NULL),
  ('empresa_horario',          'Lun–Sáb 9am–7pm', 'texto', NULL, NULL, NULL, 'Horario de atención', 1, 0, NULL),
  ('moneda',                   'PEN', 'opcion', NULL, NULL, 'PEN', 'Moneda de los pedidos', 0, 1, 'Moneda de PayPal (USD): decisión abierta'),
  ('igv_porcentaje',           '18', 'decimal', 0, 30, NULL, 'IGV + IPM incluido en los precios', 1, 0, NULL),
  ('dias_minimos_mayor',       '10', 'entero', 1, 90, NULL, 'Días mínimos de anticipación para pedidos al por mayor', 1, 0, NULL),
  ('adelanto_porcentaje',      '50', 'decimal', 1, 99, NULL, 'Porcentaje de adelanto por defecto (modalidad "mitad")', 1, 1, 'Adelanto 50 %: confirmar con el gerente'),
  ('adelanto_permitido_en',    'todos', 'opcion', NULL, NULL, 'todos,solo_mayor', 'Quién puede pagar con adelanto', 1, 1, 'El Excel decía solo mayor; el equipo indica todos'),
  ('horas_reserva_pedido',     '24', 'entero', 1, 168, NULL, 'Horas que se reserva el stock de un pedido sin pagar', 1, 0, NULL),
  ('bloquear_envio_con_saldo', '1', 'booleano', NULL, NULL, NULL, '1 = no pasa a enviado/entregado con saldo pendiente', 1, 1, 'Regla propuesta: confirmar con el gerente'),
  ('umbral_boleta_dni',        '700', 'decimal', 0, 100000, NULL, 'Boletas por encima de este monto exigen documento del cliente', 1, 1, 'Verificar con SUNAT/OSE'),
  ('emitir_comprobante_al',    'pago_total', 'opcion', NULL, NULL, 'pago_total', 'Cuándo se emite el comprobante', 1, 1, 'Anticipos: SUNAT exige comprobante por anticipo recibido; confirmar con contador/OSE'),
  ('codigo_verificacion_minutos', '5', 'entero', 1, 5, NULL, 'Vigencia de los códigos por correo (tope 5)', 1, 0, 'El Excel (HU-02) dice 10: corregir el Excel'),
  ('codigo_verificacion_digitos', '6', 'entero', 6, 8, NULL, 'Dígitos del código de verificación', 1, 0, NULL),
  ('codigo_verificacion_max_intentos', '5', 'entero', 1, 5, NULL, 'Intentos por código', 1, 0, NULL),
  ('codigo_verificacion_max_por_hora', '5', 'entero', 1, 5, NULL, 'Códigos por hora por correo y propósito (tope 5, §2.7)', 1, 0, NULL),
  ('codigo_verificacion_max_por_dia', '15', 'entero', 5, 50, NULL, 'Códigos por día por correo y propósito (limita la adivinación a largo plazo)', 1, 0, NULL),
  ('codigo_verificacion_max_por_ip_hora', '20', 'entero', 5, 200, NULL, 'Códigos por hora desde una misma IP (sin IP conocida: cupo compartido)', 1, 0, NULL),
  ('login_max_intentos',       '5', 'entero', 3, 10, NULL, 'Intentos fallidos antes del bloqueo', 1, 0, NULL),
  ('login_minutos_bloqueo',    '15', 'entero', 5, 1440, NULL, 'Minutos de bloqueo de la cuenta', 1, 0, NULL),
  ('login_max_fallos_ip_15min', '20', 'entero', 5, 500, NULL, 'Intentos fallidos desde una misma IP en 15 minutos antes de bloquearla', 1, 0, NULL),
  ('minutos_gracia_pago_pasarela', '30', 'entero', 0, 240, NULL, 'Un pedido vencido no se cancela si tiene un cobro de pasarela iniciado hace menos de estos minutos', 1, 0, NULL),
  ('contacto_max_por_hora_ip', '3', 'entero', 1, 50, NULL, 'Mensajes de contacto por hora por IP', 1, 0, NULL),
  ('reclamo_plazo_dias',       '30', 'entero', 1, 60, NULL, 'Plazo de respuesta del Libro de Reclamaciones', 1, 1, 'Verificar INDECOPI: la norma podría fijar 15 días hábiles'),
  ('reclamo_plazo_tipo',       'calendario', 'opcion', NULL, NULL, 'calendario,habiles', 'Tipo de días del plazo de reclamos', 1, 1, 'Verificar INDECOPI'),
  ('reclamo_max_por_hora_ip',  '5', 'entero', 0, 50, NULL, 'Reclamos por hora por IP (0 = sin límite)', 1, 1, 'Confirmar que limitar no afecta el derecho del consumidor'),
  ('arco_plazo_acceso_dias',   '20', 'entero', 1, 60, NULL, 'Plazo para responder solicitudes ARCO de acceso', 1, 1, 'Verificar Reglamento de la Ley 29733'),
  ('arco_plazo_otros_dias',    '10', 'entero', 1, 60, NULL, 'Plazo para rectificación, cancelación u oposición', 1, 1, 'Verificar Reglamento de la Ley 29733'),
  ('arco_plazo_tipo',          'habiles', 'opcion', NULL, NULL, 'calendario,habiles', 'Tipo de días de los plazos ARCO', 1, 1, 'Verificar Reglamento de la Ley 29733'),
  ('politica_privacidad_version', '1.0', 'texto', NULL, NULL, NULL, 'Versión vigente de la política de privacidad', 1, 1, 'Redactar y publicar la política; inscribir el banco de datos'),
  ('auditoria_retencion_meses', '12', 'entero', 12, 120, NULL, 'Retención mínima de la auditoría', 1, 0, NULL),
  ('log_api_retencion_meses',   '12', 'entero', 12, 120, NULL, 'Retención de la bitácora de APIs externas', 1, 0, NULL),
  ('intento_acceso_retencion_meses', '12', 'entero', 12, 120, NULL, 'Retención de intentos de acceso', 1, 0, NULL),
  ('evento_pasarela_retencion_dias', '180', 'entero', 30, 3650, NULL, 'Retención de webhooks procesados', 1, 0, NULL),
  ('cola_correo_retencion_dias', '30', 'entero', 1, 365, NULL, 'Retención de correos enviados', 1, 0, NULL),
  ('sesion_retencion_dias',     '90', 'entero', 1, 365, NULL, 'Retención de sesiones cerradas', 1, 0, NULL),
  ('consulta_documento_vigencia_dias', '30', 'entero', 1, 365, NULL, 'Vigencia de la caché de consultas DNI/RUC', 1, 0, NULL),
  ('carrito_dias_abandono',     '30', 'entero', 1, 365, NULL, 'Días sin actividad para marcar un carrito como abandonado', 1, 0, NULL),
  ('cotizacion_vigencia_dias',  '15', 'entero', 1, 90, NULL, 'Vigencia por defecto de una cotización', 1, 1, 'Confirmar con el gerente'),
  ('descontar_insumos_en_produccion', '0', 'booleano', NULL, NULL, NULL, '1 = al pasar a producción se descuentan insumos según receta', 1, 1, 'Activar cuando las recetas estén cargadas'),
  ('complementario_envio_gratis', '1', 'booleano', NULL, NULL, NULL, '1 = el pedido complementario no paga envío si el original aún no salió', 1, 1, 'Confirmar con el gerente'),
  ('cola_emision_max_intentos', '8', 'entero', 1, 50, NULL, 'Reintentos de emisión al OSE', 1, 0, NULL),
  ('cola_correo_max_intentos',  '5', 'entero', 1, 20, NULL, 'Reintentos de envío de correo', 1, 0, NULL)
ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion), tipo = VALUES(tipo), valor_minimo = VALUES(valor_minimo),
                        valor_maximo = VALUES(valor_maximo), opciones = VALUES(opciones), editable = VALUES(editable),
                        por_verificar = VALUES(por_verificar), nota_verificacion = VALUES(nota_verificacion);

-- ---------------------------------------------------------------------
-- Estados y transiciones del pedido (única fuente de verdad)
-- ---------------------------------------------------------------------
INSERT INTO estado_pedido (codigo, nombre, grupo, orden, es_final, notifica_cliente, descripcion) VALUES
  ('pendiente_pago', 'Pendiente de pago', 'pendiente',  1, 0, 0, 'Creado; espera el pago requerido por la modalidad'),
  ('confirmado',     'Confirmado',        'en_proceso', 2, 0, 1, 'Pago requerido recibido'),
  ('en_preparacion', 'En preparación',    'en_proceso', 3, 0, 1, 'Preparando productos de stock'),
  ('en_produccion',  'En producción',     'en_proceso', 4, 0, 1, 'Fabricando productos a pedido'),
  ('listo',          'Listo',             'terminado',  5, 0, 1, 'Listo para recojo o despacho'),
  ('enviado',        'Enviado',           'terminado',  6, 0, 1, 'Entregado al courier'),
  ('entregado',      'Entregado',         'terminado',  7, 1, 1, 'Recibido por el cliente'),
  ('cancelado',      'Cancelado',         'cancelado',  8, 1, 1, 'Cancelado (sin pago o con reembolso pendiente)'),
  ('devuelto',       'Devuelto',          'devuelto',   9, 1, 1, 'Devuelto por el cliente')
ON DUPLICATE KEY UPDATE nombre = VALUES(nombre), grupo = VALUES(grupo), orden = VALUES(orden), es_final = VALUES(es_final),
                        notifica_cliente = VALUES(notifica_cliente), descripcion = VALUES(descripcion);

INSERT INTO transicion_estado_pedido (estado_origen, estado_destino, tipo_entrega_aplicable, automatica, permitido_cliente, requiere_saldo_cero, descripcion) VALUES
  ('pendiente_pago', 'confirmado',     'ambos',     1, 0, 0, 'Automática al recibir el pago requerido (total o adelanto)'),
  ('pendiente_pago', 'cancelado',      'ambos',     0, 1, 0, 'El cliente o el administrador cancela; o expira sin pago'),
  ('confirmado',     'en_preparacion', 'ambos',     0, 0, 0, 'Productos de stock'),
  ('confirmado',     'en_produccion',  'ambos',     0, 0, 0, 'Productos a pedido / personalizados'),
  ('confirmado',     'cancelado',      'ambos',     0, 0, 0, 'Devuelve unidades al stock; lo pagado queda por reembolsar'),
  ('en_preparacion', 'listo',          'ambos',     0, 0, 0, NULL),
  ('en_preparacion', 'cancelado',      'ambos',     0, 0, 0, NULL),
  ('en_produccion',  'listo',          'ambos',     0, 0, 0, NULL),
  ('en_produccion',  'cancelado',      'ambos',     0, 0, 0, NULL),
  ('listo',          'enviado',        'domicilio', 0, 0, 1, 'Solo domicilio; exige saldo 0 (configurable)'),
  ('listo',          'entregado',      'recojo',    0, 0, 1, 'Recojo en tienda no pasa por enviado; exige saldo 0 (configurable)'),
  ('listo',          'cancelado',      'ambos',     0, 0, 0, NULL),
  ('enviado',        'entregado',      'domicilio', 0, 0, 1, 'Domicilio debe pasar por enviado antes de entregado'),
  ('enviado',        'devuelto',       'domicilio', 1, 0, 0, 'Solo con sp_devolver_pedido (repone stock y genera reembolso/NC)'),
  ('entregado',      'devuelto',       'ambos',     1, 0, 0, 'Solo con sp_devolver_pedido (repone stock y genera reembolso/NC)')
ON DUPLICATE KEY UPDATE tipo_entrega_aplicable = VALUES(tipo_entrega_aplicable), automatica = VALUES(automatica),
                        permitido_cliente = VALUES(permitido_cliente), requiere_saldo_cero = VALUES(requiere_saldo_cero), descripcion = VALUES(descripcion);

INSERT INTO transicion_estado_pago (estado_origen, estado_destino, descripcion) VALUES
  ('pendiente',   'en_revision', 'El cliente adjuntó voucher/operación'),
  ('pendiente',   'confirmado',  'Webhook verificado de la pasarela'),
  ('pendiente',   'rechazado',   'Rechazado por un administrador'),
  ('pendiente',   'fallido',     'La pasarela informó rechazo'),
  ('pendiente',   'anulado',     'Intento abandonado'),
  ('en_revision', 'confirmado',  'Validado por un administrador'),
  ('en_revision', 'rechazado',   'Rechazado por un administrador con motivo'),
  ('confirmado',  'reembolsado', 'Reembolso total completado'),
  ('fallido',     'confirmado',  'La pasarela confirmó el cobro después del rechazo: se registra (huérfano si el pedido ya no está vigente)'),
  ('anulado',     'confirmado',  'La pasarela confirmó un intento abandonado: se registra para no perder el dinero')
ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion);

INSERT INTO transicion_estado_cotizacion (estado_origen, estado_destino, descripcion) VALUES
  ('solicitada',  'en_revision', 'El administrador la toma'),
  ('solicitada',  'rechazada',   NULL),
  ('en_revision', 'cotizada',    'Precios, envío, adelanto y vigencia definidos'),
  ('en_revision', 'rechazada',   NULL),
  ('cotizada',    'aceptada',    'El cliente acepta dentro de la vigencia'),
  ('cotizada',    'rechazada',   'El cliente o el administrador la rechaza'),
  ('cotizada',    'vencida',     'Evento diario al pasar la vigencia'),
  ('aceptada',    'convertida',  'Se generó el pedido (sp_aceptar_cotizacion)')
ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion);

-- ---------------------------------------------------------------------
-- Métodos de pago
-- ---------------------------------------------------------------------
INSERT INTO metodo_pago (codigo, nombre, tipo, requiere_comprobante, canal, orden) VALUES
  ('mercadopago',   'Tarjeta (Mercado Pago)', 'pasarela', 0, 'web',        1),
  ('paypal',        'PayPal',                 'pasarela', 0, 'web',        2),
  ('yape',          'Yape',                   'manual',   1, 'ambos',      3),
  ('plin',          'Plin',                   'manual',   1, 'ambos',      4),
  ('transferencia', 'Transferencia bancaria', 'manual',   1, 'ambos',      5),
  ('efectivo',      'Efectivo (en tienda, con N.º de recibo)', 'manual', 1, 'presencial', 6)
ON DUPLICATE KEY UPDATE nombre = VALUES(nombre), canal = VALUES(canal), orden = VALUES(orden), requiere_comprobante = VALUES(requiere_comprobante);

-- ---------------------------------------------------------------------
-- Motivos de nota de crédito: catálogo SUNAT N.º 09 (verificar vigencia con el OSE)
-- ---------------------------------------------------------------------
INSERT INTO motivo_nota_credito (codigo, descripcion, es_total, repone_stock, activo) VALUES
  ('01', 'Anulación de la operación',                 1, 0, 1),
  ('02', 'Anulación por error en el RUC',             1, 0, 1),
  ('03', 'Corrección por error en la descripción',    0, 0, 1),
  ('04', 'Descuento global',                          0, 0, 1),
  ('05', 'Descuento por ítem',                        0, 0, 1),
  ('06', 'Devolución total',                          1, 1, 1),
  ('07', 'Devolución por ítem',                       0, 1, 1),
  ('08', 'Bonificación',                              0, 0, 1),
  ('09', 'Disminución en el valor',                   0, 0, 1),
  ('10', 'Otros conceptos',                           0, 0, 1),
  ('11', 'Ajustes de operaciones de exportación',     0, 0, 0),
  ('12', 'Ajustes afectos al IVAP',                   0, 0, 0),
  ('13', 'Ajustes - montos y/o fechas de pago',       0, 0, 0)
ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion), es_total = VALUES(es_total), repone_stock = VALUES(repone_stock);

-- ---------------------------------------------------------------------
-- Series de comprobantes: EJEMPLO — reemplazar por las reales del OSE/PSE
-- ---------------------------------------------------------------------
INSERT IGNORE INTO serie_comprobante (tipo, serie, por_verificar) VALUES
  ('boleta', 'B001', 1), ('factura', 'F001', 1), ('nota_credito', 'BC01', 1), ('nota_credito', 'FC01', 1);

-- ---------------------------------------------------------------------
-- Catálogo inicial (del script original)
-- ---------------------------------------------------------------------
INSERT INTO categoria (nombre, slug, descripcion, icono, orden) VALUES
  ('Polleras', 'polleras', 'Diseños únicos bordados a mano',     'pollera', 1),
  ('Fajas',    'fajas',    'Tejido tradicional de alta calidad', 'faja',    2),
  ('Chalecos', 'chalecos', 'Elegancia folklórica',               'chaleco', 3)
ON DUPLICATE KEY UPDATE descripcion = VALUES(descripcion), icono = VALUES(icono), orden = VALUES(orden);

INSERT INTO zona_envio (nombre, costo, dias_estimados) VALUES
  ('Huancayo Centro', 5.00, 1),
  ('Huancayo Distritos', 10.00, 2),
  ('Otras provincias de Junín', 20.00, 3),
  ('Lima y otras regiones', 35.00, 5)
ON DUPLICATE KEY UPDATE costo = costo;

INSERT INTO courier (nombre, url_seguimiento, tiene_api) VALUES ('Reparto propio', NULL, 0)
ON DUPLICATE KEY UPDATE nombre = nombre;

-- ---------------------------------------------------------------------
-- Cliente de mostrador (ventas presenciales sin cuenta web). No puede iniciar
-- sesión (hash "!" = contraseña inutilizable de Django) y no recibe correos (.invalid)
-- ---------------------------------------------------------------------
INSERT IGNORE INTO usuario (id_rol, correo, hash_contrasena, nombres, apellidos, estado, correo_verificado_en)
SELECT id_rol, 'mostrador@bordadoswanka.invalid', '!venta-presencial-sin-acceso-web', 'Cliente', 'Mostrador', 'activo', UTC_TIMESTAMP(3)
  FROM rol WHERE codigo = 'cliente';

COMMIT;

SELECT 'Datos iniciales cargados. Revise v_configuracion_por_verificar y cree el primer administrador (LEEME_INSTALACION.md)' AS siguiente_paso;
