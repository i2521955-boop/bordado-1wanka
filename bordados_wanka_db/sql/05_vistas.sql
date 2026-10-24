-- =====================================================================
-- BORDADOS WANKA S.A.C. — 05_vistas.sql
-- ---------------------------------------------------------------------
-- Propósito : vistas limpias para que cada endpoint/reporte de Django sea
--             un SELECT simple. Reglas:
--   * Fechas convertidas a hora de Lima (sufijo _lima); el "día" de un
--     reporte es el día de Lima.
--   * Datos personales ENMASCARADOS (DNI/RUC, correo, celular) en las vistas
--     de listado; el dato completo solo con sp_ver_documento_completo
--     (queda auditado) o en v_comprobante_copia_completa (solo rol admin).
--   * Sin subconsultas correlacionadas en reportes: agregados con JOIN.
--   * Sin ORDER BY: el orden y la paginación (LIMIT/OFFSET o keyset) los
--     aplica la consulta de la app.
--   * DEFINER + SQL SECURITY DEFINER: rol_reportes lee vistas sin acceso a
--     las tablas.
-- Re-ejecutable: sí (CREATE OR REPLACE).
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- =====================================================================
-- CATÁLOGO (público)
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_catalogo_productos AS
SELECT p.id_producto, p.slug, p.nombre, p.descripcion, c.id_categoria, c.nombre AS categoria, c.slug AS categoria_slug,
       p.tipo_fabricacion, p.dias_produccion, p.permite_personalizacion, p.destacado,
       COALESCE(v.precio_desde, p.precio_base) AS precio_desde, p.precio_base,
       CASE WHEN p.tipo_fabricacion = 'a_pedido' THEN NULL ELSE COALESCE(v.stock_disponible, 0) END AS stock_disponible,
       (p.tipo_fabricacion = 'a_pedido' OR COALESCE(v.stock_disponible, 0) > 0) AS disponible,
       img.url AS imagen_principal, p.valoracion_promedio, p.total_resenas,
       (pv.id_producto IS NOT NULL) AS tiene_precio_volumen
  FROM producto p
  JOIN categoria c ON c.id_categoria = p.id_categoria AND c.activo = 1
  LEFT JOIN (SELECT vv.id_producto, MIN(COALESCE(vv.precio, pp.precio_base)) AS precio_desde, SUM(vv.stock_disponible) AS stock_disponible
               FROM variante_producto vv JOIN producto pp ON pp.id_producto = vv.id_producto
              WHERE vv.activo = 1 GROUP BY vv.id_producto) v ON v.id_producto = p.id_producto
  LEFT JOIN imagen_producto img ON img.principal_clave = p.id_producto
  LEFT JOIN (SELECT DISTINCT id_producto FROM precio_volumen WHERE activo = 1) pv ON pv.id_producto = p.id_producto
 WHERE p.estado = 'activo';

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_variantes_disponibles AS
SELECT v.id_variante, v.id_producto, p.nombre AS producto, v.sku, v.talla, v.color,
       COALESCE(v.precio, p.precio_base) AS precio,
       CASE WHEN p.tipo_fabricacion = 'a_pedido' THEN NULL ELSE v.stock_disponible END AS stock_disponible,
       (p.tipo_fabricacion = 'a_pedido' OR v.stock_disponible > 0) AS disponible
  FROM variante_producto v
  JOIN producto p ON p.id_producto = v.id_producto AND p.estado = 'activo'
 WHERE v.activo = 1;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_precios_volumen AS
SELECT pv.id_producto, p.nombre AS producto, pv.cantidad_minima, pv.precio_unitario
  FROM precio_volumen pv JOIN producto p ON p.id_producto = pv.id_producto
 WHERE pv.activo = 1 AND p.estado = 'activo';

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_banners_vigentes AS
SELECT id_banner, titulo, subtitulo, imagen_url, enlace, texto_boton, orden
  FROM banner
 WHERE activo = 1 AND (vigente_desde IS NULL OR vigente_desde <= UTC_TIMESTAMP(3)) AND (vigente_hasta IS NULL OR vigente_hasta > UTC_TIMESTAMP(3));

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_resenas_publicadas AS
SELECT r.id_resena, r.id_producto, r.calificacion, r.titulo, r.comentario,
       CONCAT(u.nombres, ' ', LEFT(u.apellidos, 1), '.') AS autor, fn_utc_a_lima(r.creado_en) AS creado_lima
  FROM resena r JOIN usuario u ON u.id_usuario = r.id_usuario
 WHERE r.estado = 'publicada';

-- =====================================================================
-- PEDIDOS: estado siempre consultable (pendientes, en proceso, terminados, cancelados, devueltos)
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_pedidos_estado AS
SELECT pe.id_pedido, pe.numero, pe.id_usuario, u.nombre_completo AS cliente, fn_enmascarar_correo(u.correo) AS cliente_correo,
       pe.estado, ep.nombre AS estado_nombre, ep.grupo AS estado_grupo, ep.orden AS estado_orden,
       pe.estado_pago, pe.modalidad_pago, pe.adelanto_porcentaje, pe.monto_requerido,
       pe.tipo_venta, pe.canal, pe.tipo_entrega, pe.comprobante_solicitado,
       pe.subtotal, pe.descuento, pe.costo_envio, pe.total, pe.monto_pagado, pe.monto_reembolsado, pe.monto_neto_pagado,
       pe.monto_devuelto, pe.monto_ajustes,
       CASE WHEN pe.estado = 'cancelado' THEN 0 ELSE GREATEST(pe.saldo, 0) END AS saldo,
       CASE WHEN pe.estado = 'cancelado' THEN pe.monto_neto_pagado ELSE GREATEST(-pe.saldo, 0) END AS saldo_a_favor_cliente,
       pe.fecha_entrega_solicitada, pe.fecha_entrega_estimada,
       fn_utc_a_lima(pe.creado_en) AS creado_lima, fn_utc_a_lima(pe.expira_en) AS expira_lima,
       fn_utc_a_lima(pe.confirmado_en) AS confirmado_lima, fn_utc_a_lima(pe.entregado_en) AS entregado_lima,
       fn_utc_a_lima(pe.cancelado_en) AS cancelado_lima, pe.motivo_cancelacion,
       pe.id_pedido_origen, pe.id_cotizacion
  FROM pedido pe
  JOIN usuario u ON u.id_usuario = pe.id_usuario
  JOIN estado_pedido ep ON ep.codigo = pe.estado;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_resumen_estados_pedido AS
SELECT ep.grupo AS estado_grupo, ep.codigo AS estado, ep.nombre AS estado_nombre, ep.orden,
       COUNT(pe.id_pedido) AS pedidos, COALESCE(SUM(pe.total), 0) AS monto_total
  FROM estado_pedido ep LEFT JOIN pedido pe ON pe.estado = ep.codigo
 GROUP BY ep.grupo, ep.codigo, ep.nombre, ep.orden;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_pedido_detalle AS
SELECT i.id_item_pedido, i.id_pedido, pe.numero, i.id_variante, i.id_producto, i.nombre_producto, i.sku, i.talla, i.color,
       i.tipo_fabricacion, i.cantidad, i.cantidad_devuelta, i.precio_lista, i.precio_unitario, i.origen_precio, i.subtotal,
       i.personalizacion
  FROM item_pedido i JOIN pedido pe ON pe.id_pedido = i.id_pedido
 WHERE i.estado = 'vigente';

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_historial_pedido AS
SELECT h.id_historial, h.id_pedido, pe.numero, h.estado_anterior, h.estado_nuevo, ep.nombre AS estado_nombre,
       COALESCE(u.nombre_completo, 'Sistema') AS realizado_por, h.comentario, fn_utc_a_lima(h.creado_en) AS fecha_lima
  FROM historial_estado_pedido h
  JOIN pedido pe ON pe.id_pedido = h.id_pedido
  JOIN estado_pedido ep ON ep.codigo = h.estado_nuevo
  LEFT JOIN usuario u ON u.id_usuario = h.id_usuario;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_transiciones_pedido AS
SELECT t.estado_origen, o.nombre AS origen_nombre, t.estado_destino, d.nombre AS destino_nombre,
       t.tipo_entrega_aplicable, t.automatica, t.permitido_cliente, t.requiere_saldo_cero, t.descripcion
  FROM transicion_estado_pedido t
  JOIN estado_pedido o ON o.codigo = t.estado_origen
  JOIN estado_pedido d ON d.codigo = t.estado_destino;

-- =====================================================================
-- INVENTARIO
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_kardex AS
SELECT m.id_movimiento, fn_utc_a_lima(m.creado_en) AS fecha_lima, m.id_variante, v.sku, p.nombre AS producto, v.talla, v.color,
       m.tipo, m.cantidad, m.stock_actual_resultante, m.stock_reservado_resultante,
       m.stock_actual_resultante - m.stock_reservado_resultante AS disponible_resultante,
       pe.numero AS pedido, d.numero AS devolucion, COALESCE(u.nombre_completo, 'Sistema') AS realizado_por, m.motivo
  FROM movimiento_stock m
  JOIN variante_producto v ON v.id_variante = m.id_variante
  JOIN producto p ON p.id_producto = v.id_producto
  LEFT JOIN pedido pe ON pe.id_pedido = m.id_pedido
  LEFT JOIN devolucion d ON d.id_devolucion = m.id_devolucion
  LEFT JOIN usuario u ON u.id_usuario = m.id_usuario;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_reservas_activas AS
SELECT r.id_reserva, r.id_pedido, pe.numero, r.id_variante, v.sku, r.cantidad, fn_utc_a_lima(r.creado_en) AS reservado_lima,
       fn_utc_a_lima(pe.expira_en) AS expira_lima
  FROM reserva_stock r JOIN pedido pe ON pe.id_pedido = r.id_pedido JOIN variante_producto v ON v.id_variante = r.id_variante
 WHERE r.estado = 'activa';

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_stock_bajo AS
SELECT v.id_variante, p.id_producto, p.nombre AS producto, v.sku, v.talla, v.color,
       v.stock_actual, v.stock_reservado, v.stock_disponible, v.stock_minimo
  FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
 WHERE v.activo = 1 AND p.estado = 'activo' AND p.tipo_fabricacion = 'stock' AND v.stock_disponible <= v.stock_minimo;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_insumos_stock_bajo AS
SELECT id_insumo, nombre, tipo, unidad, stock_actual, stock_minimo
  FROM insumo WHERE activo = 1 AND stock_actual <= stock_minimo;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_kardex_insumos AS
SELECT m.id_movimiento, fn_utc_a_lima(m.creado_en) AS fecha_lima, i.id_insumo, i.nombre AS insumo, i.unidad, m.tipo, m.cantidad,
       m.stock_resultante, pe.numero AS pedido, COALESCE(u.nombre_completo, 'Sistema') AS realizado_por, m.motivo
  FROM movimiento_insumo m
  JOIN insumo i ON i.id_insumo = m.id_insumo
  LEFT JOIN pedido pe ON pe.id_pedido = m.id_pedido
  LEFT JOIN usuario u ON u.id_usuario = m.id_usuario;

-- =====================================================================
-- PAGOS Y REEMBOLSOS
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_pagos_por_validar AS
SELECT pg.id_pago, pg.id_pedido, pe.numero AS pedido, u.nombre_completo AS cliente, pg.metodo, m.nombre AS metodo_nombre,
       pg.tipo, pg.monto, pg.referencia_externa AS numero_operacion, pg.voucher_url, pe.saldo AS saldo_pedido,
       fn_utc_a_lima(pg.creado_en) AS registrado_lima
  FROM pago pg
  JOIN metodo_pago m ON m.codigo = pg.metodo
  JOIN pedido pe ON pe.id_pedido = pg.id_pedido
  JOIN usuario u ON u.id_usuario = pe.id_usuario
 WHERE pg.estado = 'en_revision';

-- Dinero por devolver al cliente (nunca se pierde ni se ignora):
--   1) pagos huérfanos (cobrados con el pedido ya cancelado/expirado o por encima del total): se devuelven completos;
--   2) pagos de pedidos cancelados;
--   3) pedidos vigentes o devueltos con saldo a favor del cliente (devolución o rebaja posterior) que aún no tiene
--      reembolso en curso (p. ej. un reembolso que falló). Si pagó solo un adelanto, quizá no se le debe nada.
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_pagos_por_reembolsar AS
SELECT pg.id_pago, pg.id_pedido, pe.numero AS pedido, pe.estado AS estado_pedido, u.nombre_completo AS cliente,
       fn_enmascarar_correo(u.correo) AS cliente_correo, pg.metodo, pg.monto, pg.referencia_externa,
       COALESCE(r.comprometido, 0) AS reembolso_en_curso_o_hecho,
       pg.monto - COALESCE(r.comprometido, 0) AS pendiente_de_reembolsar,
       IF(pg.aplicado_al_pedido = 0, CONCAT('pago_huerfano:', pg.motivo_no_aplicado), 'pedido_cancelado') AS motivo,
       NULL AS id_devolucion, fn_utc_a_lima(pg.confirmado_en) AS confirmado_lima
  FROM pago pg
  JOIN pedido pe ON pe.id_pedido = pg.id_pedido
  JOIN usuario u ON u.id_usuario = pe.id_usuario
  LEFT JOIN (SELECT id_pago, SUM(monto) AS comprometido FROM reembolso
              WHERE estado IN ('solicitado','procesando','completado') GROUP BY id_pago) r ON r.id_pago = pg.id_pago
 WHERE pg.estado = 'confirmado'
   AND (pg.aplicado_al_pedido = 0 OR pe.estado = 'cancelado')
   AND pg.monto - COALESCE(r.comprometido, 0) > 0
UNION ALL
SELECT NULL, pe.id_pedido, pe.numero, pe.estado, u.nombre_completo, fn_enmascarar_correo(u.correo), NULL, -pe.saldo, d.numero,
       COALESCE(r.en_curso, 0),
       -pe.saldo - COALESCE(r.en_curso, 0),
       IF(d.id_devolucion IS NULL, 'saldo_a_favor', 'devolucion'), d.id_devolucion, fn_utc_a_lima(pe.actualizado_en)
  FROM pedido pe
  JOIN usuario u ON u.id_usuario = pe.id_usuario
  LEFT JOIN (SELECT id_pedido, MAX(id_devolucion) AS id_devolucion, MAX(numero) AS numero FROM devolucion GROUP BY id_pedido) d
         ON d.id_pedido = pe.id_pedido
  LEFT JOIN (SELECT p.id_pedido, SUM(r.monto) AS en_curso FROM reembolso r JOIN pago p ON p.id_pago = r.id_pago
              WHERE p.aplicado_al_pedido = 1 AND r.estado IN ('solicitado','procesando') GROUP BY p.id_pedido) r
         ON r.id_pedido = pe.id_pedido
 WHERE pe.estado <> 'cancelado' AND pe.saldo < 0 AND -pe.saldo - COALESCE(r.en_curso, 0) > 0;

-- Notas de crédito que faltan: pedidos cancelados con comprobante vigente y devoluciones sin NC
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_notas_credito_pendientes AS
SELECT c.id_comprobante, c.numero_completo, c.id_pedido, pe.numero AS pedido, 'pedido_cancelado' AS motivo,
       '01' AS motivo_sunat_sugerido, c.total - COALESCE(nc.emitido, 0) AS monto_sugerido, NULL AS id_devolucion, c.estado_sunat
  FROM comprobante c
  JOIN pedido pe ON pe.id_pedido = c.id_pedido AND pe.estado = 'cancelado'
  LEFT JOIN (SELECT id_comprobante_ref, SUM(total) AS emitido FROM comprobante
              WHERE tipo = 'nota_credito' AND estado_sunat NOT IN ('rechazado','anulado') GROUP BY id_comprobante_ref) nc
         ON nc.id_comprobante_ref = c.id_comprobante
 WHERE c.tipo IN ('boleta','factura') AND c.estado_sunat NOT IN ('rechazado','anulado')
   AND c.total - COALESCE(nc.emitido, 0) > 0
UNION ALL
SELECT c.id_comprobante, c.numero_completo, d.id_pedido, pe.numero, 'devolucion_sin_nota', IF(d.tipo = 'total', '06', '07'),
       d.monto_total, d.id_devolucion, c.estado_sunat
  FROM devolucion d
  JOIN pedido pe ON pe.id_pedido = d.id_pedido
  JOIN comprobante c ON c.id_pedido = d.id_pedido AND c.tipo IN ('boleta','factura') AND c.estado_sunat NOT IN ('rechazado','anulado')
 WHERE NOT EXISTS (SELECT 1 FROM comprobante n WHERE n.id_devolucion = d.id_devolucion AND n.tipo = 'nota_credito'
                     AND n.estado_sunat NOT IN ('rechazado','anulado'));

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_reembolsos AS
SELECT r.id_reembolso, r.id_pago, r.id_pedido, pe.numero AS pedido, r.monto, r.motivo, r.detalle, r.estado, r.medio,
       r.referencia_externa, nc.numero_completo AS nota_credito, d.numero AS devolucion,
       COALESCE(us.nombre_completo, 'Sistema') AS solicitado_por, up.nombre_completo AS procesado_por,
       fn_utc_a_lima(r.creado_en) AS solicitado_lima, fn_utc_a_lima(r.completado_en) AS completado_lima, r.error
  FROM reembolso r
  JOIN pedido pe ON pe.id_pedido = r.id_pedido
  LEFT JOIN comprobante nc ON nc.id_comprobante = r.id_nota_credito
  LEFT JOIN devolucion d ON d.id_devolucion = r.id_devolucion
  LEFT JOIN usuario us ON us.id_usuario = r.solicitado_por
  LEFT JOIN usuario up ON up.id_usuario = r.procesado_por;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_ingresos_diarios AS
SELECT fecha, metodo, SUM(pagos) AS pagos, SUM(cobrado) AS cobrado, SUM(reembolsado) AS reembolsado,
       SUM(cobrado) - SUM(reembolsado) AS neto
  FROM (SELECT DATE(fn_utc_a_lima(confirmado_en)) AS fecha, metodo, COUNT(*) AS pagos, SUM(monto) AS cobrado, 0 AS reembolsado
          FROM pago WHERE estado IN ('confirmado','reembolsado') GROUP BY DATE(fn_utc_a_lima(confirmado_en)), metodo
        UNION ALL
        SELECT DATE(fn_utc_a_lima(r.completado_en)), p.metodo, 0, 0, SUM(r.monto)
          FROM reembolso r JOIN pago p ON p.id_pago = r.id_pago
         WHERE r.estado = 'completado' GROUP BY DATE(fn_utc_a_lima(r.completado_en)), p.metodo) x
 GROUP BY fecha, metodo;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_eventos_pasarela_con_error AS
SELECT id_evento, proveedor, id_externo, tipo, estado, intentos, error, id_pago, firma_valida, fn_utc_a_lima(recibido_en) AS recibido_lima
  FROM evento_pasarela WHERE estado IN ('error','recibido');

-- =====================================================================
-- VENTAS Y REPORTES
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_ventas_diarias AS
SELECT DATE(fn_utc_a_lima(confirmado_en)) AS fecha, tipo_venta, canal, COUNT(*) AS pedidos,
       SUM(subtotal) AS subtotal, SUM(costo_envio) AS envio, SUM(monto_devuelto) AS devuelto, SUM(monto_ajustes) AS ajustes,
       SUM(total - monto_devuelto - monto_ajustes) AS total_neto
  FROM pedido
 WHERE confirmado_en IS NOT NULL AND estado NOT IN ('cancelado','devuelto')
 GROUP BY DATE(fn_utc_a_lima(confirmado_en)), tipo_venta, canal;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_ventas_por_categoria AS
SELECT c.id_categoria, c.nombre AS categoria,
       SUM(i.cantidad - i.cantidad_devuelta) AS unidades,
       SUM((i.cantidad - i.cantidad_devuelta) * i.precio_unitario) AS ingresos
  FROM item_pedido i
  JOIN pedido pe ON pe.id_pedido = i.id_pedido
  JOIN producto p ON p.id_producto = i.id_producto
  JOIN categoria c ON c.id_categoria = p.id_categoria
 WHERE i.estado = 'vigente' AND pe.estado NOT IN ('pendiente_pago','cancelado','devuelto')
 GROUP BY c.id_categoria, c.nombre;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_productos_mas_vendidos AS
SELECT p.id_producto, p.nombre, c.nombre AS categoria,
       SUM(i.cantidad - i.cantidad_devuelta) AS unidades,
       SUM((i.cantidad - i.cantidad_devuelta) * i.precio_unitario) AS ingresos,
       COUNT(DISTINCT pe.id_pedido) AS pedidos
  FROM item_pedido i
  JOIN pedido pe ON pe.id_pedido = i.id_pedido
  JOIN producto p ON p.id_producto = i.id_producto
  JOIN categoria c ON c.id_categoria = p.id_categoria
 WHERE i.estado = 'vigente' AND pe.estado NOT IN ('pendiente_pago','cancelado','devuelto')
 GROUP BY p.id_producto, p.nombre, c.nombre;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_clientes_resumen AS
SELECT u.id_usuario, u.nombre_completo, fn_enmascarar_correo(u.correo) AS correo, fn_enmascarar_telefono(u.celular) AS celular,
       u.tipo_documento, fn_enmascarar_documento(u.numero_documento) AS numero_documento, u.estado,
       COALESCE(s.pedidos, 0) AS pedidos, COALESCE(s.total_compras, 0) AS total_compras,
       fn_utc_a_lima(s.ultimo_pedido) AS ultimo_pedido_lima, fn_utc_a_lima(u.creado_en) AS registrado_lima
  FROM usuario u
  JOIN rol r ON r.id_rol = u.id_rol AND r.codigo = 'cliente'
  LEFT JOIN (SELECT id_usuario, COUNT(*) AS pedidos, SUM(total - monto_devuelto - monto_ajustes) AS total_compras, MAX(creado_en) AS ultimo_pedido
               FROM pedido WHERE estado NOT IN ('pendiente_pago','cancelado','devuelto') GROUP BY id_usuario) s
         ON s.id_usuario = u.id_usuario;

-- =====================================================================
-- COMPROBANTES: "la copia de lo que se emitió"
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_comprobantes AS
SELECT c.id_comprobante, c.id_pedido, pe.numero AS pedido, c.tipo, c.codigo_tipo_sunat, c.numero_completo, c.fecha_emision,
       c.cliente_tipo_doc, fn_enmascarar_documento(c.cliente_num_doc) AS cliente_num_doc, c.cliente_nombre,
       c.moneda, c.op_gravada, c.igv, c.total, c.estado_sunat, c.codigo_respuesta_sunat, c.mensaje_sunat,
       ref.numero_completo AS comprobante_referencia, c.codigo_motivo_nc, c.motivo_detalle,
       c.url_pdf, c.url_xml, c.url_cdr, (a.id_comprobante IS NOT NULL) AS tiene_copia_archivo,
       fn_utc_a_lima(c.emitido_en) AS registrado_lima, fn_utc_a_lima(c.aceptado_en) AS aceptado_lima,
       fn_utc_a_lima(c.enviado_correo_en) AS enviado_correo_lima
  FROM comprobante c
  JOIN pedido pe ON pe.id_pedido = c.id_pedido
  LEFT JOIN comprobante ref ON ref.id_comprobante = c.id_comprobante_ref
  LEFT JOIN (SELECT DISTINCT id_comprobante FROM comprobante_archivo) a ON a.id_comprobante = c.id_comprobante;

-- Copia completa (incluye documento del cliente sin enmascarar y payloads): solo rol_app_admin
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_comprobante_copia_completa AS
SELECT c.id_comprobante, c.id_pedido, c.tipo, c.codigo_tipo_sunat, c.serie, c.correlativo, c.numero_completo, c.fecha_emision,
       c.emisor_ruc, c.emisor_razon_social, c.emisor_nombre_comercial, c.emisor_domicilio_fiscal,
       c.cliente_tipo_doc, c.cliente_num_doc, c.cliente_nombre, c.cliente_direccion, c.cliente_correo,
       c.moneda, c.igv_porcentaje, c.op_gravada, c.op_exonerada, c.op_inafecta, c.igv, c.total,
       c.id_comprobante_ref, c.codigo_motivo_nc, m.descripcion AS motivo_nc, c.motivo_detalle,
       c.estado_sunat, c.proveedor_ose, c.id_externo, c.hash_cpe, c.codigo_respuesta_sunat, c.mensaje_sunat,
       c.url_pdf, c.url_xml, c.url_cdr, c.payload_envio, c.payload_respuesta,
       fn_utc_a_lima(c.emitido_en) AS registrado_lima, fn_utc_a_lima(c.aceptado_en) AS aceptado_lima
  FROM comprobante c LEFT JOIN motivo_nota_credito m ON m.codigo = c.codigo_motivo_nc;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_comprobante_items AS
SELECT ci.id_comprobante, c.numero_completo, ci.orden, ci.codigo_producto, ci.descripcion, ci.unidad_medida, ci.cantidad,
       ci.precio_unitario, ci.valor_unitario, ci.valor_venta, ci.igv, ci.total_linea, ci.codigo_afectacion_igv
  FROM comprobante_item ci JOIN comprobante c ON c.id_comprobante = ci.id_comprobante;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_notas_credito_saldo AS
SELECT c.id_comprobante, c.numero_completo, c.tipo, c.estado_sunat, c.total,
       COALESCE(nc.emitido, 0) AS notas_credito, c.total - COALESCE(nc.emitido, 0) AS saldo_disponible
  FROM comprobante c
  LEFT JOIN (SELECT id_comprobante_ref, SUM(total) AS emitido FROM comprobante
              WHERE tipo = 'nota_credito' AND estado_sunat NOT IN ('rechazado','anulado') GROUP BY id_comprobante_ref) nc
         ON nc.id_comprobante_ref = c.id_comprobante
 WHERE c.tipo IN ('boleta','factura');

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_cola_emision AS
SELECT q.id_trabajo, q.id_comprobante, c.numero_completo, c.tipo, c.estado_sunat, q.estado, q.intentos, q.max_intentos,
       fn_utc_a_lima(q.proximo_intento_en) AS proximo_intento_lima, q.ultimo_error, q.tomado_por
  FROM cola_emision_comprobante q JOIN comprobante c ON c.id_comprobante = q.id_comprobante
 WHERE q.estado IN ('pendiente','procesando','error','descartado');

-- =====================================================================
-- COTIZACIONES, ENVÍOS
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_cotizaciones AS
SELECT ct.id_cotizacion, ct.numero, ct.id_usuario, u.nombre_completo AS cliente, ct.origen, ct.estado, ct.descripcion,
       ct.fecha_entrega_solicitada, ct.subtotal, ct.costo_envio, ct.total, ct.adelanto_porcentaje, ct.vigencia_hasta,
       (ct.estado = 'cotizada' AND ct.vigencia_hasta >= fn_hoy_lima()) AS aceptable, pe.numero AS pedido,
       fn_utc_a_lima(ct.creado_en) AS solicitado_lima, fn_utc_a_lima(ct.cotizado_en) AS cotizado_lima
  FROM cotizacion ct
  JOIN usuario u ON u.id_usuario = ct.id_usuario
  LEFT JOIN pedido pe ON pe.id_cotizacion = ct.id_cotizacion;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_envios_seguimiento AS
SELECT e.id_envio, e.id_pedido, pe.numero AS pedido, co.nombre AS courier, e.numero_guia,
       CASE WHEN co.url_seguimiento IS NOT NULL AND e.numero_guia IS NOT NULL THEN REPLACE(co.url_seguimiento, '{guia}', e.numero_guia) END AS url_seguimiento,
       e.estado, e.fecha_entrega_estimada, fn_utc_a_lima(e.despachado_en) AS despachado_lima, fn_utc_a_lima(e.entregado_en) AS entregado_lima,
       ult.descripcion AS ultimo_evento, ult.ubicacion AS ultima_ubicacion, fn_utc_a_lima(ult.ocurrido_en) AS ultimo_evento_lima
  FROM envio e
  JOIN pedido pe ON pe.id_pedido = e.id_pedido
  LEFT JOIN courier co ON co.id_courier = e.id_courier
  LEFT JOIN (SELECT s.* FROM seguimiento_envio s
               JOIN (SELECT id_envio, MAX(id_seguimiento) AS id_max FROM seguimiento_envio GROUP BY id_envio) m
                 ON m.id_max = s.id_seguimiento) ult ON ult.id_envio = e.id_envio;

-- =====================================================================
-- ATENCIÓN AL CLIENTE Y DATOS PERSONALES
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_mensajes_contacto_pendientes AS
SELECT id_mensaje, ticket, nombre, fn_enmascarar_correo(correo) AS correo, asunto, id_pedido, LEFT(mensaje, 200) AS extracto, estado,
       fn_utc_a_lima(creado_en) AS recibido_lima
  FROM mensaje_contacto WHERE estado IN ('nuevo','en_proceso');

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_reclamos_pendientes AS
SELECT id_reclamo, numero, tipo, CONCAT(nombres, ' ', apellidos) AS consumidor, tipo_doc, fn_enmascarar_documento(num_doc) AS num_doc,
       estado, fecha_limite, DATEDIFF(fecha_limite, fn_hoy_lima()) AS dias_restantes, fn_utc_a_lima(creado_en) AS registrado_lima
  FROM reclamo WHERE estado IN ('registrado','en_atencion');

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_solicitudes_arco_pendientes AS
SELECT id_solicitud, numero, tipo, nombres, tipo_documento, fn_enmascarar_documento(numero_documento) AS numero_documento,
       estado, fecha_limite, DATEDIFF(fecha_limite, fn_hoy_lima()) AS dias_restantes, fn_utc_a_lima(creado_en) AS recibida_lima
  FROM solicitud_arco WHERE estado IN ('recibida','en_atencion');

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_usuarios AS
SELECT u.id_usuario, r.codigo AS rol, u.nombre_completo, fn_enmascarar_correo(u.correo) AS correo, fn_enmascarar_telefono(u.celular) AS celular,
       u.tipo_documento, fn_enmascarar_documento(u.numero_documento) AS numero_documento, u.estado,
       (u.bloqueado_hasta IS NOT NULL AND u.bloqueado_hasta > UTC_TIMESTAMP(3)) AS bloqueado,
       COALESCE(f.activo, 0) AS tiene_2fa, fn_utc_a_lima(u.ultimo_acceso_en) AS ultimo_acceso_lima,
       fn_utc_a_lima(u.creado_en) AS registrado_lima, fn_utc_a_lima(u.inhabilitado_en) AS inhabilitado_lima
  FROM usuario u JOIN rol r ON r.id_rol = u.id_rol LEFT JOIN autenticacion_2fa f ON f.id_usuario = u.id_usuario;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_administradores_sin_2fa AS
SELECT u.id_usuario, u.nombre_completo, fn_enmascarar_correo(u.correo) AS correo
  FROM usuario u
  JOIN rol r ON r.id_rol = u.id_rol AND r.requiere_2fa = 1
  LEFT JOIN autenticacion_2fa f ON f.id_usuario = u.id_usuario AND f.activo = 1 AND f.metodo = 'totp'
 WHERE u.estado = 'activo' AND f.id_usuario IS NULL;   -- el 2FA por correo no cuenta para administradores

-- Últimos hashes (para que Django compare la nueva contraseña con check_password)
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_historial_contrasena_reciente AS
SELECT id_usuario, hash_contrasena, creado_en
  FROM (SELECT id_usuario, hash_contrasena, creado_en,
               ROW_NUMBER() OVER (PARTITION BY id_usuario ORDER BY id_historial DESC) AS n
          FROM historial_contrasena) h
 WHERE h.n <= 3;

-- =====================================================================
-- SISTEMA Y CONTROL DE CALIDAD
-- =====================================================================
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_auditoria AS
SELECT a.id_auditoria, fn_utc_a_lima(a.creado_en) AS fecha_lima, a.evento, a.entidad, a.id_entidad,
       COALESCE(u.nombre_completo, 'Sistema') AS actor, a.id_usuario_afectado, a.detalle, a.origen, a.usuario_bd,
       INET6_NTOA(a.ip) AS ip
  FROM auditoria a LEFT JOIN usuario u ON u.id_usuario = a.id_usuario_actor;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_configuracion_por_verificar AS
SELECT clave, valor, descripcion, nota_verificacion FROM configuracion WHERE por_verificar = 1;

CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_correos_pendientes AS
SELECT id_correo, fn_enmascarar_correo(destinatario) AS destinatario, plantilla, prioridad, estado, intentos, max_intentos,
       fn_utc_a_lima(proximo_intento_en) AS proximo_intento_lima, ultimo_error
  FROM cola_correo WHERE estado IN ('pendiente','procesando','error');

-- Chequeos de consistencia: debe devolver 0 filas en una base sana
CREATE OR REPLACE DEFINER=`wanka_definer`@`localhost` SQL SECURITY DEFINER VIEW v_inconsistencias AS
SELECT 'stock_reservado_vs_reservas' AS control, v.id_variante AS id, CONCAT(v.sku, ': reservado ', v.stock_reservado, ' vs reservas ', COALESCE(r.res, 0)) AS detalle
  FROM variante_producto v
  LEFT JOIN (SELECT id_variante, SUM(cantidad) AS res FROM reserva_stock WHERE estado = 'activa' GROUP BY id_variante) r ON r.id_variante = v.id_variante
 WHERE v.stock_reservado <> COALESCE(r.res, 0)
UNION ALL
SELECT 'stock_vs_kardex', v.id_variante, CONCAT(v.sku, ': stock ', v.stock_actual, ' vs kardex ', k.stock_actual_resultante)
  FROM variante_producto v
  JOIN (SELECT m.id_variante, m.stock_actual_resultante FROM movimiento_stock m
          JOIN (SELECT id_variante, MAX(id_movimiento) AS ult FROM movimiento_stock GROUP BY id_variante) u ON u.ult = m.id_movimiento) k
    ON k.id_variante = v.id_variante
 WHERE v.stock_actual <> k.stock_actual_resultante
UNION ALL
SELECT 'stock_sin_kardex', v.id_variante, CONCAT(v.sku, ': stock ', v.stock_actual, ' sin movimientos')
  FROM variante_producto v LEFT JOIN (SELECT DISTINCT id_variante FROM movimiento_stock) m ON m.id_variante = v.id_variante
 WHERE m.id_variante IS NULL AND (v.stock_actual <> 0 OR v.stock_reservado <> 0)
UNION ALL
SELECT 'pedido_subtotal_vs_items', pe.id_pedido, CONCAT(pe.numero, ': subtotal ', pe.subtotal, ' vs items ', COALESCE(i.s, 0))
  FROM pedido pe
  LEFT JOIN (SELECT id_pedido, SUM(subtotal) AS s FROM item_pedido WHERE estado = 'vigente' GROUP BY id_pedido) i ON i.id_pedido = pe.id_pedido
 WHERE pe.subtotal <> COALESCE(i.s, 0)
UNION ALL
SELECT 'pedido_pagado_vs_pagos', pe.id_pedido, CONCAT(pe.numero, ': pagado ', pe.monto_pagado, ' vs pagos ', COALESCE(p.s, 0))
  FROM pedido pe
  LEFT JOIN (SELECT id_pedido, SUM(monto) AS s, SUM(monto_reembolsado) AS r FROM pago
              WHERE aplicado_al_pedido = 1 AND estado IN ('confirmado','reembolsado') GROUP BY id_pedido) p ON p.id_pedido = pe.id_pedido
 WHERE pe.monto_pagado <> COALESCE(p.s, 0) OR pe.monto_reembolsado <> COALESCE(p.r, 0)
UNION ALL
SELECT 'pedido_devuelto_vs_devoluciones', pe.id_pedido, CONCAT(pe.numero, ': devuelto ', pe.monto_devuelto, ' vs devoluciones ', COALESCE(d.s, 0))
  FROM pedido pe
  LEFT JOIN (SELECT id_pedido, SUM(monto_total) AS s FROM devolucion GROUP BY id_pedido) d ON d.id_pedido = pe.id_pedido
 WHERE pe.monto_devuelto <> COALESCE(d.s, 0)
UNION ALL
SELECT 'pedido_ajustes_vs_notas', pe.id_pedido, CONCAT(pe.numero, ': ajustes ', pe.monto_ajustes, ' vs notas/compensaciones ', COALESCE(a.s, 0))
  FROM pedido pe
  LEFT JOIN (SELECT x.id_pedido, SUM(x.monto) AS s FROM (
               SELECT c.id_pedido, c.total AS monto FROM comprobante c JOIN motivo_nota_credito m ON m.codigo = c.codigo_motivo_nc
                WHERE c.tipo = 'nota_credito' AND c.estado_sunat NOT IN ('rechazado','anulado') AND m.es_total = 0 AND m.repone_stock = 0
                  AND c.id_devolucion IS NULL
               UNION ALL
               SELECT id_pedido, monto FROM reembolso WHERE motivo = 'ajuste_precio' AND id_nota_credito IS NULL AND estado = 'completado') x
              GROUP BY x.id_pedido) a ON a.id_pedido = pe.id_pedido
 WHERE pe.monto_ajustes <> LEAST(COALESCE(a.s, 0), pe.total - pe.monto_devuelto)
UNION ALL
SELECT 'pedido_vencido_con_pago_huerfano', pe.id_pedido, CONCAT(pe.numero, ': pendiente de pago vencido con pago no aplicado (debió expirar)')
  FROM pedido pe
 WHERE pe.estado = 'pendiente_pago' AND pe.expira_en < UTC_TIMESTAMP(3) - INTERVAL 1 DAY
   AND EXISTS (SELECT 1 FROM pago p WHERE p.id_pedido = pe.id_pedido AND p.estado = 'confirmado' AND p.aplicado_al_pedido = 0)
UNION ALL
SELECT 'comprobante_vs_lineas', c.id_comprobante, CONCAT(c.numero_completo, ': total ', c.total, ' vs líneas ', COALESCE(l.t, 0))
  FROM comprobante c
  LEFT JOIN (SELECT id_comprobante, SUM(total_linea) AS t, SUM(igv) AS i FROM comprobante_item GROUP BY id_comprobante) l ON l.id_comprobante = c.id_comprobante
 WHERE c.total <> COALESCE(l.t, 0) OR c.igv <> COALESCE(l.i, 0)
UNION ALL
SELECT 'insumo_vs_kardex', i.id_insumo, CONCAT(i.nombre, ': stock ', i.stock_actual, ' vs kardex ', k.stock_resultante)
  FROM insumo i
  JOIN (SELECT m.id_insumo, m.stock_resultante FROM movimiento_insumo m
          JOIN (SELECT id_insumo, MAX(id_movimiento) AS ult FROM movimiento_insumo GROUP BY id_insumo) u ON u.ult = m.id_movimiento) k
    ON k.id_insumo = i.id_insumo
 WHERE i.stock_actual <> k.stock_resultante;

SELECT 'Vistas listas: continúa con 06_eventos.sql' AS siguiente_paso;
