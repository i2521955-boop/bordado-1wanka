-- =====================================================================
-- BORDADOS WANKA S.A.C. — 99_pruebas.sql
-- ---------------------------------------------------------------------
-- Propósito : pruebas automáticas con resultado ✔ / ✘.
-- IMPORTANTE: corre SOLO sobre una base de pruebas desechable
--             (bordados_wanka_test). Los procedimientos confirman sus propias
--             transacciones, por eso no se usa ROLLBACK: se usa una base
--             aparte que se borra y recrea en cada corrida:
--                 ./scripts/instalar.sh --pruebas
--             En phpMyAdmin: instale 00..08 cambiando el nombre de la base
--             a bordados_wanka_test y luego importe este archivo.
-- Resultado : al final se listan los casos; "✘" = falla.
--
-- PRUEBAS DE CONCURRENCIA (manuales, dos pestañas de phpMyAdmin o dos
-- terminales "mysql"):
--  C1. Último ítem: deje stock 1 de una variante. Sesión A:
--        SET @app_actor_id=<cliente A>; START TRANSACTION;
--        SELECT * FROM variante_producto WHERE id_variante=<v> FOR UPDATE;
--      Sesión B: CALL sp_crear_pedido(<cliente B>, '[{"id_variante":<v>,"cantidad":1}]', 'recojo', NULL,'total','boleta',NULL,NULL,NULL,NULL,NULL,NULL,'web',@p,@n,@t);
--        → queda esperando el bloqueo. Sesión A: CALL sp_crear_pedido(... cliente A ...) → se confirma y libera.
--        Sesión B termina con ERROR 45001 (stock insuficiente). Nunca hay sobreventa.
--  C2. Doble clic en "pagar": ejecute dos veces sp_registrar_pago con la MISMA
--      idempotency_key desde dos sesiones a la vez → un solo pago; la segunda
--      llamada devuelve p_duplicado = 1 y el mismo id_pago.
--  C3. Webhook duplicado: dos sesiones llaman sp_registrar_evento_pasarela con el
--      mismo (proveedor, id_externo) → una sola fila; la segunda ve p_ya_procesado
--      cuando la primera terminó; sp_procesar_pago_pasarela devuelve "duplicado".
--  C4. Dos administradores validan el mismo voucher: ambos llaman
--      sp_confirmar_pago_manual(<id_pago>) → el primero confirma; el segundo espera
--      el bloqueo del pedido y recibe ERROR 45004 "El pago ya fue confirmado".
--  C5. Dos solicitudes de código a la vez para el mismo correo: se serializan por
--      control_frecuencia (FOR UPDATE); nunca hay dos códigos activos iguales
--      (índice único sobre hash_vigente) y el límite de 5 por hora se respeta.
-- =====================================================================
USE bordados_wanka_test;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';

DROP TABLE IF EXISTS tst_resultado;
CREATE TABLE tst_resultado (
  id        INT AUTO_INCREMENT PRIMARY KEY,
  caso      VARCHAR(150) NOT NULL,
  resultado VARCHAR(2)   NOT NULL,
  detalle   VARCHAR(600) NULL
);

DELIMITER $$
DROP PROCEDURE IF EXISTS tst_guardia $$
CREATE PROCEDURE tst_guardia()
BEGIN
  IF DATABASE() NOT LIKE '%\_test' THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Las pruebas solo corren sobre una base *_test (desechable)';
  END IF;
END $$

DROP PROCEDURE IF EXISTS tst_ok $$
CREATE PROCEDURE tst_ok(IN p_caso VARCHAR(150), IN p_cond BOOLEAN, IN p_detalle VARCHAR(600))
BEGIN
  INSERT INTO tst_resultado (caso, resultado, detalle) VALUES (p_caso, IF(COALESCE(p_cond, 0), '✔', '✘'), p_detalle);
END $$

DROP PROCEDURE IF EXISTS tst_error $$
CREATE PROCEDURE tst_error(IN p_caso VARCHAR(150), IN p_sql TEXT, IN p_errno INT)
BEGIN
  DECLARE v_errno INT DEFAULT 0;
  DECLARE v_msg VARCHAR(512) DEFAULT 'no hubo error';
  BEGIN
    DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_errno = MYSQL_ERRNO, v_msg = MESSAGE_TEXT;
    SET @tst_sql = p_sql;
    PREPARE tst_stmt FROM @tst_sql;
    EXECUTE tst_stmt;
    DEALLOCATE PREPARE tst_stmt;
  END;
  SET @wanka_ctx_interno = NULL;
  INSERT INTO tst_resultado (caso, resultado, detalle)
  VALUES (p_caso, IF(v_errno = p_errno, '✔', '✘'), LEFT(CONCAT('esperado ', p_errno, ' / obtenido ', v_errno, ': ', v_msg), 600));
END $$

-- Crea un cliente activo (registro + verificación del correo con código)
DROP PROCEDURE IF EXISTS tst_crear_cliente $$
CREATE PROCEDURE tst_crear_cliente(IN p_correo VARCHAR(254), IN p_nombres VARCHAR(80), IN p_apellidos VARCHAR(80), OUT p_id BIGINT UNSIGNED)
BEGIN
  DECLARE v_actor VARCHAR(30) DEFAULT @app_actor_id;
  SET @app_actor_id = NULL;
  CALL sp_registrar_usuario(p_correo, @hash, p_nombres, p_apellidos, NULL, '1.0', 0, p_id);
  CALL sp_generar_codigo_verificacion(p_id, p_correo, 'verificar_correo', @pepper, @tst_cod, @tst_exp, @tst_idc);
  CALL sp_verificar_codigo(p_correo, 'verificar_correo', @tst_cod, @pepper, @tst_res, @tst_rest, @tst_uid);
  SET @app_actor_id = v_actor;
END $$
DELIMITER ;

CALL tst_guardia();

SET @pepper = 'pepper-solo-para-pruebas-0123456789';
SET @hash   = 'pbkdf2_sha256$600000$salpruebas$QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=';
SET @app_ip = '190.12.34.56';
SET @app_actor_id = NULL;

-- =====================================================================
-- 0. FUNCIONES BASE
-- =====================================================================
CALL tst_ok('F01 IGV incluido en S/ 118.00 = S/ 18.00', fn_igv_incluido(118.00, 18) = 18.00, NULL);
CALL tst_ok('F02 Base + IGV = total exacto (S/ 505.00)', (505.00 - fn_igv_incluido(505.00, 18)) + fn_igv_incluido(505.00, 18) = 505.00,
            CONCAT('IGV = ', fn_igv_incluido(505.00, 18)));
CALL tst_ok('F03 RUC de la empresa válido (dígito verificador)', fn_ruc_valido('20615339386'), NULL);
CALL tst_ok('F04 RUC con dígito verificador errado se rechaza', NOT fn_ruc_valido('20615339387'), NULL);
CALL tst_ok('F05 RUC con prefijo no permitido se rechaza', NOT fn_ruc_valido('30615339386'), NULL);
CALL tst_ok('F06 "Día" de Lima: 03:00 UTC del 01/01 es 31/12 en Lima', DATE(fn_utc_a_lima('2026-01-01 03:00:00')) = '2025-12-31', NULL);
CALL tst_ok('F07 Código aleatorio de 6 dígitos (RANDOM_BYTES)', REGEXP_LIKE(fn_generar_digitos(6), '^[0-9]{6}$'), NULL);
CALL tst_ok('F08 Detecta número de tarjeta (Luhn) en JSON', fn_contiene_datos_tarjeta('{"nro":"4111 1111 1111 1111"}'), NULL);
CALL tst_ok('F09 Detecta la clave "cvv"', fn_contiene_datos_tarjeta('{"cvv":"123"}'), NULL);
CALL tst_ok('F10 No confunde un id de pago con una tarjeta', NOT fn_contiene_datos_tarjeta('{"payment_id":12345678901,"status":"approved"}'), NULL);
CALL tst_ok('F11 Enmascarado de DNI', fn_enmascarar_documento('45678912') = '*****912', NULL);
CALL tst_ok('F12 Días hábiles: viernes + 1 = lunes', fn_sumar_dias_habiles('2026-10-16', 1) = '2026-10-19', NULL);

-- =====================================================================
-- 1. ADMINISTRADOR, CATÁLOGO E INVENTARIO
-- =====================================================================
CALL sp_crear_administrador_inicial(' Admin@Prueba.PE ', @hash, 'Ana', 'Administradora', @id_admin);
CALL tst_ok('A01 Administrador inicial creado (correo normalizado)', (SELECT correo FROM usuario WHERE id_usuario = @id_admin) = 'admin@prueba.pe', NULL);
CALL tst_error('A02 No se crea un segundo administrador "inicial"', "CALL sp_crear_administrador_inicial('otro@prueba.pe', @hash, 'Otro', 'Admin', @x)", 45023);
CALL tst_ok('A03 El administrador sin 2FA aparece en v_administradores_sin_2fa', (SELECT COUNT(*) FROM v_administradores_sin_2fa WHERE id_usuario = @id_admin) = 1, NULL);
SET @app_actor_id = @id_admin;

SET @cat_pol = (SELECT id_categoria FROM categoria WHERE slug = 'polleras');
SET @cat_cha = (SELECT id_categoria FROM categoria WHERE slug = 'chalecos');
INSERT INTO producto (id_categoria, nombre, slug, descripcion, precio_base, tipo_fabricacion, estado)
VALUES (@cat_pol, ' Pollera Bordada Wanka ', 'pollera-bordada-wanka', 'Pollera de bayeta bordada a mano, acabado artesanal único del valle del Mantaro', 250.00, 'stock', 'activo');
SET @prod_pol = LAST_INSERT_ID();
INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES (@prod_pol, ' pol-roj-m ', 'M', 'Rojo');
SET @var_pol = LAST_INSERT_ID();
INSERT INTO precio_volumen (id_producto, cantidad_minima, precio_unitario) VALUES (@prod_pol, 6, 220.00);
INSERT INTO producto (id_categoria, nombre, slug, descripcion, precio_base, tipo_fabricacion, dias_produccion, permite_personalizacion, estado)
VALUES (@cat_cha, 'Chaleco Personalizado', 'chaleco-personalizado', 'Chaleco bordado con el nombre de la comparsa', 180.00, 'a_pedido', 7, 1, 'activo');
SET @prod_cha = LAST_INSERT_ID();
INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES (@prod_cha, 'CHA-NEG-U', 'U', 'Negro');
SET @var_cha = LAST_INSERT_ID();

CALL tst_ok('C01 SKU normalizado (trim + MAYÚSCULAS) y nombre sin espacios',
            (SELECT sku FROM variante_producto WHERE id_variante = @var_pol) = 'POL-ROJ-M'
            AND (SELECT nombre FROM producto WHERE id_producto = @prod_pol) = 'Pollera Bordada Wanka', NULL);
CALL tst_error('C02 Stock inicial directo prohibido (debe pasar por el kardex)',
               "INSERT INTO variante_producto (id_producto, sku, stock_actual) VALUES (@prod_pol, 'POL-AZU-S', 5)", 45023);
CALL sp_ajustar_stock(@var_pol, 'ingreso', 10, 'Lote inicial', @st);
CALL tst_ok('C03 Ingreso de stock registrado en el kardex', @st = 10 AND (SELECT COUNT(*) FROM movimiento_stock WHERE id_variante = @var_pol AND tipo = 'ingreso') = 1, NULL);
CALL tst_error('C04 UPDATE directo del stock bloqueado', "UPDATE variante_producto SET stock_actual = 999 WHERE id_variante = @var_pol", 45023);
CALL tst_error('C05 Slug inválido rechazado por CHECK', "INSERT INTO producto (id_categoria, nombre, slug, precio_base) VALUES (@cat_pol, 'Malo', 'Slug Malo', 10)", 3819);
CALL tst_ok('C06 Búsqueda FULLTEXT insensible a tildes ("unico" encuentra "único")',
            (SELECT COUNT(*) FROM producto WHERE MATCH(nombre, descripcion) AGAINST ('unico' IN NATURAL LANGUAGE MODE)) = 1, NULL);
CALL tst_ok('C07 v_catalogo_productos muestra precio y stock', (SELECT stock_disponible FROM v_catalogo_productos WHERE id_producto = @prod_pol) = 10, NULL);
CALL tst_error('C08 DELETE físico de producto bloqueado', "DELETE FROM producto WHERE id_producto = @prod_pol", 45005);
CALL tst_error('C09 Inhabilitar categoría con productos activos', "CALL sp_inhabilitar_categoria(@cat_pol, 'prueba')", 45032);
CALL tst_error('C10 Inhabilitar directo (UPDATE activo) bloqueado', "UPDATE categoria SET activo = 0, inhabilitado_en = UTC_TIMESTAMP(3) WHERE id_categoria = @cat_pol", 45023);

-- =====================================================================
-- 2. REGISTRO, CÓDIGOS DE VERIFICACIÓN Y ACCESO
-- =====================================================================
SET @app_actor_id = NULL;
CALL sp_registrar_usuario(' Rosa.Quispe@Correo.PE', @hash, 'Rosa', 'Quispe', '987 654 321', '1.0', 0, @cli1);
CALL tst_ok('U01 Registro: pendiente de verificación, correo y celular normalizados',
            (SELECT estado = 'pendiente_verificacion' AND correo = 'rosa.quispe@correo.pe' AND celular = '987654321' FROM usuario WHERE id_usuario = @cli1), NULL);
CALL tst_ok('U02 Registro guarda consentimientos con versión e IP', (SELECT COUNT(*) FROM consentimiento_datos WHERE id_usuario = @cli1 AND ip IS NOT NULL) = 3, NULL);
CALL tst_ok('U03 Registro guarda el historial de contraseña', (SELECT COUNT(*) FROM historial_contrasena WHERE id_usuario = @cli1) = 1, NULL);
CALL tst_error('U04 Correo duplicado', "CALL sp_registrar_usuario('ROSA.quispe@correo.pe', @hash, 'Rosa', 'Q', NULL, '1.0', 0, @x)", 45033);
CALL tst_error('U05 Contraseña en texto plano rechazada', "CALL sp_registrar_usuario('plano@correo.pe', 'MiClave123', 'Juan', 'Perez', NULL, '1.0', 0, @x)", 3819);

CALL sp_generar_codigo_verificacion(@cli1, 'rosa.quispe@correo.pe', 'verificar_correo', @pepper, @cod1, @exp1, @idcod1);
CALL tst_ok('V01 Solo se guarda el hash del código (SHA-256 + pepper)',
            (SELECT codigo_hash <> @cod1 AND codigo_hash = SHA2(CONCAT(@pepper, ':', @cod1), 256) FROM codigo_verificacion WHERE id_codigo = @idcod1), NULL);
CALL tst_ok('V02 El código vence en 5 minutos', TIMESTAMPDIFF(SECOND, (SELECT creado_en FROM codigo_verificacion WHERE id_codigo = @idcod1), @exp1) = 300, NULL);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'verificar_correo', @cod1, @pepper, @res, @rest, @uid);
CALL tst_ok('V03 Código correcto: la cuenta queda activa', @res = 'ok' AND (SELECT estado FROM usuario WHERE id_usuario = @cli1) = 'activo', @res);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'verificar_correo', @cod1, @pepper, @res, @rest, @uid);
CALL tst_ok('V04 Código reutilizado se rechaza', @res = 'usado', @res);

-- Código vencido (se acorta su vigencia; extenderla está prohibido)
CALL sp_generar_codigo_verificacion(@cli1, 'rosa.quispe@correo.pe', 'iniciar_sesion', @pepper, @cod2, @exp2, @idcod2);
UPDATE codigo_verificacion SET expira_en = creado_en + INTERVAL 1000 MICROSECOND WHERE id_codigo = @idcod2;
DO SLEEP(0.05);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'iniciar_sesion', @cod2, @pepper, @res, @rest, @uid);
CALL tst_ok('V05 Código vencido (5 min) se rechaza en la BD', @res = 'vencido', @res);
CALL tst_error('V06 No se puede extender la vigencia de un código', "UPDATE codigo_verificacion SET expira_en = expira_en + INTERVAL 1 HOUR WHERE id_codigo = @idcod2", 45004);

-- Más de 5 intentos
CALL sp_generar_codigo_verificacion(@cli1, 'rosa.quispe@correo.pe', 'recuperar_contrasena', @pepper, @cod3, @exp3, @idcod3);
SET @malo = IF(@cod3 = '000000', '111111', '000000');
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @malo, @pepper, @r1, @rest1, @uid);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @malo, @pepper, @r2, @rest2, @uid);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @malo, @pepper, @r3, @rest3, @uid);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @malo, @pepper, @r4, @rest4, @uid);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @malo, @pepper, @r5, @rest5, @uid);
CALL tst_ok('V07 Intentos fallidos descuentan y al 5.º se bloquea', @r1 = 'invalido' AND @rest1 = 4 AND @r4 = 'invalido' AND @r5 = 'bloqueado',
            CONCAT_WS(',', @r1, @rest1, @r4, @r5));
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @cod3, @pepper, @r6, @rest6, @uid);
CALL tst_ok('V08 Código bloqueado ya no sirve ni con el valor correcto', @r6 = 'bloqueado', @r6);
CALL tst_error('V09 Recuperar contraseña sin código verificado', "CALL sp_cambiar_contrasena(@cli1, 'pbkdf2_sha256$600000$otra$NUEVAHASHNUEVAHASHNUEVAHASH=', 'recuperacion')", 45011);

-- Nunca dos códigos vigentes iguales (índice único sobre el hash vigente)
SET @app_actor_id = @cli1;   -- cambiar_contrasena se pide desde la cuenta iniciada
CALL sp_generar_codigo_verificacion(@cli1, 'rosa.quispe@correo.pe', 'cambiar_contrasena', @pepper, @cod4, @exp4, @idcod4);
SET @app_actor_id = NULL;
CALL tst_error('V10 Código vigente repetido rechazado por índice único',
               "INSERT INTO codigo_verificacion (correo_destino, proposito, codigo_hash, expira_en) SELECT 'otro@correo.pe', 'iniciar_sesion', codigo_hash, UTC_TIMESTAMP(3) + INTERVAL 2 MINUTE FROM codigo_verificacion WHERE id_codigo = @idcod4", 1062);

-- Más de 5 códigos por hora (correo nuevo)
CALL sp_registrar_usuario('limite@correo.pe', @hash, 'Luis', 'Limite', NULL, '1.0', 0, @cli_lim);
CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z);
CALL tst_ok('V11 Cada código nuevo reemplaza al anterior (un solo vigente)',
            (SELECT COUNT(*) FROM codigo_verificacion WHERE correo_destino = 'limite@correo.pe' AND estado = 'activo') = 1, NULL);
CALL tst_error('V12 El 6.º código en una hora se rechaza', "CALL sp_generar_codigo_verificacion(@cli_lim, 'limite@correo.pe', 'verificar_correo', @pepper, @x, @y, @z)", 45010);
CALL tst_ok('V13 El bloqueo por límite queda auditado', (SELECT COUNT(*) FROM auditoria WHERE evento = 'codigo_limite_excedido' AND id_usuario_afectado = @cli_lim) = 1, NULL);
CALL tst_ok('V14 La cola de correos no lleva códigos en claro', (SELECT COUNT(*) FROM cola_correo WHERE JSON_CONTAINS_PATH(contexto, 'one', '$.codigo')) = 0, NULL);

-- Bloqueo de cuenta: 5 intentos fallidos = 15 minutos
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 0, 'pruebas', @ra1, @u, @b, @f);
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 0, 'pruebas', @ra2, @u, @b, @f);
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 0, 'pruebas', @ra3, @u, @b, @f);
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 0, 'pruebas', @ra4, @u, @b, @f);
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 0, 'pruebas', @ra5, @u, @bloqueo, @f);
CALL sp_registrar_intento_acceso('rosa.quispe@correo.pe', 1, 'pruebas', @ra6, @u, @b, @f);
CALL tst_ok('L01 Al 5.º intento fallido la cuenta se bloquea 15 minutos',
            @ra4 = 'credenciales_invalidas' AND @ra5 = 'bloqueada_ahora' AND TIMESTAMPDIFF(MINUTE, UTC_TIMESTAMP(3), @bloqueo) BETWEEN 14 AND 15, CONCAT_WS(',', @ra4, @ra5, @bloqueo));
CALL tst_ok('L02 Bloqueada: ni con la contraseña correcta entra', @ra6 = 'cuenta_bloqueada', @ra6);
CALL tst_ok('L03 Intentos y bloqueo registrados (intento_acceso + auditoría)',
            (SELECT COUNT(*) FROM intento_acceso WHERE id_usuario = @cli1) = 6 AND (SELECT COUNT(*) FROM auditoria WHERE evento = 'cuenta_bloqueada' AND id_usuario_afectado = @cli1) = 1, NULL);
SET @app_actor_id = @id_admin;
CALL sp_desbloquear_usuario(@cli1);
SET @app_actor_id = NULL;
CALL sp_registrar_intento_acceso('admin@prueba.pe', 1, 'pruebas', @radm, @u, @b, @req2fa);
CALL tst_ok('L04 El administrador siempre requiere segundo factor', @radm = 'requiere_2fa' AND @req2fa = 1, @radm);

-- =====================================================================
-- 3. FLUJO FELIZ: carrito → pedido → pago total (webhook) → preparación → envío → entrega → comprobante → reseña
-- =====================================================================
SET @app_actor_id = @cli1;
INSERT INTO direccion (id_usuario, alias, nombre_receptor, telefono, direccion, distrito, provincia, departamento, id_zona)
VALUES (@cli1, 'Casa', 'Rosa Quispe', '987-654-321', 'Jr. Puno 123', 'Huancayo', 'Huancayo', 'Junín', 1);
SET @dir1 = LAST_INSERT_ID();
CALL sp_definir_direccion_predeterminada(@dir1);
CALL sp_agregar_item_carrito(@cli1, @var_pol, 2, NULL, @disp);
CALL tst_ok('P01 El carrito no guarda precios', (SELECT COUNT(*) FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'item_carrito' AND column_name LIKE '%precio%') = 0, NULL);
CALL sp_crear_pedido(@cli1, NULL, 'domicilio', @dir1, 'total', 'boleta', 'DNI', '45678912', 'Rosa Quispe', NULL, NULL, NULL, 'web', @p1, @n1, @t1);
CALL tst_ok('P02 Pedido desde el carrito: total = 2 × 250 + envío de la zona (5)', @t1 = 505.00 AND @n1 LIKE 'BW-%', CONCAT(@n1, ' ', @t1));
CALL tst_ok('P03 Nace pendiente de pago, con historial y stock reservado',
            (SELECT estado FROM pedido WHERE id_pedido = @p1) = 'pendiente_pago'
            AND (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol) = 2
            AND (SELECT COUNT(*) FROM historial_estado_pedido WHERE id_pedido = @p1) = 1, NULL);
CALL tst_ok('P04 El carrito quedó convertido', (SELECT estado FROM carrito WHERE id_pedido = @p1) = 'convertido', NULL);
CALL tst_ok('P05 Copia del ítem (nombre, SKU, talla, precio) en el pedido',
            (SELECT nombre_producto = 'Pollera Bordada Wanka' AND sku = 'POL-ROJ-M' AND talla = 'M' AND precio_unitario = 250.00 FROM item_pedido WHERE id_pedido = @p1), NULL);

CALL sp_registrar_pago(@p1, 'mercadopago', 505.00, 'idem-pedido1-intento-0001', NULL, NULL, '{"preference_id":"PREF-1"}', NULL, NULL, NULL, @pg1, @epg1, @dup1);
CALL sp_registrar_pago(@p1, 'mercadopago', 505.00, 'idem-pedido1-intento-0001', NULL, NULL, '{"preference_id":"PREF-1"}', NULL, NULL, NULL, @pg1b, @epg1b, @dup1b);
CALL tst_ok('P06 Doble clic en pagar: mismo pago (idempotencia)', @pg1 = @pg1b AND @dup1b = 1 AND (SELECT COUNT(*) FROM pago WHERE id_pedido = @p1) = 1, NULL);
CALL tst_error('P07 Misma clave con otro monto = conflicto', "CALL sp_registrar_pago(@p1, 'mercadopago', 100.00, 'idem-pedido1-intento-0001', NULL, NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45027);
CALL tst_error('P08 Prohibido guardar datos de tarjeta', "CALL sp_registrar_pago(@p1, 'mercadopago', 505.00, 'idem-pedido1-intento-0002', NULL, NULL, '{\"card_number\":\"4111111111111111\"}', NULL, NULL, NULL, @x, @y, @z)", 45031);

SET @app_actor_id = NULL;   -- webhook
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-0001', 'payment.updated', '{"id":"9001","status":"approved"}', 1, @ev1, @proc1);
CALL sp_procesar_pago_pasarela(@ev1, 'mercadopago', 'idem-pedido1-intento-0001', 'MP-9001', 'aprobado', 505.00, NULL, NULL, NULL, '{"status":"approved"}', @rp1);
CALL tst_ok('P09 Webhook aprobado confirma el pago y el pedido',
            @rp1 = 'confirmado' AND (SELECT estado = 'confirmado' AND estado_pago = 'pagado' AND saldo = 0 FROM pedido WHERE id_pedido = @p1), @rp1);
CALL tst_ok('P10 Al confirmar: la reserva se convierte en venta (stock 10 → 8)',
            (SELECT stock_actual = 8 AND stock_reservado = 0 FROM variante_producto WHERE id_variante = @var_pol)
            AND (SELECT estado FROM reserva_stock WHERE id_pedido = @p1) = 'consumida', NULL);
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-0001', 'payment.updated', '{"id":"9001","status":"approved"}', 1, @ev1b, @proc1b);
CALL sp_procesar_pago_pasarela(@ev1b, 'mercadopago', 'idem-pedido1-intento-0001', 'MP-9001', 'aprobado', 505.00, NULL, NULL, NULL, NULL, @rp1b);
CALL tst_ok('P11 Webhook duplicado: una fila, se reconoce como ya procesado', @ev1 = @ev1b AND @proc1b = 1 AND @rp1b = 'duplicado'
            AND (SELECT intentos FROM evento_pasarela WHERE id_evento = @ev1) = 2, CONCAT_WS(',', @proc1b, @rp1b));
CALL tst_ok('P12 Aviso al cliente: correo en cola + notificación', (SELECT COUNT(*) FROM cola_correo WHERE plantilla = 'pedido_confirmado' AND id_usuario = @cli1) = 1
            AND (SELECT COUNT(*) FROM notificacion WHERE id_pedido = @p1 AND tipo = 'pedido_confirmado') = 1, NULL);

SET @app_actor_id = @id_admin;
CALL sp_cambiar_estado_pedido(@p1, 'en_preparacion', 'Empaquetando');
CALL sp_cambiar_estado_pedido(@p1, 'listo', NULL);
CALL tst_error('P13 Domicilio no pasa de listo a entregado (debe ir por enviado)', "CALL sp_cambiar_estado_pedido(@p1, 'entregado', NULL)", 45002);
CALL sp_registrar_envio(@p1, 1, 'G-0001', NULL, NULL, NULL, @env1);
CALL sp_registrar_seguimiento_envio(@env1, 'en_transito', 'Salió de Huancayo', 'Huancayo', NULL, 'admin', NULL, @d);
CALL sp_registrar_seguimiento_envio(@env1, 'entregado', 'Entregado a Rosa', 'Huancayo', NULL, 'admin', 'evt-curier-1', @d);
CALL sp_registrar_seguimiento_envio(@env1, 'entregado', 'Entregado a Rosa', 'Huancayo', NULL, 'admin', 'evt-curier-1', @dup_seg);
CALL tst_ok('P14 Envío con seguimiento: el evento "entregado" cierra el pedido',
            (SELECT estado FROM pedido WHERE id_pedido = @p1) = 'entregado' AND (SELECT COUNT(*) FROM seguimiento_envio WHERE id_envio = @env1) = 3 AND @dup_seg = 1, NULL);
CALL tst_ok('P15 Historial completo con quién hizo cada cambio', (SELECT COUNT(*) FROM v_historial_pedido WHERE id_pedido = @p1) = 6
            AND (SELECT COUNT(*) FROM historial_estado_pedido WHERE id_pedido = @p1 AND estado_nuevo = 'listo' AND id_usuario = @id_admin) = 1, NULL);

SET @app_actor_id = NULL;   -- worker del sistema
CALL sp_emitir_comprobante(@p1, @c1, @ya1);
CALL tst_ok('P16 Boleta B001 con copia de emisor y cliente, IGV cuadrado',
            (SELECT serie = 'B001' AND correlativo = 1 AND total = 505.00 AND op_gravada + igv = total AND emisor_ruc = '20615339386'
                    AND cliente_num_doc = '45678912' AND estado_sunat = 'pendiente' FROM comprobante WHERE id_comprobante = @c1), NULL);
CALL tst_ok('P17 Líneas del comprobante (producto + envío) cuadran con la cabecera',
            (SELECT COUNT(*) = 2 AND SUM(total_linea) = 505.00 FROM comprobante_item WHERE id_comprobante = @c1), NULL);
CALL sp_emitir_comprobante(@p1, @c1b, @ya1b);
CALL tst_ok('P18 Emitir otra vez es idempotente (mismo comprobante)', @c1 = @c1b AND @ya1b = 1, NULL);
CALL sp_tomar_comprobante_para_emitir('worker-1', @cola1);
CALL sp_registrar_respuesta_ose(@cola1, 'aceptado', 'OSE-PRUEBA', 'ext-0001', 'hash-cpe', '0', 'La Boleta ha sido aceptada',
                                'https://ose.example/b001-1.pdf', 'https://ose.example/b001-1.xml', 'https://ose.example/b001-1.cdr',
                                '{"documento":"B001-1"}', '{"codigo":"0"}');
CALL tst_ok('P19 Respuesta del OSE guardada (payloads, URLs) y cola completada',
            @cola1 = @c1 AND (SELECT estado_sunat = 'aceptado' AND payload_envio IS NOT NULL AND url_pdf IS NOT NULL FROM comprobante WHERE id_comprobante = @c1)
            AND (SELECT estado FROM cola_emision_comprobante WHERE id_comprobante = @c1) = 'completado', NULL);
CALL sp_guardar_archivo_comprobante(@c1, 'xml', 'application/xml', CAST('<Invoice>B001-1</Invoice>' AS BINARY));
CALL tst_ok('P20 Copia binaria del XML guardada con huella SHA-256', (SELECT tamano_bytes > 0 AND CHAR_LENGTH(sha256) = 64 FROM comprobante_archivo WHERE id_comprobante = @c1) = 1, NULL);
CALL tst_error('P21 Un comprobante aceptado no se modifica', "UPDATE comprobante SET cliente_nombre = 'Otro' WHERE id_comprobante = @c1", 45004);

SET @app_actor_id = @cli1;
CALL sp_registrar_resena(@cli1, @prod_pol, @p1, 5, 'Hermosa', 'Bordado impecable', @res1);
CALL tst_error('P22 Una sola reseña por producto y cliente', "CALL sp_registrar_resena(@cli1, @prod_pol, @p1, 4, 'Otra', NULL, @x)", 45026);
SET @app_actor_id = @id_admin;
CALL sp_moderar_resena(@res1, 'publicada', NULL);
CALL tst_ok('P23 Reseña moderada recalcula la valoración del producto',
            (SELECT valoracion_promedio = 5.0 AND total_resenas = 1 FROM producto WHERE id_producto = @prod_pol), NULL);
CALL tst_error('P24 La valoración no se fija a mano', "UPDATE producto SET valoracion_promedio = 1.0 WHERE id_producto = @prod_pol", 45023);

-- =====================================================================
-- 4. ADELANTO 50 %: adelanto → confirmado → saldo → pagado
-- =====================================================================
CALL tst_crear_cliente('maria.huaman@correo.pe', 'María', 'Huamán', @cli2);
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":2,"personalizacion":"Comparsa Los Wankas"}]'),
                     'recojo', NULL, 'adelanto', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p2, @n2, @t2);
CALL tst_ok('D01 Modalidad adelanto 50 %: monto requerido = mitad del total',
            (SELECT modalidad_pago = 'adelanto' AND adelanto_porcentaje = 50.00 AND monto_requerido = 180.00 AND total = 360.00 FROM pedido WHERE id_pedido = @p2), NULL);
CALL tst_ok('D02 Producto a pedido no reserva stock', (SELECT COUNT(*) FROM reserva_stock WHERE id_pedido = @p2) = 0, NULL);
CALL tst_error('D03 Con adelanto el primer pago no puede ser menor al adelanto', "CALL sp_registrar_pago(@p2, 'yape', 100.00, 'idem-pedido2-intento-0001', 'OP-1001', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45017);
CALL tst_error('D04 Yape sin voucher ni número de operación', "CALL sp_registrar_pago(@p2, 'yape', 180.00, 'idem-pedido2-intento-0002', NULL, NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45017);
CALL sp_registrar_pago(@p2, 'yape', 180.00, 'idem-pedido2-intento-0003', 'OP-1001', 'https://cdn.example/voucher1.jpg', NULL, NULL, NULL, NULL, @pg2, @epg2, @d);
CALL tst_ok('D05 Yape queda en revisión hasta que lo valide un administrador', @epg2 = 'en_revision' AND (SELECT COUNT(*) FROM v_pagos_por_validar WHERE id_pago = @pg2) = 1, @epg2);
CALL tst_error('D06 Un cliente no puede validar pagos', "CALL sp_confirmar_pago_manual(@pg2, @x)", 45023);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pg2, @ep2);
CALL tst_ok('D07 Adelanto validado: pedido confirmado con pago parcial y saldo 180',
            @ep2 = 'confirmado' AND (SELECT estado_pago = 'parcial' AND saldo = 180.00 FROM pedido WHERE id_pedido = @p2), @ep2);
CALL tst_error('D08 Segundo administrador validando el mismo voucher', "CALL sp_confirmar_pago_manual(@pg2, @x)", 45004);
CALL tst_error('D09 Un pago confirmado no se modifica', "UPDATE pago SET voucher_url = 'https://cdn.example/otro.jpg' WHERE id_pago = @pg2", 45004);
CALL sp_cambiar_estado_pedido(@p2, 'en_produccion', NULL);
CALL sp_cambiar_estado_pedido(@p2, 'listo', NULL);
CALL tst_error('D10 Regla de saldo: no se entrega con saldo pendiente', "CALL sp_cambiar_estado_pedido(@p2, 'entregado', NULL)", 45025);
SET @app_actor_id = @cli2;
CALL tst_error('D11 La misma operación Yape no se usa dos veces', "CALL sp_registrar_pago(@p2, 'yape', 180.00, 'idem-pedido2-intento-0004', 'OP-1001', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45027);
CALL tst_error('D12 Pago que excede el saldo', "CALL sp_registrar_pago(@p2, 'plin', 200.00, 'idem-pedido2-intento-0005', 'OP-2001', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45003);
CALL sp_registrar_pago(@p2, 'plin', 180.00, 'idem-pedido2-intento-0006', 'OP-2001', NULL, NULL, NULL, NULL, NULL, @pg2b, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pg2b, @x);
CALL tst_ok('D13 Saldo pagado: pedido pagado y tipo de pago "saldo"',
            (SELECT estado_pago = 'pagado' AND saldo = 0 FROM pedido WHERE id_pedido = @p2) AND (SELECT tipo FROM pago WHERE id_pago = @pg2b) = 'saldo', NULL);
CALL sp_cambiar_estado_pedido(@p2, 'entregado', 'Recogido en tienda');
CALL tst_ok('D14 Recojo: de listo a entregado sin pasar por enviado', (SELECT estado FROM pedido WHERE id_pedido = @p2) = 'entregado', NULL);

-- =====================================================================
-- 5. VENTA AL POR MAYOR: cotización → aceptación → pedido → adelanto
-- =====================================================================
CALL tst_crear_cliente('comparsa@correo.pe', 'Juan', 'Comparsa', @cli3);
SET @app_actor_id = @cli3;
CALL tst_error('M01 Mayorista sin anticipación (precio por volumen exige fecha)',
               CONCAT("CALL sp_crear_pedido(@cli3, '[{\"id_variante\":", @var_pol, ",\"cantidad\":6}]', 'recojo', NULL, 'total', 'boleta', 'DNI', '41234567', 'Juan Comparsa', NULL, NULL, NULL, 'web', @x, @y, @z)"), 45009);
CALL sp_solicitar_cotizacion(@cli3, 'mayor', 'Necesitamos polleras y fajas para la comparsa del Huaylarsh',
                             CONCAT('[{"id_variante":', @var_pol, ',"cantidad":6},{"descripcion":"Faja bordada con el nombre de la comparsa","cantidad":20,"personalizacion":"Los Wankas 2027"}]'),
                             fn_hoy_lima() + INTERVAL 20 DAY, NULL, @ct1, @ctn1);
SET @app_actor_id = @id_admin;
SET @it_pol = (SELECT id_item_cotizacion FROM item_cotizacion WHERE id_cotizacion = @ct1 AND id_variante = @var_pol);
SET @it_faj = (SELECT id_item_cotizacion FROM item_cotizacion WHERE id_cotizacion = @ct1 AND id_variante IS NULL);
CALL sp_cotizar(@ct1, CONCAT('[{"id_item_cotizacion":', @it_pol, ',"precio_unitario":210.00},{"id_item_cotizacion":', @it_faj, ',"precio_unitario":45.00}]'),
                30.00, 50, 15, 'Precio especial por volumen', NULL, @ctt1);
CALL tst_ok('M02 Cotización: total = 6×210 + 20×45 + envío 30', @ctt1 = 2190.00 AND (SELECT estado FROM cotizacion WHERE id_cotizacion = @ct1) = 'cotizada', @ctt1);
SET @app_actor_id = @cli3;
CALL tst_error('M03 Factura con RUC de dígito verificador inválido',
               "CALL sp_aceptar_cotizacion(@ct1, 'recojo', NULL, 'adelanto', 'factura', 'RUC', '20123456789', 'Comparsa SAC', 'Huancayo', NULL, @x, @y, @z)", 45006);
CALL sp_aceptar_cotizacion(@ct1, 'recojo', NULL, 'adelanto', 'factura', 'RUC', '20123456786', 'Asociación Cultural Los Wankas', 'Jr. Real 456, Huancayo', NULL, @p3, @n3, @t3);
CALL tst_ok('M04 Cotización convertida en pedido al por mayor con precios cotizados',
            @n3 LIKE 'BW-MAY-%' AND @t3 = 2160.00
            AND (SELECT estado FROM cotizacion WHERE id_cotizacion = @ct1) = 'convertida'
            AND (SELECT COUNT(*) FROM item_pedido WHERE id_pedido = @p3 AND origen_precio = 'cotizacion') = 2, CONCAT(@n3, ' ', @t3));
CALL tst_ok('M05 Adelanto de la cotización (50 %) y reserva de las 6 polleras',
            (SELECT monto_requerido FROM pedido WHERE id_pedido = @p3) = 1080.00
            AND (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol) = 6, NULL);
CALL tst_error('M06 Una cotización convertida no se acepta de nuevo',
               "CALL sp_aceptar_cotizacion(@ct1, 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45018);
CALL sp_registrar_pago(@p3, 'transferencia', 1080.00, 'idem-pedido3-intento-0001', 'BCP-778899', NULL, NULL, NULL, NULL, NULL, @pg3, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pg3, @ep3);
CALL tst_ok('M07 Adelanto mayorista validado: pedido confirmado', @ep3 = 'confirmado' AND (SELECT estado_pago FROM pedido WHERE id_pedido = @p3) = 'parcial', @ep3);

-- =====================================================================
-- 6. CANCELACIONES, PAGOS HUÉRFANOS, DEVOLUCIONES Y NOTAS DE CRÉDITO
-- =====================================================================
-- 6a. Cancelación sin pago: libera la reserva
SET @app_actor_id = @cli2;
SET @reservado_antes = (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol);
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p4, @n4, @t4);
CALL sp_cancelar_pedido(@p4, 'Ya no lo necesito');
CALL tst_ok('X01 Cancelar sin pago libera la reserva (kardex: reserva + liberación)',
            (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol) = @reservado_antes
            AND (SELECT COUNT(*) FROM movimiento_stock WHERE id_pedido = @p4) = 2 AND (SELECT estado FROM pedido WHERE id_pedido = @p4) = 'cancelado', NULL);
CALL tst_error('X02a El cliente no cambia estados a mano (solo el administrador)', "CALL sp_cambiar_estado_pedido(@p4, 'pendiente_pago', NULL)", 45023);
SET @app_actor_id = @id_admin;
CALL tst_error('X02 Cancelado no vuelve a pendiente (transición inválida)', "CALL sp_cambiar_estado_pedido(@p4, 'pendiente_pago', NULL)", 45002);
SET @app_actor_id = @cli2;

-- 6b. Pago huérfano: la pasarela confirma después de cancelado el pedido
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p5, @n5, @t5);
CALL sp_registrar_pago(@p5, 'mercadopago', 250.00, 'idem-pedido5-intento-0001', NULL, NULL, NULL, NULL, NULL, NULL, @pg5, @e, @d);
CALL tst_error('X02b Con un cobro de tarjeta en proceso el cliente no cancela (evita huérfanos)', "CALL sp_cancelar_pedido(@p5, 'Me equivoqué de talla')", 45007);
CALL tst_error('X02c Con un cobro en proceso el pedido no se edita', CONCAT("CALL sp_agregar_item(@p5, ", @var_cha, ", 1, NULL, @x)"), 45007);
CALL sp_anular_pago_pendiente(@pg5, 'Cerré la ventana de pago');
CALL tst_ok('X02d El cliente anula su cobro abandonado', (SELECT estado FROM pago WHERE id_pago = @pg5) = 'anulado', NULL);
CALL sp_cancelar_pedido(@p5, 'Me equivoqué de talla');
SET @app_actor_id = NULL;
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-0005', 'payment.updated', '{"id":"9005"}', 1, @ev5, @proc5);
CALL sp_procesar_pago_pasarela(@ev5, 'mercadopago', 'idem-pedido5-intento-0001', 'MP-9005', 'aprobado', 250.00, NULL, NULL, NULL, NULL, @rp5);
CALL tst_ok('X03 Cobro con pedido cancelado = pago huérfano por reembolsar (no se pierde)',
            @rp5 = 'confirmado_huerfano' AND (SELECT aplicado_al_pedido = 0 AND motivo_no_aplicado = 'pedido_cancelado' FROM pago WHERE id_pago = @pg5)
            AND (SELECT pendiente_de_reembolsar FROM v_pagos_por_reembolsar WHERE id_pago = @pg5) = 250.00
            AND (SELECT estado_pago FROM pedido WHERE id_pedido = @p5) = 'pendiente', @rp5);
CALL tst_error('X04 Webhook sin firma válida no se procesa',
               "CALL sp_registrar_evento_pasarela('paypal', 'pp-evt-1', 'x', '{\"a\":1}', 0, @evx, @px)", 0);
CALL tst_error('X05 ... y al procesarlo se rechaza', "CALL sp_procesar_pago_pasarela(@evx, 'paypal', NULL, 'PP-1', 'aprobado', 1.00, NULL, NULL, NULL, NULL, @r)", 45017);

-- 6c. Cancelación de un pedido ya confirmado: repone stock y queda por reembolsar
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p6, @n6, @t6);
CALL sp_registrar_pago(@p6, 'yape', 250.00, 'idem-pedido6-intento-0001', 'OP-6006', NULL, NULL, NULL, NULL, NULL, @pg6, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pg6, @x);
SET @stock_antes = (SELECT stock_actual FROM variante_producto WHERE id_variante = @var_pol);
CALL sp_cancelar_pedido(@p6, 'Cliente desistió');
CALL tst_ok('X06 Cancelar confirmado devuelve la unidad al stock y deja el pago por reembolsar',
            (SELECT stock_actual FROM variante_producto WHERE id_variante = @var_pol) = @stock_antes + 1
            AND (SELECT COUNT(*) FROM v_pagos_por_reembolsar WHERE id_pago = @pg6) = 1, NULL);
CALL sp_reembolsar_pago(@pg6, NULL, 'cancelacion', 'Devolución por Yape', 'yape', NULL, @rb6);
CALL tst_error('X07 No se reembolsa más de lo cobrado', "CALL sp_reembolsar_pago(@pg6, 1.00, 'otro', NULL, 'yape', NULL, @x)", 45029);
CALL sp_completar_reembolso(@rb6, 1, 'YAPE-REEMB-1', NULL);
CALL tst_ok('X08 Reembolso completado: pago reembolsado y pedido reembolsado',
            (SELECT estado FROM pago WHERE id_pago = @pg6) = 'reembolsado' AND (SELECT estado_pago FROM pedido WHERE id_pedido = @p6) = 'reembolsado'
            AND (SELECT COUNT(*) FROM v_pagos_por_reembolsar WHERE id_pago = @pg6) = 0, NULL);

-- 6d. Devolución parcial y total del pedido 1 (entregado y con boleta aceptada)
SET @item_p1 = (SELECT id_item_pedido FROM item_pedido WHERE id_pedido = @p1);
SET @stock_antes = (SELECT stock_actual FROM variante_producto WHERE id_variante = @var_pol);
CALL sp_devolver_pedido(@p1, CONCAT('[{"id_item_pedido":', @item_p1, ',"cantidad":1}]'), 'Talla incorrecta', 1, @dv1, @mdv1, @nc1);
CALL tst_ok('X09 Devolución parcial: repone 1 unidad, emite NC (BC01) y solicita reembolso',
            (SELECT stock_actual FROM variante_producto WHERE id_variante = @var_pol) = @stock_antes + 1
            AND (SELECT serie = 'BC01' AND total = 250.00 AND id_devolucion = @dv1 AND codigo_motivo_nc = '07' FROM comprobante WHERE id_comprobante = @nc1)
            AND (SELECT COUNT(*) FROM reembolso WHERE id_devolucion = @dv1 AND monto = 250.00 AND id_nota_credito = @nc1) = 1
            AND (SELECT estado FROM pedido WHERE id_pedido = @p1) = 'entregado', CONCAT_WS(',', @dv1, @mdv1, @nc1));
CALL tst_error('X10 No se devuelve más de lo vendido (ni dos veces)',
               CONCAT("CALL sp_devolver_pedido(@p1, '[{\"id_item_pedido\":", @item_p1, ",\"cantidad\":2}]', 'Otra vez', 0, @x, @y, @z)"), 45019);
CALL tst_error('X11 Nota de crédito mayor al saldo del comprobante', "CALL sp_emitir_nota_credito(@c1, '09', 'Ajuste', 300.00, NULL, 0, @x, @y)", 45016);
CALL sp_devolver_pedido(@p1, NULL, 'Devuelve la otra pollera', 1, @dv2, @mdv2, @nc2);
CALL tst_ok('X12 Devolución del resto: pedido devuelto, segunda NC y saldo del comprobante = envío',
            (SELECT estado FROM pedido WHERE id_pedido = @p1) = 'devuelto' AND (SELECT saldo_disponible FROM v_notas_credito_saldo WHERE id_comprobante = @c1) = 5.00, NULL);
CALL tst_error('X13 Devolver un pedido ya devuelto', "CALL sp_devolver_pedido(@p1, NULL, 'Tercera vez', 0, @x, @y, @z)", 45019);
CALL tst_error('X14 NC con motivo de anulación total por monto parcial', "CALL sp_emitir_nota_credito(@c1, '01', 'Anulación', 1.00, NULL, 0, @x, @y)", 45016);

-- 6e. NC contra un comprobante no aceptado
SET @app_actor_id = NULL;
CALL sp_emitir_comprobante(@p2, @c2, @ya2);
SET @app_actor_id = @id_admin;
CALL tst_error('X15 No se emite NC contra un comprobante pendiente/no aceptado', "CALL sp_emitir_nota_credito(@c2, '01', 'Anulación', NULL, NULL, 0, @x, @y)", 45016);
CALL sp_registrar_respuesta_ose(@c2, 'rechazado', 'OSE-PRUEBA', NULL, NULL, '2800', 'Rechazo de prueba', NULL, NULL, NULL, '{}', '{"codigo":"2800"}');
CALL tst_error('X16 Tampoco contra un comprobante rechazado', "CALL sp_emitir_nota_credito(@c2, '01', 'Anulación', NULL, NULL, 0, @x, @y)", 45016);
SET @app_actor_id = NULL;
CALL sp_emitir_comprobante(@p2, @c2b, @ya2b);
CALL tst_ok('X17 Rechazado: se puede emitir un nuevo comprobante (nuevo correlativo)', @c2b <> @c2 AND @ya2b = 0
            AND (SELECT correlativo FROM comprobante WHERE id_comprobante = @c2b) = (SELECT correlativo FROM comprobante WHERE id_comprobante = @c2) + 1, NULL);

-- 6f. Expiración automática de pedidos sin pago
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p7, @n7, @t7);
SET @app_actor_id = NULL;
SET @wanka_ctx_interno = fn_token_interno();   -- solo root puede calcular la marca: simula el paso del tiempo
UPDATE pedido SET expira_en = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE id_pedido = @p7;
SET @wanka_ctx_interno = NULL;
CALL sp_expirar_pedidos_pendientes(@exp_n);
CALL tst_ok('X18 Evento de expiración cancela el pedido sin pago y libera la reserva',
            (SELECT estado = 'cancelado' AND motivo_cancelacion = 'Expirado por falta de pago' FROM pedido WHERE id_pedido = @p7)
            AND (SELECT estado FROM reserva_stock WHERE id_pedido = @p7) = 'liberada', CONCAT('cancelados: ', @exp_n));

-- =====================================================================
-- 7. RECHAZOS ESPERADOS (reglas de integridad)
-- =====================================================================
SET @app_actor_id = @cli2;
CALL tst_error('R01 Stock insuficiente', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_pol, ",\"cantidad\":5}]', 'recojo', NULL, 'total', 'boleta', 'DNI', '41234567', 'María Huamán', NULL, fn_hoy_lima() + INTERVAL 30 DAY, NULL, 'web', @x, @y, @z)"), 45001);
CALL tst_error('R02 Factura sin RUC', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'recojo', NULL, 'total', 'factura', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45015);
CALL tst_error('R03 Boleta mayor a S/ 700 sin documento', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_cha, ",\"cantidad\":4}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45015);
CALL tst_error('R04 Pedido vacío', "CALL sp_crear_pedido(@cli2, '[]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)", 45030);
CALL tst_error('R05 Personalización en un producto que no la admite', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_pol, ",\"cantidad\":1,\"personalizacion\":\"Mi nombre\"}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45006);
CALL tst_error('R06 Dirección de otro cliente', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'domicilio', @dir1, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45028);
CALL tst_error('R07 Un cliente no crea pedidos a nombre de otro', CONCAT("CALL sp_crear_pedido(@cli1, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45023);
CALL tst_error('R08 Otro cliente no agrega ítems a un pedido ajeno', "CALL sp_agregar_item(@p3, @var_cha, 1, NULL, @x)", 45023);
SET @app_actor_id = @cli3;
CALL tst_error('R09 Agregar ítems a un pedido confirmado (dueño)', "CALL sp_agregar_item(@p3, @var_cha, 1, NULL, @x)", 45007);
SET @app_actor_id = @id_admin;
CALL tst_error('R10 Cambio de estado directo por UPDATE bloqueado', "UPDATE pedido SET estado = 'entregado' WHERE id_pedido = @p3", 45023);
CALL tst_error('R11 monto_pagado no se fija a mano', "UPDATE pedido SET monto_pagado = 2160.00 WHERE id_pedido = @p3", 45023);
CALL tst_error('R12 El kardex no se escribe a mano', "INSERT INTO movimiento_stock (id_variante, tipo, cantidad, stock_actual_resultante, stock_reservado_resultante) VALUES (@var_pol, 'ingreso', 1, 1, 0)", 45023);
CALL tst_error('R13 El kardex no se modifica', "UPDATE movimiento_stock SET cantidad = 99 WHERE id_variante = @var_pol", 45004);
CALL tst_error('R14 DELETE físico de pedido bloqueado', "DELETE FROM pedido WHERE id_pedido = @p4", 45005);
CALL tst_error('R15 DELETE físico de pago bloqueado (aun con la marca, si no es la cuenta DBA)', "SET @wanka_autorizo_borrado = 'SI-AUTORIZO'", 0);
CALL tst_error('R15b ...', "DELETE FROM pago WHERE id_pago = @pg5", 45005);
SET @wanka_autorizo_borrado = NULL;
CALL tst_error('R16 La auditoría es inmutable', "UPDATE auditoria SET evento = 'x' ORDER BY id_auditoria LIMIT 1", 45004);
CALL tst_error('R17 Ni se borra', "DELETE FROM auditoria ORDER BY id_auditoria LIMIT 1", 45005);
CALL tst_error('R18 Usuario: no se borra, se inhabilita', "DELETE FROM usuario WHERE id_usuario = @cli_lim", 45005);
CALL tst_error('R19 Configuración: tope de 5 minutos para el código', "CALL sp_actualizar_configuracion('codigo_verificacion_minutos', '10')", 45020);
CALL tst_error('R20 Configuración: tipo inválido', "CALL sp_actualizar_configuracion('adelanto_permitido_en', 'algunos')", 45020);
CALL tst_error('R21 Reseña de un producto no comprado', "CALL sp_registrar_resena(@cli2, @prod_pol, @p2, 5, NULL, NULL, @x)", 45026);
CALL tst_error('R22 Último administrador no se inhabilita a sí mismo', "CALL sp_inhabilitar_usuario(@id_admin, 'prueba')", 45023);
CALL sp_actualizar_configuracion('adelanto_permitido_en', 'solo_mayor');
SET @app_actor_id = @cli2;
CALL tst_error('R23 Con "solo_mayor", un pedido menor no puede pagar con adelanto',
               CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'recojo', NULL, 'adelanto', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45035);
SET @app_actor_id = @id_admin;
CALL sp_actualizar_configuracion('adelanto_permitido_en', 'todos');
CALL tst_ok('R24 Cambios de configuración auditados', (SELECT COUNT(*) FROM auditoria WHERE evento = 'configuracion_cambiada') = 2, NULL);

-- Producto archivado: no se vende pero se conserva
CALL sp_inhabilitar_producto(@prod_cha, 'Fin de temporada');
SET @app_actor_id = @cli2;
CALL tst_error('R25 Producto archivado no se vende', CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45008);
CALL tst_ok('R26 El producto archivado sigue existiendo con su historial', (SELECT estado FROM producto WHERE id_producto = @prod_cha) = 'archivado'
            AND (SELECT COUNT(*) FROM item_pedido WHERE id_producto = @prod_cha) > 0, NULL);

-- Contacto: máximo 3 por hora por IP
SET @app_actor_id = NULL;
SET @app_ip = '200.48.10.20';
CALL sp_registrar_mensaje_contacto(NULL, 'Pedro', 'pedro@correo.pe', NULL, 'producto', NULL, 'Consulta sobre tallas disponibles', 1, '1.0', @m1, @tk1);
CALL sp_registrar_mensaje_contacto(NULL, 'Pedro', 'pedro@correo.pe', NULL, 'producto', NULL, 'Consulta sobre colores disponibles', 1, '1.0', @m2, @tk2);
CALL sp_registrar_mensaje_contacto(NULL, 'Pedro', 'pedro@correo.pe', NULL, 'producto', NULL, 'Consulta sobre envíos a Lima', 1, '1.0', @m3, @tk3);
CALL tst_ok('K01 Tickets correlativos por año sin saltos', @tk1 LIKE 'TK-%-000001' AND @tk3 LIKE 'TK-%-000003', CONCAT_WS(',', @tk1, @tk3));
CALL tst_error('K02 El 4.º mensaje en una hora desde la misma IP se rechaza',
               "CALL sp_registrar_mensaje_contacto(NULL, 'Pedro', 'pedro@correo.pe', NULL, 'producto', NULL, 'Cuarto mensaje de prueba', 1, '1.0', @x, @y)", 45010);
CALL sp_registrar_reclamo(NULL, 'Carla', 'Rojas', 'DNI', '40000001', 'Av. Giráldez 100, Huancayo', 'carla@correo.pe', '964111222', 0, NULL,
                          'producto', 250.00, 'Pollera talla M', 'reclamo', 'El bordado llegó descosido', 'Cambio de la prenda', NULL, 1, @rc1, @rcn1, @rcf1);
CALL tst_ok('K03 Libro de Reclamaciones: número LR y fecha límite según configuración', @rcn1 LIKE 'LR-%' AND @rcf1 = fn_hoy_lima() + INTERVAL 30 DAY, CONCAT_WS(',', @rcn1, @rcf1));
CALL tst_error('K04 La hoja de reclamación no se modifica', "UPDATE reclamo SET detalle = 'otro' WHERE id_reclamo = @rc1", 45004);

-- =====================================================================
-- 7b. OTROS MÓDULOS: 2FA, sesiones, insumos, edición de pedidos, complementario, ARCO, colas, tareas programadas
-- =====================================================================
SET @app_actor_id = @id_admin;
CALL sp_configurar_2fa(@id_admin, 'totp', CAST('secreto-cifrado-por-la-app' AS BINARY));
CALL sp_confirmar_2fa(@id_admin, 1000);
CALL tst_ok('O01 2FA del administrador activo (sale de v_administradores_sin_2fa)', (SELECT COUNT(*) FROM v_administradores_sin_2fa) = 0, NULL);
SET @app_actor_id = NULL;
CALL sp_registrar_segundo_factor(@id_admin, 1001, 1, 'pruebas', @f1);
CALL sp_registrar_segundo_factor(@id_admin, 1001, 1, 'pruebas', @f2);
CALL tst_ok('O02 TOTP: el mismo paso no se reutiliza (anti-replay)', @f1 = 'ok' AND @f2 = 'segundo_factor_fallido', CONCAT_WS(',', @f1, @f2));
SET @app_actor_id = @id_admin;
CALL tst_error('O03 El administrador no puede desactivar su propio 2FA', "CALL sp_desactivar_2fa(@id_admin)", 45023);
DROP TEMPORARY TABLE IF EXISTS tst_codigos;
CALL sp_generar_codigos_respaldo_2fa(@id_admin, @pepper, 10);
CALL tst_ok('O04 Códigos de respaldo: se guardan 10 hashes', (SELECT COUNT(*) FROM codigo_respaldo_2fa WHERE id_usuario = @id_admin AND usado_en IS NULL AND invalidado_en IS NULL) = 10, NULL);
SET @app_actor_id = @cli2;
CALL sp_abrir_sesion(@cli2, SHA2('clave-de-sesion-1', 256), 'pruebas', 60, @ses1);
SET @app_actor_id = @id_admin;
CALL sp_inhabilitar_usuario(@cli_lim, 'Cuenta de prueba');
CALL tst_ok('O05 Inhabilitar usuario: estado y auditoría (no se borra)', (SELECT estado FROM usuario WHERE id_usuario = @cli_lim) = 'inhabilitado'
            AND (SELECT COUNT(*) FROM auditoria WHERE evento = 'usuario_inhabilitado' AND id_entidad = @cli_lim) = 1, NULL);
CALL sp_reactivar_usuario(@cli_lim);
CALL tst_ok('O06 Reactivar usuario (sin correo verificado vuelve a pendiente)', (SELECT estado FROM usuario WHERE id_usuario = @cli_lim) = 'pendiente_verificacion', NULL);
SET @app_actor_id = @cli2;
CALL sp_cerrar_sesiones_usuario(@cli2);
CALL tst_ok('O07 Cierre remoto de sesiones', (SELECT cerrada_en IS NOT NULL AND motivo_cierre = 'revocada' FROM sesion WHERE id_sesion = @ses1), NULL);

-- Insumos y receta
SET @app_actor_id = @id_admin;
INSERT INTO insumo (nombre, tipo, unidad, stock_minimo) VALUES ('Hilo dorado', 'hilo', 'cono', 2);
SET @ins1 = LAST_INSERT_ID();
CALL sp_ajustar_insumo(@ins1, 'ingreso', 5, 'Compra', NULL, @si);
CALL tst_error('O08 Consumo mayor al stock de insumo', "CALL sp_ajustar_insumo(@ins1, 'consumo', 9, 'Prueba', NULL, @x)", 45001);
CALL sp_ajustar_insumo(@ins1, 'consumo', 4, 'Bordado', NULL, @si2);
CALL tst_ok('O09 Insumo: kardex y alerta de stock mínimo', @si2 = 1.000 AND (SELECT COUNT(*) FROM v_insumos_stock_bajo WHERE id_insumo = @ins1) = 1
            AND (SELECT COUNT(*) FROM notificacion WHERE tipo = 'insumo_bajo') >= 1, NULL);
CALL tst_error('O10 Stock de insumo no se edita a mano', "UPDATE insumo SET stock_actual = 50 WHERE id_insumo = @ins1", 45023);

-- Edición de un pedido pendiente: agregar y retirar líneas (borrado lógico)
CALL sp_reactivar_producto(@prod_cha);
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p8, @n8, @t8);
CALL sp_agregar_item(@p8, @var_cha, 1, 'Nombre: María', @t8b);
SET @it_p8 = (SELECT id_item_pedido FROM item_pedido WHERE id_pedido = @p8 AND id_variante = @var_pol);
CALL sp_quitar_item(@p8, @it_p8, @t8c);
CALL tst_ok('O11 Agregar y retirar líneas recalcula el total y libera la reserva',
            @t8b = 430.00 AND @t8c = 180.00 AND (SELECT estado FROM item_pedido WHERE id_item_pedido = @it_p8) = 'retirado'
            AND (SELECT estado FROM reserva_stock WHERE id_item_pedido = @it_p8) = 'liberada', CONCAT_WS(',', @t8b, @t8c));
CALL tst_error('O12 No se quita la última línea (se cancela el pedido)', CONCAT("CALL sp_quitar_item(@p8, ", (SELECT id_item_pedido FROM item_pedido WHERE id_pedido = @p8 AND estado = 'vigente'), ", @x)"), 45030);
CALL tst_error('O13 Los ítems no se borran físicamente', "DELETE FROM item_pedido WHERE id_pedido = @p8", 45005);

-- Pedido complementario (HU-29) del pedido mayorista confirmado
SET @app_actor_id = @cli3;
CALL sp_crear_pedido_complementario(@p3, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1,"personalizacion":"Delegado"}]'), 'total', NULL, NULL, @p9, @n9, @t9);
CALL tst_ok('O14 Complementario: enlazado al original y hereda entrega y comprobante',
            (SELECT id_pedido_origen = @p3 AND comprobante_solicitado = 'factura' AND facturacion_num_doc = '20123456786' AND tipo_entrega = 'recojo' FROM pedido WHERE id_pedido = @p9), @n9);

-- ARCO, cambio de correo, caché DNI/RUC, bitácora de APIs, cola de correos
SET @app_actor_id = @cli2;
CALL sp_registrar_solicitud_arco(@cli2, 'María Huamán', 'DNI', '41234567', 'maria.huaman@correo.pe', 'acceso', 'Quiero saber qué datos personales guardan', @arco1, @arcon1, @arcof1);
CALL tst_ok('O15 Solicitud ARCO con número y plazo en días hábiles', @arcon1 LIKE 'ARCO-%' AND @arcof1 = fn_sumar_dias_habiles(fn_hoy_lima(), 20), CONCAT_WS(',', @arcon1, @arcof1));
CALL tst_error('O16 Cambiar correo sin verificar el nuevo', "CALL sp_cambiar_correo(@cli2, 'maria.nuevo@correo.pe')", 45011);
CALL sp_generar_codigo_verificacion(@cli2, 'maria.nuevo@correo.pe', 'cambiar_correo', @pepper, @cc, @ce, @ci);
CALL sp_verificar_codigo('maria.nuevo@correo.pe', 'cambiar_correo', @cc, @pepper, @cr, @crest, @cu);
CALL sp_cambiar_correo(@cli2, 'maria.nuevo@correo.pe');
CALL tst_ok('O17 Cambio de correo verificado y aviso al correo anterior', (SELECT correo FROM usuario WHERE id_usuario = @cli2) = 'maria.nuevo@correo.pe'
            AND (SELECT COUNT(*) FROM cola_correo WHERE plantilla = 'correo_cambiado' AND destinatario = 'maria.huaman@correo.pe') = 1, NULL);
CALL tst_error('O18 El correo no se cambia por UPDATE directo', "UPDATE usuario SET correo = 'hack@correo.pe' WHERE id_usuario = @cli2", 45023);
CALL sp_guardar_consulta_documento('RUC', '20615339386', 'BORDADOS WANKA S.A.C.', 'ACTIVO', 'HABIDO', 'Sapallanga, Huancayo', 'proveedor-prueba', 1);
CALL sp_guardar_consulta_documento('DNI', '41234567', 'MARIA HUAMAN', NULL, NULL, 'Domicilio que no debe guardarse', 'proveedor-prueba', 1);
CALL tst_ok('O19 Caché DNI/RUC: para DNI no se guarda domicilio (minimización)', (SELECT domicilio_fiscal FROM consulta_documento WHERE numero = '41234567') IS NULL
            AND (SELECT domicilio_fiscal FROM consulta_documento WHERE numero = '20615339386') IS NOT NULL, NULL);
CALL tst_error('O20 Bitácora de API rechaza tokens en la URL', "CALL sp_registrar_log_api('ose', '/api/v1/emitir?token=abc123', 'POST', 200, 120, 1, NULL, NULL, 'corr-1', NULL, NULL, NULL, NULL, @x)", 45006);
CALL sp_registrar_log_api('reniec', '/api/dni/41234567', 'GET', 200, 85, 1, '{"dni":"41234567"}', '{"nombre":"M*** H***"}', 'corr-2', NULL, NULL, NULL, NULL, @log1);
CALL tst_ok('O21 Bitácora de API registrada (solo inserción)', @log1 IS NOT NULL, NULL);
SET @app_actor_id = NULL;
DROP TEMPORARY TABLE IF EXISTS tst_tmp;
CALL sp_tomar_correos_pendientes('worker-correo', 3);
SET @correo1 = (SELECT MIN(id_correo) FROM cola_correo WHERE estado = 'procesando');
CALL sp_marcar_correo(@correo1, 1, NULL, 'msg-001');
SET @correo2 = (SELECT MIN(id_correo) FROM cola_correo WHERE estado = 'procesando');
CALL sp_marcar_correo(@correo2, 0, 'SMTP 421 temporalmente no disponible', NULL);
CALL tst_ok('O22 Cola de correo: enviado y reintento con backoff',
            (SELECT estado FROM cola_correo WHERE id_correo = @correo1) = 'enviado'
            AND (SELECT estado = 'error' AND proximo_intento_en > UTC_TIMESTAMP(3) FROM cola_correo WHERE id_correo = @correo2), NULL);

-- Tareas programadas (lo que corren los eventos)
CALL tst_error('O23 sp_mantenimiento_diario corre sin errores', "CALL sp_mantenimiento_diario()", 0);
CALL tst_error('O24 sp_vencer_cotizaciones corre sin errores', "CALL sp_vencer_cotizaciones(@x)", 0);
CALL tst_error('O25 sp_alertar_vencimientos corre sin errores', "CALL sp_alertar_vencimientos()", 0);
CALL tst_error('O26 sp_expirar_codigos_verificacion corre sin errores', "CALL sp_expirar_codigos_verificacion(@x)", 0);
CALL tst_ok('O27 El mantenimiento no purga intentos de acceso recientes', (SELECT COUNT(*) FROM intento_acceso WHERE id_usuario = @cli1) = 6, NULL);

-- =====================================================================
-- 7c. CORRECCIONES DE LA REVISIÓN (regresiones)
-- =====================================================================
-- Devolución: saldo a favor del cliente y sin falsas deudas por el envío
CALL tst_ok('Q01 Tras devolver todo: monto_devuelto = 500 y saldo a favor del cliente = 500 mientras el reembolso está en curso',
            (SELECT monto_devuelto = 500.00 AND estado_pago = 'pagado' FROM pedido WHERE id_pedido = @p1)
            AND (SELECT saldo_a_favor_cliente FROM v_pedidos_estado WHERE id_pedido = @p1) = 500.00, NULL);
CALL tst_ok('Q02 v_pagos_por_reembolsar no inventa deuda por el envío no reembolsado', (SELECT COUNT(*) FROM v_pagos_por_reembolsar WHERE id_pedido = @p1) = 0, NULL);
SET @app_actor_id = @id_admin;
SET @rbq1 = (SELECT MIN(id_reembolso) FROM reembolso WHERE id_pedido = @p1);
SET @rbq2 = (SELECT MAX(id_reembolso) FROM reembolso WHERE id_pedido = @p1);
CALL sp_completar_reembolso(@rbq1, 1, 'MP-REF-1', NULL);
CALL sp_completar_reembolso(@rbq2, 0, NULL, 'Cuenta del cliente cerrada');
CALL tst_ok('Q03 Un reembolso de devolución que falla vuelve a figurar como pendiente',
            (SELECT pendiente_de_reembolsar FROM v_pagos_por_reembolsar WHERE id_pedido = @p1 AND motivo = 'devolucion') = 250.00, NULL);
CALL tst_ok('Q04 Cuadres después de reembolsar (v_inconsistencias)', (SELECT COUNT(*) FROM v_inconsistencias) = 0,
            (SELECT GROUP_CONCAT(detalle SEPARATOR ' | ') FROM v_inconsistencias));

-- Usuario: columnas sensibles e IDOR
SET @app_actor_id = @cli2;
CALL tst_error('Q05 Un cliente no toca su bloqueo ni sus intentos por UPDATE directo', "UPDATE usuario SET bloqueado_hasta = UTC_TIMESTAMP(3) + INTERVAL 1 DAY WHERE id_usuario = @cli2", 45023);
SET @app_actor_id = @cli_lim;
CALL tst_error('Q06 Un cliente no marca su correo como verificado ni se activa a mano', "UPDATE usuario SET estado = 'activo', correo_verificado_en = UTC_TIMESTAMP(3) WHERE id_usuario = @cli_lim", 45023);
SET @app_actor_id = @cli2;
CALL tst_error('Q07 Un cliente no modifica los datos de otro (IDOR)', "UPDATE usuario SET nombres = 'Hackeado' WHERE id_usuario = @cli1", 45023);
CALL tst_error('Q08 Un cliente no crea direcciones para otro (IDOR)',
               "INSERT INTO direccion (id_usuario, alias, nombre_receptor, telefono, direccion, distrito, provincia, departamento, id_zona) VALUES (@cli1, 'X', 'Otra Persona', '987654321', 'Jr. Falso 1', 'Huancayo', 'Huancayo', 'Junín', 1)", 45023);
CALL tst_error('Q09 Su propio perfil sí lo edita', "UPDATE usuario SET nombres = 'María José' WHERE id_usuario = @cli2", 0);

-- Webhooks: método, monto y firma
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pq, @nq, @tq);
CALL sp_registrar_pago(@pq, 'yape', 180.00, 'idem-pedidoq-intento-0001', 'OP-Q-0001', NULL, NULL, NULL, NULL, NULL, @pgq, @e, @d);
SET @app_actor_id = NULL;
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-q1', 'payment.updated', '{"id":"q1"}', 1, @evq, @pr);
CALL sp_procesar_pago_pasarela(@evq, 'mercadopago', 'idem-pedidoq-intento-0001', 'MP-Q1', 'aprobado', 180.00, NULL, NULL, NULL, NULL, @rq);
CALL tst_ok('Q10 Un webhook de pasarela no confirma un Yape por validar', @rq = 'metodo_distinto' AND (SELECT estado FROM pago WHERE id_pago = @pgq) = 'en_revision', @rq);
CALL tst_error('Q11 Webhook aprobado sin monto se rechaza', "CALL sp_procesar_pago_pasarela(@evq, 'mercadopago', 'idem-pedidoq-intento-0001', 'MP-Q1', 'aprobado', NULL, NULL, NULL, NULL, NULL, @r)", 45017);
CALL tst_error('Q12 Webhook de otro proveedor se rechaza', "CALL sp_procesar_pago_pasarela(@evq, 'paypal', 'idem-pedidoq-intento-0001', 'PP-Q1', 'aprobado', 180.00, NULL, NULL, NULL, NULL, @r)", 45017);
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-q2', 'payment.updated', '{"falso":true}', 0, @evq2, @pr);
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-q2', 'payment.updated', '{"id":"q2"}', 1, @evq2b, @pr2);
CALL tst_ok('Q13 Un evento falso (firma inválida) no bloquea al verdadero con el mismo id',
            @evq2 = @evq2b AND (SELECT firma_valida = 1 AND JSON_EXTRACT(payload, '$.id') = 'q2' FROM evento_pasarela WHERE id_evento = @evq2), NULL);
SET @app_actor_id = @id_admin;
SET @pg_pasarela = (SELECT MIN(id_pago) FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE m.tipo = 'pasarela' AND p.estado = 'pendiente');
CALL tst_error('Q14 Un pago de pasarela no se rechaza a mano', "CALL sp_rechazar_pago(COALESCE(@pg_pasarela, @pg1), 'Prueba de rechazo')", 45023);

-- Pedidos, carrito y cotizaciones
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pq2, @n, @t);
CALL tst_error('Q15 Variante repetida en el pedido: mensaje claro (no error 1062)', "CALL sp_agregar_item(@pq2, @var_cha, 1, NULL, @x)", 45006);
CALL tst_error('Q16 El carrito no acepta personalización si el producto no la admite', "CALL sp_agregar_item_carrito(@cli2, @var_pol, 1, 'Mi nombre', @x)", 45006);
CALL tst_error('Q17 Cotización al por mayor sin fecha de entrega', "CALL sp_solicitar_cotizacion(@cli2, 'mayor', 'Necesito veinte polleras para la comparsa', '[{\"descripcion\":\"Pollera\",\"cantidad\":20}]', NULL, NULL, @x, @y)", 45009);
CALL tst_error('Q18 ARCO a nombre de otro usuario', "CALL sp_registrar_solicitud_arco(@cli1, 'Rosa Quispe', 'DNI', '45678912', 'rosa.quispe@correo.pe', 'acceso', 'Quiero ver los datos de otra persona', @x, @y, @z)", 45023);
CALL tst_error('Q19 Reclamo vinculado a un pedido ajeno', "CALL sp_registrar_reclamo(@cli2, 'María', 'Huamán', 'DNI', '41234567', 'Av. Real 1', 'maria@correo.pe', '964000111', 0, NULL, 'producto', 10, 'x', 'reclamo', 'detalle', 'pedido', @p1, 1, @x, @y, @z)", 45006);
SET @wanka_ctx_interno = fn_token_interno();   -- solo root puede calcular la marca: simula el paso del tiempo
UPDATE pedido SET expira_en = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE id_pedido = @pq;
SET @wanka_ctx_interno = NULL;
CALL tst_error('Q20 No se registra un pago en un pedido vencido', "CALL sp_registrar_pago(@pq, 'plin', 180.00, 'idem-pedidoq-intento-0002', 'OP-Q-0002', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45007);
SET @app_actor_id = @id_admin;
CALL tst_error('Q21 Efectivo exige número de recibo', "CALL sp_registrar_pago(@p3, 'efectivo', 100.00, 'idem-pedido3-efectivo-0001', NULL, NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45017);
CALL tst_error('Q22 La zona de envío de un pedido no se cambia a mano', "UPDATE pedido SET id_zona = 2 WHERE id_pedido = @p3", 45023);
INSERT INTO categoria (nombre, slug, id_categoria_padre) VALUES ('Subpolleras', 'subpolleras', @cat_pol);
SET @subcat = LAST_INSERT_ID();
CALL tst_error('Q23 Ciclo en la jerarquía de categorías', "UPDATE categoria SET id_categoria_padre = @subcat WHERE id_categoria = @cat_pol", 45006);
INSERT INTO categoria (nombre, slug) VALUES ('Temporal', 'temporal');
SET @cat_tmp = LAST_INSERT_ID();
CALL sp_inhabilitar_categoria(@cat_tmp, 'Prueba');
CALL tst_error('Q24 No se crea un producto en una categoría inhabilitada', "INSERT INTO producto (id_categoria, nombre, slug, precio_base) VALUES (@cat_tmp, 'Producto X', 'producto-x', 10)", 45032);

-- Límite por IP en el inicio de sesión
DELIMITER $$
DROP PROCEDURE IF EXISTS tst_fallar_login $$
CREATE PROCEDURE tst_fallar_login(IN p_veces INT)
BEGIN
  DECLARE i INT DEFAULT 0;
  WHILE i < p_veces DO
    CALL sp_registrar_intento_acceso(CONCAT('noexiste', i, '@correo.pe'), 0, 'pruebas', @rl, @u, @b, @f);
    SET i = i + 1;
  END WHILE;
END $$
DELIMITER ;
SET @app_actor_id = NULL;
SET @app_ip = '203.0.113.77';
CALL tst_fallar_login(20);
CALL sp_registrar_intento_acceso('maria.nuevo@correo.pe', 1, 'pruebas', @rip, @u, @b, @f);
CALL tst_ok('Q25 Veinte fallos desde una IP en 15 minutos la bloquean (aun con la contraseña correcta)', @rip = 'ip_bloqueada', @rip);
SET @app_ip = '198.51.100.10';
CALL sp_registrar_intento_acceso('maria.nuevo@correo.pe', 1, 'pruebas', @rip2, @u, @b, @f);
CALL tst_ok('Q26 Desde otra IP la misma cuenta entra', @rip2 = 'ok', @rip2);

-- Gracia de expiración para cobros de pasarela en curso
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pg_gr, @n, @t);
CALL sp_registrar_pago(@pg_gr, 'mercadopago', 180.00, 'idem-pedido-gracia-0001', NULL, NULL, NULL, NULL, NULL, NULL, @x, @y, @z);
SET @app_actor_id = NULL;
SET @wanka_ctx_interno = fn_token_interno();   -- solo root puede calcular la marca: simula el paso del tiempo
UPDATE pedido SET expira_en = UTC_TIMESTAMP(3) - INTERVAL 1 MINUTE WHERE id_pedido = @pg_gr;
SET @wanka_ctx_interno = NULL;
CALL sp_expirar_pedidos_pendientes(@nexp);
CALL tst_ok('Q27 No expira un pedido con un cobro de pasarela recién iniciado', (SELECT estado FROM pedido WHERE id_pedido = @pg_gr) = 'pendiente_pago', NULL);

-- Notas de crédito pendientes, reintento de emisión y anonimización
SET @app_actor_id = @id_admin;
CALL tst_ok('Q28 Las devoluciones con NC no aparecen como notas de crédito pendientes', (SELECT COUNT(*) FROM v_notas_credito_pendientes WHERE id_pedido = @p1) = 0, NULL);
CALL tst_error('Q29 No se reintenta la emisión de un comprobante rechazado', "CALL sp_reintentar_emision(@c2)", 45004);
CALL sp_anonimizar_usuario(@cli_lim, NULL);
CALL tst_ok('Q30 Anonimización (ARCO): sin datos personales y sin borrar filas',
            (SELECT correo LIKE 'anonimizado+%@bordadoswanka.invalid' AND nombres = 'Usuario' AND numero_documento IS NULL AND celular IS NULL
                    AND estado = 'inhabilitado' FROM usuario WHERE id_usuario = @cli_lim), NULL);
CALL tst_error('Q31 No se anonimiza a un cliente con pedidos en curso', "CALL sp_anonimizar_usuario(@cli3, NULL)", 45032);

-- =====================================================================
-- 7d. SEGUNDA REVISIÓN: pedidos (T01-T24), pagos y comprobantes (T25-T45), acceso y permisos (T46-T79), entrega sin cierre (T80-T81)
-- =====================================================================
SET @app_ip = '192.0.2.10';
SET @app_actor_id = @id_admin;
-- Contexto interno: ya no basta con fijar una variable de sesión
SET @wanka_ctx_interno = 1;
CALL tst_error('T01 La marca de contexto interno no se falsifica con @wanka_ctx_interno = 1', "UPDATE pedido SET monto_pagado = total WHERE id_pedido = @p3", 45023);
SET @wanka_ctx_interno = SHA2('adivinanza', 256);
CALL tst_error('T02 ...ni con un hash inventado', "UPDATE pedido SET estado_pago = 'pagado' WHERE id_pedido = @p3", 45023);
CALL tst_ok('T03 rol_app_admin: ningún spi_* interno, ni fn_token_interno, ni el secreto (ninguna cuenta de la app lo lee)',
            (SELECT COUNT(*) FROM mysql.procs_priv WHERE Db = DATABASE() AND User IN ('rol_app_admin','rol_app_tienda','rol_reportes')
              AND (Routine_name LIKE 'spi\_%' OR Routine_name IN ('fn_token_interno','sp_redactar_log_api'))) = 0
            AND (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'secreto_interno'
                  AND GRANTEE IN ("'rol_app_admin'@'%'", "'rol_app_tienda'@'%'", "'rol_reportes'@'%'")) = 0, NULL);

-- Cotización con la misma variante en dos líneas y envío no cotizado
CALL sp_ajustar_stock(@var_pol, 'ingreso', 20, 'Lote para pruebas de la segunda revisión', @st);
SET @app_actor_id = @cli2;
INSERT INTO direccion (id_usuario, alias, nombre_receptor, telefono, direccion, distrito, provincia, departamento, id_zona)
VALUES (@cli2, 'Casa', 'María Huamán', '964111222', 'Av. Giráldez 456', 'Huancayo', 'Huancayo', 'Junín', 1);
SET @dir2 = LAST_INSERT_ID();
SET @res_antes = (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol);
CALL sp_solicitar_cotizacion(@cli2, 'personalizado', 'Dos polleras con bordados distintos para el grupo',
     CONCAT('[{"id_variante":', @var_pol, ',"cantidad":1,"personalizacion":"Grupo A"},{"id_variante":', @var_pol, ',"cantidad":1,"personalizacion":"Grupo B"}]'),
     NULL, NULL, @ctr, @ctrn);
SET @app_actor_id = @id_admin;
SET @it_a = (SELECT MIN(id_item_cotizacion) FROM item_cotizacion WHERE id_cotizacion = @ctr);
SET @it_b = (SELECT MAX(id_item_cotizacion) FROM item_cotizacion WHERE id_cotizacion = @ctr);
CALL sp_cotizar(@ctr, CONCAT('[{"id_item_cotizacion":', @it_a, ',"precio_unitario":260.00},{"id_item_cotizacion":', @it_b, ',"precio_unitario":270.00}]'),
                NULL, 50, 15, 'Cotización por grupo', NULL, @ctr_total);
SET @app_actor_id = @cli2;
CALL sp_aceptar_cotizacion(@ctr, 'domicilio', @dir2, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, @pctr, @nctr, @tctr);
CALL tst_ok('T04 Cotización con la misma variante en dos líneas se convierte (una reserva por línea)',
            (SELECT COUNT(*) FROM item_pedido WHERE id_pedido = @pctr AND id_variante = @var_pol AND estado = 'vigente') = 2
            AND (SELECT COUNT(*) FROM reserva_stock WHERE id_pedido = @pctr AND estado = 'activa') = 2, NULL);
CALL tst_ok('T05 Envío no cotizado (NULL): se cobra la tarifa de la zona elegida, no sale gratis',
            (SELECT costo_envio FROM pedido WHERE id_pedido = @pctr) = 5.00 AND @tctr = 535.00, @tctr);
SET @app_actor_id = @id_admin;
CALL tst_error('T06 Tampoco el administrador cancela con sp_cambiar_estado_pedido (va por sp_cancelar_pedido)', "CALL sp_cambiar_estado_pedido(@pctr, 'cancelado', 'x')", 45002);
CALL sp_cancelar_pedido(@pctr, 'Prueba de liberación de reservas');
CALL tst_ok('T07 Al cancelar se liberan las dos reservas de la misma variante',
            (SELECT COUNT(*) FROM reserva_stock WHERE id_pedido = @pctr AND estado = 'liberada') = 2
            AND (SELECT stock_reservado FROM variante_producto WHERE id_variante = @var_pol) = @res_antes, NULL);

-- Columnas del ciclo de vida del pedido y del envío
CALL tst_error('T08 El plazo de reserva no se extiende a mano', "UPDATE pedido SET expira_en = '2099-12-31' WHERE id_pedido = @pq2", 45023);
CALL tst_error('T09 La fecha de entrega solicitada no se cambia a mano (saltaría la anticipación)', "UPDATE pedido SET fecha_entrega_solicitada = CURDATE() WHERE id_pedido = @p3", 45023);
CALL tst_error('T10 El estado del envío no se cambia por UPDATE directo', "UPDATE envio SET estado = 'entregado', entregado_en = UTC_TIMESTAMP(3) WHERE id_envio = @env1", 45023);
CALL tst_error('T11 La fecha estimada sí se edita directamente', "UPDATE pedido SET fecha_entrega_estimada = CURDATE() + INTERVAL 3 DAY WHERE id_pedido = @p3", 0);

-- Tipo de venta con el mismo criterio al crear y al recalcular
INSERT INTO producto (id_categoria, nombre, slug, descripcion, precio_base, tipo_fabricacion, estado)
VALUES (@cat_pol, 'Faja Tejida', 'faja-tejida', 'Faja tejida a telar con diseños del valle', 200.00, 'stock', 'activo');
SET @prod_faja = LAST_INSERT_ID();
INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES (@prod_faja, 'FAJ-U', 'U', 'Multicolor');
SET @var_faja = LAST_INSERT_ID();
INSERT INTO precio_volumen (id_producto, cantidad_minima, precio_unitario) VALUES (@prod_faja, 6, 220.00);
CALL sp_ajustar_stock(@var_faja, 'ingreso', 30, 'Lote inicial', @st);
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_faja, ',"cantidad":6}]'), 'recojo', NULL, 'total', 'boleta', 'DNI', '41234567', 'María Huamán',
                     NULL, NULL, NULL, 'web', @pfj, @nfj, @tfj);
CALL tst_ok('T12 Tramo de volumen más caro que la lista: se cobra la lista y la venta es al por menor (sin exigir 10 días)',
            (SELECT tipo_venta = 'menor' AND numero NOT LIKE 'BW-MAY-%' FROM pedido WHERE id_pedido = @pfj) AND @tfj = 1200.00, CONCAT(@nfj, ' ', @tfj));
CALL sp_cancelar_pedido(@pfj, 'Prueba terminada');

-- Producción e insumos
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pch, @n, @t);
SET @app_actor_id = @id_admin;
CALL tst_error('T13 Los insumos no se descuentan en un pedido sin confirmar', "CALL sp_consumir_insumos_pedido(@pch)", 45007);
SET @app_actor_id = @cli2;
CALL sp_registrar_pago(@pch, 'yape', 180.00, 'idem-pedido-ch-000000001', 'OP-CH-0001', NULL, NULL, NULL, NULL, NULL, @pgch, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pgch, @e);
CALL tst_error('T14 Un pedido con productos a pedido no salta la producción', "CALL sp_cambiar_estado_pedido(@pch, 'en_preparacion', NULL)", 45002);
CALL sp_cambiar_estado_pedido(@pch, 'en_produccion', 'Bordando');
SET @app_actor_id = @cli2;
CALL tst_error('T15 Pedido complementario con fecha de entrega pasada',
               CONCAT("CALL sp_crear_pedido_complementario(@pch, '[{\"id_variante\":", @var_cha, ",\"cantidad\":1}]', 'total', NULL, '2020-01-01', @x, @y, @z)"), 45006);

-- Envíos: idempotencia y errores propios
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_faja, ',"cantidad":1}]'), 'domicilio', @dir2, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pdm, @n, @tdm);
CALL sp_registrar_pago(@pdm, 'plin', @tdm, 'idem-pedido-dm-000000001', 'OP-DM-0001', NULL, NULL, NULL, NULL, NULL, @pgdm, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pgdm, @e);
CALL sp_cambiar_estado_pedido(@pdm, 'en_preparacion', NULL);
CALL sp_cambiar_estado_pedido(@pdm, 'listo', NULL);
CALL sp_registrar_envio(@pdm, 1, 'G-R16', NULL, NULL, NULL, @envA);
CALL sp_registrar_envio(@pdm, 1, 'G-R16', NULL, NULL, NULL, @envB);   -- mismo clic repetido, misma guía
CALL tst_ok('T16 Despachar dos veces (doble clic) devuelve el mismo envío', @envA = @envB AND (SELECT COUNT(*) FROM envio WHERE id_pedido = @pdm) = 1, NULL);
CALL tst_error('T17 Guía repetida: error propio (no 1062)', "CALL sp_registrar_envio(@p1, 1, 'G-0001', NULL, NULL, NULL, @x)", 45028);
CALL tst_error('T18 Estado de seguimiento inexistente: error propio (no 1265)', "CALL sp_registrar_seguimiento_envio(@envA, 'perdido', NULL, NULL, NULL, 'admin', NULL, @x)", 45028);
SET @app_actor_id = NULL;
CALL tst_error('T19 Sin actor y sin origen no se registra seguimiento (antes NULL saltaba el permiso)', "CALL sp_registrar_seguimiento_envio(@envA, 'en_transito', NULL, NULL, NULL, NULL, NULL, @x)", 45023);

-- Validaciones de datos de entrada
SET @app_actor_id = @cli2;
CALL sp_solicitar_cotizacion(@cli2, 'personalizado', 'Chaleco con logo bordado para delegados', CONCAT('[{"id_variante":', @var_cha, ',"cantidad":2}]'), NULL, NULL, @ct9, @ct9n);
SET @app_actor_id = @id_admin;
SET @it9 = (SELECT id_item_cotizacion FROM item_cotizacion WHERE id_cotizacion = @ct9);
CALL tst_error('T20 Cotización con adelanto 0 %: error propio', CONCAT("CALL sp_cotizar(@ct9, '[{\"id_item_cotizacion\":", @it9, ",\"precio_unitario\":190}]', NULL, 0, 15, NULL, NULL, @x)"), 45018);
CALL tst_error('T21 Cotización con vigencia negativa', CONCAT("CALL sp_cotizar(@ct9, '[{\"id_item_cotizacion\":", @it9, ",\"precio_unitario\":190}]', NULL, 50, -3, NULL, NULL, @x)"), 45018);
CALL tst_error('T22 Devolución con una línea sin cantidad: error propio (no 1048)', "CALL sp_devolver_pedido(@pdm, '[{\"id_item_pedido\":1}]', 'Prueba de validación', 0, @x, @y, @z)", 45019);
CALL tst_error('T23 Devolución con p_items que no es un arreglo', "CALL sp_devolver_pedido(@pdm, '{\"id_item_pedido\":1}', 'Prueba de validación', 0, @x, @y, @z)", 45019);
SET @app_actor_id = @cli2;
CALL tst_error('T24 Cantidad no entera (1.5) se rechaza en vez de redondearse',
               CONCAT("CALL sp_crear_pedido(@cli2, '[{\"id_variante\":", @var_faja, ",\"cantidad\":1.5}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @x, @y, @z)"), 45006);

-- Pagos: excedente manual y cobros en proceso
SET @app_actor_id = @id_admin;
CALL sp_actualizar_configuracion('minutos_gracia_pago_pasarela', '0');
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pb3, @n, @t);
CALL sp_registrar_pago(@pb3, 'mercadopago', 180.00, 'idem-b3-mp-0000000001', NULL, NULL, NULL, NULL, NULL, NULL, @pgb3mp, @e, @d);
CALL sp_registrar_pago(@pb3, 'yape', 180.00, 'idem-b3-yape-000000001', 'OP-B3-0001', NULL, NULL, NULL, NULL, NULL, @pgb3y, @e, @d);
SET @app_actor_id = NULL;
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-b3', 'payment.updated', '{"id":"b3"}', 1, @evb3, @pr);
CALL sp_procesar_pago_pasarela(@evb3, 'mercadopago', 'idem-b3-mp-0000000001', 'MP-B3', 'aprobado', 180.00, NULL, NULL, NULL, NULL, @rb3);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pgb3y, @epb3);
CALL tst_ok('T25 Un Yape que llega con el pedido ya pagado se confirma como huérfano por reembolsar (no hay que rechazar dinero real)',
            (SELECT estado = 'confirmado' AND aplicado_al_pedido = 0 AND motivo_no_aplicado = 'excede_total' FROM pago WHERE id_pago = @pgb3y)
            AND (SELECT pendiente_de_reembolsar FROM v_pagos_por_reembolsar WHERE id_pago = @pgb3y) = 180.00, NULL);
CALL sp_actualizar_configuracion('minutos_gracia_pago_pasarela', '30');
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pb3b, @n, @t);
CALL sp_registrar_pago(@pb3b, 'mercadopago', 180.00, 'idem-b3b-mp-000000001', NULL, NULL, NULL, NULL, NULL, NULL, @x, @e, @d);
CALL tst_error('T26 Con un cobro de pasarela en proceso no se registra otro pago por el mismo saldo',
               "CALL sp_registrar_pago(@pb3b, 'yape', 180.00, 'idem-b3b-yape-00000001', 'OP-B3-0002', NULL, NULL, NULL, NULL, NULL, @x, @y, @z)", 45003);

-- Notas de crédito coherentes con el pedido, rebajas de precio y rechazo de SUNAT
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_faja, ',"cantidad":2}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pb, @n, @t);
CALL sp_registrar_pago(@pb, 'yape', 400.00, 'idem-pedido-b-000000001', 'OP-B-0001', NULL, NULL, NULL, NULL, NULL, @pgb, @e, @d);
SET @app_actor_id = @id_admin;
CALL sp_confirmar_pago_manual(@pgb, @e);
SET @app_actor_id = NULL;
CALL sp_emitir_comprobante(@pb, @cb, @ya);
CALL sp_registrar_respuesta_ose(@cb, 'aceptado', 'OSE-PRUEBA', NULL, NULL, '0', 'Aceptada', NULL, NULL, NULL, NULL, NULL);
SET @app_actor_id = @id_admin;
CALL tst_error('T27 NC por devolución (07) sin devolución registrada', "CALL sp_emitir_nota_credito(@cb, '07', 'Devolución sin registrar', NULL, NULL, 1, @x, @y)", 45016);
CALL tst_error('T28 NC de anulación (01) con el pedido vigente', "CALL sp_emitir_nota_credito(@cb, '01', 'Anular la operación', NULL, NULL, 1, @x, @y)", 45016);
CALL sp_emitir_nota_credito(@cb, '09', 'Descuento por demora en la entrega', 20.00, NULL, 1, @ncb, @rbb);
CALL tst_ok('T29 NC de rebaja con reembolso: monto_ajustes = 20, estado de pago "pagado" y nada "por reembolsar" de más',
            (SELECT monto_ajustes = 20.00 AND estado_pago = 'pagado' FROM pedido WHERE id_pedido = @pb)
            AND (SELECT motivo FROM reembolso WHERE id_reembolso = @rbb) = 'ajuste_precio'
            AND (SELECT COUNT(*) FROM v_pagos_por_reembolsar WHERE id_pedido = @pb) = 0, NULL);
CALL tst_error('T30 La misma NC dos veces seguidas (doble clic)', "CALL sp_emitir_nota_credito(@cb, '09', 'Descuento por demora en la entrega', 20.00, NULL, 1, @x, @y)", 45016);
SET @app_actor_id = NULL;
CALL sp_registrar_respuesta_ose(@ncb, 'rechazado', 'OSE-PRUEBA', NULL, NULL, '2800', 'NC rechazada de prueba', NULL, NULL, NULL, NULL, NULL);
CALL tst_ok('T31 NC rechazada por SUNAT: su reembolso se anula y la rebaja se revierte',
            (SELECT estado FROM reembolso WHERE id_reembolso = @rbb) = 'anulado' AND (SELECT monto_ajustes FROM pedido WHERE id_pedido = @pb) = 0.00, NULL);
SET @app_actor_id = @id_admin;
CALL tst_error('T32 No se reembolsa un pago de un pedido vigente sin causa (dejaría saldo y el IGV sin corregir)', "CALL sp_reembolsar_pago(@pgb, 50.00, 'otro', 'x', NULL, NULL, @x)", 45029);
CALL tst_error('T33 Con comprobante, la compensación va por nota de crédito', "CALL sp_reembolsar_pago(@pgb, 10.00, 'ajuste_precio', 'Demora', NULL, NULL, @x)", 45029);
CALL sp_reembolsar_pago(@pgch, 10.00, 'ajuste_precio', 'Compensación por demora', NULL, NULL, @rbch);
CALL sp_completar_reembolso(@rbch, 1, 'OP-DEV-10', NULL);
CALL tst_ok('T34 Compensación sin comprobante: rebaja el precio y el pedido no queda con saldo pendiente (no se bloquea la entrega)',
            (SELECT monto_ajustes = 10.00 AND saldo = 0.00 AND estado_pago = 'pagado' FROM pedido WHERE id_pedido = @pch), NULL);

-- Webhooks: NULL, reverso y monedas
SET @app_actor_id = NULL;
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-b5', 'payment.updated', '{"id":"b5"}', 1, @evb5, @pr);
CALL tst_error('T35 Webhook con estado NULL no se consume en silencio', "CALL sp_procesar_pago_pasarela(@evb5, 'mercadopago', 'idem-b3-mp-0000000001', 'MP-B3', NULL, 180.00, NULL, NULL, NULL, NULL, @r)", 45006);
CALL tst_ok('T36 ...y el evento sigue pendiente de procesar', (SELECT estado FROM evento_pasarela WHERE id_evento = @evb5) = 'recibido', NULL);
CALL tst_error('T37 Moneda de cobro sin monto: error propio (no 3819)', "CALL sp_procesar_pago_pasarela(@evb5, 'mercadopago', 'idem-b3-mp-0000000001', 'MP-B3', 'aprobado', 180.00, 'USD', NULL, NULL, NULL, @r)", 45017);
CALL sp_procesar_pago_pasarela(@evb5, 'mercadopago', 'idem-b3-mp-0000000001', 'MP-B3', 'revertido', NULL, NULL, NULL, NULL, NULL, @rb5);
CALL tst_ok('T38 Reverso o contracargo de la pasarela queda para revisión (evento con error y aviso)',
            @rb5 = 'revertido_revisar' AND (SELECT estado FROM evento_pasarela WHERE id_evento = @evb5) = 'error'
            AND (SELECT COUNT(*) FROM notificacion WHERE tipo = 'pago_revertido') >= 1, @rb5);
CALL tst_error('T39 Webhook de un proveedor desconocido: error propio (no 1265)', "CALL sp_registrar_evento_pasarela('stripe', 'x-1', NULL, '{}', 1, @x, @y)", 45006);

-- Cola de emisión: trabajo atascado en el último intento
CALL sp_emitir_comprobante(@pch, @cch, @ya);
SET @wanka_ctx_interno = fn_token_interno();   -- solo root: simula un worker que murió en su último intento
UPDATE cola_emision_comprobante SET estado = 'procesando', intentos = max_intentos, tomado_por = 'worker-muerto',
       tomado_en = UTC_TIMESTAMP(3) - INTERVAL 11 MINUTE WHERE id_comprobante = @cch;
SET @wanka_ctx_interno = NULL;
CALL sp_tomar_comprobante_para_emitir('worker-2', @x);
CALL tst_ok('T40 Un trabajo cuyo worker murió en el último intento se descarta y se avisa (no queda "procesando" para siempre)',
            (SELECT estado FROM cola_emision_comprobante WHERE id_comprobante = @cch) = 'descartado'
            AND (SELECT COUNT(*) FROM notificacion WHERE tipo = 'emision_descartada') >= 1, NULL);

-- Errores propios y otros detalles
SET @app_actor_id = @id_admin;
CALL tst_error('T41 Completar un reembolso sin indicar el resultado', "CALL sp_completar_reembolso(@rbb, NULL, NULL, 'texto')", 45029);
CALL tst_error('T42 Archivo de comprobante con tipo inválido', "CALL sp_guardar_archivo_comprobante(@cb, 'zip', 'application/zip', CAST('x' AS BINARY))", 45006);
CALL tst_error('T43 Archivo de un comprobante inexistente', "CALL sp_guardar_archivo_comprobante(999999, 'pdf', 'application/pdf', CAST('x' AS BINARY))", 45022);
CALL tst_error('T44 El correlativo de una serie no salta por UPDATE directo', "UPDATE serie_comprobante SET ultimo_correlativo = ultimo_correlativo + 500 WHERE serie = 'FC01'", 45023);
CALL tst_ok('T45 Sin dirección del cliente el comprobante guarda NULL (no cadena vacía)', (SELECT COUNT(*) FROM comprobante WHERE cliente_direccion = '') = 0, NULL);

-- Segundo factor: fallos, bloqueo y anti-replay
SET @app_actor_id = NULL;
SET @app_ip = '192.0.2.11';
CALL sp_registrar_segundo_factor(@id_admin, 2000, 1, 'pruebas', @s0);
CALL sp_registrar_segundo_factor(@id_admin, 2001, 0, 'pruebas', @s1);
CALL sp_registrar_segundo_factor(@id_admin, 2002, 0, 'pruebas', @s2);
CALL sp_registrar_segundo_factor(@id_admin, 2003, 0, 'pruebas', @s3);
CALL sp_registrar_segundo_factor(@id_admin, 2004, 0, 'pruebas', @s4);
CALL sp_registrar_segundo_factor(@id_admin, 2005, 0, 'pruebas', @s5);
CALL tst_ok('T46 Cinco fallos del segundo factor bloquean la cuenta 15 minutos',
            @s0 = 'ok' AND @s4 = 'segundo_factor_fallido' AND @s5 = 'bloqueada_ahora'
            AND (SELECT bloqueado_hasta > UTC_TIMESTAMP(3) FROM usuario WHERE id_usuario = @id_admin), CONCAT_WS(',', @s0, @s4, @s5));
CALL sp_registrar_segundo_factor(@id_admin, 2010, 1, 'pruebas', @s6);
CALL tst_ok('T47 Con la cuenta bloqueada ni el código correcto entra', @s6 = 'cuenta_bloqueada', @s6);
CALL tst_error('T48 Con la cuenta bloqueada no se abre sesión', "CALL sp_abrir_sesion(@id_admin, SHA2('sesion-bloqueada', 256), 'pruebas', 60, @x)", 45021);
CALL sp_usar_codigo_respaldo_2fa(@id_admin, '12345678', @pepper, @okr);
CALL tst_ok('T49 Con la cuenta bloqueada los códigos de respaldo tampoco sirven', @okr = 0, NULL);
SET @app_actor_id = @id_admin;
CALL sp_desbloquear_usuario(@id_admin);
SET @app_actor_id = NULL;
CALL tst_error('T50 TOTP correcto sin el paso validado: error (evita reutilizar el código)', "CALL sp_registrar_segundo_factor(@id_admin, NULL, 1, 'pruebas', @x)", 45006);
CALL sp_registrar_segundo_factor(@id_admin, 2011, 0, 'pruebas', @x);
CALL sp_registrar_segundo_factor(@id_admin, 2012, 0, 'pruebas', @x);
CALL sp_registrar_intento_acceso('admin@prueba.pe', 1, 'pruebas', @ra, @u, @b, @f);
CALL tst_ok('T51 La contraseña correcta no borra los fallos del 2FA hasta pasar el segundo factor',
            @ra = 'requiere_2fa' AND (SELECT intentos_fallidos FROM usuario WHERE id_usuario = @id_admin) = 2, @ra);
CALL sp_registrar_segundo_factor(@id_admin, 2013, 1, 'pruebas', @ok2);
CALL tst_ok('T52 El 2FA correcto reinicia el contador', @ok2 = 'ok' AND (SELECT intentos_fallidos FROM usuario WHERE id_usuario = @id_admin) = 0, @ok2);
CALL sp_registrar_intento_acceso('maria.nuevo@correo.pe', NULL, 'pruebas', @rn, @u, @b, @f);
CALL tst_ok('T53 Contraseña "NULL" cuenta como fallo, nunca como acierto', @rn = 'credenciales_invalidas', @rn);

-- IP de la sesión
SET @app_ip = 'unknown';
CALL sp_registrar_intento_acceso('maria.nuevo@correo.pe', 1, 'pruebas', @rx, @u, @b, @f);
CALL tst_ok('T54 Una IP inválida en @app_ip no rompe el login (se registra sin IP)',
            @rx = 'ok' AND (SELECT ip IS NULL FROM intento_acceso ORDER BY id_intento DESC LIMIT 1), @rx);
SET @app_ip = '203.0.113.9, 10.0.0.1';
CALL tst_ok('T55 De una lista X-Forwarded-For se toma la primera IP', INET6_NTOA(fn_ip_sesion()) = '203.0.113.9', NULL);
SET @app_ip = NULL;
CALL sp_registrar_mensaje_contacto(NULL, 'Ana', 'ana1@correo.pe', NULL, 'producto', NULL, 'Consulta sobre tallas de polleras', 1, NULL, @msg1, @tk);
CALL sp_registrar_mensaje_contacto(NULL, 'Ana', 'ana2@correo.pe', NULL, 'producto', NULL, 'Consulta sobre colores de polleras', 1, NULL, @msg2, @tk);
CALL sp_registrar_mensaje_contacto(NULL, 'Ana', 'ana3@correo.pe', NULL, 'producto', NULL, 'Consulta sobre precios por mayor', 1, NULL, @msg3, @tk);
CALL tst_error('T56 Sin IP conocida el límite de mensajes se aplica igual (cupo compartido)',
               "CALL sp_registrar_mensaje_contacto(NULL, 'Ana', 'ana4@correo.pe', NULL, 'producto', NULL, 'Cuarto mensaje en la hora', 1, NULL, @x, @y)", 45010);

-- Códigos de verificación: destino y cupos
SET @app_ip = '192.0.2.12';
CALL tst_error('T57 Un código de la cuenta no se envía a otro correo', "CALL sp_generar_codigo_verificacion(@cli1, 'atacante@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z)", 45006);
CALL sp_generar_codigo_verificacion(NULL, 'rosa.quispe@correo.pe', 'recuperar_contrasena', @pepper, @crc, @cre, @cri);
CALL sp_verificar_codigo('rosa.quispe@correo.pe', 'recuperar_contrasena', @crc, @pepper, @crr, @crrest, @cru);
CALL sp_cambiar_contrasena(@cru, 'pbkdf2_sha256$600000$recupera$NUEVAHASHRECUPERACIONABCDEF=', 'recuperacion');
CALL tst_ok('T58 Recuperación anónima: el código queda ligado a la cuenta del correo y permite cambiar la contraseña',
            @crr = 'ok' AND @cru = @cli1 AND (SELECT hash_contrasena FROM usuario WHERE id_usuario = @cli1) LIKE 'pbkdf2_sha256$600000$recupera$%', CONCAT_WS(',', @crr, @cru));
SET @app_ip = '192.0.2.13';
CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z);
CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z);
CALL tst_error('T59 El 6.º código de recuperación en una hora se rechaza', "CALL sp_generar_codigo_verificacion(NULL, 'maria.nuevo@correo.pe', 'recuperar_contrasena', @pepper, @x, @y, @z)", 45010);
CALL tst_error('T60 ...pero no bloquea el segundo factor de la titular (cupo por propósito)', "CALL sp_generar_codigo_verificacion(@cli2, 'maria.nuevo@correo.pe', 'segundo_factor', @pepper, @x, @y, @z)", 0);
SET @app_actor_id = @id_admin;
CALL tst_error('T61 El tope de códigos por hora no supera 5 (§2.7)', "CALL sp_actualizar_configuracion('codigo_verificacion_max_por_hora', '20')", 45020);

-- 2FA de administradores
CALL tst_error('T62 Un administrador no cambia su 2FA a "correo"', "CALL sp_configurar_2fa(@id_admin, 'correo', NULL)", 45023);
CALL sp_configurar_2fa(@id_admin, 'totp', CAST('secreto-nuevo-cifrado' AS BINARY));
CALL tst_ok('T63 Reconfigurar el TOTP deja el nuevo pendiente: el 2FA actual sigue activo',
            (SELECT activo = 1 AND metodo_pendiente = 'totp' AND secreto_cifrado = CAST('secreto-cifrado-por-la-app' AS BINARY)
               FROM autenticacion_2fa WHERE id_usuario = @id_admin) AND (SELECT COUNT(*) FROM v_administradores_sin_2fa) = 0, NULL);
CALL sp_confirmar_2fa(@id_admin, 3000);
CALL tst_ok('T64 Al confirmar, el secreto nuevo reemplaza al anterior y los códigos de respaldo viejos se invalidan',
            (SELECT secreto_cifrado = CAST('secreto-nuevo-cifrado' AS BINARY) AND metodo_pendiente IS NULL FROM autenticacion_2fa WHERE id_usuario = @id_admin)
            AND (SELECT COUNT(*) FROM codigo_respaldo_2fa WHERE id_usuario = @id_admin AND usado_en IS NULL AND invalidado_en IS NULL) = 0, NULL);
SET @app_actor_id = NULL;
CALL sp_usar_codigo_respaldo_2fa(@cli2, '12345678', @pepper, @okc);
CALL tst_ok('T65 Sin 2FA activo los códigos de respaldo no sirven', @okc = 0, NULL);

-- Datos personales y permisos
CALL tst_ok('T66 Tienda y admin no leen el DNI completo de usuario por SELECT; la tienda tampoco la caché de RENIEC',
            (SELECT COUNT(*) FROM information_schema.COLUMN_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'usuario'
              AND GRANTEE IN ("'rol_app_tienda'@'%'", "'rol_app_admin'@'%'") AND COLUMN_NAME = 'numero_documento' AND PRIVILEGE_TYPE = 'SELECT') = 0
            AND (SELECT COUNT(*) FROM information_schema.COLUMN_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = 'usuario'
              AND GRANTEE = "'rol_app_tienda'@'%'" AND COLUMN_NAME = 'correo' AND PRIVILEGE_TYPE = 'SELECT') = 1
            AND (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_tienda'@'%'"
              AND TABLE_NAME IN ('usuario','consulta_documento')) = 0, NULL);
CALL sp_obtener_consulta_documento('RUC', '20615339386', @enc, @nom, @est, @cond, @dom);
CALL tst_ok('T67 La tienda consulta la caché de UN documento exacto', @enc = 1 AND @nom = 'BORDADOS WANKA S.A.C.', @nom);
SET @app_actor_id = @id_admin;
CALL tst_error('T68 El Libro de Reclamaciones no se edita a mano (ni el estado)', "UPDATE reclamo SET estado = 'cerrado', respondido_en = UTC_TIMESTAMP(3) WHERE id_reclamo = @rc1", 45023);
CALL sp_marcar_en_atencion('mensaje', @msg3);
CALL tst_ok('T69 Un mensaje se toma en atención por procedimiento', (SELECT estado FROM mensaje_contacto WHERE id_mensaje = @msg3) = 'en_proceso', NULL);
CALL tst_error('T70 La bitácora de APIs rechaza credenciales en el JSON',
               "CALL sp_registrar_log_api('mercadopago', '/v1/payments', 'POST', 200, 120, 1, '{\"headers\":{\"Authorization\":\"Bearer APP_USR-1\"}}', NULL, NULL, NULL, NULL, NULL, NULL, @x)", 45031);
CALL tst_error('T71 Solo el DBA autorizado redacta la bitácora', "CALL sp_redactar_log_api(@log1, 'Secreto guardado por error')", 45005);
CALL tst_ok('T72 Detección de tarjeta: claves compuestas (card_cvv, cvv_code, cvn) y PAN con puntos',
            fn_contiene_datos_tarjeta('{"card_cvv":"123"}') AND fn_contiene_datos_tarjeta('{"cvv_code":"123"}')
            AND fn_contiene_datos_tarjeta('{"card":{"cvn":"123"}}') AND fn_contiene_datos_tarjeta('{"tarjeta":"4111.1111.1111.1111"}'), NULL);
CALL tst_ok('T73 ...y un PAN escondido después de muchos números también se detecta',
            fn_contiene_datos_tarjeta(CONCAT('{"n":[', REPEAT('1234567890123,', 51), '0],"card":"4111111111111111"}')), NULL);
CALL tst_ok('T74 El DBA no tiene DROP (TRUNCATE saltaría los triggers de borrado de la auditoría)',
            (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_dba_mantenimiento'@'%'" AND PRIVILEGE_TYPE = 'DROP') = 0, NULL);
SET @app_actor_id = @cli2;
CALL sp_actualizar_documento_usuario(@cli2, 'DNI', '40123456');
SET @app_actor_id = @cli1;
CALL tst_error('T75 Dos cuentas pueden registrar el mismo DNI (no revela ni "ocupa" el documento de otro)', "CALL sp_actualizar_documento_usuario(@cli1, 'DNI', '40123456')", 0);
CALL tst_error('T76 La contraseña no se cambia por UPDATE directo (saltaría el historial y el cierre de sesiones)', "UPDATE usuario SET hash_contrasena = @hash WHERE id_usuario = @cli1", 45023);
CALL tst_error('T77 El documento no se cambia por UPDATE directo', "UPDATE usuario SET numero_documento = '45678912' WHERE id_usuario = @cli1", 45023);
SET @app_actor_id = @cli2;
CALL sp_corregir_facturacion_pedido(@pb3b, 'factura', 'RUC', '20615339386', 'BORDADOS WANKA S.A.C.', 'Sapallanga, Huancayo');
CALL tst_ok('T78 La facturación se corrige por procedimiento antes de emitir', (SELECT comprobante_solicitado = 'factura' AND facturacion_num_doc = '20615339386' FROM pedido WHERE id_pedido = @pb3b), NULL);
SET @app_actor_id = @id_admin;
CALL tst_error('T79 Con comprobante emitido la facturación ya no se corrige', "CALL sp_corregir_facturacion_pedido(@pb, 'boleta', NULL, NULL, NULL, NULL)", 45016);

-- El courier informa la entrega pero el pedido no puede cerrarse: el evento no se pierde
SET @wanka_ctx_interno = fn_token_interno();   -- solo root: simula un saldo pendiente después del despacho
UPDATE pedido SET monto_pagado = monto_pagado - 10.00 WHERE id_pedido = @pdm;
SET @wanka_ctx_interno = NULL;
SET @app_actor_id = NULL;
CALL sp_registrar_seguimiento_envio(@envA, 'entregado', 'Entregado al cliente', 'Huancayo', NULL, 'api_courier', 'evt-t80', @d);
CALL tst_ok('T80 Entrega del courier con el pedido sin poder cerrarse: el evento y el envío quedan registrados y se avisa',
            (SELECT COUNT(*) FROM seguimiento_envio WHERE id_envio = @envA AND id_evento_externo = 'evt-t80') = 1
            AND (SELECT estado FROM envio WHERE id_envio = @envA) = 'entregado'
            AND (SELECT estado FROM pedido WHERE id_pedido = @pdm) = 'enviado'
            AND (SELECT COUNT(*) FROM notificacion WHERE tipo = 'entrega_sin_cerrar' AND id_pedido = @pdm) >= 1, NULL);
SET @wanka_ctx_interno = fn_token_interno();
UPDATE pedido SET monto_pagado = monto_pagado + 10.00 WHERE id_pedido = @pdm;
SET @wanka_ctx_interno = NULL;
SET @app_actor_id = @id_admin;
CALL sp_cambiar_estado_pedido(@pdm, 'entregado', 'Saldo regularizado');
CALL tst_ok('T81 Con el saldo al día el administrador cierra el pedido', (SELECT estado FROM pedido WHERE id_pedido = @pdm) = 'entregado', NULL);
-- La pasarela informa una operación que ya pertenece a otro pago
SET @app_actor_id = @cli2;
CALL sp_crear_pedido(@cli2, CONCAT('[{"id_variante":', @var_cha, ',"cantidad":1}]'), 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @pdup, @n, @t);
CALL sp_registrar_pago(@pdup, 'mercadopago', 180.00, 'idem-pedido-dup-00000001', NULL, NULL, NULL, NULL, NULL, NULL, @pgdup, @e, @d);
SET @app_actor_id = NULL;
CALL sp_registrar_evento_pasarela('mercadopago', 'mp-evt-dup', 'payment.updated', '{"id":"dup"}', 1, @evdup, @pr);
CALL sp_procesar_pago_pasarela(@evdup, 'mercadopago', 'idem-pedido-dup-00000001', 'MP-B3', 'aprobado', 180.00, NULL, NULL, NULL, NULL, @rdup);
CALL tst_ok('T82 Operación de la pasarela repetida en otro pago: queda para revisión (no error 1062 ni reintentos sin fin)',
            @rdup = 'referencia_duplicada' AND (SELECT estado FROM evento_pasarela WHERE id_evento = @evdup) = 'error'
            AND (SELECT estado FROM pago WHERE id_pago = @pgdup) = 'pendiente', @rdup);
SET @app_ip = '190.12.34.56';

-- =====================================================================
-- 8. CONSISTENCIA GLOBAL
-- =====================================================================
CALL tst_ok('Z01 v_inconsistencias vacía (stock = reservas = kardex; pagos = pedido; comprobantes = líneas)',
            (SELECT COUNT(*) FROM v_inconsistencias) = 0, (SELECT GROUP_CONCAT(CONCAT(control, ' ', detalle) SEPARATOR ' | ') FROM v_inconsistencias));
CALL tst_ok('Z02 Pedidos consultables por grupo de estado', (SELECT COUNT(DISTINCT estado_grupo) FROM v_pedidos_estado) >= 4, NULL);
CALL tst_ok('Z03 Ingresos por día de Lima', (SELECT SUM(cobrado) FROM v_ingresos_diarios) > 0, NULL);

-- =====================================================================
-- 9. MATRIZ DE PERMISOS POR ROL (lo que puede y lo que no)
-- =====================================================================
CALL tst_ok('S01 rol_app_tienda: sin DELETE en ninguna tabla',
            (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_tienda'@'%'" AND PRIVILEGE_TYPE = 'DELETE')
          + (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_tienda'@'%'" AND PRIVILEGE_TYPE = 'DELETE') = 0, NULL);
CALL tst_ok('S02 rol_app_tienda: sin INSERT/UPDATE directo en pedido, pago, comprobante ni kardex',
            (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_tienda'@'%'" AND PRIVILEGE_TYPE IN ('INSERT','UPDATE')
              AND TABLE_NAME IN ('pedido','pago','comprobante','movimiento_stock','item_pedido','reembolso')) = 0, NULL);
CALL tst_ok('S03 rol_app_admin: sin DELETE (eliminar = inhabilitar)',
            (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_admin'@'%'" AND PRIVILEGE_TYPE = 'DELETE')
          + (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_admin'@'%'" AND PRIVILEGE_TYPE = 'DELETE') = 0, NULL);
CALL tst_ok('S04 rol_app_admin: EXECUTE explícito en los sp_* públicos (sin permiso global sobre la base)',
            (SELECT COUNT(*) FROM mysql.procs_priv WHERE Db = DATABASE() AND User = 'rol_app_admin' AND Routine_name LIKE 'sp\_%') > 100
            AND (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_app_admin'@'%'") = 0, NULL);
CALL tst_ok('S05 rol_reportes: solo SELECT y solo sobre vistas v_*',
            (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_reportes'@'%'" AND (PRIVILEGE_TYPE <> 'SELECT' OR TABLE_NAME NOT LIKE 'v\_%')) = 0
            AND (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_reportes'@'%'") = 0, NULL);
CALL tst_ok('S06 rol_reportes no ve la copia completa de comprobantes ni hashes',
            (SELECT COUNT(*) FROM information_schema.TABLE_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_reportes'@'%'"
              AND TABLE_NAME IN ('v_comprobante_copia_completa','v_historial_contrasena_reciente')) = 0, NULL);
CALL tst_ok('S07 rol_dba_mantenimiento: único con DELETE',
            (SELECT COUNT(*) FROM information_schema.SCHEMA_PRIVILEGES WHERE TABLE_SCHEMA = DATABASE() AND GRANTEE = "'rol_dba_mantenimiento'@'%'" AND PRIVILEGE_TYPE = 'DELETE') = 1, NULL);
CALL tst_ok('S08 Cuenta técnica DEFINER bloqueada (sin inicio de sesión)', (SELECT account_locked FROM mysql.user WHERE user = 'wanka_definer') = 'Y', NULL);
CALL tst_ok('S09 Cuentas de la app creadas bloqueadas hasta fijar su contraseña',
            (SELECT COUNT(*) FROM mysql.user WHERE user IN ('wanka_tienda','wanka_admin','wanka_reportes','wanka_dba') AND account_locked = 'Y') = 4, NULL);
CALL tst_ok('S10 Procedimientos con SQL SECURITY DEFINER y dueño wanka_definer',
            (SELECT COUNT(*) FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME NOT LIKE 'tst\_%'
              AND (DEFINER <> 'wanka_definer@localhost'
                   OR (SECURITY_TYPE <> 'DEFINER' AND ROUTINE_NAME <> 'fn_token_interno'))) = 0
            AND (SELECT SECURITY_TYPE FROM information_schema.ROUTINES WHERE ROUTINE_SCHEMA = DATABASE() AND ROUTINE_NAME = 'fn_token_interno') = 'INVOKER',
            'fn_token_interno es INVOKER a propósito: fuera de los procedimientos no puede leer el secreto');

-- =====================================================================
-- RESUMEN
-- =====================================================================
SELECT resultado, COUNT(*) AS casos FROM tst_resultado GROUP BY resultado;
SELECT id, caso, detalle FROM tst_resultado WHERE resultado = '✘' ORDER BY id;
SELECT id, resultado, caso FROM tst_resultado ORDER BY id;
