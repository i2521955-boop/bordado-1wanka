-- =====================================================================
-- BORDADOS WANKA S.A.C. — 03_funciones_procedimientos.sql
-- ---------------------------------------------------------------------
-- Propósito : lógica de negocio en la base de datos.
--   fn_*  funciones puras o de solo lectura (validaciones, IGV, fechas Lima)
--   spi_* procedimientos INTERNOS: no abren ni cierran transacciones; los
--         llaman otros procedimientos y los triggers (red de seguridad).
--   sp_*  procedimientos PÚBLICOS para Django: cada uno es una transacción
--         completa (START TRANSACTION ... COMMIT, ROLLBACK + RESIGNAL ante
--         error) y falla con SIGNAL SQLSTATE '45000' + MYSQL_ERRNO del
--         catálogo de errores (tabla catalogo_error, 45001..45035).
-- Contexto de sesión que fija Django al abrir la conexión o la petición:
--   SET @app_actor_id = <id_usuario autenticado o NULL>;
--   SET @app_ip       = '<ip del cliente>';   (IPv4/IPv6; si llega una lista X-Forwarded-For se usa la primera)
-- Contexto interno: los sp_* fijan @wanka_ctx_interno = fn_token_interno(), un SHA-256 del
--   secreto de la instalación (tabla secreto_interno) y del id de conexión. Las cuentas de la
--   app no pueden leer ese secreto ni ejecutar fn_token_interno, así que no pueden fabricar la
--   marca que exigen los triggers para tocar columnas derivadas.
-- Reglas de concurrencia:
--   * Orden de bloqueo único: pedido → pago → variantes (ascendente por id).
--   * sp_crear_pedido reintenta automáticamente ante deadlock (error 1213).
-- Importante para Django: llamar los sp_* en modo autocommit (fuera de
--   transaction.atomic), porque START TRANSACTION confirma cualquier
--   transacción abierta.
-- Seguridad: todos con DEFINER = wanka_definer (cuenta bloqueada) y
--   SQL SECURITY DEFINER; parámetros tipados, sin SQL dinámico.
-- Re-ejecutable: sí (DROP ... IF EXISTS antes de cada CREATE).
-- COMPAT-MARIADB: JSON_TABLE desde 10.6; REGEXP_LIKE(..., 'c') no existe (usar REGEXP);
--   INSERT ... AS alias no existe (usar VALUES()); RANDOM_BYTES desde 10.10; SKIP LOCKED desde 10.6.
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';

DELIMITER $$

-- #####################################################################
-- A. FUNCIONES
-- #####################################################################

DROP FUNCTION IF EXISTS fn_actor $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_actor()
RETURNS BIGINT UNSIGNED NOT DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Usuario que actúa en esta sesión (@app_actor_id fijado por Django). NULL = sistema'
BEGIN
  IF @app_actor_id IS NULL OR CAST(@app_actor_id AS CHAR) = '' THEN
    RETURN NULL;
  END IF;
  RETURN CAST(@app_actor_id AS UNSIGNED);
END $$

DROP FUNCTION IF EXISTS fn_ip_sesion $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_ip_sesion()
RETURNS VARBINARY(16) NOT DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'IP del cliente informada por Django en @app_ip (binario INET6_ATON). Texto inválido = NULL (nunca rompe la operación)'
BEGIN
  DECLARE v_ip VARCHAR(64) DEFAULT NULLIF(TRIM(SUBSTRING_INDEX(LEFT(CAST(@app_ip AS CHAR), 200), ',', 1)), '');
  IF v_ip IS NULL OR NOT (IS_IPV4(v_ip) OR IS_IPV6(v_ip)) THEN
    RETURN NULL;
  END IF;
  RETURN INET6_ATON(v_ip);
END $$

DROP FUNCTION IF EXISTS fn_utc_a_lima $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_utc_a_lima(p_fecha DATETIME(3))
RETURNS DATETIME(3) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Convierte UTC a hora de Lima (UTC−5 fijo, Perú no usa horario de verano)'
BEGIN
  RETURN p_fecha - INTERVAL 5 HOUR;
END $$

DROP FUNCTION IF EXISTS fn_hoy_lima $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_hoy_lima()
RETURNS DATE NOT DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Fecha actual en Lima'
BEGIN
  RETURN DATE(UTC_TIMESTAMP() - INTERVAL 5 HOUR);
END $$

DROP FUNCTION IF EXISTS fn_config $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_config(p_clave VARCHAR(60))
RETURNS VARCHAR(500) NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Valor de configuración como texto; error 45020 si la clave no existe'
BEGIN
  DECLARE v_valor VARCHAR(500) DEFAULT NULL;
  DECLARE v_msg VARCHAR(128);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_valor = NULL;
  SELECT valor INTO v_valor FROM configuracion WHERE clave = p_clave;
  IF v_valor IS NULL THEN
    SET v_msg = LEFT(CONCAT('Falta la configuración: ', p_clave), 128);
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg, MYSQL_ERRNO = 45020;
  END IF;
  RETURN v_valor;
END $$

DROP FUNCTION IF EXISTS fn_config_entero $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_config_entero(p_clave VARCHAR(60))
RETURNS BIGINT NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Valor de configuración entero'
BEGIN
  RETURN CAST(fn_config(p_clave) AS SIGNED);
END $$

DROP FUNCTION IF EXISTS fn_config_decimal $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_config_decimal(p_clave VARCHAR(60))
RETURNS DECIMAL(14,4) NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Valor de configuración decimal'
BEGIN
  RETURN CAST(fn_config(p_clave) AS DECIMAL(14,4));
END $$

DROP FUNCTION IF EXISTS fn_normalizar_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_normalizar_correo(p_correo VARCHAR(300))
RETURNS VARCHAR(300) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Correo sin espacios y en minúsculas'
BEGIN
  RETURN LOWER(TRIM(p_correo));
END $$

DROP FUNCTION IF EXISTS fn_normalizar_telefono $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_normalizar_telefono(p_tel VARCHAR(40))
RETURNS VARCHAR(40) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Deja solo dígitos y el + inicial'
BEGIN
  IF p_tel IS NULL THEN RETURN NULL; END IF;
  RETURN NULLIF(REGEXP_REPLACE(TRIM(p_tel), '[^0-9+]', ''), '');
END $$

DROP FUNCTION IF EXISTS fn_ruc_valido $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_ruc_valido(p_ruc VARCHAR(20))
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'RUC de 11 dígitos, prefijo 10/15/16/17/20 y dígito verificador (módulo 11) correcto'
BEGIN
  DECLARE i INT DEFAULT 1;
  DECLARE v_suma INT DEFAULT 0;
  DECLARE v_pesos CHAR(10) DEFAULT '5432765432';
  DECLARE v_dv INT;
  IF p_ruc IS NULL OR NOT REGEXP_LIKE(p_ruc, '^(10|15|16|17|20)[0-9]{9}$', 'c') THEN
    RETURN 0;
  END IF;
  WHILE i <= 10 DO
    SET v_suma = v_suma + CAST(SUBSTRING(p_ruc, i, 1) AS UNSIGNED) * CAST(SUBSTRING(v_pesos, i, 1) AS UNSIGNED);
    SET i = i + 1;
  END WHILE;
  SET v_dv = 11 - (v_suma MOD 11);
  IF v_dv = 10 THEN SET v_dv = 0; ELSEIF v_dv = 11 THEN SET v_dv = 1; END IF;
  RETURN v_dv = CAST(SUBSTRING(p_ruc, 11, 1) AS UNSIGNED);
END $$

DROP FUNCTION IF EXISTS fn_documento_valido $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_documento_valido(p_tipo VARCHAR(3), p_numero VARCHAR(20))
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'DNI 8 dígitos, RUC válido (con dígito verificador), CE 6-12 alfanumérico en mayúsculas; ambos NULL = válido'
BEGIN
  IF p_tipo IS NULL AND p_numero IS NULL THEN RETURN 1; END IF;
  IF p_tipo IS NULL OR p_numero IS NULL THEN RETURN 0; END IF;
  RETURN CASE p_tipo
           WHEN 'DNI' THEN REGEXP_LIKE(p_numero, '^[0-9]{8}$', 'c')
           WHEN 'RUC' THEN fn_ruc_valido(p_numero)
           WHEN 'CE'  THEN REGEXP_LIKE(p_numero, '^[A-Z0-9]{6,12}$', 'c')
           ELSE 0
         END;
END $$

DROP FUNCTION IF EXISTS fn_correo_valido $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_correo_valido(p_correo VARCHAR(300))
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Formato de correo (ASCII, ya normalizado)'
BEGIN
  RETURN p_correo IS NOT NULL AND CHAR_LENGTH(p_correo) <= 254
         AND REGEXP_LIKE(p_correo, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c');
END $$

DROP FUNCTION IF EXISTS fn_igv_incluido $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_igv_incluido(p_total DECIMAL(12,2), p_tasa DECIMAL(5,2))
RETURNS DECIMAL(12,2) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'ÚNICA función de IGV: IGV contenido en un importe que ya lo incluye, redondeado a 2 decimales. Base = importe − IGV (cuadre exacto)'
BEGIN
  RETURN ROUND(p_total - p_total / (1 + p_tasa / 100), 2);
END $$

DROP FUNCTION IF EXISTS fn_tasa_igv $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_tasa_igv()
RETURNS DECIMAL(5,2) NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Tasa de IGV vigente (configuración igv_porcentaje)'
BEGIN
  RETURN CAST(fn_config('igv_porcentaje') AS DECIMAL(5,2));
END $$

DROP FUNCTION IF EXISTS fn_precio_volumen $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_precio_volumen(p_id_producto BIGINT UNSIGNED, p_cantidad INT UNSIGNED)
RETURNS DECIMAL(10,2) NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Precio del mayor tramo de volumen alcanzado por la cantidad; NULL si no alcanza ninguno'
BEGIN
  DECLARE v_precio DECIMAL(10,2) DEFAULT NULL;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_precio = NULL;
  SELECT precio_unitario INTO v_precio
    FROM precio_volumen
   WHERE id_producto = p_id_producto AND activo = 1 AND cantidad_minima <= p_cantidad
   ORDER BY cantidad_minima DESC
   LIMIT 1;
  RETURN v_precio;
END $$

DROP FUNCTION IF EXISTS fn_precio_unitario $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_precio_unitario(p_id_variante BIGINT UNSIGNED, p_cantidad INT UNSIGNED)
RETURNS DECIMAL(10,2) NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Precio que se cobra por unidad: el menor entre el de lista (variante o producto) y el de volumen alcanzado'
BEGIN
  DECLARE v_lista DECIMAL(10,2) DEFAULT NULL;
  DECLARE v_producto BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_vol DECIMAL(10,2);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_lista = NULL;
  SELECT COALESCE(v.precio, p.precio_base), p.id_producto INTO v_lista, v_producto
    FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
   WHERE v.id_variante = p_id_variante;
  IF v_lista IS NULL THEN RETURN NULL; END IF;
  SET v_vol = fn_precio_volumen(v_producto, p_cantidad);
  RETURN IF(v_vol IS NOT NULL AND v_vol < v_lista, v_vol, v_lista);
END $$

DROP FUNCTION IF EXISTS fn_generar_digitos $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_generar_digitos(p_digitos TINYINT UNSIGNED)
RETURNS VARCHAR(9) NOT DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Código numérico con aleatoriedad criptográfica: RANDOM_BYTES(4) + muestreo por rechazo (sin sesgo de módulo). Nunca RAND()'
BEGIN
  DECLARE v_modulo BIGINT UNSIGNED;
  DECLARE v_limite BIGINT UNSIGNED;
  DECLARE v_valor  BIGINT UNSIGNED;
  IF p_digitos IS NULL OR p_digitos < 4 OR p_digitos > 9 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cantidad de dígitos inválida (4 a 9)', MYSQL_ERRNO = 45006;
  END IF;
  SET v_modulo = CAST(POW(10, p_digitos) AS UNSIGNED);
  SET v_limite = 4294967296 - (4294967296 MOD v_modulo);
  REPEAT
    SET v_valor = CAST(CONV(HEX(RANDOM_BYTES(4)), 16, 10) AS UNSIGNED);   -- COMPAT-MARIADB: RANDOM_BYTES desde 10.10
  UNTIL v_valor < v_limite END REPEAT;
  RETURN LPAD(v_valor MOD v_modulo, p_digitos, '0');
END $$

DROP FUNCTION IF EXISTS fn_hash_codigo $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_hash_codigo(p_pepper VARCHAR(200), p_codigo VARCHAR(64))
RETURNS CHAR(64) CHARSET ascii DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'SHA-256(pepper : código). El pepper vive en la configuración de Django, nunca en la BD'
BEGIN
  RETURN SHA2(CONCAT(p_pepper, ':', p_codigo), 256);
END $$

DROP FUNCTION IF EXISTS fn_luhn_valido $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_luhn_valido(p_numero VARCHAR(30))
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Algoritmo de Luhn (detección de números de tarjeta)'
BEGIN
  DECLARE i INT;
  DECLARE v_suma INT DEFAULT 0;
  DECLARE v_d INT;
  DECLARE v_alterna BOOLEAN DEFAULT 0;
  IF p_numero IS NULL OR NOT REGEXP_LIKE(p_numero, '^[0-9]{12,19}$', 'c') THEN RETURN 0; END IF;
  SET i = CHAR_LENGTH(p_numero);
  WHILE i >= 1 DO
    SET v_d = CAST(SUBSTRING(p_numero, i, 1) AS UNSIGNED);
    IF v_alterna THEN
      SET v_d = v_d * 2;
      IF v_d > 9 THEN SET v_d = v_d - 9; END IF;
    END IF;
    SET v_suma = v_suma + v_d;
    SET v_alterna = NOT v_alterna;
    SET i = i - 1;
  END WHILE;
  RETURN (v_suma MOD 10) = 0;
END $$

DROP FUNCTION IF EXISTS fn_contiene_datos_tarjeta $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_contiene_datos_tarjeta(p_json JSON)
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Defensa en profundidad: 1 si el JSON trae claves de tarjeta (PAN, CVV...) o un número con prefijo de tarjeta que pasa Luhn. Falla cerrado ante JSON enormes'
BEGIN
  DECLARE v_texto LONGTEXT;
  DECLARE v_cand VARCHAR(40);
  DECLARE i INT DEFAULT 1;
  IF p_json IS NULL THEN RETURN 0; END IF;
  SET v_texto = CAST(p_json AS CHAR);
  -- Claves: "pan" exacta; las demás también como parte del nombre (card_cvv, cvv_code, numero_de_tarjeta...)
  IF REGEXP_LIKE(v_texto, '"pan"[[:space:]]*:', 'i')
     OR REGEXP_LIKE(v_texto, '"[^"]{0,40}(card_?number|cardnumber|card_?num|numero_?(de_?)?tarjeta|cvv|cvc|cvn|cid_?code|security_?code|codigo_?(de_?)?seguridad)[^"]{0,40}"[[:space:]]*:', 'i') THEN
    RETURN 1;
  END IF;
  busqueda: LOOP
    SET v_cand = REGEXP_SUBSTR(v_texto, '(?<![0-9])[0-9]{4}([ .-]?[0-9]{3,4}){2,4}(?![0-9])', 1, i);
    IF v_cand IS NULL THEN LEAVE busqueda; END IF;
    IF i > 500 THEN RETURN 1; END IF;   -- demasiados números para revisarlos: se rechaza (falla cerrado)
    SET v_cand = REGEXP_REPLACE(v_cand, '[ .-]', '');
    IF REGEXP_LIKE(v_cand, '^(4[0-9]{12}([0-9]{3,6})?|5[1-5][0-9]{14}|2[2-7][0-9]{14}|3[47][0-9]{13}|3[0689][0-9]{11,12}|6[0-9]{15,18})$', 'c')
       AND fn_luhn_valido(v_cand) THEN
      RETURN 1;
    END IF;
    SET i = i + 1;
  END LOOP busqueda;
  RETURN 0;
END $$

DROP FUNCTION IF EXISTS fn_contiene_secretos $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_contiene_secretos(p_json JSON, p_url VARCHAR(500))
RETURNS BOOLEAN DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT '1 si el JSON trae claves de credenciales (authorization, token, password, secret, api_key...) o la URL lleva un secreto en la consulta'
BEGIN
  IF p_json IS NOT NULL AND REGEXP_LIKE(CAST(p_json AS CHAR),
       '"[^"]{0,40}(authorization|token|password|passwd|contrasena|secret|api_?key|apikey|private_?key|cookie|signature)[^"]{0,40}"[[:space:]]*:', 'i') THEN
    RETURN 1;
  END IF;
  IF p_url IS NOT NULL AND REGEXP_LIKE(p_url,
       '[?&;](key|api_?key|apikey|token|access_?token|auth|password|passwd|secret|client_?secret|signature|sig)=', 'i') THEN
    RETURN 1;
  END IF;
  RETURN 0;
END $$

DROP FUNCTION IF EXISTS fn_enmascarar_documento $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_enmascarar_documento(p_numero VARCHAR(20))
RETURNS VARCHAR(20) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Muestra solo los 3 últimos caracteres (Ley 29733)'
BEGIN
  IF p_numero IS NULL THEN RETURN NULL; END IF;
  RETURN CONCAT(REPEAT('*', GREATEST(CHAR_LENGTH(p_numero) - 3, 0)), RIGHT(p_numero, 3));
END $$

DROP FUNCTION IF EXISTS fn_enmascarar_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_enmascarar_correo(p_correo VARCHAR(254))
RETURNS VARCHAR(254) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'jo***@dominio.com'
BEGIN
  IF p_correo IS NULL OR LOCATE('@', p_correo) = 0 THEN RETURN p_correo; END IF;
  RETURN CONCAT(LEFT(p_correo, LEAST(2, LOCATE('@', p_correo) - 1)), '***', SUBSTRING(p_correo, LOCATE('@', p_correo)));
END $$

DROP FUNCTION IF EXISTS fn_enmascarar_telefono $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_enmascarar_telefono(p_tel VARCHAR(20))
RETURNS VARCHAR(20) DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Muestra solo los 3 últimos dígitos'
BEGIN
  IF p_tel IS NULL THEN RETURN NULL; END IF;
  RETURN CONCAT(REPEAT('*', GREATEST(CHAR_LENGTH(p_tel) - 3, 0)), RIGHT(p_tel, 3));
END $$

DROP FUNCTION IF EXISTS fn_sumar_dias_habiles $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_sumar_dias_habiles(p_fecha DATE, p_dias INT)
RETURNS DATE DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Suma días hábiles (lunes a viernes). No descuenta feriados: verificar si la norma los exige'
BEGIN
  DECLARE v_fecha DATE DEFAULT p_fecha;
  DECLARE v_n INT DEFAULT 0;
  WHILE v_n < p_dias DO
    SET v_fecha = v_fecha + INTERVAL 1 DAY;
    IF DAYOFWEEK(v_fecha) NOT IN (1, 7) THEN SET v_n = v_n + 1; END IF;
  END WHILE;
  RETURN v_fecha;
END $$

DROP FUNCTION IF EXISTS fn_fecha_limite $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_fecha_limite(p_desde DATE, p_dias INT, p_tipo VARCHAR(20))
RETURNS DATE DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT 'Fecha límite por días calendario o hábiles'
BEGIN
  IF p_tipo = 'habiles' THEN RETURN fn_sumar_dias_habiles(p_desde, p_dias); END IF;
  RETURN p_desde + INTERVAL p_dias DAY;
END $$

DROP FUNCTION IF EXISTS fn_es_admin $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_es_admin(p_id_usuario BIGINT UNSIGNED)
RETURNS BOOLEAN NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT '1 si el usuario es administrador activo'
BEGIN
  IF p_id_usuario IS NULL THEN RETURN 0; END IF;
  RETURN EXISTS (SELECT 1 FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                  WHERE u.id_usuario = p_id_usuario AND u.estado = 'activo' AND r.codigo = 'administrador');
END $$

DROP FUNCTION IF EXISTS fn_borrado_dba_autorizado $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_borrado_dba_autorizado()
RETURNS BOOLEAN NOT DETERMINISTIC NO SQL SQL SECURITY DEFINER
COMMENT '1 solo si la sesión es de la cuenta DBA de mantenimiento (wanka_dba) y declaró @wanka_autorizo_borrado = ''SI-AUTORIZO'''
BEGIN
  -- COALESCE: sin la variable la comparación da NULL, y "NOT NULL" dejaría pasar el borrado
  RETURN COALESCE(SUBSTRING_INDEX(SESSION_USER(), '@', 1) = 'wanka_dba'
                  AND CAST(@wanka_autorizo_borrado AS CHAR) = 'SI-AUTORIZO', FALSE);
END $$

DROP FUNCTION IF EXISTS fn_token_interno $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_token_interno()
RETURNS CHAR(64) NOT DETERMINISTIC READS SQL DATA SQL SECURITY INVOKER
COMMENT 'Marca de contexto interno de esta conexión: SHA-256(secreto de la instalación, id de conexión). INVOKER: solo funciona dentro de los procedimientos/triggers (wanka_definer)'
BEGIN
  DECLARE v_secreto CHAR(64) DEFAULT NULL;
  SELECT secreto INTO v_secreto FROM secreto_interno WHERE id_secreto = 1;
  IF v_secreto IS NULL THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Falta el secreto interno de la instalación (01_esquema_acceso.sql)', MYSQL_ERRNO = 45020;
  END IF;
  RETURN SHA2(CONCAT(v_secreto, ':', CONNECTION_ID()), 256);
END $$

DROP FUNCTION IF EXISTS fn_contexto_interno $$
CREATE DEFINER=`wanka_definer`@`localhost` FUNCTION fn_contexto_interno()
RETURNS BOOLEAN NOT DETERMINISTIC READS SQL DATA SQL SECURITY DEFINER
COMMENT '1 si el cambio viene de un procedimiento de la BD (columnas derivadas: stock, montos pagados, valoraciones). La marca no se puede falsificar desde la app'
BEGIN
  -- Comparación binaria: no depende de la colación de la conexión de Django
  RETURN @wanka_ctx_interno IS NOT NULL AND CAST(@wanka_ctx_interno AS BINARY) = CAST(fn_token_interno() AS BINARY);
END $$

-- #####################################################################
-- B. PROCEDIMIENTOS INTERNOS (spi_*) — sin control de transacción
-- #####################################################################

DROP PROCEDURE IF EXISTS spi_error $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_error(IN p_codigo SMALLINT UNSIGNED, IN p_mensaje VARCHAR(500))
NO SQL SQL SECURITY DEFINER
COMMENT 'Lanza SIGNAL 45000 con MYSQL_ERRNO del catálogo de errores y mensaje (máx. 128 caracteres)'
BEGIN
  DECLARE v_msg VARCHAR(128) DEFAULT LEFT(p_mensaje, 128);
  SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_msg, MYSQL_ERRNO = p_codigo;
END $$

DROP PROCEDURE IF EXISTS spi_auditar $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_auditar(
  IN p_evento VARCHAR(60), IN p_entidad VARCHAR(40), IN p_id_entidad BIGINT UNSIGNED,
  IN p_id_afectado BIGINT UNSIGNED, IN p_detalle JSON, IN p_origen VARCHAR(15))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Inserta un registro de auditoría con actor, IP y cuenta MySQL'
BEGIN
  INSERT INTO auditoria (id_usuario_actor, id_usuario_afectado, evento, entidad, id_entidad, detalle, ip, origen, usuario_bd)
  VALUES (fn_actor(), p_id_afectado, p_evento, p_entidad, p_id_entidad, p_detalle, fn_ip_sesion(),
          COALESCE(p_origen, 'procedimiento'), LEFT(SESSION_USER(), 100));
END $$

DROP PROCEDURE IF EXISTS spi_validar_admin $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_admin()
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Error 45023 si el actor no es administrador activo'
BEGIN
  IF NOT fn_es_admin(fn_actor()) THEN
    CALL spi_error(45023, 'Solo un administrador activo puede realizar esta operación');
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_validar_dueno_o_admin $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_dueno_o_admin(IN p_id_usuario BIGINT UNSIGNED)
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Error 45023 si el actor no es el dueño del recurso ni administrador'
BEGIN
  IF NOT (fn_es_admin(fn_actor()) OR (fn_actor() IS NOT NULL AND fn_actor() = p_id_usuario)) THEN
    CALL spi_error(45023, 'No tiene permiso sobre este recurso');
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_siguiente_numero $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_siguiente_numero(
  IN p_prefijo VARCHAR(12), IN p_ancho TINYINT UNSIGNED, OUT p_numero VARCHAR(25))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Correlativo anual atómico y sin saltos: PREFIJO-AAAA-000001 (bloquea la fila de la secuencia hasta el fin de la transacción)'
BEGIN
  DECLARE v_anio SMALLINT UNSIGNED DEFAULT YEAR(fn_hoy_lima());
  DECLARE v_n INT UNSIGNED;
  INSERT INTO secuencia_documento (prefijo, anio, ultimo)
  VALUES (p_prefijo, v_anio, LAST_INSERT_ID(1))
  ON DUPLICATE KEY UPDATE ultimo = LAST_INSERT_ID(ultimo + 1);
  SET v_n = LAST_INSERT_ID();
  SET p_numero = CONCAT(p_prefijo, '-', v_anio, '-', LPAD(v_n, p_ancho, '0'));
END $$

DROP PROCEDURE IF EXISTS spi_siguiente_correlativo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_siguiente_correlativo(
  IN p_id_serie SMALLINT UNSIGNED, OUT p_correlativo INT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Siguiente correlativo de una serie activa (atómico con LAST_INSERT_ID(expr))'
BEGIN
  UPDATE serie_comprobante
     SET ultimo_correlativo = LAST_INSERT_ID(ultimo_correlativo + 1)
   WHERE id_serie = p_id_serie AND activo = 1;
  IF ROW_COUNT() = 0 THEN
    CALL spi_error(45015, 'La serie de comprobante no existe o está inactiva');
  END IF;
  SET p_correlativo = LAST_INSERT_ID();
END $$

DROP PROCEDURE IF EXISTS spi_bloquear_frecuencia $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_bloquear_frecuencia(IN p_ambito VARCHAR(30), IN p_clave VARCHAR(254))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Bloquea (FOR UPDATE) la fila del sujeto limitado para que dos solicitudes simultáneas cuenten en serie'
BEGIN
  DECLARE v_x VARCHAR(30);
  INSERT INTO control_frecuencia (ambito, clave) VALUES (p_ambito, p_clave)
  ON DUPLICATE KEY UPDATE ambito = ambito;
  SELECT ambito INTO v_x FROM control_frecuencia WHERE ambito = p_ambito AND clave = p_clave FOR UPDATE;
END $$

DROP PROCEDURE IF EXISTS spi_encolar_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_encolar_correo(
  IN p_id_usuario BIGINT UNSIGNED, IN p_destinatario VARCHAR(254), IN p_plantilla VARCHAR(60),
  IN p_contexto JSON, IN p_prioridad TINYINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Encola un correo (lo envía la app). Ignora destinos .invalid (cliente de mostrador)'
BEGIN
  DECLARE v_dest VARCHAR(254) DEFAULT fn_normalizar_correo(p_destinatario);
  IF v_dest IS NOT NULL AND v_dest NOT LIKE '%.invalid' AND fn_correo_valido(v_dest) THEN
    INSERT INTO cola_correo (id_usuario, destinatario, plantilla, contexto, prioridad, max_intentos)
    VALUES (p_id_usuario, v_dest, p_plantilla, p_contexto, COALESCE(p_prioridad, 5), fn_config_entero('cola_correo_max_intentos'));
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_notificar $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_notificar(
  IN p_id_usuario BIGINT UNSIGNED, IN p_tipo VARCHAR(40), IN p_titulo VARCHAR(120),
  IN p_mensaje VARCHAR(300), IN p_enlace VARCHAR(300), IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Notificación dentro del sistema para un usuario'
BEGIN
  INSERT INTO notificacion (id_usuario, tipo, titulo, mensaje, enlace, id_pedido)
  VALUES (p_id_usuario, p_tipo, LEFT(p_titulo, 120), LEFT(p_mensaje, 300), p_enlace, p_id_pedido);
END $$

DROP PROCEDURE IF EXISTS spi_notificar_admins $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_notificar_admins(
  IN p_tipo VARCHAR(40), IN p_titulo VARCHAR(120), IN p_mensaje VARCHAR(300), IN p_enlace VARCHAR(300), IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Notificación para todos los administradores activos'
BEGIN
  INSERT INTO notificacion (id_usuario, tipo, titulo, mensaje, enlace, id_pedido)
  SELECT u.id_usuario, p_tipo, LEFT(p_titulo, 120), LEFT(p_mensaje, 300), p_enlace, p_id_pedido
    FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
   WHERE r.codigo = 'administrador' AND u.estado = 'activo';
END $$

-- ---------------------------------------------------------------------
-- B.1 Stock e insumos
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_mover_stock $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_mover_stock(
  IN p_id_variante BIGINT UNSIGNED, IN p_tipo VARCHAR(20), IN p_cantidad INT,
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_item_pedido BIGINT UNSIGNED, IN p_id_devolucion BIGINT UNSIGNED,
  IN p_motivo VARCHAR(200), OUT p_stock_actual INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Único punto que cambia el stock: bloquea la fila (sin sobreventa), valida, actualiza y escribe el kardex'
BEGIN
  DECLARE v_actual INT;
  DECLARE v_reservado INT;
  DECLARE v_sku VARCHAR(40);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;

  SELECT stock_actual, stock_reservado, sku INTO v_actual, v_reservado, v_sku
    FROM variante_producto WHERE id_variante = p_id_variante FOR UPDATE;
  IF v_nf THEN CALL spi_error(45022, 'La variante no existe'); END IF;
  IF p_cantidad IS NULL OR p_cantidad = 0 OR (p_tipo <> 'ajuste' AND p_cantidad < 0) THEN
    CALL spi_error(45006, 'Cantidad de stock inválida');
  END IF;

  CASE p_tipo
    WHEN 'ingreso' THEN
      SET v_actual = v_actual + p_cantidad;
    WHEN 'devolucion' THEN
      SET v_actual = v_actual + p_cantidad;
    WHEN 'reserva' THEN
      IF v_actual - v_reservado < p_cantidad THEN
        CALL spi_error(45001, CONCAT('Stock insuficiente para ', v_sku, ' (disponible: ', v_actual - v_reservado, ')'));
      END IF;
      SET v_reservado = v_reservado + p_cantidad;
    WHEN 'liberacion_reserva' THEN
      IF v_reservado < p_cantidad THEN
        CALL spi_error(45001, CONCAT('No hay tantas unidades reservadas de ', v_sku));
      END IF;
      SET v_reservado = v_reservado - p_cantidad;
    WHEN 'venta' THEN
      IF v_reservado < p_cantidad THEN
        CALL spi_error(45001, CONCAT('No hay tantas unidades reservadas de ', v_sku));
      END IF;
      SET v_actual = v_actual - p_cantidad;
      SET v_reservado = v_reservado - p_cantidad;
    WHEN 'ajuste' THEN
      IF v_actual + p_cantidad < v_reservado THEN
        CALL spi_error(45001, CONCAT('El ajuste dejaría ', v_sku, ' por debajo de lo reservado (', v_reservado, ')'));
      END IF;
      SET v_actual = v_actual + p_cantidad;
    ELSE
      CALL spi_error(45006, CONCAT('Tipo de movimiento de stock inválido: ', COALESCE(p_tipo, 'NULL')));
  END CASE;

  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE variante_producto SET stock_actual = v_actual, stock_reservado = v_reservado WHERE id_variante = p_id_variante;
  SET @wanka_ctx_interno = v_prev;

  INSERT INTO movimiento_stock (id_variante, tipo, cantidad, stock_actual_resultante, stock_reservado_resultante,
                                id_pedido, id_item_pedido, id_devolucion, id_usuario, motivo)
  VALUES (p_id_variante, p_tipo, p_cantidad, v_actual, v_reservado,
          p_id_pedido, p_id_item_pedido, p_id_devolucion, fn_actor(), p_motivo);
  SET p_stock_actual = v_actual;
END $$

DROP PROCEDURE IF EXISTS spi_mover_insumo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_mover_insumo(
  IN p_id_insumo BIGINT UNSIGNED, IN p_tipo VARCHAR(10), IN p_cantidad DECIMAL(12,3),
  IN p_id_pedido BIGINT UNSIGNED, IN p_motivo VARCHAR(200), OUT p_stock DECIMAL(12,3))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Único punto que cambia el stock de insumos (bloqueo de fila + kardex)'
BEGIN
  DECLARE v_stock DECIMAL(12,3);
  DECLARE v_minimo DECIMAL(12,3);
  DECLARE v_nombre VARCHAR(120);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;

  SELECT stock_actual, stock_minimo, nombre INTO v_stock, v_minimo, v_nombre FROM insumo WHERE id_insumo = p_id_insumo FOR UPDATE;
  IF v_nf THEN CALL spi_error(45022, 'El insumo no existe'); END IF;
  IF p_cantidad IS NULL OR p_cantidad = 0 OR (p_tipo <> 'ajuste' AND p_cantidad < 0) THEN
    CALL spi_error(45006, 'Cantidad de insumo inválida');
  END IF;
  CASE p_tipo
    WHEN 'ingreso' THEN SET v_stock = v_stock + p_cantidad;
    WHEN 'consumo' THEN SET v_stock = v_stock - p_cantidad;
    WHEN 'ajuste'  THEN SET v_stock = v_stock + p_cantidad;
    ELSE CALL spi_error(45006, 'Tipo de movimiento de insumo inválido');
  END CASE;
  IF v_stock < 0 THEN
    CALL spi_error(45001, CONCAT('Insumo insuficiente: ', v_nombre));
  END IF;

  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE insumo SET stock_actual = v_stock WHERE id_insumo = p_id_insumo;
  SET @wanka_ctx_interno = v_prev;

  INSERT INTO movimiento_insumo (id_insumo, tipo, cantidad, stock_resultante, id_pedido, id_usuario, motivo)
  VALUES (p_id_insumo, p_tipo, p_cantidad, v_stock, p_id_pedido, fn_actor(), p_motivo);

  IF p_tipo IN ('consumo','ajuste') AND v_stock <= v_minimo AND v_stock + p_cantidad * IF(p_tipo = 'consumo', 1, -1) > v_minimo THEN
    CALL spi_notificar_admins('insumo_bajo', CONCAT('Insumo bajo: ', v_nombre),
                              CONCAT('Quedan ', v_stock, ' (mínimo ', v_minimo, ')'), '/admin/insumos', NULL);
  END IF;
  SET p_stock = v_stock;
END $$

DROP PROCEDURE IF EXISTS spi_reservar_item $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_reservar_item(IN p_id_item_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Reserva el stock de un ítem de tipo stock y registra la reserva'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED;
  DECLARE v_variante BIGINT UNSIGNED;
  DECLARE v_cantidad INT UNSIGNED;
  DECLARE v_tipo VARCHAR(15);
  DECLARE v_stock INT;
  SELECT id_pedido, id_variante, cantidad, tipo_fabricacion INTO v_pedido, v_variante, v_cantidad, v_tipo
    FROM item_pedido WHERE id_item_pedido = p_id_item_pedido;
  IF v_tipo = 'stock' THEN
    CALL spi_mover_stock(v_variante, 'reserva', v_cantidad, v_pedido, p_id_item_pedido, NULL, 'Reserva por pedido', v_stock);
    INSERT INTO reserva_stock (id_pedido, id_item_pedido, id_variante, cantidad) VALUES (v_pedido, p_id_item_pedido, v_variante, v_cantidad);
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_cerrar_reservas_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_cerrar_reservas_pedido(
  IN p_id_pedido BIGINT UNSIGNED, IN p_accion VARCHAR(10), IN p_id_item BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Consume (venta) o libera las reservas activas del pedido (o de un ítem), bloqueando variantes en orden ascendente'
BEGIN
  DECLARE v_ult_variante BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_ult_reserva BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_reserva BIGINT UNSIGNED;
  DECLARE v_variante BIGINT UNSIGNED;
  DECLARE v_cantidad INT UNSIGNED;
  DECLARE v_item BIGINT UNSIGNED;
  DECLARE v_stock INT;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_reserva = NULL;
  IF p_accion NOT IN ('consumir','liberar') THEN CALL spi_error(45006, 'Acción de reserva inválida'); END IF;
  -- Recorre (variante, reserva) en orden ascendente: mismo orden de bloqueo en todas las sesiones y
  -- ninguna reserva queda colgada aunque la misma variante esté en varias líneas (cotizaciones)
  bucle: LOOP
    SET v_reserva = NULL;
    SELECT id_reserva, id_variante, cantidad, id_item_pedido INTO v_reserva, v_variante, v_cantidad, v_item
      FROM reserva_stock
     WHERE id_pedido = p_id_pedido AND estado = 'activa'
       AND (id_variante > v_ult_variante OR (id_variante = v_ult_variante AND id_reserva > v_ult_reserva))
       AND (p_id_item IS NULL OR id_item_pedido = p_id_item)
     ORDER BY id_variante, id_reserva LIMIT 1;
    IF v_reserva IS NULL THEN LEAVE bucle; END IF;
    CALL spi_mover_stock(v_variante, IF(p_accion = 'consumir', 'venta', 'liberacion_reserva'), v_cantidad,
                         p_id_pedido, v_item, NULL, p_motivo, v_stock);
    UPDATE reserva_stock SET estado = IF(p_accion = 'consumir', 'consumida', 'liberada'), cerrada_en = UTC_TIMESTAMP(3)
     WHERE id_reserva = v_reserva;
    SET v_ult_variante = v_variante;
    SET v_ult_reserva = v_reserva;
  END LOOP bucle;
END $$

DROP PROCEDURE IF EXISTS spi_reponer_stock_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_reponer_stock_pedido(IN p_id_pedido BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cancelación de un pedido ya confirmado: devuelve al stock las unidades vendidas no devueltas y marca los ítems como anulados'
BEGIN
  DECLARE v_ultima BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_item BIGINT UNSIGNED;
  DECLARE v_variante BIGINT UNSIGNED;
  DECLARE v_pendiente INT;
  DECLARE v_tipo VARCHAR(15);
  DECLARE v_stock INT;
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_item = NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  bucle: LOOP
    SET v_item = NULL;
    SELECT id_item_pedido, id_variante, cantidad - cantidad_devuelta, tipo_fabricacion
      INTO v_item, v_variante, v_pendiente, v_tipo
      FROM item_pedido
     WHERE id_pedido = p_id_pedido AND estado = 'vigente' AND cantidad > cantidad_devuelta
     ORDER BY COALESCE(id_variante, 0), id_item_pedido LIMIT 1;
    IF v_item IS NULL THEN LEAVE bucle; END IF;
    IF v_tipo = 'stock' THEN
      CALL spi_mover_stock(v_variante, 'devolucion', v_pendiente, p_id_pedido, v_item, NULL, p_motivo, v_stock);
    END IF;
    SET v_prev = @wanka_ctx_interno;
    SET @wanka_ctx_interno = fn_token_interno();
    UPDATE item_pedido SET cantidad_devuelta = cantidad WHERE id_item_pedido = v_item;
    SET @wanka_ctx_interno = v_prev;
  END LOOP bucle;
END $$

DROP PROCEDURE IF EXISTS spi_consumir_insumos_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_consumir_insumos_pedido(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Descuenta insumos según receta_producto × cantidades vigentes del pedido (una sola vez por pedido)'
BEGIN
  DECLARE v_ultimo BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_insumo BIGINT UNSIGNED;
  DECLARE v_total DECIMAL(12,3);
  DECLARE v_stock DECIMAL(12,3);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_insumo = NULL;
  IF EXISTS (SELECT 1 FROM movimiento_insumo WHERE id_pedido = p_id_pedido AND tipo = 'consumo') THEN
    CALL spi_error(45004, 'Los insumos de este pedido ya fueron descontados');
  END IF;
  bucle: LOOP
    SET v_insumo = NULL;
    SELECT r.id_insumo, SUM(r.cantidad_por_unidad * (i.cantidad - i.cantidad_devuelta)) INTO v_insumo, v_total
      FROM item_pedido i
      JOIN receta_producto r ON r.id_producto = i.id_producto AND r.activo = 1
     WHERE i.id_pedido = p_id_pedido AND i.estado = 'vigente' AND r.id_insumo > v_ultimo
     GROUP BY r.id_insumo
     ORDER BY r.id_insumo LIMIT 1;
    IF v_insumo IS NULL THEN LEAVE bucle; END IF;
    IF v_total > 0 THEN
      CALL spi_mover_insumo(v_insumo, 'consumo', v_total, p_id_pedido, 'Consumo por producción del pedido', v_stock);
    END IF;
    SET v_ultimo = v_insumo;
  END LOOP bucle;
END $$

-- ---------------------------------------------------------------------
-- B.2 Pedido: totales, estados y pagos derivados
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_recalcular_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_recalcular_pedido(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Subtotal = suma de ítems vigentes; total = subtotal − descuento + envío'
BEGIN
  DECLARE v_sub DECIMAL(12,2);
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  SELECT COALESCE(SUM(subtotal), 0) INTO v_sub FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente';
  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE pedido
     SET subtotal  = v_sub,
         descuento = LEAST(descuento, v_sub),
         total     = v_sub - LEAST(descuento, v_sub) + costo_envio
   WHERE id_pedido = p_id_pedido;
  SET @wanka_ctx_interno = v_prev;
END $$

DROP PROCEDURE IF EXISTS spi_cambiar_estado_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_cambiar_estado_pedido(
  IN p_id_pedido BIGINT UNSIGNED, IN p_estado_nuevo VARCHAR(20), IN p_comentario VARCHAR(200), IN p_es_sistema BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Valida la transición (tabla transicion_estado_pedido, tipo de entrega, permisos, saldo) y aplica sus efectos de stock/insumos'
BEGIN
  DECLARE v_estado VARCHAR(20);
  DECLARE v_entrega VARCHAR(10);
  DECLARE v_saldo DECIMAL(12,2);
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE v_aplicable VARCHAR(10);
  DECLARE v_automatica BOOLEAN;
  DECLARE v_cliente BOOLEAN;
  DECLARE v_saldo_cero BOOLEAN;
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;

  SELECT estado, tipo_entrega, saldo, id_usuario INTO v_estado, v_entrega, v_saldo, v_usuario
    FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_nf THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  IF v_estado = p_estado_nuevo THEN
    CALL spi_error(45002, CONCAT('El pedido ya está en estado ', p_estado_nuevo));
  END IF;

  SELECT tipo_entrega_aplicable, automatica, permitido_cliente, requiere_saldo_cero
    INTO v_aplicable, v_automatica, v_cliente, v_saldo_cero
    FROM transicion_estado_pedido WHERE estado_origen = v_estado AND estado_destino = p_estado_nuevo;
  IF v_nf THEN
    CALL spi_error(45002, CONCAT('Cambio de estado no permitido: ', v_estado, ' -> ', COALESCE(p_estado_nuevo, 'NULL')));
  END IF;
  IF v_aplicable <> 'ambos' AND v_aplicable <> v_entrega THEN
    CALL spi_error(45002, CONCAT('Ese cambio no aplica a pedidos con entrega por ', v_entrega));
  END IF;
  IF v_automatica = 1 AND NOT p_es_sistema THEN
    CALL spi_error(45002, CONCAT('El paso a ', p_estado_nuevo, ' lo hace el sistema (pago confirmado o devolución registrada)'));
  END IF;
  IF NOT p_es_sistema AND NOT fn_es_admin(fn_actor()) THEN
    IF v_cliente = 0 OR fn_actor() IS NULL OR fn_actor() <> v_usuario THEN
      CALL spi_error(45023, 'No tiene permiso para cambiar el estado de este pedido');
    END IF;
  END IF;
  IF v_saldo_cero = 1 AND fn_config_entero('bloquear_envio_con_saldo') = 1 AND v_saldo > 0 THEN
    CALL spi_error(45025, CONCAT('El pedido tiene saldo pendiente de S/ ', v_saldo, '; no puede pasar a ', p_estado_nuevo));
  END IF;
  IF v_estado = 'confirmado' AND p_estado_nuevo = 'en_preparacion'
     AND EXISTS (SELECT 1 FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente'
                    AND tipo_fabricacion IN ('a_pedido','personalizado') AND cantidad > cantidad_devuelta) THEN
    CALL spi_error(45002, 'El pedido tiene productos a pedido o personalizados: debe pasar por en_produccion');
  END IF;

  -- Efectos sobre el inventario
  IF p_estado_nuevo = 'confirmado' THEN
    CALL spi_cerrar_reservas_pedido(p_id_pedido, 'consumir', NULL, 'Venta: pedido confirmado');
  ELSEIF p_estado_nuevo = 'cancelado' THEN
    IF v_estado = 'pendiente_pago' THEN
      CALL spi_cerrar_reservas_pedido(p_id_pedido, 'liberar', NULL, 'Pedido cancelado sin pago');
    ELSE
      CALL spi_reponer_stock_pedido(p_id_pedido, 'Pedido cancelado: unidades devueltas al stock');
    END IF;
  ELSEIF p_estado_nuevo = 'en_produccion' AND fn_config_entero('descontar_insumos_en_produccion') = 1
         AND NOT EXISTS (SELECT 1 FROM movimiento_insumo WHERE id_pedido = p_id_pedido AND tipo = 'consumo') THEN
    CALL spi_consumir_insumos_pedido(p_id_pedido);   -- si ya se descontaron a mano, no se repite
  END IF;

  SET @wanka_comentario_estado = p_comentario;
  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE pedido
     SET estado             = p_estado_nuevo,
         confirmado_en      = IF(p_estado_nuevo = 'confirmado', UTC_TIMESTAMP(3), confirmado_en),
         entregado_en       = IF(p_estado_nuevo = 'entregado', UTC_TIMESTAMP(3), entregado_en),
         cancelado_en       = IF(p_estado_nuevo = 'cancelado', UTC_TIMESTAMP(3), cancelado_en),
         cancelado_por      = IF(p_estado_nuevo = 'cancelado', fn_actor(), cancelado_por),
         motivo_cancelacion = IF(p_estado_nuevo = 'cancelado', LEFT(COALESCE(p_comentario, 'Sin motivo'), 200), motivo_cancelacion)
   WHERE id_pedido = p_id_pedido;
  SET @wanka_ctx_interno = v_prev;
  SET @wanka_comentario_estado = NULL;
END $$

DROP PROCEDURE IF EXISTS spi_recalcular_pagos_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_recalcular_pagos_pedido(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Deriva monto_pagado, monto_reembolsado y estado_pago desde los pagos; confirma el pedido si se alcanzó el monto de la modalidad'
BEGIN
  DECLARE v_pagado DECIMAL(12,2);
  DECLARE v_reemb DECIMAL(12,2);
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_requerido DECIMAL(12,2);
  DECLARE v_estado VARCHAR(20);
  DECLARE v_devuelto DECIMAL(12,2);
  DECLARE v_ajustes DECIMAL(12,2);
  DECLARE v_ep VARCHAR(12);
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;

  SELECT total, estado, monto_devuelto, monto_ajustes INTO v_total, v_estado, v_devuelto, v_ajustes
    FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  -- FOR SHARE: lectura actual aunque la transacción tenga una instantánea vieja (REPEATABLE READ)
  SELECT COALESCE(SUM(monto), 0), COALESCE(SUM(monto_reembolsado), 0) INTO v_pagado, v_reemb
    FROM pago WHERE id_pedido = p_id_pedido AND aplicado_al_pedido = 1 AND estado IN ('confirmado','reembolsado') FOR SHARE;

  -- Lo que el cliente debe pagar descuenta lo devuelto y las rebajas posteriores (no dejan "saldo" pendiente)
  SET v_ep = CASE
               WHEN v_pagado - v_reemb = 0 AND v_reemb > 0 THEN 'reembolsado'
               WHEN v_pagado - v_reemb = 0 THEN 'pendiente'
               WHEN v_pagado - v_reemb < v_total - v_devuelto - v_ajustes THEN 'parcial'
               ELSE 'pagado'
             END;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE pedido SET monto_pagado = v_pagado, monto_reembolsado = v_reemb, estado_pago = v_ep WHERE id_pedido = p_id_pedido;
  SET @wanka_ctx_interno = v_prev;

  SELECT monto_requerido INTO v_requerido FROM pedido WHERE id_pedido = p_id_pedido;
  IF v_estado = 'pendiente_pago' AND v_requerido > 0 AND (v_pagado - v_reemb) >= v_requerido THEN
    CALL spi_cambiar_estado_pedido(p_id_pedido, 'confirmado', 'Pago requerido recibido', 1);
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_recalcular_ajustes_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_recalcular_ajustes_pedido(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Deriva monto_ajustes: notas de crédito vigentes que rebajan el precio (motivo no total y sin devolución de mercadería) + compensaciones reembolsadas sin nota de crédito'
BEGIN
  DECLARE v_nc DECIMAL(12,2);
  DECLARE v_comp DECIMAL(12,2);
  DECLARE v_total DECIMAL(12,2);
  DECLARE v_devuelto DECIMAL(12,2);
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  SELECT total, monto_devuelto INTO v_total, v_devuelto FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  SELECT COALESCE(SUM(c.total), 0) INTO v_nc
    FROM comprobante c JOIN motivo_nota_credito m ON m.codigo = c.codigo_motivo_nc
   WHERE c.id_pedido = p_id_pedido AND c.tipo = 'nota_credito' AND c.estado_sunat NOT IN ('rechazado','anulado')
     AND m.es_total = 0 AND m.repone_stock = 0 AND c.id_devolucion IS NULL
     FOR SHARE;
  SELECT COALESCE(SUM(monto), 0) INTO v_comp FROM reembolso
   WHERE id_pedido = p_id_pedido AND motivo = 'ajuste_precio' AND id_nota_credito IS NULL AND estado = 'completado'
     FOR SHARE;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE pedido SET monto_ajustes = LEAST(v_nc + v_comp, v_total - v_devuelto) WHERE id_pedido = p_id_pedido;
  SET @wanka_ctx_interno = v_prev;
END $$

-- #####################################################################
-- C. ACCESO Y SEGURIDAD
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_registrar_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_usuario(
  IN p_correo VARCHAR(254), IN p_hash_contrasena VARCHAR(255), IN p_nombres VARCHAR(80), IN p_apellidos VARCHAR(80),
  IN p_celular VARCHAR(20), IN p_version_politica VARCHAR(20), IN p_acepta_publicidad BOOLEAN,
  OUT p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registro de cliente: cuenta pendiente de verificación + historial de contraseña + consentimientos (versión, fecha, IP)'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT fn_normalizar_correo(p_correo);
  DECLARE v_rol TINYINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;

  IF NOT fn_correo_valido(v_correo) THEN CALL spi_error(45006, 'Correo con formato inválido'); END IF;
  IF p_version_politica IS NULL OR TRIM(p_version_politica) = '' THEN
    CALL spi_error(45006, 'Debe aceptar la política de privacidad vigente');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM usuario WHERE correo = v_correo) THEN
    CALL spi_error(45033, 'El correo ya está registrado');
  END IF;
  SELECT id_rol INTO v_rol FROM rol WHERE codigo = 'cliente';
  INSERT INTO usuario (id_rol, correo, hash_contrasena, nombres, apellidos, celular, contrasena_cambiada_en)
  VALUES (v_rol, v_correo, p_hash_contrasena, TRIM(p_nombres), TRIM(p_apellidos), fn_normalizar_telefono(p_celular), UTC_TIMESTAMP(3));
  SET p_id_usuario = LAST_INSERT_ID();
  INSERT INTO historial_contrasena (id_usuario, hash_contrasena, origen) VALUES (p_id_usuario, p_hash_contrasena, 'registro');
  INSERT INTO consentimiento_datos (id_usuario, finalidad, version_documento, otorgado, ip)
  VALUES (p_id_usuario, 'politica_privacidad', p_version_politica, 1, fn_ip_sesion()),
         (p_id_usuario, 'terminos_condiciones', p_version_politica, 1, fn_ip_sesion()),
         (p_id_usuario, 'publicidad', p_version_politica, COALESCE(p_acepta_publicidad, 0), fn_ip_sesion());
  CALL spi_auditar('usuario_registrado', 'usuario', p_id_usuario, p_id_usuario, JSON_OBJECT('correo', fn_enmascarar_correo(v_correo)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_crear_administrador_inicial $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_crear_administrador_inicial(
  IN p_correo VARCHAR(254), IN p_hash_contrasena VARCHAR(255), IN p_nombres VARCHAR(80), IN p_apellidos VARCHAR(80),
  OUT p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Crea el PRIMER administrador (solo si no existe ninguno). El hash lo genera Django (make_password)'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT fn_normalizar_correo(p_correo);
  DECLARE v_rol TINYINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_rol INTO v_rol FROM rol WHERE codigo = 'administrador' FOR UPDATE;
  IF EXISTS (SELECT 1 FROM usuario WHERE id_rol = v_rol) THEN
    CALL spi_error(45023, 'Ya existe un administrador: use sp_cambiar_rol_usuario desde una cuenta administradora');
  END IF;
  INSERT INTO usuario (id_rol, correo, hash_contrasena, nombres, apellidos, estado, correo_verificado_en, contrasena_cambiada_en)
  VALUES (v_rol, v_correo, p_hash_contrasena, TRIM(p_nombres), TRIM(p_apellidos), 'activo', UTC_TIMESTAMP(3), UTC_TIMESTAMP(3));
  SET p_id_usuario = LAST_INSERT_ID();
  INSERT INTO historial_contrasena (id_usuario, hash_contrasena, origen) VALUES (p_id_usuario, p_hash_contrasena, 'administrador');
  CALL spi_auditar('administrador_inicial_creado', 'usuario', p_id_usuario, p_id_usuario, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cambiar_rol_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cambiar_rol_usuario(IN p_id_usuario BIGINT UNSIGNED, IN p_codigo_rol VARCHAR(20))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cambia el rol (solo administrador). No permite dejar el sistema sin administradores'
BEGIN
  DECLARE v_rol_nuevo TINYINT UNSIGNED DEFAULT NULL;
  DECLARE v_rol_actual VARCHAR(20);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_rol_nuevo = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    CALL spi_validar_admin();
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT id_rol INTO v_rol_nuevo FROM rol WHERE codigo = p_codigo_rol AND activo = 1;
    IF v_rol_nuevo IS NULL THEN CALL spi_error(45006, 'Rol inexistente'); END IF;
    SELECT r.codigo INTO v_rol_actual FROM usuario u JOIN rol r ON r.id_rol = u.id_rol WHERE u.id_usuario = p_id_usuario FOR UPDATE;
    IF v_rol_actual IS NULL THEN CALL spi_error(45022, 'El usuario no existe'); END IF;
    IF v_rol_actual = 'administrador' AND p_codigo_rol <> 'administrador'
       AND (SELECT COUNT(*) FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
             WHERE r.codigo = 'administrador' AND u.estado = 'activo' AND u.id_usuario <> p_id_usuario) = 0 THEN
      CALL spi_error(45023, 'No se puede quitar el rol al último administrador activo');
    END IF;
    UPDATE usuario SET id_rol = v_rol_nuevo WHERE id_usuario = p_id_usuario;
    CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'revocada');   -- los permisos nuevos rigen desde el próximo inicio de sesión
    CALL spi_auditar('usuario_rol_cambiado', 'usuario', p_id_usuario, p_id_usuario,
                     JSON_OBJECT('de', v_rol_actual, 'a', p_codigo_rol), 'procedimiento');
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS spi_registrar_fallo_acceso $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_registrar_fallo_acceso(
  IN p_id_usuario BIGINT UNSIGNED, IN p_que VARCHAR(30), OUT p_bloqueado_hasta DATETIME(3))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cuenta un fallo de contraseña, segundo factor o código de respaldo; al llegar al tope bloquea la cuenta (la fila de usuario debe estar bloqueada FOR UPDATE)'
BEGIN
  DECLARE v_intentos INT;
  DECLARE v_max INT DEFAULT fn_config_entero('login_max_intentos');
  DECLARE v_min INT DEFAULT fn_config_entero('login_minutos_bloqueo');
  SET p_bloqueado_hasta = NULL;
  SELECT intentos_fallidos + 1 INTO v_intentos FROM usuario WHERE id_usuario = p_id_usuario FOR UPDATE;
  IF v_intentos >= v_max THEN
    SET p_bloqueado_hasta = UTC_TIMESTAMP(3) + INTERVAL v_min MINUTE;
    UPDATE usuario SET intentos_fallidos = 0, bloqueado_hasta = p_bloqueado_hasta WHERE id_usuario = p_id_usuario;
    CALL spi_auditar('cuenta_bloqueada', 'usuario', p_id_usuario, p_id_usuario,
                     JSON_OBJECT('intentos', v_intentos, 'por', p_que, 'hasta_utc', p_bloqueado_hasta), 'procedimiento');
  ELSE
    UPDATE usuario SET intentos_fallidos = v_intentos WHERE id_usuario = p_id_usuario;
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_intento_acceso $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_intento_acceso(
  IN p_correo VARCHAR(254), IN p_contrasena_correcta BOOLEAN, IN p_user_agent VARCHAR(255),
  OUT p_resultado VARCHAR(30), OUT p_id_usuario BIGINT UNSIGNED, OUT p_bloqueado_hasta DATETIME(3), OUT p_requiere_2fa BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra el intento de login (Django verifica la contraseña). 5 fallos = bloqueo 15 min; demasiados fallos desde una IP = ip_bloqueada. No lanza error: devuelve el resultado'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT fn_normalizar_correo(p_correo);
  DECLARE v_estado VARCHAR(30);
  DECLARE v_bloqueo DATETIME(3);
  DECLARE v_intentos INT;
  DECLARE v_req2fa BOOLEAN;
  DECLARE v_2fa_activo BOOLEAN;
  DECLARE v_ip VARBINARY(16) DEFAULT fn_ip_sesion();
  DECLARE v_fallos_ip INT DEFAULT 0;
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    SET p_requiere_2fa = 0;
    SET p_bloqueado_hasta = NULL;
    SET p_id_usuario = NULL;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    -- Límite por IP (prueba de contraseñas contra muchas cuentas): fallos en los últimos 15 minutos.
    -- Sin IP conocida todas las solicitudes comparten un mismo cupo (falla cerrado)
    SELECT COUNT(*) INTO v_fallos_ip FROM intento_acceso
     WHERE ip <=> v_ip AND exitoso = 0 AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 15 MINUTE
       AND resultado IN ('credenciales_invalidas','usuario_inexistente','bloqueada_ahora','segundo_factor_fallido');
    SELECT u.id_usuario, u.estado, u.bloqueado_hasta, u.intentos_fallidos, r.requiere_2fa
      INTO p_id_usuario, v_estado, v_bloqueo, v_intentos, v_req2fa
      FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
     WHERE u.correo = v_correo FOR UPDATE;

    IF v_fallos_ip >= fn_config_entero('login_max_fallos_ip_15min') THEN
      SET p_resultado = 'ip_bloqueada';
    ELSEIF v_nf THEN
      SET p_id_usuario = NULL;
      SET p_resultado = 'usuario_inexistente';
    ELSEIF v_estado = 'inhabilitado' THEN
      SET p_resultado = 'cuenta_inhabilitada';
    ELSEIF v_bloqueo IS NOT NULL AND v_bloqueo > UTC_TIMESTAMP(3) THEN
      SET p_resultado = 'cuenta_bloqueada';
      SET p_bloqueado_hasta = v_bloqueo;
    ELSEIF NOT COALESCE(p_contrasena_correcta, 0) THEN   -- NULL cuenta como fallo, nunca como acierto
      CALL spi_registrar_fallo_acceso(p_id_usuario, 'contrasena', p_bloqueado_hasta);
      SET p_resultado = IF(p_bloqueado_hasta IS NULL, 'credenciales_invalidas', 'bloqueada_ahora');
    ELSEIF v_estado = 'pendiente_verificacion' THEN
      SET p_resultado = 'correo_no_verificado';
    ELSE
      SELECT COALESCE(MAX(activo), 0) INTO v_2fa_activo FROM autenticacion_2fa WHERE id_usuario = p_id_usuario;
      SET p_requiere_2fa = (v_req2fa = 1 OR v_2fa_activo = 1);
      IF NOT p_requiere_2fa THEN
        -- Con segundo factor el contador se reinicia recién cuando el 2FA da 'ok'
        UPDATE usuario SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso_en = UTC_TIMESTAMP(3)
         WHERE id_usuario = p_id_usuario;
      END IF;
      SET p_resultado = IF(p_requiere_2fa, 'requiere_2fa', 'ok');
    END IF;

    INSERT INTO intento_acceso (correo_intentado, id_usuario, ip, user_agent, exitoso, resultado)
    VALUES (LEFT(v_correo, 254), p_id_usuario, v_ip, LEFT(p_user_agent, 255),
            p_resultado IN ('ok','requiere_2fa'), p_resultado);
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_segundo_factor $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_segundo_factor(
  IN p_id_usuario BIGINT UNSIGNED, IN p_paso_totp BIGINT UNSIGNED, IN p_correcto BOOLEAN, IN p_user_agent VARCHAR(255),
  OUT p_resultado VARCHAR(30))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Resultado del 2FA (Django valida el TOTP). Respeta el bloqueo, cuenta los fallos para bloquear la cuenta y evita reutilizar el mismo paso TOTP'
BEGIN
  DECLARE v_ultimo BIGINT UNSIGNED;
  DECLARE v_metodo VARCHAR(10);
  DECLARE v_correo VARCHAR(254);
  DECLARE v_estado VARCHAR(30);
  DECLARE v_bloqueo DATETIME(3);
  DECLARE v_hasta DATETIME(3);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT correo, estado, bloqueado_hasta INTO v_correo, v_estado, v_bloqueo FROM usuario WHERE id_usuario = p_id_usuario FOR UPDATE;
    IF v_nf THEN CALL spi_error(45022, 'El usuario no existe'); END IF;
    SELECT ultimo_paso_totp, metodo INTO v_ultimo, v_metodo FROM autenticacion_2fa WHERE id_usuario = p_id_usuario AND activo = 1 FOR UPDATE;
    IF v_estado = 'inhabilitado' THEN
      SET p_resultado = 'cuenta_inhabilitada';
    ELSEIF v_estado <> 'activo' THEN
      SET p_resultado = 'correo_no_verificado';
    ELSEIF v_bloqueo IS NOT NULL AND v_bloqueo > UTC_TIMESTAMP(3) THEN
      SET p_resultado = 'cuenta_bloqueada';
    ELSEIF v_nf THEN
      SET v_nf = 0;
      SET p_resultado = 'sin_2fa_configurado';
    ELSEIF COALESCE(p_correcto, 0) AND v_metodo = 'totp' AND p_paso_totp IS NULL THEN
      CALL spi_error(45006, 'Falta el paso TOTP validado (evita reutilizar el mismo código)');
    ELSEIF NOT COALESCE(p_correcto, 0) OR (p_paso_totp IS NOT NULL AND v_ultimo IS NOT NULL AND p_paso_totp <= v_ultimo) THEN
      CALL spi_registrar_fallo_acceso(p_id_usuario, 'segundo_factor', v_hasta);
      SET p_resultado = IF(v_hasta IS NULL, 'segundo_factor_fallido', 'bloqueada_ahora');
    ELSE
      UPDATE autenticacion_2fa SET ultimo_paso_totp = COALESCE(p_paso_totp, ultimo_paso_totp), ultimo_uso_en = UTC_TIMESTAMP(3)
       WHERE id_usuario = p_id_usuario;
      UPDATE usuario SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario;
      SET p_resultado = 'ok';
    END IF;
    INSERT INTO intento_acceso (correo_intentado, id_usuario, ip, user_agent, exitoso, resultado)
    VALUES (v_correo, p_id_usuario, fn_ip_sesion(), LEFT(p_user_agent, 255), p_resultado = 'ok',
            IF(p_resultado = 'sin_2fa_configurado', 'segundo_factor_fallido', p_resultado));
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_abrir_sesion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_abrir_sesion(
  IN p_id_usuario BIGINT UNSIGNED, IN p_token_hash CHAR(64), IN p_user_agent VARCHAR(255), IN p_minutos INT,
  OUT p_id_sesion BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra una sesión (solo el SHA-256 del token)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_minutos IS NULL OR p_minutos < 5 OR p_minutos > 43200 THEN CALL spi_error(45006, 'Duración de sesión inválida'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND estado = 'activo') THEN
    CALL spi_error(45021, 'La cuenta no está activa');
  END IF;
  IF EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND bloqueado_hasta > UTC_TIMESTAMP(3)) THEN
    CALL spi_error(45021, 'La cuenta está bloqueada temporalmente por intentos fallidos');
  END IF;
  INSERT INTO sesion (id_usuario, token_hash, ip, user_agent, expira_en)
  VALUES (p_id_usuario, LOWER(p_token_hash), fn_ip_sesion(), LEFT(p_user_agent, 255), UTC_TIMESTAMP(3) + INTERVAL p_minutos MINUTE);
  SET p_id_sesion = LAST_INSERT_ID();
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cerrar_sesion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cerrar_sesion(IN p_token_hash CHAR(64), IN p_motivo VARCHAR(20))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cierra una sesión por su hash'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE sesion SET cerrada_en = UTC_TIMESTAMP(3), motivo_cierre = COALESCE(p_motivo, 'logout')
   WHERE token_hash = LOWER(p_token_hash) AND cerrada_en IS NULL;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS spi_cerrar_sesiones_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_cerrar_sesiones_usuario(IN p_id_usuario BIGINT UNSIGNED, IN p_motivo VARCHAR(20))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cierra todas las sesiones abiertas de un usuario'
BEGIN
  UPDATE sesion SET cerrada_en = UTC_TIMESTAMP(3), motivo_cierre = p_motivo
   WHERE id_usuario = p_id_usuario AND cerrada_en IS NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cerrar_sesiones_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cerrar_sesiones_usuario(IN p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cierra todas las sesiones del usuario (él mismo o un administrador)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'revocada');
  CALL spi_auditar('sesiones_revocadas', 'usuario', p_id_usuario, p_id_usuario, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- ---------------------------------------------------------------------
-- C.1 Códigos de verificación por correo (§2.7)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_generar_codigo_verificacion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_generar_codigo_verificacion(
  IN p_id_usuario BIGINT UNSIGNED, IN p_correo_destino VARCHAR(254), IN p_proposito VARCHAR(30), IN p_pepper VARCHAR(200),
  OUT p_codigo VARCHAR(9), OUT p_expira_en DATETIME(3), OUT p_id_codigo BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Genera un código aleatorio (RANDOM_BYTES), guarda solo su hash, vence en <= 5 min, reemplaza al anterior. Cupos: por correo y propósito (hora y día) y por IP. Salvo cambiar_correo, solo se envía al correo de la cuenta'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT fn_normalizar_correo(p_correo_destino);
  DECLARE v_id_usuario BIGINT UNSIGNED DEFAULT p_id_usuario;
  DECLARE v_correo_cuenta VARCHAR(254) DEFAULT NULL;
  DECLARE v_ip VARBINARY(16) DEFAULT fn_ip_sesion();
  DECLARE v_max_dia INT;
  DECLARE v_max_ip INT;
  DECLARE v_dia INT;
  DECLARE v_por_ip INT;
  DECLARE v_minutos INT;
  DECLARE v_digitos INT;
  DECLARE v_max_hora INT;
  DECLARE v_max_intentos INT;
  DECLARE v_recientes INT;
  DECLARE v_hash CHAR(64);
  DECLARE v_duplicado BOOLEAN;
  DECLARE v_vueltas INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;

  IF p_pepper IS NULL OR CHAR_LENGTH(p_pepper) < 16 THEN
    CALL spi_error(45006, 'Pepper ausente o débil (mínimo 16 caracteres): configúrelo en Django');
  END IF;
  IF NOT fn_correo_valido(v_correo) THEN CALL spi_error(45006, 'Correo de destino inválido'); END IF;
  IF p_proposito NOT IN ('verificar_correo','iniciar_sesion','recuperar_contrasena','cambiar_contrasena','cambiar_correo','segundo_factor') THEN
    CALL spi_error(45006, 'Propósito de código inválido');
  END IF;

  SET v_minutos     = LEAST(fn_config_entero('codigo_verificacion_minutos'), 5);
  SET v_digitos     = fn_config_entero('codigo_verificacion_digitos');
  SET v_max_hora    = fn_config_entero('codigo_verificacion_max_por_hora');
  SET v_max_intentos = LEAST(fn_config_entero('codigo_verificacion_max_intentos'), 5);
  SET v_max_hora    = LEAST(v_max_hora, 5);   -- §2.7: máximo 5 por hora
  SET v_max_dia     = fn_config_entero('codigo_verificacion_max_por_dia');
  SET v_max_ip      = fn_config_entero('codigo_verificacion_max_por_ip_hora');
  IF p_proposito IN ('cambiar_correo','cambiar_contrasena') THEN
    IF p_id_usuario IS NULL THEN CALL spi_error(45006, 'Ese código se pide desde la cuenta iniciada'); END IF;
    CALL spi_validar_dueno_o_admin(p_id_usuario);
  END IF;

  SET @wanka_ctx_interno = fn_token_interno();
  -- Búsquedas de la cuenta FUERA de la transacción: así la instantánea nace después del bloqueo de frecuencia
  -- y el conteo del cupo ve los códigos que otra sesión acaba de crear
  IF p_id_usuario IS NOT NULL THEN
    SELECT correo INTO v_correo_cuenta FROM usuario WHERE id_usuario = p_id_usuario AND estado <> 'inhabilitado';
    IF v_correo_cuenta IS NULL THEN CALL spi_error(45021, 'La cuenta no existe o está inhabilitada'); END IF;
    -- El código va siempre al correo de la cuenta (salvo para verificar un correo nuevo)
    IF p_proposito <> 'cambiar_correo' AND v_correo <> v_correo_cuenta THEN
      CALL spi_error(45006, 'El código solo se envía al correo registrado en la cuenta');
    END IF;
  ELSE
    -- Flujo anónimo (recuperar contraseña, verificar correo...): el dueño se deduce del correo
    SELECT id_usuario INTO v_id_usuario FROM usuario WHERE correo = v_correo AND estado <> 'inhabilitado';
  END IF;
  START TRANSACTION;
  -- Serializa solicitudes simultáneas del mismo correo (primera sentencia de la transacción)
  CALL spi_bloquear_frecuencia('codigo_correo', v_correo);
  -- Cupo por correo y propósito: un abuso con "recuperar contraseña" no bloquea el segundo factor del titular
  SELECT COUNT(*), COALESCE(SUM(creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 HOUR), 0) INTO v_dia, v_recientes
    FROM codigo_verificacion
   WHERE correo_destino = v_correo AND proposito = p_proposito AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 DAY;
  -- Cupo por IP (sin IP conocida todas comparten el mismo cupo: falla cerrado)
  SELECT COUNT(*) INTO v_por_ip FROM codigo_verificacion WHERE ip <=> v_ip AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 HOUR;
  IF v_recientes >= v_max_hora OR v_dia >= v_max_dia OR v_por_ip >= v_max_ip THEN
    CALL spi_auditar('codigo_limite_excedido', 'codigo_verificacion', NULL, v_id_usuario,
                     JSON_OBJECT('correo', fn_enmascarar_correo(v_correo), 'proposito', p_proposito,
                                 'hora', v_recientes, 'dia', v_dia, 'ip', v_por_ip), 'procedimiento');
    COMMIT;  -- el bloqueo queda registrado aunque se informe el error
    SET @wanka_ctx_interno = NULL;
    CALL spi_error(45010, IF(v_dia >= v_max_dia, 'Demasiadas solicitudes de código hoy. Intente mañana',
                             CONCAT('Demasiadas solicitudes de código. Intente nuevamente en una hora (máximo ', v_max_hora, ')')));
  END IF;

  -- El código anterior del mismo propósito deja de servir
  UPDATE codigo_verificacion SET estado = 'reemplazado', cerrado_en = UTC_TIMESTAMP(3)
   WHERE correo_destino = v_correo AND proposito = p_proposito AND estado = 'activo';

  -- Genera hasta que no choque con otro código vigente (índice único sobre el hash vigente)
  generar: LOOP
    SET v_vueltas = v_vueltas + 1;
    IF v_vueltas > 25 THEN CALL spi_error(45034, 'No se pudo generar un código único, reintente'); END IF;
    SET p_codigo = fn_generar_digitos(v_digitos);
    SET v_hash = fn_hash_codigo(p_pepper, p_codigo);
    SET v_duplicado = 0;
    BEGIN
      DECLARE CONTINUE HANDLER FOR 1062 SET v_duplicado = 1;
      INSERT INTO codigo_verificacion (id_usuario, correo_destino, proposito, codigo_hash, max_intentos, ip, creado_en, expira_en)
      VALUES (v_id_usuario, v_correo, p_proposito, v_hash, v_max_intentos, v_ip,
              UTC_TIMESTAMP(3), UTC_TIMESTAMP(3) + INTERVAL v_minutos MINUTE);
    END;
    IF NOT v_duplicado THEN LEAVE generar; END IF;
  END LOOP generar;

  SET p_id_codigo = LAST_INSERT_ID();
  SELECT expira_en INTO p_expira_en FROM codigo_verificacion WHERE id_codigo = p_id_codigo;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_verificar_codigo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_verificar_codigo(
  IN p_correo_destino VARCHAR(254), IN p_proposito VARCHAR(30), IN p_codigo VARCHAR(12), IN p_pepper VARCHAR(200),
  OUT p_resultado VARCHAR(20), OUT p_intentos_restantes TINYINT, OUT p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Verifica un código: vencido / usado / bloqueado / inválido / ok. El vencimiento se valida aquí (no solo en la app). Persiste los intentos'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT fn_normalizar_correo(p_correo_destino);
  DECLARE v_id BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_hash CHAR(64);
  DECLARE v_estado VARCHAR(20);
  DECLARE v_intentos INT;
  DECLARE v_max INT;
  DECLARE v_expira DATETIME(3);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_id = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    SET p_intentos_restantes = 0;
    SET p_id_usuario = NULL;
    IF p_pepper IS NULL OR CHAR_LENGTH(p_pepper) < 16 THEN CALL spi_error(45006, 'Pepper ausente o débil'); END IF;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    -- Último código emitido para ese correo y propósito
    SELECT id_codigo, codigo_hash, estado, intentos, max_intentos, expira_en, id_usuario
      INTO v_id, v_hash, v_estado, v_intentos, v_max, v_expira, p_id_usuario
      FROM codigo_verificacion
     WHERE correo_destino = v_correo AND proposito = p_proposito
     ORDER BY id_codigo DESC LIMIT 1
       FOR UPDATE;

    IF v_id IS NULL THEN
      SET p_resultado = 'no_existe';
    ELSEIF v_estado = 'usado' THEN
      SET p_resultado = 'usado';
    ELSEIF v_estado = 'bloqueado' THEN
      SET p_resultado = 'bloqueado';
    ELSEIF v_estado IN ('expirado','reemplazado') OR v_expira <= UTC_TIMESTAMP(3) THEN
      IF v_estado = 'activo' THEN
        UPDATE codigo_verificacion SET estado = 'expirado', cerrado_en = UTC_TIMESTAMP(3) WHERE id_codigo = v_id;
      END IF;
      SET p_resultado = 'vencido';
    ELSEIF v_hash = fn_hash_codigo(p_pepper, TRIM(p_codigo)) THEN
      UPDATE codigo_verificacion SET estado = 'usado', usado_en = UTC_TIMESTAMP(3) WHERE id_codigo = v_id;
      SET p_resultado = 'ok';
      SET p_intentos_restantes = v_max - v_intentos;
      IF p_proposito = 'verificar_correo' AND p_id_usuario IS NOT NULL THEN
        UPDATE usuario SET correo_verificado_en = COALESCE(correo_verificado_en, UTC_TIMESTAMP(3)),
                           estado = IF(estado = 'pendiente_verificacion', 'activo', estado)
         WHERE id_usuario = p_id_usuario;
      END IF;
    ELSE
      SET v_intentos = v_intentos + 1;
      IF v_intentos >= v_max THEN
        UPDATE codigo_verificacion SET intentos = v_intentos, estado = 'bloqueado', cerrado_en = UTC_TIMESTAMP(3) WHERE id_codigo = v_id;
        SET p_resultado = 'bloqueado';
        CALL spi_auditar('codigo_bloqueado', 'codigo_verificacion', v_id, p_id_usuario,
                         JSON_OBJECT('proposito', p_proposito, 'intentos', v_intentos), 'procedimiento');
      ELSE
        UPDATE codigo_verificacion SET intentos = v_intentos WHERE id_codigo = v_id;
        SET p_resultado = 'invalido';
        SET p_intentos_restantes = v_max - v_intentos;
      END IF;
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_cambiar_contrasena $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cambiar_contrasena(
  IN p_id_usuario BIGINT UNSIGNED, IN p_nuevo_hash VARCHAR(255), IN p_origen VARCHAR(15))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cambia la contraseña (hash de Django). En "recuperacion" exige un código de recuperación enviado al correo de la cuenta y usado en los últimos 10 min. Cierra sesiones'
BEGIN
  DECLARE v_cambio DATETIME(3);
  DECLARE v_correo VARCHAR(254);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; SET @wanka_origen_contrasena = NULL; RESIGNAL; END;
    IF p_origen NOT IN ('cambio','recuperacion','administrador') THEN CALL spi_error(45006, 'Origen de cambio inválido'); END IF;
    IF p_origen = 'cambio' THEN CALL spi_validar_dueno_o_admin(p_id_usuario); END IF;
    IF p_origen = 'administrador' THEN CALL spi_validar_admin(); END IF;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT contrasena_cambiada_en, correo INTO v_cambio, v_correo FROM usuario WHERE id_usuario = p_id_usuario AND estado <> 'inhabilitado' FOR UPDATE;
    IF v_nf THEN CALL spi_error(45021, 'La cuenta no existe o está inhabilitada'); END IF;
    IF p_origen = 'recuperacion' AND NOT EXISTS (
         SELECT 1 FROM codigo_verificacion
          WHERE id_usuario = p_id_usuario AND correo_destino = v_correo AND proposito = 'recuperar_contrasena' AND estado = 'usado'
            AND usado_en > UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE
            AND (v_cambio IS NULL OR usado_en > v_cambio)) THEN
      CALL spi_error(45011, 'Para recuperar la contraseña primero verifique el código enviado a su correo');
    END IF;
    IF EXISTS (SELECT 1 FROM (SELECT hash_contrasena FROM historial_contrasena WHERE id_usuario = p_id_usuario
                               ORDER BY id_historial DESC LIMIT 3) h WHERE h.hash_contrasena = p_nuevo_hash) THEN
      CALL spi_error(45024, 'No puede reutilizar una de sus últimas 3 contraseñas');
    END IF;
    SET @wanka_origen_contrasena = p_origen;
    UPDATE usuario SET hash_contrasena = p_nuevo_hash, intentos_fallidos = 0, bloqueado_hasta = NULL WHERE id_usuario = p_id_usuario;
    SET @wanka_origen_contrasena = NULL;
    CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'cambio_contrasena');
    CALL spi_auditar('contrasena_cambiada', 'usuario', p_id_usuario, p_id_usuario, JSON_OBJECT('origen', p_origen), 'procedimiento');
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

-- ---------------------------------------------------------------------
-- C.2 Segundo factor
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_configurar_2fa $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_configurar_2fa(
  IN p_id_usuario BIGINT UNSIGNED, IN p_metodo VARCHAR(10), IN p_secreto_cifrado VARBINARY(512))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Guarda el secreto TOTP YA CIFRADO por la app. Si ya hay un 2FA activo, el nuevo queda PENDIENTE (el actual sigue protegiendo la cuenta) hasta sp_confirmar_2fa. Administradores: solo TOTP'
BEGIN
  DECLARE v_activo BOOLEAN DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF p_metodo IS NULL OR p_metodo NOT IN ('totp','correo') THEN CALL spi_error(45006, 'Método de segundo factor inválido: totp o correo'); END IF;
  IF p_metodo = 'totp' AND p_secreto_cifrado IS NULL THEN CALL spi_error(45006, 'Falta el secreto TOTP cifrado'); END IF;
  IF p_metodo <> 'totp' AND fn_es_admin(p_id_usuario) THEN
    CALL spi_error(45023, 'Los administradores usan una app autenticadora (TOTP) como segundo factor');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT activo INTO v_activo FROM autenticacion_2fa WHERE id_usuario = p_id_usuario FOR UPDATE;
  IF COALESCE(v_activo, 0) = 1 THEN
    UPDATE autenticacion_2fa SET metodo_pendiente = p_metodo, secreto_pendiente_cifrado = p_secreto_cifrado, pendiente_desde = UTC_TIMESTAMP(3)
     WHERE id_usuario = p_id_usuario;
  ELSE
    INSERT INTO autenticacion_2fa (id_usuario, metodo, secreto_cifrado, activo)
    VALUES (p_id_usuario, p_metodo, p_secreto_cifrado, 0) AS nuevo
    -- COMPAT-MARIADB: alias de fila "AS nuevo" no existe; usar VALUES(columna)
    ON DUPLICATE KEY UPDATE metodo = nuevo.metodo, secreto_cifrado = nuevo.secreto_cifrado, activo = 0,
                            verificado_en = NULL, ultimo_paso_totp = NULL, desactivado_en = NULL,
                            metodo_pendiente = NULL, secreto_pendiente_cifrado = NULL, pendiente_desde = NULL;
  END IF;
  CALL spi_auditar('2fa_configurado', 'autenticacion_2fa', p_id_usuario, p_id_usuario,
                   JSON_OBJECT('metodo', p_metodo, 'pendiente', COALESCE(v_activo, 0) = 1), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_confirmar_2fa $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_confirmar_2fa(IN p_id_usuario BIGINT UNSIGNED, IN p_paso_totp BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Activa el 2FA (o la reconfiguración pendiente) después de que la app validó el primer código. Al reconfigurar invalida los códigos de respaldo anteriores'
BEGIN
  DECLARE v_activo BOOLEAN DEFAULT NULL;
  DECLARE v_metodo VARCHAR(10);
  DECLARE v_pendiente VARCHAR(10);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT activo, metodo, metodo_pendiente INTO v_activo, v_metodo, v_pendiente FROM autenticacion_2fa WHERE id_usuario = p_id_usuario FOR UPDATE;
  IF v_activo IS NULL OR (v_activo = 1 AND v_pendiente IS NULL) THEN
    CALL spi_error(45022, 'Primero configure el segundo factor');
  END IF;
  IF COALESCE(v_pendiente, v_metodo) = 'totp' AND p_paso_totp IS NULL THEN CALL spi_error(45006, 'Falta el paso TOTP del primer código'); END IF;
  IF COALESCE(v_pendiente, v_metodo) <> 'totp' AND fn_es_admin(p_id_usuario) THEN
    CALL spi_error(45023, 'Los administradores usan una app autenticadora (TOTP) como segundo factor');
  END IF;
  IF v_activo = 1 THEN
    -- Reconfiguración: el secreto nuevo reemplaza al anterior y el lote de respaldo anterior deja de servir
    UPDATE autenticacion_2fa
       SET metodo = metodo_pendiente, secreto_cifrado = secreto_pendiente_cifrado, verificado_en = UTC_TIMESTAMP(3),
           ultimo_paso_totp = p_paso_totp, metodo_pendiente = NULL, secreto_pendiente_cifrado = NULL, pendiente_desde = NULL
     WHERE id_usuario = p_id_usuario;
    UPDATE codigo_respaldo_2fa SET invalidado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND usado_en IS NULL AND invalidado_en IS NULL;
  ELSE
    UPDATE autenticacion_2fa SET activo = 1, verificado_en = UTC_TIMESTAMP(3), ultimo_paso_totp = p_paso_totp, desactivado_en = NULL
     WHERE id_usuario = p_id_usuario;
  END IF;
  CALL spi_auditar('2fa_activado', 'autenticacion_2fa', p_id_usuario, p_id_usuario,
                   JSON_OBJECT('reconfiguracion', v_activo = 1), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_desactivar_2fa $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_desactivar_2fa(IN p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Desactiva el 2FA. Un administrador no puede desactivar el suyo (es obligatorio); otro administrador sí puede restablecerlo'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF fn_actor() = p_id_usuario AND fn_es_admin(p_id_usuario) THEN
    CALL spi_error(45023, 'El segundo factor es obligatorio para administradores');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE autenticacion_2fa SET activo = 0, desactivado_en = UTC_TIMESTAMP(3),
                               metodo_pendiente = NULL, secreto_pendiente_cifrado = NULL, pendiente_desde = NULL
   WHERE id_usuario = p_id_usuario;
  UPDATE codigo_respaldo_2fa SET invalidado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND usado_en IS NULL AND invalidado_en IS NULL;
  CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'revocada');
  CALL spi_auditar('2fa_desactivado', 'autenticacion_2fa', p_id_usuario, p_id_usuario, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_generar_codigos_respaldo_2fa $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_generar_codigos_respaldo_2fa(
  IN p_id_usuario BIGINT UNSIGNED, IN p_pepper VARCHAR(200), IN p_cantidad TINYINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Genera códigos de respaldo (se muestran UNA vez en el resultado; se guarda solo el hash) e invalida el lote anterior'
BEGIN
  DECLARE v_lote SMALLINT UNSIGNED;
  DECLARE v_i INT DEFAULT 0;
  DECLARE v_codigo VARCHAR(9);
  DECLARE v_dup BOOLEAN;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF p_pepper IS NULL OR CHAR_LENGTH(p_pepper) < 16 THEN CALL spi_error(45006, 'Pepper ausente o débil'); END IF;
  IF p_cantidad IS NULL OR p_cantidad NOT BETWEEN 5 AND 20 THEN CALL spi_error(45006, 'Cantidad de códigos inválida (5 a 20)'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_usuario INTO @wanka_x FROM usuario WHERE id_usuario = p_id_usuario FOR UPDATE;
  SELECT COALESCE(MAX(lote), 0) + 1 INTO v_lote FROM codigo_respaldo_2fa WHERE id_usuario = p_id_usuario;
  UPDATE codigo_respaldo_2fa SET invalidado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND usado_en IS NULL AND invalidado_en IS NULL;
  DROP TEMPORARY TABLE IF EXISTS tmp_codigos_respaldo;
  CREATE TEMPORARY TABLE tmp_codigos_respaldo (codigo VARCHAR(9) NOT NULL);
  WHILE v_i < p_cantidad DO
    SET v_codigo = fn_generar_digitos(8);
    SET v_dup = 0;
    BEGIN
      DECLARE CONTINUE HANDLER FOR 1062 SET v_dup = 1;
      INSERT INTO codigo_respaldo_2fa (id_usuario, lote, codigo_hash) VALUES (p_id_usuario, v_lote, fn_hash_codigo(p_pepper, v_codigo));
    END;
    IF NOT v_dup THEN
      INSERT INTO tmp_codigos_respaldo VALUES (v_codigo);
      SET v_i = v_i + 1;
    END IF;
  END WHILE;
  CALL spi_auditar('2fa_codigos_respaldo', 'codigo_respaldo_2fa', p_id_usuario, p_id_usuario, JSON_OBJECT('lote', v_lote), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
  SELECT codigo FROM tmp_codigos_respaldo;
  DROP TEMPORARY TABLE IF EXISTS tmp_codigos_respaldo;
END $$

DROP PROCEDURE IF EXISTS sp_usar_codigo_respaldo_2fa $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_usar_codigo_respaldo_2fa(
  IN p_id_usuario BIGINT UNSIGNED, IN p_codigo VARCHAR(12), IN p_pepper VARCHAR(200), OUT p_ok BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Consume un código de respaldo (uso único). Exige 2FA activo, respeta el bloqueo, cuenta los fallos y audita el uso'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT NULL;
  DECLARE v_estado VARCHAR(30);
  DECLARE v_bloqueo DATETIME(3);
  DECLARE v_hasta DATETIME(3) DEFAULT NULL;
  DECLARE v_resultado VARCHAR(30);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_pepper IS NULL OR CHAR_LENGTH(p_pepper) < 16 THEN CALL spi_error(45006, 'Pepper ausente o débil'); END IF;
  SET p_ok = 0;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo, estado, bloqueado_hasta INTO v_correo, v_estado, v_bloqueo FROM usuario WHERE id_usuario = p_id_usuario FOR UPDATE;
  IF v_correo IS NULL THEN CALL spi_error(45022, 'El usuario no existe'); END IF;
  IF v_estado <> 'activo' THEN
    SET v_resultado = IF(v_estado = 'inhabilitado', 'cuenta_inhabilitada', 'correo_no_verificado');
  ELSEIF v_bloqueo IS NOT NULL AND v_bloqueo > UTC_TIMESTAMP(3) THEN
    SET v_resultado = 'cuenta_bloqueada';
  ELSEIF NOT EXISTS (SELECT 1 FROM autenticacion_2fa WHERE id_usuario = p_id_usuario AND activo = 1) THEN
    SET v_resultado = 'segundo_factor_fallido';   -- sin 2FA activo los códigos de respaldo no sirven
  ELSE
    UPDATE codigo_respaldo_2fa SET usado_en = UTC_TIMESTAMP(3)
     WHERE id_usuario = p_id_usuario AND codigo_hash = fn_hash_codigo(p_pepper, TRIM(p_codigo))
       AND usado_en IS NULL AND invalidado_en IS NULL;
    SET p_ok = ROW_COUNT() = 1;
    IF p_ok THEN
      UPDATE usuario SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario;
      CALL spi_auditar('2fa_codigo_respaldo_usado', 'usuario', p_id_usuario, p_id_usuario,
                       JSON_OBJECT('quedan', (SELECT COUNT(*) FROM codigo_respaldo_2fa
                                               WHERE id_usuario = p_id_usuario AND usado_en IS NULL AND invalidado_en IS NULL)), 'procedimiento');
      SET v_resultado = 'ok';
    ELSE
      CALL spi_registrar_fallo_acceso(p_id_usuario, 'codigo_respaldo', v_hasta);
      SET v_resultado = IF(v_hasta IS NULL, 'segundo_factor_fallido', 'bloqueada_ahora');
    END IF;
  END IF;
  INSERT INTO intento_acceso (correo_intentado, id_usuario, ip, exitoso, resultado)
  VALUES (v_correo, p_id_usuario, fn_ip_sesion(), p_ok, v_resultado);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- ---------------------------------------------------------------------
-- C.3 Protección de datos personales (Ley 29733)
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS sp_registrar_consentimiento $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_consentimiento(
  IN p_id_usuario BIGINT UNSIGNED, IN p_correo VARCHAR(254), IN p_finalidad VARCHAR(30), IN p_version VARCHAR(20),
  IN p_otorgado BOOLEAN, IN p_user_agent VARCHAR(255))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra aceptación o revocación de un consentimiento (nueva fila; nunca se edita)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_id_usuario IS NOT NULL THEN CALL spi_validar_dueno_o_admin(p_id_usuario); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  INSERT INTO consentimiento_datos (id_usuario, correo, finalidad, version_documento, otorgado, ip, user_agent)
  VALUES (p_id_usuario, fn_normalizar_correo(p_correo), p_finalidad, p_version, p_otorgado, fn_ip_sesion(), LEFT(p_user_agent, 255));
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_solicitud_arco $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_solicitud_arco(
  IN p_id_usuario BIGINT UNSIGNED, IN p_nombres VARCHAR(160), IN p_tipo_documento VARCHAR(3), IN p_numero_documento VARCHAR(12),
  IN p_correo VARCHAR(254), IN p_tipo VARCHAR(15), IN p_detalle TEXT,
  OUT p_id_solicitud BIGINT UNSIGNED, OUT p_numero VARCHAR(25), OUT p_fecha_limite DATE)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Solicitud ARCO con correlativo y fecha límite (plazos configurables, por verificar)'
BEGIN
  DECLARE v_dias INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_id_usuario IS NOT NULL THEN CALL spi_validar_dueno_o_admin(p_id_usuario); END IF;
  IF NOT fn_correo_valido(fn_normalizar_correo(p_correo)) THEN CALL spi_error(45006, 'Correo de respuesta inválido'); END IF;
  IF NOT fn_documento_valido(p_tipo_documento, UPPER(TRIM(p_numero_documento))) THEN CALL spi_error(45006, 'Documento de identidad inválido'); END IF;
  SET v_dias = IF(p_tipo = 'acceso', fn_config_entero('arco_plazo_acceso_dias'), fn_config_entero('arco_plazo_otros_dias'));
  SET p_fecha_limite = fn_fecha_limite(fn_hoy_lima(), v_dias, fn_config('arco_plazo_tipo'));
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  INSERT INTO solicitud_arco (numero, id_usuario, nombres, tipo_documento, numero_documento, correo, tipo, detalle, fecha_limite, ip)
  VALUES (NULL, p_id_usuario, TRIM(p_nombres), p_tipo_documento, UPPER(TRIM(p_numero_documento)), fn_normalizar_correo(p_correo),
          p_tipo, p_detalle, p_fecha_limite, fn_ip_sesion());
  SET p_id_solicitud = LAST_INSERT_ID();
  SELECT numero INTO p_numero FROM solicitud_arco WHERE id_solicitud = p_id_solicitud;
  CALL spi_notificar_admins('arco_nueva', CONCAT('Solicitud ARCO ', p_numero), CONCAT('Tipo: ', p_tipo, '. Vence: ', p_fecha_limite), '/admin/arco', NULL);
  CALL spi_encolar_correo(p_id_usuario, p_correo, 'arco_recibida', JSON_OBJECT('numero', p_numero, 'fecha_limite', p_fecha_limite), 3);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_atender_solicitud_arco $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_atender_solicitud_arco(
  IN p_id_solicitud BIGINT UNSIGNED, IN p_estado VARCHAR(15), IN p_respuesta TEXT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Administrador atiende o deniega una solicitud ARCO'
BEGIN
  DECLARE v_correo VARCHAR(254);
  DECLARE v_numero VARCHAR(25);
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_estado NOT IN ('en_atencion','atendida','denegada') THEN CALL spi_error(45006, 'Estado ARCO inválido'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo, numero, id_usuario INTO v_correo, v_numero, v_usuario FROM solicitud_arco WHERE id_solicitud = p_id_solicitud FOR UPDATE;
  IF v_numero IS NULL THEN CALL spi_error(45022, 'La solicitud no existe'); END IF;
  UPDATE solicitud_arco
     SET estado = p_estado,
         respuesta = COALESCE(p_respuesta, respuesta),
         atendido_por = IF(p_estado IN ('atendida','denegada'), fn_actor(), atendido_por),
         atendido_en = IF(p_estado IN ('atendida','denegada'), UTC_TIMESTAMP(3), atendido_en)
   WHERE id_solicitud = p_id_solicitud;
  IF p_estado IN ('atendida','denegada') THEN
    CALL spi_encolar_correo(v_usuario, v_correo, 'arco_respuesta', JSON_OBJECT('numero', v_numero, 'estado', p_estado), 3);
  END IF;
  CALL spi_auditar('arco_atendida', 'solicitud_arco', p_id_solicitud, v_usuario, JSON_OBJECT('estado', p_estado), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_ver_documento_completo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_ver_documento_completo(
  IN p_id_usuario BIGINT UNSIGNED, OUT p_tipo VARCHAR(3), OUT p_numero VARCHAR(12))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Devuelve el documento completo de un cliente y deja constancia del acceso (las vistas solo muestran el dato enmascarado)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT tipo_documento, numero_documento INTO p_tipo, p_numero FROM usuario WHERE id_usuario = p_id_usuario;
  CALL spi_auditar('acceso_dato_personal', 'usuario', p_id_usuario, p_id_usuario, JSON_OBJECT('dato', 'numero_documento'), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_actualizar_documento_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_actualizar_documento_usuario(
  IN p_id_usuario BIGINT UNSIGNED, IN p_tipo VARCHAR(3), IN p_numero VARCHAR(12))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra o corrige el documento del cliente validando DNI/RUC (con dígito verificador)/CE'
BEGIN
  DECLARE v_numero VARCHAR(12) DEFAULT UPPER(TRIM(p_numero));
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF NOT fn_documento_valido(p_tipo, v_numero) THEN CALL spi_error(45006, 'Documento inválido (DNI 8 dígitos, RUC 11 válido, CE 6-12)'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE usuario SET tipo_documento = p_tipo, numero_documento = v_numero WHERE id_usuario = p_id_usuario;
  CALL spi_auditar('documento_actualizado', 'usuario', p_id_usuario, p_id_usuario,
                   JSON_OBJECT('tipo', p_tipo, 'numero', fn_enmascarar_documento(v_numero)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cambiar_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cambiar_correo(IN p_id_usuario BIGINT UNSIGNED, IN p_nuevo_correo VARCHAR(254))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cambia el correo de acceso solo si el nuevo correo fue verificado con un código "cambiar_correo" en los últimos 10 minutos. Avisa al correo anterior'
BEGIN
  DECLARE v_nuevo VARCHAR(254) DEFAULT fn_normalizar_correo(p_nuevo_correo);
  DECLARE v_anterior VARCHAR(254) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF NOT fn_correo_valido(v_nuevo) THEN CALL spi_error(45006, 'Correo con formato inválido'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo INTO v_anterior FROM usuario WHERE id_usuario = p_id_usuario AND estado <> 'inhabilitado' FOR UPDATE;
  IF v_anterior IS NULL THEN CALL spi_error(45021, 'La cuenta no existe o está inhabilitada'); END IF;
  IF EXISTS (SELECT 1 FROM usuario WHERE correo = v_nuevo AND id_usuario <> p_id_usuario) THEN
    CALL spi_error(45033, 'El correo ya está registrado');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM codigo_verificacion
                  WHERE id_usuario = p_id_usuario AND correo_destino = v_nuevo AND proposito = 'cambiar_correo'
                    AND estado = 'usado' AND usado_en > UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE) THEN
    CALL spi_error(45011, 'Verifique primero el nuevo correo con el código enviado');
  END IF;
  UPDATE usuario SET correo = v_nuevo, correo_verificado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario;
  CALL spi_encolar_correo(p_id_usuario, v_anterior, 'correo_cambiado', JSON_OBJECT('nuevo', fn_enmascarar_correo(v_nuevo)), 2);
  CALL spi_auditar('correo_cambiado', 'usuario', p_id_usuario, p_id_usuario,
                   JSON_OBJECT('antes', fn_enmascarar_correo(v_anterior), 'despues', fn_enmascarar_correo(v_nuevo)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- D. "ELIMINAR" = INHABILITAR (borrado lógico) — sp_inhabilitar_* / sp_reactivar_*
-- #####################################################################

DROP PROCEDURE IF EXISTS spi_cambiar_activo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_cambiar_activo(
  IN p_entidad VARCHAR(30), IN p_id BIGINT UNSIGNED, IN p_activar BOOLEAN, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Inhabilita/reactiva una fila de catálogo con sentencias estáticas por entidad (sin SQL dinámico) y audita'
BEGIN
  DECLARE v_filas INT DEFAULT 0;
  DECLARE v_actor BIGINT UNSIGNED DEFAULT fn_actor();
  CASE p_entidad
    WHEN 'categoria' THEN
      IF NOT p_activar AND EXISTS (SELECT 1 FROM producto WHERE id_categoria = p_id AND estado = 'activo') THEN
        CALL spi_error(45032, 'La categoría tiene productos activos: archívelos o muévalos primero');
      END IF;
      UPDATE categoria SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_categoria = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'variante' THEN
      IF p_activar AND EXISTS (SELECT 1 FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
                                WHERE v.id_variante = p_id AND p.estado = 'archivado') THEN
        CALL spi_error(45032, 'El producto está archivado: reactívelo primero');
      END IF;
      UPDATE variante_producto SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_variante = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'imagen' THEN
      UPDATE imagen_producto SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_imagen = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'precio_volumen' THEN
      UPDATE precio_volumen SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_precio_volumen = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'insumo' THEN
      UPDATE insumo SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_insumo = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'zona_envio' THEN
      UPDATE zona_envio SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_zona = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'direccion' THEN
      UPDATE direccion SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor),
                           predeterminada = IF(p_activar, predeterminada, 0)
       WHERE id_direccion = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'courier' THEN
      UPDATE courier SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_courier = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'banner' THEN
      UPDATE banner SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_banner = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    WHEN 'serie_comprobante' THEN
      UPDATE serie_comprobante SET activo = p_activar, inhabilitado_en = IF(p_activar, NULL, UTC_TIMESTAMP(3)), inhabilitado_por = IF(p_activar, NULL, v_actor)
       WHERE id_serie = p_id AND activo <> p_activar;
      SET v_filas = ROW_COUNT();
    ELSE
      CALL spi_error(45006, CONCAT('Entidad no soportada: ', COALESCE(p_entidad, 'NULL')));
  END CASE;
  IF v_filas = 0 THEN
    CALL spi_error(45022, CONCAT('No existe o ya estaba ', IF(p_activar, 'activo', 'inhabilitado'), ': ', p_entidad, ' ', p_id));
  END IF;
  CALL spi_auditar(IF(p_activar, 'registro_reactivado', 'registro_inhabilitado'), p_entidad, p_id, NULL,
                   JSON_OBJECT('motivo', p_motivo), 'procedimiento');
END $$

-- Envoltorios públicos (todos exigen administrador, salvo la dirección: dueño o administrador)
DROP PROCEDURE IF EXISTS spi_activo_publico $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_activo_publico(
  IN p_entidad VARCHAR(30), IN p_id BIGINT UNSIGNED, IN p_activar BOOLEAN, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Transacción común de los sp_inhabilitar_* / sp_reactivar_*'
BEGIN
  DECLARE v_dueno BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_entidad = 'direccion' THEN
    SELECT id_usuario INTO v_dueno FROM direccion WHERE id_direccion = p_id;
    CALL spi_validar_dueno_o_admin(v_dueno);
  ELSE
    CALL spi_validar_admin();
  END IF;
  IF NOT p_activar AND p_entidad <> 'direccion' AND (p_motivo IS NULL OR TRIM(p_motivo) = '') THEN
    CALL spi_error(45006, 'Indique el motivo de la inhabilitación');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_cambiar_activo(p_entidad, p_id, p_activar, p_motivo);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_categoria $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_categoria(IN p_id SMALLINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita una categoría (sin productos activos)'
BEGIN CALL spi_activo_publico('categoria', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_categoria $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_categoria(IN p_id SMALLINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una categoría'
BEGIN CALL spi_activo_publico('categoria', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_variante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_variante(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita una variante (deja de venderse; el historial se conserva)'
BEGIN CALL spi_activo_publico('variante', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_variante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_variante(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una variante'
BEGIN CALL spi_activo_publico('variante', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_imagen $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_imagen(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita una imagen de producto'
BEGIN CALL spi_activo_publico('imagen', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_imagen $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_imagen(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una imagen'
BEGIN CALL spi_activo_publico('imagen', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_precio_volumen $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_precio_volumen(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita un tramo de precio por volumen'
BEGIN CALL spi_activo_publico('precio_volumen', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_precio_volumen $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_precio_volumen(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva un tramo de precio por volumen'
BEGIN CALL spi_activo_publico('precio_volumen', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_insumo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_insumo(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita un insumo'
BEGIN CALL spi_activo_publico('insumo', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_insumo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_insumo(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva un insumo'
BEGIN CALL spi_activo_publico('insumo', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_zona_envio $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_zona_envio(IN p_id SMALLINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita una zona de envío (los pedidos existentes conservan su copia)'
BEGIN CALL spi_activo_publico('zona_envio', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_zona_envio $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_zona_envio(IN p_id SMALLINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una zona de envío'
BEGIN CALL spi_activo_publico('zona_envio', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_direccion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_direccion(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'El cliente "elimina" una dirección (borrado lógico)'
BEGIN CALL spi_activo_publico('direccion', p_id, 0, 'Eliminada por el usuario'); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_direccion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_direccion(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una dirección'
BEGIN CALL spi_activo_publico('direccion', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_courier $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_courier(IN p_id SMALLINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita un courier'
BEGIN CALL spi_activo_publico('courier', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_courier $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_courier(IN p_id SMALLINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva un courier'
BEGIN CALL spi_activo_publico('courier', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_banner $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_banner(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita un banner'
BEGIN CALL spi_activo_publico('banner', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_banner $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_banner(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva un banner'
BEGIN CALL spi_activo_publico('banner', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_serie_comprobante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_serie_comprobante(IN p_id SMALLINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Inhabilita una serie de comprobantes'
BEGIN CALL spi_activo_publico('serie_comprobante', p_id, 0, p_motivo); END $$
DROP PROCEDURE IF EXISTS sp_reactivar_serie_comprobante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_serie_comprobante(IN p_id SMALLINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Reactiva una serie de comprobantes'
BEGIN CALL spi_activo_publico('serie_comprobante', p_id, 1, NULL); END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_metodo_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_metodo_pago(IN p_codigo VARCHAR(20), IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Deja de ofrecer un método de pago'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE metodo_pago SET activo = 0, inhabilitado_en = UTC_TIMESTAMP(3), inhabilitado_por = fn_actor() WHERE codigo = p_codigo AND activo = 1;
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Método inexistente o ya inhabilitado'); END IF;
  CALL spi_auditar('registro_inhabilitado', 'metodo_pago', NULL, NULL, JSON_OBJECT('codigo', p_codigo, 'motivo', p_motivo), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$
DROP PROCEDURE IF EXISTS sp_reactivar_metodo_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_metodo_pago(IN p_codigo VARCHAR(20))
MODIFIES SQL DATA SQL SECURITY DEFINER COMMENT 'Vuelve a ofrecer un método de pago'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE metodo_pago SET activo = 1, inhabilitado_en = NULL, inhabilitado_por = NULL WHERE codigo = p_codigo AND activo = 0;
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Método inexistente o ya activo'); END IF;
  CALL spi_auditar('registro_reactivado', 'metodo_pago', NULL, NULL, JSON_OBJECT('codigo', p_codigo), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_producto $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_producto(IN p_id BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Archiva un producto (con o sin ventas nunca se borra) y sus variantes dejan de venderse'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_motivo IS NULL OR TRIM(p_motivo) = '' THEN CALL spi_error(45006, 'Indique el motivo del archivo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE producto SET estado = 'archivado', inhabilitado_en = UTC_TIMESTAMP(3), inhabilitado_por = fn_actor(), destacado = 0
   WHERE id_producto = p_id AND estado <> 'archivado';
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Producto inexistente o ya archivado'); END IF;
  CALL spi_auditar('producto_archivado', 'producto', p_id, NULL,
                   JSON_OBJECT('motivo', p_motivo, 'tiene_ventas', EXISTS (SELECT 1 FROM item_pedido WHERE id_producto = p_id)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_reactivar_producto $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_producto(IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Saca un producto del archivo (vuelve a "activo")'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF EXISTS (SELECT 1 FROM producto p JOIN categoria c ON c.id_categoria = p.id_categoria WHERE p.id_producto = p_id AND c.activo = 0) THEN
    CALL spi_error(45032, 'La categoría del producto está inhabilitada');
  END IF;
  UPDATE producto SET estado = 'activo', inhabilitado_en = NULL, inhabilitado_por = NULL WHERE id_producto = p_id AND estado = 'archivado';
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Producto inexistente o no archivado'); END IF;
  CALL spi_auditar('producto_reactivado', 'producto', p_id, NULL, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_inhabilitar_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_inhabilitar_usuario(IN p_id_usuario BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Inhabilita una cuenta (nunca se borra): cierra sesiones, invalida códigos. No permite inhabilitarse a sí mismo ni al último administrador'
BEGIN
  DECLARE v_es_admin BOOLEAN;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_id_usuario = fn_actor() THEN CALL spi_error(45023, 'No puede inhabilitar su propia cuenta'); END IF;
  IF p_motivo IS NULL OR TRIM(p_motivo) = '' THEN CALL spi_error(45006, 'Indique el motivo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SET v_es_admin = fn_es_admin(p_id_usuario);
  IF v_es_admin AND (SELECT COUNT(*) FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                      WHERE r.codigo = 'administrador' AND u.estado = 'activo' AND u.id_usuario <> p_id_usuario) = 0 THEN
    CALL spi_error(45023, 'No se puede inhabilitar al último administrador activo');
  END IF;
  UPDATE usuario SET estado = 'inhabilitado', inhabilitado_en = UTC_TIMESTAMP(3), inhabilitado_por = fn_actor(), motivo_inhabilitacion = p_motivo
   WHERE id_usuario = p_id_usuario AND estado <> 'inhabilitado';
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Usuario inexistente o ya inhabilitado'); END IF;
  CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'inhabilitacion');
  UPDATE codigo_verificacion SET estado = 'bloqueado', cerrado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND estado = 'activo';
  CALL spi_auditar('usuario_inhabilitado', 'usuario', p_id_usuario, p_id_usuario, JSON_OBJECT('motivo', p_motivo), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_reactivar_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reactivar_usuario(IN p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Reactiva una cuenta inhabilitada (activa si ya verificó su correo; si no, pendiente de verificación)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE usuario
     SET estado = IF(correo_verificado_en IS NULL, 'pendiente_verificacion', 'activo'),
         inhabilitado_en = NULL, inhabilitado_por = NULL, motivo_inhabilitacion = NULL,
         intentos_fallidos = 0, bloqueado_hasta = NULL
   WHERE id_usuario = p_id_usuario AND estado = 'inhabilitado';
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'Usuario inexistente o no inhabilitado'); END IF;
  CALL spi_auditar('usuario_reactivado', 'usuario', p_id_usuario, p_id_usuario, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_desbloquear_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_desbloquear_usuario(IN p_id_usuario BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Quita el bloqueo temporal por intentos fallidos'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE usuario SET intentos_fallidos = 0, bloqueado_hasta = NULL WHERE id_usuario = p_id_usuario;
  CALL spi_auditar('usuario_desbloqueado', 'usuario', p_id_usuario, p_id_usuario, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- E. CATÁLOGO, INVENTARIO, DIRECCIONES, CARRITO Y FAVORITOS
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_definir_imagen_principal $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_definir_imagen_principal(IN p_id_imagen BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Marca la imagen principal del producto (en MySQL un trigger no puede tocar su propia tabla: por eso es procedimiento)'
BEGIN
  DECLARE v_producto BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_producto INTO v_producto FROM imagen_producto WHERE id_imagen = p_id_imagen AND activo = 1 FOR UPDATE;
  IF v_producto IS NULL THEN CALL spi_error(45022, 'Imagen inexistente o inactiva'); END IF;
  UPDATE imagen_producto SET principal = 0 WHERE id_producto = v_producto AND principal = 1 AND id_imagen <> p_id_imagen;
  UPDATE imagen_producto SET principal = 1 WHERE id_imagen = p_id_imagen;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_definir_direccion_predeterminada $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_definir_direccion_predeterminada(IN p_id_direccion BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Deja una sola dirección predeterminada por cliente (reemplaza al trigger del original, que en MySQL daría error 1442)'
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_usuario INTO v_usuario FROM direccion WHERE id_direccion = p_id_direccion AND activo = 1 FOR UPDATE;
  IF v_usuario IS NULL THEN CALL spi_error(45022, 'Dirección inexistente o inactiva'); END IF;
  CALL spi_validar_dueno_o_admin(v_usuario);
  UPDATE direccion SET predeterminada = 0 WHERE id_usuario = v_usuario AND predeterminada = 1 AND id_direccion <> p_id_direccion;
  UPDATE direccion SET predeterminada = 1 WHERE id_direccion = p_id_direccion;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_ajustar_stock $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_ajustar_stock(
  IN p_id_variante BIGINT UNSIGNED, IN p_tipo VARCHAR(10), IN p_cantidad INT, IN p_motivo VARCHAR(200), OUT p_stock_actual INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Ingreso o ajuste manual de stock por el administrador (queda en el kardex)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_tipo NOT IN ('ingreso','ajuste') THEN CALL spi_error(45006, 'Tipo inválido: use ingreso o ajuste'); END IF;
  IF p_tipo = 'ajuste' AND (p_motivo IS NULL OR TRIM(p_motivo) = '') THEN CALL spi_error(45006, 'El ajuste requiere motivo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_mover_stock(p_id_variante, p_tipo, p_cantidad, NULL, NULL, NULL, COALESCE(p_motivo, 'Ingreso de mercadería'), p_stock_actual);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_ajustar_insumo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_ajustar_insumo(
  IN p_id_insumo BIGINT UNSIGNED, IN p_tipo VARCHAR(10), IN p_cantidad DECIMAL(12,3), IN p_motivo VARCHAR(200),
  IN p_id_pedido BIGINT UNSIGNED, OUT p_stock DECIMAL(12,3))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Ingreso, consumo o ajuste de insumos (kardex de insumos)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_tipo = 'ajuste' AND (p_motivo IS NULL OR TRIM(p_motivo) = '') THEN CALL spi_error(45006, 'El ajuste requiere motivo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_mover_insumo(p_id_insumo, p_tipo, p_cantidad, p_id_pedido, p_motivo, p_stock);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_consumir_insumos_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_consumir_insumos_pedido(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Descuenta los insumos de un pedido según la receta (una sola vez)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SET @wanka_estado_insumos = NULL;
  SELECT estado INTO @wanka_estado_insumos FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF @wanka_estado_insumos IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  IF @wanka_estado_insumos NOT IN ('confirmado','en_produccion') THEN
    CALL spi_error(45007, CONCAT('Los insumos se descuentan con el pedido confirmado o en producción (está ', @wanka_estado_insumos, ')'));
  END IF;
  CALL spi_consumir_insumos_pedido(p_id_pedido);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS spi_validar_variante_vendible $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_variante_vendible(IN p_id_variante BIGINT UNSIGNED)
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Error 45008 si la variante o su producto no están a la venta'
BEGIN
  IF NOT EXISTS (SELECT 1 FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
                  JOIN categoria c ON c.id_categoria = p.id_categoria
                  WHERE v.id_variante = p_id_variante AND v.activo = 1 AND p.estado = 'activo' AND c.activo = 1) THEN
    CALL spi_error(45008, CONCAT('El producto (variante ', COALESCE(p_id_variante, 0), ') no está disponible para la venta'));
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_agregar_item_carrito $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_agregar_item_carrito(
  IN p_id_usuario BIGINT UNSIGNED, IN p_id_variante BIGINT UNSIGNED, IN p_cantidad INT, IN p_personalizacion VARCHAR(500),
  OUT p_disponible INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Fija la cantidad de una variante en el carrito activo (lo crea si no existe). No guarda precios. Devuelve el disponible informativo'
BEGIN
  DECLARE v_carrito BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_tipo VARCHAR(10);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_carrito = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    CALL spi_validar_dueno_o_admin(p_id_usuario);
    IF p_cantidad IS NULL OR p_cantidad < 1 OR p_cantidad > 100000 THEN CALL spi_error(45006, 'Cantidad inválida'); END IF;
    CALL spi_validar_variante_vendible(p_id_variante);
    IF NULLIF(TRIM(p_personalizacion), '') IS NOT NULL AND NOT EXISTS (
         SELECT 1 FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto
          WHERE v.id_variante = p_id_variante AND p.permite_personalizacion = 1) THEN
      CALL spi_error(45006, 'Este producto no admite personalización');
    END IF;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SET @wanka_x = NULL;
    SELECT id_usuario INTO @wanka_x FROM usuario WHERE id_usuario = p_id_usuario AND estado = 'activo' FOR UPDATE;
    IF @wanka_x IS NULL THEN CALL spi_error(45021, 'La cuenta no está activa'); END IF;
    SELECT id_carrito INTO v_carrito FROM carrito WHERE id_usuario = p_id_usuario AND estado = 'activo';
    IF v_carrito IS NULL THEN
      INSERT INTO carrito (id_usuario) VALUES (p_id_usuario);
      SET v_carrito = LAST_INSERT_ID();
    END IF;
    INSERT INTO item_carrito (id_carrito, id_variante, cantidad, personalizacion)
    VALUES (v_carrito, p_id_variante, p_cantidad, NULLIF(TRIM(p_personalizacion), '')) AS nuevo
    -- COMPAT-MARIADB: usar VALUES(columna) en lugar del alias "nuevo"
    ON DUPLICATE KEY UPDATE cantidad = nuevo.cantidad, personalizacion = nuevo.personalizacion, actualizado_en = UTC_TIMESTAMP(3);
    UPDATE carrito SET actualizado_en = UTC_TIMESTAMP(3) WHERE id_carrito = v_carrito;
    SELECT p.tipo_fabricacion, v.stock_disponible INTO v_tipo, p_disponible
      FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto WHERE v.id_variante = p_id_variante;
    IF v_tipo = 'a_pedido' THEN SET p_disponible = NULL; END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
    SET @wanka_x = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_quitar_item_carrito $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_quitar_item_carrito(IN p_id_usuario BIGINT UNSIGNED, IN p_id_variante BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Quita una variante del carrito activo (estado de interfaz, sin valor histórico: borrado físico permitido solo aquí)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  DELETE ic FROM item_carrito ic JOIN carrito c ON c.id_carrito = ic.id_carrito
   WHERE c.id_usuario = p_id_usuario AND c.estado = 'activo' AND ic.id_variante = p_id_variante;
  UPDATE carrito SET actualizado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND estado = 'activo';
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_alternar_favorito $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_alternar_favorito(
  IN p_id_usuario BIGINT UNSIGNED, IN p_id_producto BIGINT UNSIGNED, OUT p_es_favorito BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Marca o desmarca un favorito (estado de interfaz)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  DELETE FROM favorito WHERE id_usuario = p_id_usuario AND id_producto = p_id_producto;
  IF ROW_COUNT() = 0 THEN
    IF NOT EXISTS (SELECT 1 FROM producto WHERE id_producto = p_id_producto AND estado = 'activo') THEN
      CALL spi_error(45008, 'El producto no está disponible');
    END IF;
    INSERT INTO favorito (id_usuario, id_producto) VALUES (p_id_usuario, p_id_producto);
    SET p_es_favorito = 1;
  ELSE
    SET p_es_favorito = 0;
  END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- F. PEDIDOS
-- #####################################################################

DROP PROCEDURE IF EXISTS spi_insertar_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_insertar_pedido(
  IN p_id_usuario BIGINT UNSIGNED, IN p_tipo_venta VARCHAR(5), IN p_canal VARCHAR(10),
  IN p_tipo_entrega VARCHAR(10), IN p_id_direccion BIGINT UNSIGNED, IN p_id_pedido_copia BIGINT UNSIGNED,
  IN p_modalidad VARCHAR(10), IN p_adelanto_pct DECIMAL(5,2),
  IN p_comprobante VARCHAR(10), IN p_fact_tipo VARCHAR(3), IN p_fact_num VARCHAR(12), IN p_fact_nombre VARCHAR(200), IN p_fact_dir VARCHAR(250),
  IN p_fecha_entrega DATE, IN p_notas VARCHAR(500), IN p_id_cotizacion BIGINT UNSIGNED, IN p_id_pedido_origen BIGINT UNSIGNED,
  IN p_costo_envio_forzado DECIMAL(12,2), OUT p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Crea la cabecera del pedido: copia de entrega, costo de envío desde la zona, modalidad de pago, datos de comprobante'
BEGIN
  DECLARE v_estado_usuario VARCHAR(30) DEFAULT NULL;
  DECLARE v_zona SMALLINT UNSIGNED DEFAULT NULL;
  DECLARE v_costo DECIMAL(12,2) DEFAULT 0;
  DECLARE v_nombre VARCHAR(120); DECLARE v_tel VARCHAR(16); DECLARE v_dir VARCHAR(200); DECLARE v_ref VARCHAR(200);
  DECLARE v_dist VARCHAR(80); DECLARE v_prov VARCHAR(80); DECLARE v_depa VARCHAR(80); DECLARE v_ubigeo CHAR(6);
  DECLARE v_id_dir BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_modalidad VARCHAR(10) DEFAULT COALESCE(p_modalidad, 'total');
  DECLARE v_pct DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_fact_num VARCHAR(12) DEFAULT NULLIF(UPPER(TRIM(p_fact_num)), '');
  DECLARE v_fact_tipo VARCHAR(3) DEFAULT NULLIF(p_fact_tipo, '');
  DECLARE v_dias INT;
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;

  SELECT estado INTO v_estado_usuario FROM usuario WHERE id_usuario = p_id_usuario;
  IF v_estado_usuario IS NULL OR v_estado_usuario <> 'activo' THEN
    CALL spi_error(45021, 'La cuenta del cliente no está activa (verifique su correo)');
  END IF;
  IF p_tipo_entrega NOT IN ('recojo','domicilio') OR p_tipo_entrega IS NULL THEN
    CALL spi_error(45028, 'Tipo de entrega inválido: recojo o domicilio');
  END IF;

  IF p_tipo_entrega = 'domicilio' THEN
    IF p_id_pedido_copia IS NOT NULL THEN
      SELECT id_direccion, id_zona, entrega_nombre, entrega_telefono, entrega_direccion, entrega_referencia,
             entrega_distrito, entrega_provincia, entrega_departamento, entrega_ubigeo
        INTO v_id_dir, v_zona, v_nombre, v_tel, v_dir, v_ref, v_dist, v_prov, v_depa, v_ubigeo
        FROM pedido WHERE id_pedido = p_id_pedido_copia AND tipo_entrega = 'domicilio';
      IF v_nf THEN CALL spi_error(45028, 'El pedido original no tiene entrega a domicilio'); END IF;
      SELECT costo INTO v_costo FROM zona_envio WHERE id_zona = v_zona;
    ELSE
      SELECT d.id_direccion, d.id_zona, d.nombre_receptor, d.telefono, d.direccion, d.referencia,
             d.distrito, d.provincia, d.departamento, d.ubigeo, z.costo
        INTO v_id_dir, v_zona, v_nombre, v_tel, v_dir, v_ref, v_dist, v_prov, v_depa, v_ubigeo, v_costo
        FROM direccion d JOIN zona_envio z ON z.id_zona = d.id_zona
       WHERE d.id_direccion = p_id_direccion AND d.id_usuario = p_id_usuario AND d.activo = 1 AND z.activo = 1;
      IF v_nf THEN CALL spi_error(45028, 'Dirección inválida, de otro cliente, inactiva o con zona de envío inactiva'); END IF;
    END IF;
    IF p_costo_envio_forzado IS NOT NULL THEN SET v_costo = p_costo_envio_forzado; END IF;
  ELSE
    SET v_costo = 0;
  END IF;

  IF v_modalidad NOT IN ('total','adelanto') THEN CALL spi_error(45035, 'Modalidad de pago inválida: total o adelanto'); END IF;
  IF v_modalidad = 'adelanto' THEN
    SET v_pct = COALESCE(p_adelanto_pct, fn_config_decimal('adelanto_porcentaje'));
    IF v_pct >= 100 THEN SET v_modalidad = 'total'; SET v_pct = NULL; END IF;
  END IF;

  IF p_comprobante NOT IN ('boleta','factura') OR p_comprobante IS NULL THEN CALL spi_error(45015, 'Comprobante inválido: boleta o factura'); END IF;
  IF v_fact_tipo IS NOT NULL OR v_fact_num IS NOT NULL THEN
    IF NOT fn_documento_valido(v_fact_tipo, v_fact_num) THEN
      CALL spi_error(45006, 'Documento para el comprobante inválido (DNI 8 dígitos, RUC 11 con dígito verificador, CE 6-12)');
    END IF;
  END IF;
  IF p_comprobante = 'factura' AND (v_fact_tipo IS NULL OR v_fact_tipo <> 'RUC' OR NULLIF(TRIM(p_fact_nombre), '') IS NULL) THEN
    CALL spi_error(45015, 'La factura exige RUC válido y razón social del cliente');
  END IF;

  IF p_tipo_venta = 'mayor' THEN
    SET v_dias = fn_config_entero('dias_minimos_mayor');
    IF p_fecha_entrega IS NULL OR p_fecha_entrega < fn_hoy_lima() + INTERVAL v_dias DAY THEN
      CALL spi_error(45009, CONCAT('Los pedidos al por mayor requieren al menos ', v_dias, ' días de anticipación (fecha de entrega)'));
    END IF;
  END IF;

  INSERT INTO pedido (numero, id_usuario, id_pedido_origen, id_cotizacion, tipo_venta, canal, modalidad_pago, adelanto_porcentaje,
                      tipo_entrega, id_direccion, id_zona, entrega_nombre, entrega_telefono, entrega_direccion, entrega_referencia,
                      entrega_distrito, entrega_provincia, entrega_departamento, entrega_ubigeo,
                      comprobante_solicitado, facturacion_tipo_doc, facturacion_num_doc, facturacion_nombre, facturacion_direccion,
                      costo_envio, total, fecha_entrega_solicitada, notas, expira_en)
  VALUES (NULL, p_id_usuario, p_id_pedido_origen, p_id_cotizacion, p_tipo_venta, COALESCE(p_canal, 'web'), v_modalidad, v_pct,
          p_tipo_entrega, v_id_dir, v_zona, v_nombre, v_tel, v_dir, v_ref, v_dist, v_prov, v_depa, v_ubigeo,
          p_comprobante, v_fact_tipo, v_fact_num, NULLIF(TRIM(p_fact_nombre), ''), NULLIF(TRIM(p_fact_dir), ''),
          v_costo, v_costo, p_fecha_entrega, NULLIF(TRIM(p_notas), ''),
          UTC_TIMESTAMP(3) + INTERVAL fn_config_entero('horas_reserva_pedido') HOUR);
  SET p_id_pedido = LAST_INSERT_ID();
END $$

DROP PROCEDURE IF EXISTS spi_agregar_item_interno $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_agregar_item_interno(
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_variante BIGINT UNSIGNED, IN p_cantidad INT, IN p_personalizacion VARCHAR(500),
  IN p_precio_forzado DECIMAL(10,2), IN p_descripcion VARCHAR(250), OUT p_id_item BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Agrega un ítem con copia de datos y precio desde la BD (lista, volumen o cotizado), reserva stock y recalcula'
BEGIN
  DECLARE v_producto BIGINT UNSIGNED;
  DECLARE v_nombre VARCHAR(150); DECLARE v_sku VARCHAR(40); DECLARE v_talla VARCHAR(20); DECLARE v_color VARCHAR(30);
  DECLARE v_tipo VARCHAR(15); DECLARE v_lista DECIMAL(10,2); DECLARE v_precio DECIMAL(10,2); DECLARE v_origen VARCHAR(12);
  DECLARE v_personalizable BOOLEAN;
  DECLARE v_pers VARCHAR(500) DEFAULT NULLIF(TRIM(p_personalizacion), '');

  IF p_cantidad IS NULL OR p_cantidad < 1 OR p_cantidad > 100000 THEN CALL spi_error(45006, 'Cantidad inválida'); END IF;
  IF p_id_variante IS NOT NULL THEN
    -- Bloqueo exclusivo primero: si el INSERT tomara antes el bloqueo compartido de la FK, dos compras
    -- simultáneas de la misma variante se bloquearían mutuamente al reservar (deadlock 1213)
    SELECT id_variante INTO @wanka_x FROM variante_producto WHERE id_variante = p_id_variante FOR UPDATE;
  END IF;

  IF p_id_variante IS NULL THEN
    IF p_precio_forzado IS NULL OR NULLIF(TRIM(p_descripcion), '') IS NULL THEN
      CALL spi_error(45006, 'Una pieza personalizada requiere descripción y precio cotizado');
    END IF;
    SET v_nombre = LEFT(TRIM(p_descripcion), 150); SET v_tipo = 'personalizado';
    SET v_precio = p_precio_forzado; SET v_origen = 'cotizacion'; SET v_lista = NULL;
  ELSE
    CALL spi_validar_variante_vendible(p_id_variante);
    SELECT p.id_producto, p.nombre, v.sku, v.talla, v.color, p.tipo_fabricacion, COALESCE(v.precio, p.precio_base), p.permite_personalizacion
      INTO v_producto, v_nombre, v_sku, v_talla, v_color, v_tipo, v_lista, v_personalizable
      FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto WHERE v.id_variante = p_id_variante;
    IF p_precio_forzado IS NOT NULL THEN
      SET v_precio = p_precio_forzado; SET v_origen = 'cotizacion';
    ELSE
      IF v_pers IS NOT NULL AND NOT v_personalizable THEN
        CALL spi_error(45006, CONCAT('El producto "', v_nombre, '" no admite personalización'));
      END IF;
      SET v_precio = fn_precio_unitario(p_id_variante, p_cantidad);
      SET v_origen = IF(v_precio < v_lista, 'volumen', 'lista');
    END IF;
  END IF;

  INSERT INTO item_pedido (id_pedido, id_variante, id_producto, nombre_producto, sku, talla, color, tipo_fabricacion,
                           cantidad, precio_lista, precio_unitario, origen_precio, personalizacion)
  VALUES (p_id_pedido, p_id_variante, v_producto, v_nombre, v_sku, v_talla, v_color, v_tipo,
          p_cantidad, v_lista, v_precio, v_origen, v_pers);
  SET p_id_item = LAST_INSERT_ID();
  CALL spi_reservar_item(p_id_item);
  CALL spi_recalcular_pedido(p_id_pedido);
END $$

DROP PROCEDURE IF EXISTS spi_validar_pedido_completo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_pedido_completo(IN p_id_pedido BIGINT UNSIGNED)
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Reglas que dependen del total o del tipo de venta: pedido no vacío, boleta > umbral con documento, adelanto permitido'
BEGIN
  DECLARE v_total DECIMAL(12,2); DECLARE v_sub DECIMAL(12,2); DECLARE v_comp VARCHAR(10);
  DECLARE v_doc VARCHAR(12); DECLARE v_modalidad VARCHAR(10); DECLARE v_tipo_venta VARCHAR(5);
  DECLARE v_umbral DECIMAL(14,4);
  SELECT p.total, p.subtotal, p.comprobante_solicitado, COALESCE(p.facturacion_num_doc, u.numero_documento), p.modalidad_pago, p.tipo_venta
    INTO v_total, v_sub, v_comp, v_doc, v_modalidad, v_tipo_venta
    FROM pedido p JOIN usuario u ON u.id_usuario = p.id_usuario WHERE p.id_pedido = p_id_pedido;
  IF v_sub <= 0 THEN CALL spi_error(45030, 'El pedido no tiene productos'); END IF;
  SET v_umbral = fn_config_decimal('umbral_boleta_dni');
  IF v_comp = 'boleta' AND v_total > v_umbral AND v_doc IS NULL THEN
    CALL spi_error(45015, CONCAT('Para boletas mayores a S/ ', FORMAT(v_umbral, 2), ' indique DNI, CE o RUC del cliente'));
  END IF;
  IF v_modalidad = 'adelanto' AND v_tipo_venta = 'menor' AND fn_config('adelanto_permitido_en') = 'solo_mayor' THEN
    CALL spi_error(45035, 'El pago con adelanto solo está permitido en pedidos al por mayor');
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_crear_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_crear_pedido(
  IN p_id_usuario BIGINT UNSIGNED, IN p_items JSON, IN p_tipo_entrega VARCHAR(10), IN p_id_direccion BIGINT UNSIGNED,
  IN p_modalidad VARCHAR(10), IN p_comprobante VARCHAR(10), IN p_fact_tipo VARCHAR(3), IN p_fact_num VARCHAR(12),
  IN p_fact_nombre VARCHAR(200), IN p_fact_dir VARCHAR(250), IN p_fecha_entrega DATE, IN p_notas VARCHAR(500), IN p_canal VARCHAR(10),
  IN p_id_pedido_origen BIGINT UNSIGNED, IN p_costo_envio_forzado DECIMAL(12,2), OUT p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cuerpo de sp_crear_pedido / sp_crear_pedido_complementario (sin transacción propia)'
BEGIN
  DECLARE v_items JSON DEFAULT p_items;
  DECLARE v_carrito BIGINT UNSIGNED DEFAULT NULL;
  DECLARE v_n INT; DECLARE v_distintos INT; DECLARE v_malos INT;
  DECLARE v_tipo_venta VARCHAR(5);
  DECLARE v_fin BOOLEAN DEFAULT 0;
  DECLARE c_var BIGINT UNSIGNED; DECLARE c_cant INT; DECLARE c_pers VARCHAR(2000);
  DECLARE v_item BIGINT UNSIGNED;
  DECLARE cur_items CURSOR FOR
    SELECT jt.id_variante, jt.cantidad, jt.personalizacion
      FROM JSON_TABLE(v_items, '$[*]' COLUMNS (
             id_variante     BIGINT UNSIGNED PATH '$.id_variante',
             cantidad        INT             PATH '$.cantidad',
             personalizacion VARCHAR(2000)   PATH '$.personalizacion')) jt
     ORDER BY jt.id_variante;   -- orden de bloqueo único: evita deadlocks
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;

  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF COALESCE(p_canal, 'web') = 'presencial' AND NOT fn_es_admin(fn_actor()) THEN
    CALL spi_error(45023, 'Solo un administrador registra ventas presenciales');
  END IF;

  IF v_items IS NULL THEN
    SELECT id_carrito INTO v_carrito FROM carrito WHERE id_usuario = p_id_usuario AND estado = 'activo' FOR UPDATE;
    SET v_fin = 0;
    IF v_carrito IS NOT NULL THEN
      SELECT JSON_ARRAYAGG(JSON_OBJECT('id_variante', id_variante, 'cantidad', cantidad, 'personalizacion', personalizacion))
        INTO v_items FROM item_carrito WHERE id_carrito = v_carrito;
    END IF;
  END IF;
  IF v_items IS NULL OR JSON_TYPE(v_items) <> 'ARRAY' OR JSON_LENGTH(v_items) = 0 THEN
    CALL spi_error(45030, 'El pedido no tiene productos');
  END IF;
  IF JSON_LENGTH(v_items) > 100 THEN CALL spi_error(45006, 'Máximo 100 líneas por pedido'); END IF;

  SELECT COUNT(*), COUNT(DISTINCT jt.id_variante),
         SUM(jt.id_variante IS NULL OR jt.cantidad IS NULL OR jt.cantidad < 1 OR CHAR_LENGTH(COALESCE(jt.personalizacion, '')) > 500
             OR COALESCE(JSON_TYPE(jt.cantidad_json), '') NOT IN ('INTEGER','UNSIGNED INTEGER'))
    INTO v_n, v_distintos, v_malos
    FROM JSON_TABLE(v_items, '$[*]' COLUMNS (
           id_variante BIGINT UNSIGNED PATH '$.id_variante', cantidad INT PATH '$.cantidad',
           cantidad_json JSON PATH '$.cantidad', personalizacion VARCHAR(2000) PATH '$.personalizacion')) jt;
  IF v_malos > 0 THEN CALL spi_error(45006, 'Hay líneas sin variante, con cantidad no entera o inválida, o personalización mayor a 500 caracteres'); END IF;
  IF v_distintos < v_n THEN CALL spi_error(45006, 'Hay variantes repetidas en el pedido: indique una sola línea por variante'); END IF;

  -- Venta al por mayor: alguna línea se cobra efectivamente a precio por volumen (mismo criterio que spi_recalcular_tipo_venta)
  SELECT IF(SUM(fn_precio_unitario(jt.id_variante, jt.cantidad) < COALESCE(v.precio, p.precio_base)) > 0, 'mayor', 'menor') INTO v_tipo_venta
    FROM JSON_TABLE(v_items, '$[*]' COLUMNS (id_variante BIGINT UNSIGNED PATH '$.id_variante', cantidad INT PATH '$.cantidad')) jt
    JOIN variante_producto v ON v.id_variante = jt.id_variante
    JOIN producto p ON p.id_producto = v.id_producto;
  SET v_tipo_venta = COALESCE(v_tipo_venta, 'menor');

  CALL spi_insertar_pedido(p_id_usuario, v_tipo_venta, p_canal, p_tipo_entrega, p_id_direccion, p_id_pedido_origen,
                           p_modalidad, NULL, p_comprobante, p_fact_tipo, p_fact_num, p_fact_nombre, p_fact_dir,
                           p_fecha_entrega, p_notas, NULL, p_id_pedido_origen, p_costo_envio_forzado, p_id_pedido);

  SET v_fin = 0;
  OPEN cur_items;
  leer: LOOP
    FETCH cur_items INTO c_var, c_cant, c_pers;
    IF v_fin THEN LEAVE leer; END IF;
    CALL spi_agregar_item_interno(p_id_pedido, c_var, c_cant, c_pers, NULL, NULL, v_item);
  END LOOP leer;
  CLOSE cur_items;

  CALL spi_validar_pedido_completo(p_id_pedido);

  IF p_items IS NULL AND v_carrito IS NOT NULL THEN
    UPDATE carrito SET estado = 'convertido', id_pedido = p_id_pedido, actualizado_en = UTC_TIMESTAMP(3) WHERE id_carrito = v_carrito;
  END IF;
END $$

DROP PROCEDURE IF EXISTS sp_crear_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_crear_pedido(
  IN p_id_usuario BIGINT UNSIGNED, IN p_items JSON, IN p_tipo_entrega VARCHAR(10), IN p_id_direccion BIGINT UNSIGNED,
  IN p_modalidad_pago VARCHAR(10), IN p_comprobante VARCHAR(10), IN p_fact_tipo_doc VARCHAR(3), IN p_fact_num_doc VARCHAR(12),
  IN p_fact_nombre VARCHAR(200), IN p_fact_direccion VARCHAR(250), IN p_fecha_entrega DATE, IN p_notas VARCHAR(500), IN p_canal VARCHAR(10),
  OUT p_id_pedido BIGINT UNSIGNED, OUT p_numero VARCHAR(25), OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Crea un pedido pendiente de pago desde el carrito (p_items NULL) o desde JSON [{"id_variante":1,"cantidad":2,"personalizacion":"..."}]. Reintenta ante deadlock'
BEGIN
  DECLARE v_intento INT DEFAULT 0;
  DECLARE v_deadlock BOOLEAN;
  reintento: LOOP
    SET v_intento = v_intento + 1;
    SET v_deadlock = 0;
    BEGIN
      DECLARE EXIT HANDLER FOR 1213 BEGIN ROLLBACK; SET v_deadlock = 1; END;
      DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
      SET @wanka_ctx_interno = fn_token_interno();
      START TRANSACTION;
      CALL spi_crear_pedido(p_id_usuario, p_items, p_tipo_entrega, p_id_direccion, p_modalidad_pago, p_comprobante,
                            p_fact_tipo_doc, p_fact_num_doc, p_fact_nombre, p_fact_direccion, p_fecha_entrega, p_notas, p_canal,
                            NULL, NULL, p_id_pedido);
      SELECT numero, total INTO p_numero, p_total FROM pedido WHERE id_pedido = p_id_pedido;
      COMMIT;
      SET @wanka_ctx_interno = NULL;
    END;
    IF NOT v_deadlock THEN LEAVE reintento; END IF;
    IF v_intento >= 3 THEN
      SET @wanka_ctx_interno = NULL;
      CALL spi_error(45034, 'Muchas compras simultáneas: no se pudo registrar el pedido, intente nuevamente');
    END IF;
    DO SLEEP(0.05 * v_intento);
  END LOOP reintento;
END $$

DROP PROCEDURE IF EXISTS spi_bloquear_pedido_editable $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_bloquear_pedido_editable(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Bloquea el pedido y exige: dueño o admin, pendiente de pago, sin cotización y sin pagos en curso'
BEGIN
  DECLARE v_estado VARCHAR(20) DEFAULT NULL;
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE v_cotizacion BIGINT UNSIGNED;
  DECLARE v_pagos INT DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_estado = NULL;
  SELECT estado, id_usuario, id_cotizacion INTO v_estado, v_usuario, v_cotizacion FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  CALL spi_validar_dueno_o_admin(v_usuario);
  IF v_estado <> 'pendiente_pago' THEN CALL spi_error(45007, 'Los productos solo se modifican mientras el pedido está pendiente de pago'); END IF;
  IF v_cotizacion IS NOT NULL THEN CALL spi_error(45007, 'El pedido viene de una cotización: pida una nueva cotización para cambiarlo'); END IF;
  -- SELECT ... INTO (lectura sin bloqueo): con el pedido ya bloqueado basta, y un IF EXISTS dentro de un
  -- procedimiento tomaría bloqueos compartidos con huecos en el índice (causa de deadlocks entre pedidos)
  SELECT COUNT(*) INTO v_pagos FROM pago WHERE id_pedido = p_id_pedido AND estado IN ('pendiente','en_revision','confirmado','reembolsado');
  IF v_pagos > 0 THEN
    CALL spi_error(45007, 'El pedido ya tiene pagos registrados o un cobro en proceso: no se puede modificar (anule el cobro pendiente)');
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_recalcular_tipo_venta $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_recalcular_tipo_venta(IN p_id_pedido BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Si alguna línea vigente tiene precio por volumen el pedido es "mayor" (exige anticipación)'
BEGIN
  DECLARE v_tipo VARCHAR(5);
  DECLARE v_fecha DATE;
  DECLARE v_dias INT;
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  SELECT IF(SUM(origen_precio = 'volumen') > 0, 'mayor', 'menor') INTO v_tipo FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente';
  SELECT fecha_entrega_solicitada INTO v_fecha FROM pedido WHERE id_pedido = p_id_pedido;
  IF v_tipo = 'mayor' THEN
    SET v_dias = fn_config_entero('dias_minimos_mayor');
    IF v_fecha IS NULL OR v_fecha < fn_hoy_lima() + INTERVAL v_dias DAY THEN
      CALL spi_error(45009, CONCAT('Con precio por volumen el pedido es al por mayor y requiere ', v_dias, ' días de anticipación'));
    END IF;
  END IF;
  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE pedido SET tipo_venta = COALESCE(v_tipo, tipo_venta) WHERE id_pedido = p_id_pedido;
  SET @wanka_ctx_interno = v_prev;
END $$

DROP PROCEDURE IF EXISTS sp_agregar_item $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_agregar_item(
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_variante BIGINT UNSIGNED, IN p_cantidad INT, IN p_personalizacion VARCHAR(500),
  OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Agrega una línea a un pedido pendiente de pago (precio y datos salen de la BD; reserva stock)'
BEGIN
  DECLARE v_item BIGINT UNSIGNED;
  DECLARE v_ya INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_bloquear_pedido_editable(p_id_pedido);
  -- Orden de bloqueo: pedido → variante, antes de cualquier lectura de item_pedido
  SELECT id_variante INTO @wanka_x FROM variante_producto WHERE id_variante = p_id_variante FOR UPDATE;
  SELECT COUNT(*) INTO v_ya FROM item_pedido WHERE id_pedido = p_id_pedido AND id_variante = p_id_variante AND estado = 'vigente';
  IF v_ya > 0 THEN
    CALL spi_error(45006, 'Ese producto ya está en el pedido: retire la línea y agréguela con la nueva cantidad');
  END IF;
  CALL spi_agregar_item_interno(p_id_pedido, p_id_variante, p_cantidad, p_personalizacion, NULL, NULL, v_item);
  CALL spi_recalcular_tipo_venta(p_id_pedido);
  CALL spi_validar_pedido_completo(p_id_pedido);
  SELECT total INTO p_total FROM pedido WHERE id_pedido = p_id_pedido;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_quitar_item $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_quitar_item(
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_item_pedido BIGINT UNSIGNED, OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Retira una línea de un pedido pendiente de pago (borrado lógico) y libera su reserva'
BEGIN
  DECLARE v_es_del_pedido INT DEFAULT 0;
  DECLARE v_vigentes INT DEFAULT 0;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_bloquear_pedido_editable(p_id_pedido);
  -- Lecturas sin bloqueo (SELECT ... INTO): el pedido ya está bloqueado; un IF (SELECT ...) tomaría bloqueos con huecos
  SELECT COUNT(*), COALESCE(SUM(id_item_pedido = p_id_item_pedido), 0) INTO v_vigentes, v_es_del_pedido
    FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente';
  IF v_es_del_pedido = 0 THEN
    CALL spi_error(45022, 'La línea no existe en este pedido o ya fue retirada');
  END IF;
  IF v_vigentes = 1 THEN
    CALL spi_error(45030, 'No puede quitar el último producto: cancele el pedido');
  END IF;
  CALL spi_cerrar_reservas_pedido(p_id_pedido, 'liberar', p_id_item_pedido, 'Línea retirada del pedido');
  UPDATE item_pedido SET estado = 'retirado', retirado_en = UTC_TIMESTAMP(3) WHERE id_item_pedido = p_id_item_pedido;
  CALL spi_recalcular_pedido(p_id_pedido);
  CALL spi_recalcular_tipo_venta(p_id_pedido);
  CALL spi_validar_pedido_completo(p_id_pedido);
  SELECT total INTO p_total FROM pedido WHERE id_pedido = p_id_pedido;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_definir_modalidad_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_definir_modalidad_pago(
  IN p_id_pedido BIGINT UNSIGNED, IN p_modalidad VARCHAR(10), IN p_porcentaje DECIMAL(5,2), OUT p_monto_requerido DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El cliente elige pago total o adelanto antes de pagar. El porcentaje lo toma de la cotización o la configuración; solo un administrador puede fijar otro'
BEGIN
  DECLARE v_estado VARCHAR(20); DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_cot BIGINT UNSIGNED;
  DECLARE v_pct DECIMAL(5,2) DEFAULT NULL;
  DECLARE v_modalidad VARCHAR(10) DEFAULT p_modalidad;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_modalidad NOT IN ('total','adelanto') OR p_modalidad IS NULL THEN CALL spi_error(45035, 'Modalidad inválida: total o adelanto'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT estado, id_usuario, id_cotizacion INTO v_estado, v_usuario, v_cot FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  CALL spi_validar_dueno_o_admin(v_usuario);
  IF v_estado <> 'pendiente_pago' THEN CALL spi_error(45007, 'La modalidad solo se elige antes de pagar'); END IF;
  IF EXISTS (SELECT 1 FROM pago WHERE id_pedido = p_id_pedido AND estado IN ('pendiente','en_revision','confirmado','reembolsado')) THEN
    CALL spi_error(45007, 'Ya hay pagos registrados: no se puede cambiar la modalidad');
  END IF;
  IF v_modalidad = 'adelanto' THEN
    IF p_porcentaje IS NOT NULL AND fn_es_admin(fn_actor()) THEN
      SET v_pct = p_porcentaje;
    ELSE
      SELECT adelanto_porcentaje INTO v_pct FROM cotizacion WHERE id_cotizacion = v_cot;
      SET v_pct = COALESCE(v_pct, fn_config_decimal('adelanto_porcentaje'));
    END IF;
    IF v_pct <= 0 OR v_pct > 100 THEN CALL spi_error(45035, 'Porcentaje de adelanto inválido'); END IF;
    IF v_pct = 100 THEN SET v_modalidad = 'total'; SET v_pct = NULL; END IF;
  END IF;
  UPDATE pedido SET modalidad_pago = v_modalidad, adelanto_porcentaje = v_pct WHERE id_pedido = p_id_pedido;
  CALL spi_validar_pedido_completo(p_id_pedido);
  SELECT monto_requerido INTO p_monto_requerido FROM pedido WHERE id_pedido = p_id_pedido;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cambiar_estado_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cambiar_estado_pedido(
  IN p_id_pedido BIGINT UNSIGNED, IN p_estado VARCHAR(20), IN p_comentario VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El administrador cambia el estado según las transiciones permitidas (historial, auditoría y aviso al cliente por trigger). Para cancelar: sp_cancelar_pedido'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_estado = 'cancelado' THEN
    CALL spi_error(45002, 'Para cancelar use sp_cancelar_pedido (valida pagos en curso, motivo y avisos)');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  CALL spi_cambiar_estado_pedido(p_id_pedido, p_estado, p_comentario, 0);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cancelar_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cancelar_pedido(IN p_id_pedido BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cancela: sin pago libera la reserva; confirmado devuelve unidades al stock. Lo pagado queda en v_pagos_por_reembolsar'
BEGIN
  DECLARE v_estado VARCHAR(20); DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_neto DECIMAL(12,2); DECLARE v_numero VARCHAR(25);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_motivo IS NULL OR CHAR_LENGTH(TRIM(p_motivo)) < 3 THEN CALL spi_error(45006, 'Indique el motivo de la cancelación'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT estado, id_usuario, monto_neto_pagado, numero INTO v_estado, v_usuario, v_neto, v_numero FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  IF NOT fn_es_admin(fn_actor()) THEN
    CALL spi_validar_dueno_o_admin(v_usuario);
    IF v_estado <> 'pendiente_pago' THEN CALL spi_error(45023, 'Solo puede cancelar pedidos pendientes de pago; escríbanos para los demás'); END IF;
    IF EXISTS (SELECT 1 FROM pago WHERE id_pedido = p_id_pedido AND estado = 'en_revision') THEN
      CALL spi_error(45007, 'Tiene un pago en revisión: espere la validación o contáctenos');
    END IF;
    IF EXISTS (SELECT 1 FROM pago WHERE id_pedido = p_id_pedido AND estado = 'pendiente'
                  AND creado_en > UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('minutos_gracia_pago_pasarela') MINUTE) THEN
      CALL spi_error(45007, 'Tiene un cobro con tarjeta en proceso: espere unos minutos o anúlelo antes de cancelar');
    END IF;
  END IF;
  CALL spi_cambiar_estado_pedido(p_id_pedido, 'cancelado', p_motivo, 0);
  IF EXISTS (SELECT 1 FROM comprobante WHERE id_pedido = p_id_pedido AND tipo IN ('boleta','factura') AND estado_sunat NOT IN ('rechazado','anulado')) THEN
    CALL spi_notificar_admins('nota_credito_pendiente', CONCAT('Pedido ', v_numero, ' cancelado con comprobante'),
                              'Emita la nota de crédito de anulación (ver v_notas_credito_pendientes)', '/admin/comprobantes', p_id_pedido);
  END IF;
  IF v_neto > 0 THEN
    CALL spi_notificar_admins('pedido_cancelado_con_pago', CONCAT('Pedido ', v_numero, ' cancelado con pago'),
                              CONCAT('Hay S/ ', v_neto, ' por reembolsar'), '/admin/pagos/por-reembolsar', p_id_pedido);
  END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_crear_pedido_complementario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_crear_pedido_complementario(
  IN p_id_pedido_origen BIGINT UNSIGNED, IN p_items JSON, IN p_modalidad_pago VARCHAR(10), IN p_notas VARCHAR(500),
  IN p_fecha_entrega DATE, OUT p_id_pedido BIGINT UNSIGNED, OUT p_numero VARCHAR(25), OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'HU-29: pedido complementario de uno ya confirmado; hereda entrega y comprobante (y la fecha si p_fecha_entrega es NULL). Envío gratis si el original aún no salió (configurable)'
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_estado VARCHAR(20); DECLARE v_entrega VARCHAR(10);
  DECLARE v_comp VARCHAR(10); DECLARE v_ft VARCHAR(3); DECLARE v_fn VARCHAR(12); DECLARE v_fnom VARCHAR(200); DECLARE v_fdir VARCHAR(250);
  DECLARE v_fecha DATE; DECLARE v_canal VARCHAR(10);
  DECLARE v_costo DECIMAL(12,2) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_items IS NULL THEN CALL spi_error(45030, 'Indique los productos del pedido complementario'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_usuario, estado, tipo_entrega, comprobante_solicitado, facturacion_tipo_doc, facturacion_num_doc,
         facturacion_nombre, facturacion_direccion, fecha_entrega_solicitada, canal
    INTO v_usuario, v_estado, v_entrega, v_comp, v_ft, v_fn, v_fnom, v_fdir, v_fecha, v_canal
    FROM pedido WHERE id_pedido = p_id_pedido_origen FOR UPDATE;
  IF v_usuario IS NULL THEN CALL spi_error(45022, 'El pedido original no existe'); END IF;
  CALL spi_validar_dueno_o_admin(v_usuario);
  IF v_estado IN ('pendiente_pago','cancelado','devuelto') THEN
    CALL spi_error(45007, 'El pedido original debe estar confirmado y no cancelado ni devuelto');
  END IF;
  IF v_entrega = 'domicilio' AND v_estado NOT IN ('enviado','entregado') AND fn_config_entero('complementario_envio_gratis') = 1 THEN
    SET v_costo = 0;
  END IF;
  IF p_fecha_entrega IS NOT NULL AND p_fecha_entrega < fn_hoy_lima() THEN CALL spi_error(45006, 'La fecha de entrega no puede ser pasada'); END IF;
  CALL spi_crear_pedido(v_usuario, p_items, v_entrega, NULL, p_modalidad_pago, v_comp, v_ft, v_fn, v_fnom, v_fdir,
                        COALESCE(p_fecha_entrega, v_fecha), p_notas, v_canal, p_id_pedido_origen, v_costo, p_id_pedido);
  SELECT numero, total INTO p_numero, p_total FROM pedido WHERE id_pedido = p_id_pedido;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_corregir_facturacion_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_corregir_facturacion_pedido(
  IN p_id_pedido BIGINT UNSIGNED, IN p_comprobante VARCHAR(10), IN p_fact_tipo_doc VARCHAR(3), IN p_fact_num_doc VARCHAR(12),
  IN p_fact_nombre VARCHAR(200), IN p_fact_direccion VARCHAR(250))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Corrige boleta/factura y los datos del receptor (dueño o admin) mientras el pedido no tenga comprobante vigente'
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED DEFAULT NULL; DECLARE v_estado VARCHAR(20);
  DECLARE v_num VARCHAR(12) DEFAULT NULLIF(UPPER(TRIM(p_fact_num_doc)), '');
  DECLARE v_tipo VARCHAR(3) DEFAULT NULLIF(p_fact_tipo_doc, '');
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_comprobante IS NULL OR p_comprobante NOT IN ('boleta','factura') THEN CALL spi_error(45015, 'Comprobante inválido: boleta o factura'); END IF;
  IF (v_tipo IS NOT NULL OR v_num IS NOT NULL) AND NOT fn_documento_valido(v_tipo, v_num) THEN
    CALL spi_error(45006, 'Documento para el comprobante inválido (DNI 8 dígitos, RUC 11 con dígito verificador, CE 6-12)');
  END IF;
  IF p_comprobante = 'factura' AND (v_tipo IS NULL OR v_tipo <> 'RUC' OR NULLIF(TRIM(p_fact_nombre), '') IS NULL) THEN
    CALL spi_error(45015, 'La factura exige RUC válido y razón social del cliente');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_usuario, estado INTO v_usuario, v_estado FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_usuario IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  CALL spi_validar_dueno_o_admin(v_usuario);
  IF v_estado IN ('cancelado','devuelto') THEN CALL spi_error(45007, CONCAT('El pedido está ', v_estado)); END IF;
  IF EXISTS (SELECT 1 FROM comprobante WHERE pedido_activo_clave = p_id_pedido) THEN
    CALL spi_error(45016, 'El pedido ya tiene comprobante: corríjalo con una nota de crédito');
  END IF;
  UPDATE pedido SET comprobante_solicitado = p_comprobante, facturacion_tipo_doc = v_tipo, facturacion_num_doc = v_num,
                    facturacion_nombre = NULLIF(TRIM(p_fact_nombre), ''), facturacion_direccion = NULLIF(TRIM(p_fact_direccion), '')
   WHERE id_pedido = p_id_pedido;
  CALL spi_validar_pedido_completo(p_id_pedido);
  CALL spi_auditar('pedido_facturacion_corregida', 'pedido', p_id_pedido, v_usuario,
                   JSON_OBJECT('comprobante', p_comprobante, 'documento', fn_enmascarar_documento(v_num)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- G. COTIZACIONES (HU-28 / HU-17 / HU-18)
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_solicitar_cotizacion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_solicitar_cotizacion(
  IN p_id_usuario BIGINT UNSIGNED, IN p_origen VARCHAR(15), IN p_descripcion TEXT, IN p_items JSON,
  IN p_fecha_entrega DATE, IN p_imagen_url VARCHAR(500), OUT p_id_cotizacion BIGINT UNSIGNED, OUT p_numero VARCHAR(25))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Solicitud de cotización. p_items: [{"id_variante":3,"descripcion":"...","cantidad":20,"personalizacion":"..."}]'
BEGIN
  DECLARE v_malos INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  IF p_origen NOT IN ('mayor','personalizado') OR p_origen IS NULL THEN CALL spi_error(45018, 'Origen inválido: mayor o personalizado'); END IF;
  IF p_fecha_entrega IS NOT NULL AND p_fecha_entrega < fn_hoy_lima() THEN CALL spi_error(45006, 'La fecha de entrega no puede ser pasada'); END IF;
  IF p_origen = 'mayor' AND (p_fecha_entrega IS NULL OR p_fecha_entrega < fn_hoy_lima() + INTERVAL fn_config_entero('dias_minimos_mayor') DAY) THEN
    CALL spi_error(45009, CONCAT('Las cotizaciones al por mayor requieren fecha de entrega con al menos ', fn_config_entero('dias_minimos_mayor'), ' días de anticipación'));
  END IF;
  IF p_items IS NULL OR JSON_TYPE(p_items) <> 'ARRAY' OR JSON_LENGTH(p_items) = 0 OR JSON_LENGTH(p_items) > 100 THEN
    CALL spi_error(45018, 'Indique entre 1 y 100 ítems a cotizar');
  END IF;
  SELECT SUM(jt.cantidad IS NULL OR jt.cantidad < 1 OR jt.cantidad > 100000 OR (jt.id_variante IS NULL AND NULLIF(TRIM(jt.descripcion), '') IS NULL)
             OR (jt.id_variante IS NOT NULL AND v.id_variante IS NULL)
             OR COALESCE(JSON_TYPE(jt.cantidad_json), '') NOT IN ('INTEGER','UNSIGNED INTEGER'))
    INTO v_malos
    FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_variante BIGINT UNSIGNED PATH '$.id_variante', descripcion VARCHAR(250) PATH '$.descripcion',
                                             cantidad INT PATH '$.cantidad', cantidad_json JSON PATH '$.cantidad')) jt
    LEFT JOIN variante_producto v ON v.id_variante = jt.id_variante;
  IF v_malos > 0 THEN CALL spi_error(45018, 'Ítems inválidos: cada uno necesita una cantidad entera y una variante existente o una descripción'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF NOT EXISTS (SELECT 1 FROM usuario WHERE id_usuario = p_id_usuario AND estado = 'activo') THEN
    CALL spi_error(45021, 'La cuenta no está activa');
  END IF;
  INSERT INTO cotizacion (numero, id_usuario, origen, descripcion, imagen_referencia_url, fecha_entrega_solicitada)
  VALUES (NULL, p_id_usuario, p_origen, p_descripcion, NULLIF(TRIM(p_imagen_url), ''), p_fecha_entrega);
  SET p_id_cotizacion = LAST_INSERT_ID();
  INSERT INTO item_cotizacion (id_cotizacion, id_variante, descripcion, cantidad, personalizacion)
  SELECT p_id_cotizacion, jt.id_variante,
         LEFT(COALESCE(NULLIF(TRIM(jt.descripcion), ''), CONCAT_WS(' ', p.nombre, v.talla, v.color)), 250),
         jt.cantidad, NULLIF(TRIM(jt.personalizacion), '')
    FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_variante BIGINT UNSIGNED PATH '$.id_variante', descripcion VARCHAR(250) PATH '$.descripcion',
                                             cantidad INT PATH '$.cantidad', personalizacion VARCHAR(500) PATH '$.personalizacion')) jt
    LEFT JOIN variante_producto v ON v.id_variante = jt.id_variante
    LEFT JOIN producto p ON p.id_producto = v.id_producto;
  SELECT numero INTO p_numero FROM cotizacion WHERE id_cotizacion = p_id_cotizacion;
  CALL spi_notificar_admins('cotizacion_nueva', CONCAT('Nueva cotización ', p_numero), CONCAT('Origen: ', p_origen), '/admin/cotizaciones', NULL);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cambiar_estado_cotizacion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cambiar_estado_cotizacion(
  IN p_id_cotizacion BIGINT UNSIGNED, IN p_estado VARCHAR(15), IN p_motivo VARCHAR(300))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Pasa a en_revision (admin) o rechazada (admin; o el cliente si ya está cotizada)'
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_estado NOT IN ('en_revision','rechazada') OR p_estado IS NULL THEN
    CALL spi_error(45018, 'Use sp_cotizar o sp_aceptar_cotizacion para los demás estados');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT id_usuario, estado INTO v_usuario, v_estado FROM cotizacion WHERE id_cotizacion = p_id_cotizacion FOR UPDATE;
  IF v_usuario IS NULL THEN CALL spi_error(45022, 'La cotización no existe'); END IF;
  IF NOT fn_es_admin(fn_actor()) THEN
    CALL spi_validar_dueno_o_admin(v_usuario);
    IF NOT (p_estado = 'rechazada' AND v_estado = 'cotizada') THEN CALL spi_error(45023, 'Solo puede rechazar una cotización ya cotizada'); END IF;
  END IF;
  IF p_estado = 'rechazada' AND (p_motivo IS NULL OR TRIM(p_motivo) = '') THEN CALL spi_error(45018, 'Indique el motivo del rechazo'); END IF;
  UPDATE cotizacion SET estado = p_estado, motivo_rechazo = IF(p_estado = 'rechazada', p_motivo, motivo_rechazo)
   WHERE id_cotizacion = p_id_cotizacion;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_cotizar $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_cotizar(
  IN p_id_cotizacion BIGINT UNSIGNED, IN p_precios JSON, IN p_costo_envio DECIMAL(12,2), IN p_adelanto_pct DECIMAL(5,2),
  IN p_vigencia_dias INT, IN p_respuesta TEXT, IN p_fecha_entrega_acordada DATE, OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El administrador fija precios ([{"id_item_cotizacion":1,"precio_unitario":45.00}]), envío (NULL = tarifa de la zona al aceptar), adelanto, vigencia y (opcional) la fecha de entrega acordada'
BEGIN
  DECLARE v_estado VARCHAR(15); DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_numero VARCHAR(25);
  DECLARE v_sub DECIMAL(12,2); DECLARE v_sin_precio INT; DECLARE v_correo VARCHAR(254);
  DECLARE v_pct DECIMAL(5,2); DECLARE v_vigencia DATE;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_precios IS NULL OR JSON_TYPE(p_precios) <> 'ARRAY' THEN CALL spi_error(45018, 'Precios inválidos'); END IF;
  IF COALESCE(p_costo_envio, 0) < 0 THEN CALL spi_error(45018, 'Costo de envío inválido'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT c.estado, c.id_usuario, c.numero, u.correo INTO v_estado, v_usuario, v_numero, v_correo
    FROM cotizacion c JOIN usuario u ON u.id_usuario = c.id_usuario WHERE c.id_cotizacion = p_id_cotizacion FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'La cotización no existe'); END IF;
  IF v_estado NOT IN ('solicitada','en_revision') THEN CALL spi_error(45018, CONCAT('No se puede cotizar una cotización en estado ', v_estado)); END IF;
  IF v_estado = 'solicitada' THEN
    UPDATE cotizacion SET estado = 'en_revision' WHERE id_cotizacion = p_id_cotizacion;
  END IF;
  UPDATE item_cotizacion ic
    JOIN JSON_TABLE(p_precios, '$[*]' COLUMNS (id_item BIGINT UNSIGNED PATH '$.id_item_cotizacion', precio DECIMAL(10,2) PATH '$.precio_unitario')) jt
      ON jt.id_item = ic.id_item_cotizacion
     SET ic.precio_unitario = jt.precio, ic.actualizado_en = UTC_TIMESTAMP(3)
   WHERE ic.id_cotizacion = p_id_cotizacion;
  SELECT COALESCE(SUM(subtotal), 0), SUM(precio_unitario IS NULL OR precio_unitario <= 0) INTO v_sub, v_sin_precio
    FROM item_cotizacion WHERE id_cotizacion = p_id_cotizacion;
  IF v_sin_precio > 0 THEN CALL spi_error(45018, 'Todos los ítems deben tener precio unitario mayor a cero'); END IF;
  SET v_pct = COALESCE(p_adelanto_pct, fn_config_decimal('adelanto_porcentaje'));
  IF v_pct <= 0 OR v_pct > 100 THEN CALL spi_error(45018, 'Porcentaje de adelanto inválido (1 a 100)'); END IF;
  IF p_vigencia_dias IS NOT NULL AND (p_vigencia_dias < 1 OR p_vigencia_dias > 90) THEN CALL spi_error(45018, 'Vigencia inválida (1 a 90 días)'); END IF;
  SET v_vigencia = fn_hoy_lima() + INTERVAL COALESCE(p_vigencia_dias, fn_config_entero('cotizacion_vigencia_dias')) DAY;
  IF p_fecha_entrega_acordada IS NOT NULL THEN
    IF p_fecha_entrega_acordada < fn_hoy_lima() THEN CALL spi_error(45006, 'La fecha de entrega acordada no puede ser pasada'); END IF;
    UPDATE cotizacion SET fecha_entrega_solicitada = p_fecha_entrega_acordada WHERE id_cotizacion = p_id_cotizacion;
  END IF;
  UPDATE cotizacion
     SET estado = 'cotizada', subtotal = v_sub, costo_envio = p_costo_envio, total = v_sub + COALESCE(p_costo_envio, 0),
         adelanto_porcentaje = v_pct, vigencia_hasta = v_vigencia, respuesta = p_respuesta, id_admin = fn_actor(), cotizado_en = UTC_TIMESTAMP(3)
   WHERE id_cotizacion = p_id_cotizacion;
  SET p_total = v_sub + COALESCE(p_costo_envio, 0);
  CALL spi_encolar_correo(v_usuario, v_correo, 'cotizacion_lista',
                          JSON_OBJECT('numero', v_numero, 'total', p_total, 'vigencia_hasta', v_vigencia, 'adelanto_porcentaje', v_pct), 4);
  CALL spi_notificar(v_usuario, 'cotizacion_lista', CONCAT('Tu cotización ', v_numero, ' está lista'),
                     CONCAT('Total S/ ', p_total, '. Vigente hasta ', v_vigencia), '/mi-cuenta/cotizaciones', NULL);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_aceptar_cotizacion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_aceptar_cotizacion(
  IN p_id_cotizacion BIGINT UNSIGNED, IN p_tipo_entrega VARCHAR(10), IN p_id_direccion BIGINT UNSIGNED, IN p_modalidad_pago VARCHAR(10),
  IN p_comprobante VARCHAR(10), IN p_fact_tipo_doc VARCHAR(3), IN p_fact_num_doc VARCHAR(12), IN p_fact_nombre VARCHAR(200),
  IN p_fact_direccion VARCHAR(250), IN p_notas VARCHAR(500),
  OUT p_id_pedido BIGINT UNSIGNED, OUT p_numero VARCHAR(25), OUT p_total DECIMAL(12,2))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Acepta una cotización vigente y la convierte ATÓMICAMENTE en pedido con los precios y el adelanto cotizados'
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15); DECLARE v_origen VARCHAR(15);
  DECLARE v_vigencia DATE; DECLARE v_envio DECIMAL(12,2); DECLARE v_pct DECIMAL(5,2); DECLARE v_fecha DATE;
  DECLARE v_fin BOOLEAN DEFAULT 0;
  DECLARE c_var BIGINT UNSIGNED; DECLARE c_cant INT; DECLARE c_precio DECIMAL(10,2); DECLARE c_desc VARCHAR(250); DECLARE c_pers VARCHAR(500);
  DECLARE v_item BIGINT UNSIGNED;
  DECLARE cur CURSOR FOR
    SELECT id_variante, cantidad, precio_unitario, descripcion, personalizacion
      FROM item_cotizacion WHERE id_cotizacion = p_id_cotizacion ORDER BY COALESCE(id_variante, 0), id_item_cotizacion;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT id_usuario, estado, origen, vigencia_hasta, costo_envio, adelanto_porcentaje, fecha_entrega_solicitada
      INTO v_usuario, v_estado, v_origen, v_vigencia, v_envio, v_pct, v_fecha
      FROM cotizacion WHERE id_cotizacion = p_id_cotizacion FOR UPDATE;
    IF v_usuario IS NULL THEN CALL spi_error(45022, 'La cotización no existe'); END IF;
    CALL spi_validar_dueno_o_admin(v_usuario);
    IF v_estado <> 'cotizada' THEN CALL spi_error(45018, CONCAT('Solo se acepta una cotización en estado cotizada (está ', v_estado, ')')); END IF;
    IF v_vigencia < fn_hoy_lima() THEN CALL spi_error(45018, 'La cotización está vencida: solicite una nueva'); END IF;

    -- Envío: el cotizado si se fijó; si no (NULL), la tarifa de la zona de la dirección elegida
    CALL spi_insertar_pedido(v_usuario, IF(v_origen = 'mayor', 'mayor', 'menor'), 'web', p_tipo_entrega, p_id_direccion, NULL,
                             p_modalidad_pago, v_pct, p_comprobante, p_fact_tipo_doc, p_fact_num_doc, p_fact_nombre, p_fact_direccion,
                             v_fecha, p_notas, p_id_cotizacion, NULL, IF(p_tipo_entrega = 'domicilio', v_envio, NULL), p_id_pedido);
    SET v_fin = 0;
    OPEN cur;
    leer: LOOP
      FETCH cur INTO c_var, c_cant, c_precio, c_desc, c_pers;
      IF v_fin THEN LEAVE leer; END IF;
      CALL spi_agregar_item_interno(p_id_pedido, c_var, c_cant, c_pers, c_precio, c_desc, v_item);
    END LOOP leer;
    CLOSE cur;
    CALL spi_validar_pedido_completo(p_id_pedido);

    UPDATE cotizacion SET estado = 'aceptada', aceptado_en = UTC_TIMESTAMP(3) WHERE id_cotizacion = p_id_cotizacion;
    UPDATE cotizacion SET estado = 'convertida' WHERE id_cotizacion = p_id_cotizacion;
    SELECT numero, total INTO p_numero, p_total FROM pedido WHERE id_pedido = p_id_pedido;
    CALL spi_auditar('cotizacion_convertida', 'cotizacion', p_id_cotizacion, v_usuario, JSON_OBJECT('pedido', p_numero), 'procedimiento');
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

-- #####################################################################
-- H. ENVÍOS Y SEGUIMIENTO (HU-12)
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_registrar_envio $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_envio(
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_courier SMALLINT UNSIGNED, IN p_numero_guia VARCHAR(60), IN p_fecha_estimada DATE,
  IN p_costo_real DECIMAL(8,2), IN p_observaciones VARCHAR(300), OUT p_id_envio BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Despacha un pedido a domicilio: crea el envío, su primer evento y pasa el pedido de listo a enviado (respeta la regla de saldo). Idempotente: si ya salió, devuelve el envío existente'
BEGIN
  DECLARE v_estado VARCHAR(20); DECLARE v_entrega VARCHAR(10);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT estado, tipo_entrega INTO v_estado, v_entrega FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
  IF v_entrega <> 'domicilio' THEN CALL spi_error(45028, 'Los pedidos de recojo en tienda no se envían'); END IF;
  IF p_id_courier IS NOT NULL AND NOT EXISTS (SELECT 1 FROM courier WHERE id_courier = p_id_courier AND activo = 1) THEN
    CALL spi_error(45028, 'Courier inexistente o inactivo');
  END IF;
  IF p_costo_real IS NOT NULL AND p_costo_real < 0 THEN CALL spi_error(45028, 'Costo del courier inválido'); END IF;
  SET p_id_envio = NULL;
  IF v_estado = 'enviado' THEN
    -- Doble clic o reintento: se devuelve el envío ya registrado en lugar de crear otro
    SELECT MAX(id_envio) INTO p_id_envio FROM envio WHERE id_pedido = p_id_pedido AND estado <> 'devuelto';
  END IF;
  IF p_id_envio IS NULL THEN
    IF NULLIF(TRIM(p_numero_guia), '') IS NOT NULL
       AND EXISTS (SELECT 1 FROM envio WHERE id_courier <=> p_id_courier AND numero_guia = TRIM(p_numero_guia)) THEN
      CALL spi_error(45028, 'Esa guía ya está registrada para el courier');
    END IF;
    IF v_estado = 'listo' THEN
      CALL spi_cambiar_estado_pedido(p_id_pedido, 'enviado', CONCAT('Despachado', IF(p_numero_guia IS NULL, '', CONCAT(' guía ', p_numero_guia))), 0);
    ELSEIF v_estado <> 'enviado' THEN
      CALL spi_error(45002, CONCAT('Solo se despacha un pedido listo (está ', v_estado, ')'));
    END IF;
    INSERT INTO envio (id_pedido, id_courier, numero_guia, estado, costo_real, fecha_entrega_estimada, despachado_en, observaciones)
    VALUES (p_id_pedido, p_id_courier, NULLIF(TRIM(p_numero_guia), ''), 'despachado', p_costo_real, p_fecha_estimada, UTC_TIMESTAMP(3), p_observaciones);
    SET p_id_envio = LAST_INSERT_ID();
    INSERT INTO seguimiento_envio (id_envio, estado, descripcion, ocurrido_en, origen, registrado_por)
    VALUES (p_id_envio, 'despachado', 'Pedido despachado', UTC_TIMESTAMP(3), 'admin', fn_actor());
  END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_seguimiento_envio $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_seguimiento_envio(
  IN p_id_envio BIGINT UNSIGNED, IN p_estado VARCHAR(15), IN p_descripcion VARCHAR(300), IN p_ubicacion VARCHAR(120),
  IN p_ocurrido_en DATETIME(3), IN p_origen VARCHAR(15), IN p_id_evento_externo VARCHAR(100), OUT p_duplicado BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Agrega un evento de seguimiento (idempotente por id de evento del courier). "entregado" cierra el pedido'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado_pedido VARCHAR(20); DECLARE v_numero VARCHAR(25);
  DECLARE v_fallo_estado BOOLEAN DEFAULT 0; DECLARE v_msg VARCHAR(255) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF NOT (fn_es_admin(fn_actor()) OR (COALESCE(p_origen, '') = 'api_courier' AND fn_actor() IS NULL)) THEN
    CALL spi_error(45023, 'Solo un administrador o la integración del courier registran seguimiento');
  END IF;
  IF p_estado IS NULL OR p_estado NOT IN ('preparando','despachado','en_transito','en_reparto','entregado','incidencia','devuelto') THEN
    CALL spi_error(45028, 'Estado de seguimiento inválido');
  END IF;
  IF p_origen IS NOT NULL AND p_origen NOT IN ('admin','api_courier','sistema') THEN CALL spi_error(45028, 'Origen de seguimiento inválido'); END IF;
  SET p_duplicado = 0;
  SET @wanka_ctx_interno = fn_token_interno();
  SELECT id_pedido INTO v_pedido FROM envio WHERE id_envio = p_id_envio;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El envío no existe'); END IF;
  START TRANSACTION;
  SELECT estado, numero INTO v_estado_pedido, v_numero FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
  SELECT id_envio INTO @wanka_x FROM envio WHERE id_envio = p_id_envio FOR UPDATE;
  IF p_id_evento_externo IS NOT NULL AND EXISTS (SELECT 1 FROM seguimiento_envio WHERE id_envio = p_id_envio AND id_evento_externo = p_id_evento_externo) THEN
    SET p_duplicado = 1;
  ELSE
    INSERT INTO seguimiento_envio (id_envio, estado, descripcion, ubicacion, ocurrido_en, origen, id_evento_externo, registrado_por)
    VALUES (p_id_envio, p_estado, p_descripcion, p_ubicacion, COALESCE(p_ocurrido_en, UTC_TIMESTAMP(3)), COALESCE(p_origen, 'admin'),
            p_id_evento_externo, fn_actor());
    UPDATE envio SET estado = p_estado, entregado_en = IF(p_estado = 'entregado', COALESCE(p_ocurrido_en, UTC_TIMESTAMP(3)), entregado_en)
     WHERE id_envio = p_id_envio;
    IF p_estado = 'entregado' AND v_estado_pedido = 'enviado' THEN
      -- Si el pedido no puede cerrarse (p. ej. saldo pendiente), el evento del courier igual queda registrado
      SAVEPOINT antes_de_cerrar_pedido;
      BEGIN
        DECLARE CONTINUE HANDLER FOR SQLSTATE '45000' BEGIN
          GET DIAGNOSTICS CONDITION 1 v_msg = MESSAGE_TEXT;
          SET v_fallo_estado = 1;
        END;
        CALL spi_cambiar_estado_pedido(v_pedido, 'entregado', 'Entrega confirmada por el envío', 1);
      END;
      IF v_fallo_estado THEN
        ROLLBACK TO SAVEPOINT antes_de_cerrar_pedido;
        SET @wanka_ctx_interno = fn_token_interno();
        CALL spi_notificar_admins('entrega_sin_cerrar', CONCAT('Pedido ', v_numero, ' entregado por el courier'),
                                  LEFT(CONCAT('No se pudo cerrar el pedido: ', COALESCE(v_msg, 'error')), 300), '/admin/pedidos', v_pedido);
      END IF;
    END IF;
  END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- I. PAGOS, WEBHOOKS Y REEMBOLSOS
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_registrar_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_pago(
  IN p_id_pedido BIGINT UNSIGNED, IN p_metodo VARCHAR(20), IN p_monto DECIMAL(12,2), IN p_idempotency_key VARCHAR(100),
  IN p_referencia_externa VARCHAR(100), IN p_voucher_url VARCHAR(500), IN p_datos_pasarela JSON,
  IN p_moneda_cobro CHAR(3), IN p_monto_cobro DECIMAL(12,2), IN p_tipo_cambio DECIMAL(10,6),
  OUT p_id_pago BIGINT UNSIGNED, OUT p_estado VARCHAR(15), OUT p_duplicado BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra un intento de pago. Idempotente por idempotency_key (doble clic). Manual → en_revision; pasarela → pendiente hasta el webhook'
BEGIN
  DECLARE v_estado_pedido VARCHAR(20); DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_total DECIMAL(12,2);
  DECLARE v_neto DECIMAL(12,2); DECLARE v_requerido DECIMAL(12,2); DECLARE v_modalidad VARCHAR(10); DECLARE v_estado_pago VARCHAR(12);
  DECLARE v_moneda CHAR(3); DECLARE v_canal VARCHAR(10); DECLARE v_subtotal DECIMAL(12,2); DECLARE v_expira DATETIME(3);
  DECLARE v_m_tipo VARCHAR(10); DECLARE v_m_comprobante BOOLEAN; DECLARE v_m_canal VARCHAR(10); DECLARE v_m_activo BOOLEAN;
  DECLARE v_en_revision DECIMAL(12,2); DECLARE v_tipo VARCHAR(10); DECLARE v_saldo DECIMAL(12,2);
  DECLARE e_pedido BIGINT UNSIGNED; DECLARE e_monto DECIMAL(12,2); DECLARE e_metodo VARCHAR(20);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR 1062 BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL;
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La operación o la clave de idempotencia ya fueron registradas', MYSQL_ERRNO = 45027; END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;

    SET p_duplicado = 0;
    IF p_idempotency_key IS NULL OR CHAR_LENGTH(p_idempotency_key) < 16 THEN
      CALL spi_error(45017, 'Falta la clave de idempotencia (mínimo 16 caracteres, p. ej. un UUID por intento de pago)');
    END IF;
    IF p_monto IS NULL OR p_monto <= 0 THEN CALL spi_error(45017, 'Monto de pago inválido'); END IF;
    IF NOT COALESCE((p_moneda_cobro IS NULL AND p_monto_cobro IS NULL) OR (p_moneda_cobro IN ('PEN','USD') AND p_monto_cobro > 0), FALSE)
       OR (p_tipo_cambio IS NOT NULL AND p_tipo_cambio <= 0) THEN
      CALL spi_error(45017, 'Moneda y monto cobrados por la pasarela inválidos (ambos o ninguno; PEN o USD)');
    END IF;
    IF fn_contiene_datos_tarjeta(p_datos_pasarela) THEN
      CALL spi_error(45031, 'datos_pasarela contiene datos de tarjeta: está prohibido guardarlos');
    END IF;

    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    -- 1) Bloqueo del pedido (serializa pagos simultáneos del mismo pedido)
    SELECT estado, id_usuario, total - monto_devuelto - monto_ajustes, monto_neto_pagado, monto_requerido, modalidad_pago, estado_pago, moneda, canal, subtotal, expira_en
      INTO v_estado_pedido, v_usuario, v_total, v_neto, v_requerido, v_modalidad, v_estado_pago, v_moneda, v_canal, v_subtotal, v_expira
      FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
    IF v_nf THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
    CALL spi_validar_dueno_o_admin(v_usuario);

    -- 2) Idempotencia: el mismo intento devuelve el mismo pago
    SELECT id_pago, id_pedido, monto, metodo, estado INTO p_id_pago, e_pedido, e_monto, e_metodo, p_estado
      FROM pago WHERE idempotency_key = p_idempotency_key;
    IF NOT v_nf THEN
      IF e_pedido <> p_id_pedido OR e_monto <> p_monto OR e_metodo <> p_metodo THEN
        CALL spi_error(45027, 'La clave de idempotencia ya se usó con otros datos');
      END IF;
      SET p_duplicado = 1;
    ELSE
      SET v_nf = 0;
      IF v_estado_pedido IN ('cancelado','devuelto') THEN CALL spi_error(45017, CONCAT('El pedido está ', v_estado_pedido)); END IF;
      IF v_estado_pedido = 'pendiente_pago' AND v_expira IS NOT NULL AND v_expira < UTC_TIMESTAMP(3) THEN
        CALL spi_error(45007, 'El plazo para pagar este pedido venció: genere un pedido nuevo');
      END IF;
      IF v_subtotal <= 0 THEN CALL spi_error(45030, 'No se cobra un pedido sin productos'); END IF;
      IF v_estado_pago = 'pagado' THEN CALL spi_error(45003, 'El pedido ya está pagado'); END IF;

      SELECT tipo, requiere_comprobante, canal, activo INTO v_m_tipo, v_m_comprobante, v_m_canal, v_m_activo
        FROM metodo_pago WHERE codigo = p_metodo;
      IF v_nf OR NOT v_m_activo THEN CALL spi_error(45017, 'Método de pago inexistente o no disponible'); END IF;
      IF v_m_canal = 'presencial' AND NOT fn_es_admin(fn_actor()) THEN
        CALL spi_error(45017, 'Ese método solo se usa en venta presencial (lo registra un administrador)');
      END IF;
      IF v_m_comprobante AND NULLIF(TRIM(p_voucher_url), '') IS NULL AND NULLIF(TRIM(p_referencia_externa), '') IS NULL THEN
        CALL spi_error(45017, 'Adjunte el voucher o el número de operación');
      END IF;

      -- 3) Montos: nunca más que el saldo; la modalidad define el primer pago. Cuentan también los pagos
      --    por validar y los cobros de pasarela aún en proceso (dentro del plazo de gracia)
      SET v_saldo = v_total - v_neto;
      SELECT COALESCE(SUM(monto), 0) INTO v_en_revision FROM pago
       WHERE id_pedido = p_id_pedido
         AND (estado = 'en_revision'
              OR (estado = 'pendiente' AND creado_en > UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('minutos_gracia_pago_pasarela') MINUTE))
         FOR SHARE;
      IF p_monto > v_saldo THEN
        CALL spi_error(45003, CONCAT('El pago (S/ ', p_monto, ') excede el saldo del pedido (S/ ', v_saldo, ')'));
      END IF;
      IF p_monto + v_en_revision > v_saldo THEN
        CALL spi_error(45003, CONCAT('Ya hay S/ ', v_en_revision, ' en revisión o en proceso: el pago excedería el saldo (S/ ', v_saldo, ')'));
      END IF;
      IF v_neto = 0 THEN
        IF v_modalidad = 'total' AND p_monto <> v_total THEN
          CALL spi_error(45017, CONCAT('Con la modalidad pago total debe pagar S/ ', v_total));
        END IF;
        IF v_modalidad = 'adelanto' AND p_monto < v_requerido THEN
          CALL spi_error(45017, CONCAT('El adelanto mínimo es S/ ', v_requerido));
        END IF;
        SET v_tipo = IF(p_monto >= v_total, 'total', 'adelanto');
      ELSE
        SET v_tipo = 'saldo';
      END IF;

      SET p_estado = IF(v_m_tipo = 'manual', 'en_revision', 'pendiente');
      INSERT INTO pago (id_pedido, metodo, tipo, monto, moneda, moneda_cobro, monto_cobro, tipo_cambio, estado,
                        referencia_externa, idempotency_key, voucher_url, datos_pasarela, ip)
      VALUES (p_id_pedido, p_metodo, v_tipo, p_monto, v_moneda, p_moneda_cobro, p_monto_cobro, p_tipo_cambio, p_estado,
              NULLIF(TRIM(p_referencia_externa), ''), p_idempotency_key, NULLIF(TRIM(p_voucher_url), ''), p_datos_pasarela, fn_ip_sesion());
      SET p_id_pago = LAST_INSERT_ID();
      IF p_estado = 'en_revision' THEN
        CALL spi_notificar_admins('pago_por_validar', CONCAT('Pago por validar: ', p_metodo), CONCAT('S/ ', p_monto), '/admin/pagos/por-validar', p_id_pedido);
      END IF;
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_confirmar_pago_manual $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_confirmar_pago_manual(IN p_id_pago BIGINT UNSIGNED, OUT p_estado_pedido VARCHAR(20))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Un administrador valida un Yape/Plin/transferencia/efectivo. Si dos lo intentan a la vez, el segundo recibe "ya fue validado"'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15); DECLARE v_metodo VARCHAR(20); DECLARE v_monto DECIMAL(12,2);
  DECLARE v_tipo VARCHAR(10); DECLARE v_voucher VARCHAR(500); DECLARE v_ref VARCHAR(100); DECLARE v_req BOOLEAN;
  DECLARE v_estado_pedido VARCHAR(20); DECLARE v_saldo DECIMAL(12,2); DECLARE v_validador BIGINT UNSIGNED;
  DECLARE v_aplicado BOOLEAN DEFAULT 1; DECLARE v_motivo VARCHAR(20) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  -- Búsqueda previa FUERA de la transacción: así la instantánea (REPEATABLE READ) nace después del bloqueo del pedido
  SELECT id_pedido INTO v_pedido FROM pago WHERE id_pago = p_id_pago;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El pago no existe'); END IF;
  START TRANSACTION;
  SELECT estado, saldo INTO v_estado_pedido, v_saldo FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;   -- orden: pedido → pago
  SELECT p.estado, p.metodo, p.monto, m.tipo, p.voucher_url, p.referencia_externa, m.requiere_comprobante, p.validado_por
    INTO v_estado, v_metodo, v_monto, v_tipo, v_voucher, v_ref, v_req, v_validador
    FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE p.id_pago = p_id_pago FOR UPDATE;
  IF v_tipo <> 'manual' THEN CALL spi_error(45023, 'Los pagos por pasarela se confirman solo con su webhook'); END IF;
  IF v_estado <> 'en_revision' THEN
    CALL spi_error(45004, CONCAT('El pago ya fue ', v_estado, IF(v_validador IS NULL, '', CONCAT(' por el usuario ', v_validador))));
  END IF;
  IF v_req AND v_voucher IS NULL AND v_ref IS NULL THEN CALL spi_error(45017, 'El pago no tiene voucher ni número de operación'); END IF;
  IF v_estado_pedido IN ('cancelado','devuelto') THEN
    -- El dinero existe: se confirma como huérfano para reembolsarlo (no se pierde ni se ignora)
    SET v_aplicado = 0; SET v_motivo = 'pedido_cancelado';
  ELSEIF v_monto > v_saldo THEN
    -- El dinero entró (p. ej. otro pago se confirmó antes): se registra como huérfano para reembolsarlo
    SET v_aplicado = 0; SET v_motivo = 'excede_total';
  END IF;
  UPDATE pago SET estado = 'confirmado', validado_por = fn_actor(), validado_en = UTC_TIMESTAMP(3), confirmado_en = UTC_TIMESTAMP(3),
                  aplicado_al_pedido = v_aplicado, motivo_no_aplicado = v_motivo
   WHERE id_pago = p_id_pago;
  IF NOT v_aplicado THEN
    CALL spi_notificar_admins('pago_por_reembolsar', 'Pago confirmado sin saldo que cubrir',
                              CONCAT('Pago ', p_id_pago, ' por S/ ', v_monto, ': reembolsar'), '/admin/pagos/por-reembolsar', v_pedido);
  END IF;
  SELECT estado INTO p_estado_pedido FROM pedido WHERE id_pedido = v_pedido;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_rechazar_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_rechazar_pago(IN p_id_pago BIGINT UNSIGNED, IN p_motivo VARCHAR(300))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Un administrador rechaza un pago manual con motivo (se avisa al cliente por trigger)'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_motivo IS NULL OR CHAR_LENGTH(TRIM(p_motivo)) < 5 THEN CALL spi_error(45017, 'Indique el motivo del rechazo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  -- Búsqueda previa FUERA de la transacción: así la instantánea (REPEATABLE READ) nace después del bloqueo del pedido
  SELECT id_pedido INTO v_pedido FROM pago WHERE id_pago = p_id_pago;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El pago no existe'); END IF;
  START TRANSACTION;
  SELECT id_pedido INTO @wanka_x FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
  SELECT p.estado, m.tipo INTO v_estado, @wanka_tipo_metodo FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE p.id_pago = p_id_pago FOR UPDATE;
  IF @wanka_tipo_metodo <> 'manual' THEN
    CALL spi_error(45023, 'Los pagos por pasarela no se rechazan a mano: su resultado llega por webhook');
  END IF;
  IF v_estado NOT IN ('pendiente','en_revision') THEN CALL spi_error(45004, CONCAT('El pago ya está ', v_estado)); END IF;
  UPDATE pago SET estado = 'rechazado', motivo_rechazo = p_motivo, validado_por = fn_actor(), validado_en = UTC_TIMESTAMP(3)
   WHERE id_pago = p_id_pago;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_anular_pago_pendiente $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_anular_pago_pendiente(IN p_id_pago BIGINT UNSIGNED, IN p_motivo VARCHAR(300))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El cliente (o un administrador) abandona un cobro de pasarela pendiente. Si la pasarela lo aprueba después, el webhook lo registra igual (huérfano si ya no hace falta)'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED DEFAULT NULL; DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15); DECLARE v_tipo VARCHAR(10);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  SELECT id_pedido INTO v_pedido FROM pago WHERE id_pago = p_id_pago;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El pago no existe'); END IF;
  START TRANSACTION;
  SELECT id_usuario INTO v_usuario FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
  CALL spi_validar_dueno_o_admin(v_usuario);
  SELECT p.estado, m.tipo INTO v_estado, v_tipo FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE p.id_pago = p_id_pago FOR UPDATE;
  IF v_tipo <> 'pasarela' THEN CALL spi_error(45023, 'Solo se anulan cobros de pasarela; un pago manual lo rechaza el administrador'); END IF;
  IF v_estado <> 'pendiente' THEN CALL spi_error(45004, CONCAT('El pago ya está ', v_estado)); END IF;
  UPDATE pago SET estado = 'anulado', motivo_rechazo = LEFT(COALESCE(NULLIF(TRIM(p_motivo), ''), 'Cobro abandonado'), 300) WHERE id_pago = p_id_pago;
  CALL spi_auditar('pago_anulado', 'pago', p_id_pago, v_usuario, JSON_OBJECT('motivo', LEFT(p_motivo, 200)), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_evento_pasarela $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_evento_pasarela(
  IN p_proveedor VARCHAR(20), IN p_id_externo VARCHAR(150), IN p_tipo VARCHAR(80), IN p_payload JSON, IN p_firma_valida BOOLEAN,
  OUT p_id_evento BIGINT UNSIGNED, OUT p_ya_procesado BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Guarda un webhook una sola vez (proveedor + id externo). Si ya se procesó, p_ya_procesado = 1 y la app no debe repetir nada'
BEGIN
  DECLARE v_estado VARCHAR(12);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_payload IS NULL THEN CALL spi_error(45006, 'Webhook sin cuerpo'); END IF;
  IF p_proveedor IS NULL OR p_proveedor NOT IN ('mercadopago','paypal','ose','courier') THEN CALL spi_error(45006, 'Proveedor de webhook inválido'); END IF;
  IF NULLIF(TRIM(p_id_externo), '') IS NULL THEN CALL spi_error(45006, 'Falta el id del evento del proveedor'); END IF;
  IF fn_contiene_datos_tarjeta(p_payload) THEN CALL spi_error(45031, 'El webhook trae datos de tarjeta: fíltrelos antes de guardar'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  -- Si antes llegó una copia con firma inválida (posible falsificación con el mismo id), la copia con firma
  -- válida la reemplaza: así un evento falso no bloquea al verdadero. Las asignaciones se evalúan en orden.
  INSERT INTO evento_pasarela (proveedor, id_externo, tipo, payload, firma_valida, intentos)
  VALUES (p_proveedor, p_id_externo, p_tipo, p_payload, COALESCE(p_firma_valida, 0), 1) AS nuevo
  ON DUPLICATE KEY UPDATE   -- COMPAT-MARIADB: usar VALUES(columna) en lugar del alias "nuevo"
    id_evento    = LAST_INSERT_ID(evento_pasarela.id_evento),
    intentos     = evento_pasarela.intentos + 1,
    payload      = IF(evento_pasarela.firma_valida = 0 AND nuevo.firma_valida = 1 AND evento_pasarela.estado NOT IN ('procesado','ignorado'), nuevo.payload, evento_pasarela.payload),
    tipo         = IF(evento_pasarela.firma_valida = 0 AND nuevo.firma_valida = 1 AND evento_pasarela.estado NOT IN ('procesado','ignorado'), nuevo.tipo, evento_pasarela.tipo),
    firma_valida = IF(evento_pasarela.firma_valida = 0 AND nuevo.firma_valida = 1 AND evento_pasarela.estado NOT IN ('procesado','ignorado'), 1, evento_pasarela.firma_valida);
  SET p_id_evento = LAST_INSERT_ID();
  SELECT estado INTO v_estado FROM evento_pasarela WHERE id_evento = p_id_evento FOR UPDATE;
  SET p_ya_procesado = (v_estado IN ('procesado','ignorado'));
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_procesar_pago_pasarela $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_procesar_pago_pasarela(
  IN p_id_evento BIGINT UNSIGNED, IN p_metodo VARCHAR(20), IN p_idempotency_key VARCHAR(100), IN p_referencia_externa VARCHAR(100),
  IN p_estado_externo VARCHAR(15), IN p_monto DECIMAL(12,2), IN p_moneda_cobro CHAR(3), IN p_monto_cobro DECIMAL(12,2),
  IN p_tipo_cambio DECIMAL(10,6), IN p_datos JSON, OUT p_resultado VARCHAR(25))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Aplica un webhook verificado (aprobado/rechazado/pendiente). Si el pedido ya estaba cancelado, el cobro se guarda como pago huérfano por reembolsar'
BEGIN
  DECLARE v_estado_evento VARCHAR(12); DECLARE v_firma BOOLEAN;
  DECLARE v_pago BIGINT UNSIGNED DEFAULT NULL; DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15); DECLARE v_monto DECIMAL(12,2);
  DECLARE v_estado_pedido VARCHAR(20); DECLARE v_saldo DECIMAL(12,2); DECLARE v_motivo_cancel VARCHAR(200);
  DECLARE v_aplicado BOOLEAN DEFAULT 1; DECLARE v_motivo VARCHAR(20) DEFAULT NULL;
  DECLARE v_proveedor VARCHAR(20); DECLARE v_metodo_pago VARCHAR(20); DECLARE v_tipo_metodo VARCHAR(10);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_pago = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    IF p_estado_externo IS NULL OR p_estado_externo NOT IN ('aprobado','rechazado','pendiente','revertido') THEN
      CALL spi_error(45006, 'Estado externo inválido: aprobado, rechazado, pendiente o revertido');
    END IF;
    IF NOT COALESCE((p_moneda_cobro IS NULL AND p_monto_cobro IS NULL) OR (p_moneda_cobro IN ('PEN','USD') AND p_monto_cobro > 0), FALSE)
       OR (p_tipo_cambio IS NOT NULL AND p_tipo_cambio <= 0) THEN
      CALL spi_error(45017, 'Moneda y monto cobrados inválidos (ambos o ninguno; PEN o USD)');
    END IF;
    IF p_estado_externo = 'aprobado' AND (p_monto IS NULL OR p_monto <= 0) THEN
      CALL spi_error(45017, 'Un webhook aprobado debe informar el monto cobrado');
    END IF;
    IF fn_contiene_datos_tarjeta(p_datos) THEN CALL spi_error(45031, 'Los datos de la pasarela traen datos de tarjeta'); END IF;
    SET @wanka_ctx_interno = fn_token_interno();
    -- Búsqueda del pago FUERA de la transacción: la instantánea (REPEATABLE READ) nace después de los bloqueos
    SELECT id_pago, id_pedido INTO v_pago, v_pedido FROM pago
     WHERE (p_idempotency_key IS NOT NULL AND idempotency_key = p_idempotency_key)
        OR (p_idempotency_key IS NULL AND metodo = p_metodo AND referencia_externa = p_referencia_externa)
     LIMIT 1;
    START TRANSACTION;
    SELECT estado, firma_valida, proveedor INTO v_estado_evento, v_firma, v_proveedor FROM evento_pasarela WHERE id_evento = p_id_evento FOR UPDATE;
    IF v_estado_evento IS NULL THEN CALL spi_error(45022, 'El evento no existe'); END IF;
    IF NOT v_firma THEN CALL spi_error(45017, 'Webhook sin firma válida: no se procesa'); END IF;
    IF v_proveedor <> p_metodo THEN CALL spi_error(45017, 'El webhook es de otro proveedor que el método indicado'); END IF;

    IF v_estado_evento IN ('procesado','ignorado') THEN
      SET p_resultado = 'duplicado';
    ELSE
      IF v_pago IS NULL THEN
        SET p_resultado = 'pago_no_encontrado';
        UPDATE evento_pasarela SET estado = 'error', error = 'No se encontró el pago (revisión manual en v_eventos_pasarela_con_error)'
         WHERE id_evento = p_id_evento;
      ELSE
        SELECT estado, saldo, motivo_cancelacion INTO v_estado_pedido, v_saldo, v_motivo_cancel FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
        SELECT p.estado, p.monto, p.metodo, m.tipo INTO v_estado, v_monto, v_metodo_pago, v_tipo_metodo
          FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE p.id_pago = v_pago FOR UPDATE;
        IF v_metodo_pago <> p_metodo OR v_tipo_metodo <> 'pasarela' THEN
          -- Un webhook de pasarela nunca confirma un pago de otro método (p. ej. un Yape por validar)
          SET p_resultado = 'metodo_distinto';
          UPDATE evento_pasarela SET estado = 'error', error = CONCAT('El pago ', v_pago, ' es de método ', v_metodo_pago, ', no de ', p_metodo), id_pago = v_pago
           WHERE id_evento = p_id_evento;
        ELSEIF NULLIF(TRIM(p_referencia_externa), '') IS NOT NULL
               AND EXISTS (SELECT 1 FROM pago WHERE metodo = p_metodo AND referencia_externa = TRIM(p_referencia_externa) AND id_pago <> v_pago
                              AND estado IN ('pendiente','en_revision','confirmado','reembolsado')) THEN
          -- La operación de la pasarela ya pertenece a otro pago: revisión humana (antes: error 1062 y reintentos sin fin)
          SET p_resultado = 'referencia_duplicada';
          UPDATE evento_pasarela SET estado = 'error', id_pago = v_pago,
                                     error = CONCAT('La operación ', TRIM(p_referencia_externa), ' ya está registrada en otro pago')
           WHERE id_evento = p_id_evento;
          CALL spi_notificar_admins('pago_revertido', CONCAT('Operación de ', p_metodo, ' repetida'),
                                    CONCAT('La operación ', LEFT(TRIM(p_referencia_externa), 60), ' ya figura en otro pago: revisar'), '/admin/pagos', v_pedido);
        ELSEIF p_monto IS NOT NULL AND p_monto <> v_monto THEN
          SET p_resultado = 'monto_distinto';
          UPDATE evento_pasarela SET estado = 'error', error = CONCAT('Monto del webhook ', p_monto, ' distinto al registrado ', v_monto), id_pago = v_pago
           WHERE id_evento = p_id_evento;
        ELSEIF p_estado_externo = 'aprobado' THEN
          IF v_estado IN ('confirmado','reembolsado') THEN
            SET p_resultado = 'ya_confirmado';
          ELSE
            IF v_estado_pedido IN ('cancelado','devuelto') THEN
              SET v_aplicado = 0;
              SET v_motivo = IF(v_motivo_cancel LIKE 'Expirado%', 'pedido_expirado', 'pedido_cancelado');
            ELSEIF v_monto > v_saldo THEN
              SET v_aplicado = 0; SET v_motivo = 'excede_total';
            END IF;
            UPDATE pago SET estado = 'confirmado', confirmado_en = UTC_TIMESTAMP(3),
                            referencia_externa = COALESCE(NULLIF(TRIM(p_referencia_externa), ''), referencia_externa),
                            datos_pasarela = COALESCE(p_datos, datos_pasarela),
                            moneda_cobro = COALESCE(p_moneda_cobro, moneda_cobro), monto_cobro = COALESCE(p_monto_cobro, monto_cobro),
                            tipo_cambio = COALESCE(p_tipo_cambio, tipo_cambio),
                            aplicado_al_pedido = v_aplicado, motivo_no_aplicado = v_motivo
             WHERE id_pago = v_pago;
            SET p_resultado = IF(v_aplicado, 'confirmado', 'confirmado_huerfano');
            IF NOT v_aplicado THEN
              CALL spi_notificar_admins('pago_por_reembolsar', 'Cobro recibido sin pedido vigente',
                                        CONCAT('Pago ', v_pago, ' por S/ ', v_monto, ': reembolsar'), '/admin/pagos/por-reembolsar', v_pedido);
            END IF;
          END IF;
        ELSEIF p_estado_externo = 'revertido' THEN
          -- Contracargo o reembolso iniciado desde la pasarela: requiere revisión humana (nota de crédito, stock...)
          SET p_resultado = 'revertido_revisar';
          UPDATE evento_pasarela SET estado = 'error', id_pago = v_pago,
                                     error = CONCAT('La pasarela informa reverso/contracargo del pago ', v_pago, ': registre el reembolso y revise el pedido')
           WHERE id_evento = p_id_evento;
          CALL spi_notificar_admins('pago_revertido', CONCAT('Reverso de pago en ', p_metodo),
                                    CONCAT('Pago ', v_pago, ' por S/ ', v_monto, ': revisar pedido y reembolso'), '/admin/pagos', v_pedido);
        ELSEIF p_estado_externo = 'rechazado' THEN
          IF v_estado = 'pendiente' THEN
            UPDATE pago SET estado = 'fallido', datos_pasarela = COALESCE(p_datos, datos_pasarela) WHERE id_pago = v_pago;
            SET p_resultado = 'fallido';
          ELSE
            SET p_resultado = 'sin_cambios';
          END IF;
        ELSE
          UPDATE pago SET referencia_externa = COALESCE(NULLIF(TRIM(p_referencia_externa), ''), referencia_externa) WHERE id_pago = v_pago AND estado = 'pendiente';
          SET p_resultado = 'sin_cambios';
        END IF;
        IF p_resultado NOT IN ('monto_distinto','metodo_distinto','revertido_revisar','referencia_duplicada') THEN
          UPDATE evento_pasarela SET estado = 'procesado', procesado_en = UTC_TIMESTAMP(3), id_pago = v_pago, error = NULL WHERE id_evento = p_id_evento;
        END IF;
      END IF;
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS spi_crear_reembolso $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_crear_reembolso(
  IN p_id_pago BIGINT UNSIGNED, IN p_monto DECIMAL(12,2), IN p_motivo VARCHAR(20), IN p_detalle VARCHAR(300), IN p_medio VARCHAR(15),
  IN p_id_nota_credito BIGINT UNSIGNED, IN p_id_devolucion BIGINT UNSIGNED, OUT p_id_reembolso BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Solicita un reembolso validando que la suma de reembolsos vigentes no supere lo cobrado'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15); DECLARE v_monto DECIMAL(12,2); DECLARE v_comprometido DECIMAL(12,2);
  DECLARE v_metodo VARCHAR(20); DECLARE v_tipo VARCHAR(10); DECLARE v_medio VARCHAR(15);
  SELECT p.id_pedido, p.estado, p.monto, p.metodo, m.tipo INTO v_pedido, v_estado, v_monto, v_metodo, v_tipo
    FROM pago p JOIN metodo_pago m ON m.codigo = p.metodo WHERE p.id_pago = p_id_pago FOR UPDATE;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El pago no existe'); END IF;
  IF v_estado <> 'confirmado' THEN CALL spi_error(45029, CONCAT('Solo se reembolsa un pago confirmado (está ', v_estado, ')')); END IF;
  SELECT COALESCE(SUM(monto), 0) INTO v_comprometido FROM reembolso WHERE id_pago = p_id_pago AND estado IN ('solicitado','procesando','completado') FOR SHARE;
  IF p_monto IS NULL OR p_monto <= 0 OR p_monto + v_comprometido > v_monto THEN
    CALL spi_error(45029, CONCAT('El reembolso excede lo disponible del pago (S/ ', v_monto - v_comprometido, ')'));
  END IF;
  SET v_medio = COALESCE(p_medio, IF(v_tipo = 'pasarela', 'pasarela', IF(v_metodo IN ('yape','plin','transferencia','efectivo'), v_metodo, 'transferencia')));
  INSERT INTO reembolso (id_pago, id_pedido, monto, motivo, detalle, medio, id_nota_credito, id_devolucion, solicitado_por)
  VALUES (p_id_pago, v_pedido, p_monto, p_motivo, p_detalle, v_medio, p_id_nota_credito, p_id_devolucion, fn_actor());
  SET p_id_reembolso = LAST_INSERT_ID();
  CALL spi_auditar('reembolso_solicitado', 'reembolso', p_id_reembolso, NULL,
                   JSON_OBJECT('id_pago', p_id_pago, 'monto', p_monto, 'motivo', p_motivo), 'procedimiento');
END $$

DROP PROCEDURE IF EXISTS spi_repartir_reembolso $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_repartir_reembolso(
  IN p_id_pedido BIGINT UNSIGNED, IN p_monto DECIMAL(12,2), IN p_motivo VARCHAR(20), IN p_detalle VARCHAR(300),
  IN p_id_nota_credito BIGINT UNSIGNED, IN p_id_devolucion BIGINT UNSIGNED,
  OUT p_monto_solicitado DECIMAL(12,2), OUT p_id_primer_reembolso BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Reparte un monto a devolver entre los pagos confirmados APLICADOS al pedido (del más reciente al más antiguo) creando reembolsos solicitados'
BEGIN
  DECLARE v_restante DECIMAL(12,2) DEFAULT GREATEST(COALESCE(p_monto, 0), 0);
  DECLARE v_pago BIGINT UNSIGNED;
  DECLARE v_disp DECIMAL(12,2);
  DECLARE v_monto DECIMAL(12,2);
  DECLARE v_monto_pago DECIMAL(12,2);
  DECLARE v_comp DECIMAL(12,2);
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE v_ult BIGINT UNSIGNED DEFAULT 18446744073709551615;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_pago = NULL;
  SET p_monto_solicitado = 0;
  SET p_id_primer_reembolso = NULL;
  bucle: WHILE v_restante > 0 DO
    SET v_pago = NULL;
    SELECT id_pago, monto INTO v_pago, v_monto_pago
      FROM pago
     WHERE id_pedido = p_id_pedido AND estado = 'confirmado' AND aplicado_al_pedido = 1 AND id_pago < v_ult
     ORDER BY id_pago DESC LIMIT 1
       FOR UPDATE;
    IF v_pago IS NULL THEN LEAVE bucle; END IF;
    SET v_ult = v_pago;
    SELECT COALESCE(SUM(monto), 0) INTO v_comp FROM reembolso
     WHERE id_pago = v_pago AND estado IN ('solicitado','procesando','completado') FOR SHARE;
    SET v_disp = v_monto_pago - v_comp;
    IF v_disp > 0 THEN
      SET v_monto = LEAST(v_disp, v_restante);
      CALL spi_crear_reembolso(v_pago, v_monto, p_motivo, p_detalle, NULL, p_id_nota_credito, p_id_devolucion, v_id);
      SET p_id_primer_reembolso = COALESCE(p_id_primer_reembolso, v_id);
      SET v_restante = v_restante - v_monto;
      SET p_monto_solicitado = p_monto_solicitado + v_monto;
    END IF;
  END WHILE bucle;
END $$

DROP PROCEDURE IF EXISTS sp_reembolsar_pago $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reembolsar_pago(
  IN p_id_pago BIGINT UNSIGNED, IN p_monto DECIMAL(12,2), IN p_motivo VARCHAR(20), IN p_detalle VARCHAR(300), IN p_medio VARCHAR(15),
  IN p_id_nota_credito BIGINT UNSIGNED, OUT p_id_reembolso BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El administrador solicita devolver dinero de un pago confirmado (p_monto NULL = todo lo disponible). En un pedido vigente solo se reembolsa un excedente o una compensación (ajuste_precio)'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_disp DECIMAL(12,2); DECLARE v_monto_pago DECIMAL(12,2); DECLARE v_comp DECIMAL(12,2);
  DECLARE v_aplicado BOOLEAN; DECLARE v_estado_pedido VARCHAR(20); DECLARE v_saldo DECIMAL(12,2); DECLARE v_pendiente DECIMAL(12,2);
  DECLARE v_monto DECIMAL(12,2); DECLARE v_motivo VARCHAR(20) DEFAULT COALESCE(p_motivo, 'otro');
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF v_motivo NOT IN ('cancelacion','devolucion','pago_huerfano','excedente','error_cobro','ajuste_precio','otro') THEN
    CALL spi_error(45029, 'Motivo de reembolso inválido');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  -- Búsqueda previa FUERA de la transacción: así la instantánea (REPEATABLE READ) nace después del bloqueo del pedido
  SELECT id_pedido INTO v_pedido FROM pago WHERE id_pago = p_id_pago;
  IF v_pedido IS NULL THEN CALL spi_error(45022, 'El pago no existe'); END IF;
  START TRANSACTION;
  SELECT estado, saldo INTO v_estado_pedido, v_saldo FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
  SELECT monto, aplicado_al_pedido INTO v_monto_pago, v_aplicado FROM pago WHERE id_pago = p_id_pago FOR UPDATE;
  SELECT COALESCE(SUM(monto), 0) INTO v_comp FROM reembolso
   WHERE id_pago = p_id_pago AND estado IN ('solicitado','procesando','completado') FOR SHARE;
  SET v_disp = v_monto_pago - v_comp;
  SET v_monto = COALESCE(p_monto, v_disp);
  IF v_aplicado AND v_estado_pedido NOT IN ('cancelado','devuelto') THEN
    -- Pedido vigente: devolver dinero sin más dejaría saldo pendiente y el IGV del comprobante sin corregir
    IF v_motivo = 'excedente' THEN
      SELECT COALESCE(SUM(r.monto), 0) INTO v_pendiente
        FROM reembolso r JOIN pago p ON p.id_pago = r.id_pago
       WHERE p.id_pedido = v_pedido AND p.aplicado_al_pedido = 1 AND r.estado IN ('solicitado','procesando') FOR SHARE;
      IF v_monto > GREATEST(-v_saldo, 0) - v_pendiente THEN
        CALL spi_error(45029, CONCAT('El pedido solo tiene S/ ', GREATEST(GREATEST(-v_saldo, 0) - v_pendiente, 0), ' a favor del cliente'));
      END IF;
    ELSEIF v_motivo = 'ajuste_precio' THEN
      IF p_id_nota_credito IS NULL AND EXISTS (SELECT 1 FROM comprobante WHERE pedido_activo_clave = v_pedido) THEN
        CALL spi_error(45029, 'El pedido tiene comprobante: emita una nota de crédito (motivo 09) con reembolso');
      END IF;
    ELSE
      CALL spi_error(45029, 'El pedido sigue vigente: cancélelo o registre la devolución; para una rebaja use ajuste_precio');
    END IF;
  END IF;
  CALL spi_crear_reembolso(p_id_pago, v_monto, v_motivo, p_detalle, p_medio, p_id_nota_credito, NULL, p_id_reembolso);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_completar_reembolso $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_completar_reembolso(
  IN p_id_reembolso BIGINT UNSIGNED, IN p_exitoso BOOLEAN, IN p_referencia_externa VARCHAR(100), IN p_error VARCHAR(300))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cierra un reembolso (completado o fallido). Al completarse, el trigger actualiza el pago y el pedido'
BEGIN
  DECLARE v_pago BIGINT UNSIGNED; DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_estado VARCHAR(15);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_exitoso IS NULL THEN CALL spi_error(45029, 'Indique si el reembolso se completó (1) o falló (0)'); END IF;
  IF NOT p_exitoso AND NULLIF(TRIM(p_error), '') IS NULL THEN CALL spi_error(45029, 'Indique el error del reembolso fallido'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  -- Búsqueda previa FUERA de la transacción: así la instantánea (REPEATABLE READ) nace después del bloqueo del pedido
  SELECT id_pago, id_pedido INTO v_pago, v_pedido FROM reembolso WHERE id_reembolso = p_id_reembolso;
  IF v_pago IS NULL THEN CALL spi_error(45022, 'El reembolso no existe'); END IF;
  START TRANSACTION;
  SELECT id_pedido INTO @wanka_x FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
  SELECT id_pago INTO @wanka_x FROM pago WHERE id_pago = v_pago FOR UPDATE;
  SELECT estado INTO v_estado FROM reembolso WHERE id_reembolso = p_id_reembolso FOR UPDATE;
  IF v_estado NOT IN ('solicitado','procesando') THEN CALL spi_error(45004, CONCAT('El reembolso ya está ', v_estado)); END IF;
  UPDATE reembolso
     SET estado = IF(p_exitoso, 'completado', 'fallido'),
         referencia_externa = COALESCE(NULLIF(TRIM(p_referencia_externa), ''), referencia_externa),
         completado_en = IF(p_exitoso, UTC_TIMESTAMP(3), NULL),
         error = IF(p_exitoso, NULL, p_error), procesado_por = fn_actor()
   WHERE id_reembolso = p_id_reembolso;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- J. COMPROBANTES ELECTRÓNICOS, NOTAS DE CRÉDITO Y COLA DE EMISIÓN
-- #####################################################################

DROP PROCEDURE IF EXISTS spi_encolar_emision $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_encolar_emision(IN p_id_comprobante BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Crea el trabajo de emisión asíncrona'
BEGIN
  INSERT INTO cola_emision_comprobante (id_comprobante, max_intentos) VALUES (p_id_comprobante, fn_config_entero('cola_emision_max_intentos'));
END $$

DROP PROCEDURE IF EXISTS sp_emitir_comprobante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_emitir_comprobante(
  IN p_id_pedido BIGINT UNSIGNED, OUT p_id_comprobante BIGINT UNSIGNED, OUT p_ya_existia BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Arma la boleta/factura con copia completa (emisor, cliente, líneas, IGV) y la encola para el OSE. Idempotente: un comprobante vigente por pedido'
BEGIN
  DECLARE v_estado VARCHAR(20); DECLARE v_estado_pago VARCHAR(12); DECLARE v_tipo VARCHAR(10); DECLARE v_total DECIMAL(12,2);
  DECLARE v_descuento DECIMAL(12,2); DECLARE v_envio DECIMAL(12,2); DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE v_doc_tipo VARCHAR(3); DECLARE v_doc_num VARCHAR(12); DECLARE v_nombre VARCHAR(200); DECLARE v_dir VARCHAR(300); DECLARE v_correo VARCHAR(254);
  DECLARE v_serie_id SMALLINT UNSIGNED; DECLARE v_serie CHAR(4); DECLARE v_correl INT UNSIGNED;
  DECLARE v_tasa DECIMAL(5,2); DECLARE v_gravada DECIMAL(12,2); DECLARE v_igv DECIMAL(12,2); DECLARE v_suma DECIMAL(12,2);
  DECLARE v_umbral DECIMAL(14,4); DECLARE v_zona VARCHAR(80);
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    IF fn_actor() IS NOT NULL THEN CALL spi_validar_admin(); END IF;   -- NULL = proceso del sistema (worker)
    SET p_ya_existia = 0;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT p.estado, p.estado_pago, p.comprobante_solicitado, p.total, p.descuento, p.costo_envio, p.id_usuario,
           COALESCE(p.facturacion_tipo_doc, u.tipo_documento), COALESCE(p.facturacion_num_doc, u.numero_documento),
           COALESCE(p.facturacion_nombre, u.nombre_completo),
           COALESCE(p.facturacion_direccion, NULLIF(CONCAT_WS(', ', p.entrega_direccion, p.entrega_distrito, p.entrega_provincia), '')),
           u.correo, z.nombre
      INTO v_estado, v_estado_pago, v_tipo, v_total, v_descuento, v_envio, v_usuario,
           v_doc_tipo, v_doc_num, v_nombre, v_dir, v_correo, v_zona
      FROM pedido p JOIN usuario u ON u.id_usuario = p.id_usuario
      LEFT JOIN zona_envio z ON z.id_zona = p.id_zona
     WHERE p.id_pedido = p_id_pedido FOR UPDATE;
    IF v_nf THEN CALL spi_error(45022, 'El pedido no existe'); END IF;

    SELECT id_comprobante INTO p_id_comprobante FROM comprobante WHERE pedido_activo_clave = p_id_pedido;
    IF NOT v_nf THEN
      SET p_ya_existia = 1;
    ELSE
      SET v_nf = 0;
      IF v_estado IN ('pendiente_pago','cancelado','devuelto') THEN
        CALL spi_error(45015, CONCAT('No se emite comprobante para un pedido en estado ', v_estado));
      END IF;
      IF fn_config('emitir_comprobante_al') = 'pago_total' AND v_estado_pago <> 'pagado' THEN
        CALL spi_error(45015, 'El comprobante se emite cuando el pedido está pagado por completo (ver decisión sobre anticipos)');
      END IF;
      IF v_descuento > 0 THEN CALL spi_error(45015, 'Descuentos aún no soportados en la emisión (cupones, HU-40 fuera de alcance)'); END IF;

      -- Validaciones SUNAT del receptor
      IF v_tipo = 'factura' THEN
        IF v_doc_tipo IS NULL OR v_doc_tipo <> 'RUC' OR NOT fn_ruc_valido(v_doc_num) OR NULLIF(TRIM(v_nombre), '') IS NULL THEN
          CALL spi_error(45015, 'La factura exige RUC válido (11 dígitos, dígito verificador) y razón social');
        END IF;
      ELSE
        SET v_umbral = fn_config_decimal('umbral_boleta_dni');
        IF v_total > v_umbral AND v_doc_num IS NULL THEN
          CALL spi_error(45015, CONCAT('Boleta mayor a S/ ', FORMAT(v_umbral, 2), ' sin documento del cliente'));
        END IF;
        IF v_doc_num IS NOT NULL AND NOT fn_documento_valido(v_doc_tipo, v_doc_num) THEN
          CALL spi_error(45015, 'Documento del cliente inválido');
        END IF;
      END IF;

      SELECT id_serie, serie INTO v_serie_id, v_serie FROM serie_comprobante WHERE tipo = v_tipo AND activo = 1 ORDER BY id_serie LIMIT 1;
      IF v_nf THEN CALL spi_error(45015, CONCAT('No hay serie activa para ', v_tipo)); END IF;
      CALL spi_siguiente_correlativo(v_serie_id, v_correl);

      SET v_tasa = fn_tasa_igv();
      -- Totales = suma de líneas (cada línea calcula su IGV con fn_igv_incluido)
      SELECT COALESCE(SUM(t.total_linea - fn_igv_incluido(t.total_linea, v_tasa)), 0), COALESCE(SUM(fn_igv_incluido(t.total_linea, v_tasa)), 0),
             COALESCE(SUM(t.total_linea), 0)
        INTO v_gravada, v_igv, v_suma
        FROM (SELECT subtotal AS total_linea FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente'
              UNION ALL SELECT v_envio FROM DUAL WHERE v_envio > 0) t;
      IF v_suma <> v_total THEN CALL spi_error(45015, CONCAT('Las líneas (S/ ', v_suma, ') no cuadran con el total del pedido (S/ ', v_total, ')')); END IF;

      INSERT INTO comprobante (id_pedido, tipo, id_serie, serie, correlativo, fecha_emision,
                               emisor_ruc, emisor_razon_social, emisor_nombre_comercial, emisor_domicilio_fiscal,
                               cliente_tipo_doc, cliente_num_doc, cliente_nombre, cliente_direccion, cliente_correo,
                               igv_porcentaje, op_gravada, igv, total, creado_por)
      VALUES (p_id_pedido, v_tipo, v_serie_id, v_serie, v_correl, fn_hoy_lima(),
              fn_config('empresa_ruc'), fn_config('empresa_razon_social'), fn_config('empresa_nombre_comercial'), fn_config('empresa_domicilio_fiscal'),
              IF(v_doc_num IS NULL, NULL, v_doc_tipo), v_doc_num, COALESCE(NULLIF(TRIM(v_nombre), ''), 'CLIENTE VARIOS'), v_dir,
              IF(v_correo LIKE '%.invalid', NULL, v_correo), v_tasa, v_gravada, v_igv, v_total, fn_actor());
      SET p_id_comprobante = LAST_INSERT_ID();

      INSERT INTO comprobante_item (id_comprobante, orden, id_item_pedido, codigo_producto, descripcion, unidad_medida,
                                    cantidad, precio_unitario, valor_unitario, valor_venta, igv, total_linea, codigo_afectacion_igv)
      SELECT p_id_comprobante, ROW_NUMBER() OVER (ORDER BY x.orden_base, x.id_item_pedido), x.id_item_pedido, x.codigo, x.descripcion, x.unidad,
             x.cantidad, x.precio, ROUND((x.total_linea - fn_igv_incluido(x.total_linea, v_tasa)) / x.cantidad, 6),
             x.total_linea - fn_igv_incluido(x.total_linea, v_tasa), fn_igv_incluido(x.total_linea, v_tasa), x.total_linea, x.afectacion
        FROM (SELECT 0 AS orden_base, i.id_item_pedido, i.sku AS codigo,
                     LEFT(CONCAT(i.nombre_producto, IF(i.talla IS NULL, '', CONCAT(' T. ', i.talla)), IF(i.color IS NULL, '', CONCAT(' ', i.color)),
                                 IF(i.personalizacion IS NULL, '', CONCAT(' - ', i.personalizacion))), 250) AS descripcion,
                     COALESCE(pr.unidad_medida_sunat, 'NIU') AS unidad, i.cantidad, i.precio_unitario AS precio, i.subtotal AS total_linea,
                     COALESCE(pr.codigo_afectacion_igv, '10') AS afectacion
                FROM item_pedido i LEFT JOIN producto pr ON pr.id_producto = i.id_producto
               WHERE i.id_pedido = p_id_pedido AND i.estado = 'vigente'
              UNION ALL
              SELECT 1, NULL, 'ENVIO', LEFT(CONCAT('Servicio de envío', IF(v_zona IS NULL, '', CONCAT(' - ', v_zona))), 250), 'ZZ', 1, v_envio, v_envio, '10'
                FROM DUAL WHERE v_envio > 0) x;

      CALL spi_encolar_emision(p_id_comprobante);
      CALL spi_auditar('comprobante_creado', 'comprobante', p_id_comprobante, v_usuario,
                       JSON_OBJECT('numero', CONCAT(v_serie, '-', LPAD(v_correl, 8, '0')), 'total', v_total), 'procedimiento');
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS spi_emitir_nota_credito $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_emitir_nota_credito(
  IN p_id_comprobante_ref BIGINT UNSIGNED, IN p_codigo_motivo CHAR(2), IN p_motivo_detalle VARCHAR(250), IN p_monto DECIMAL(12,2),
  IN p_id_devolucion BIGINT UNSIGNED, OUT p_id_nc BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Nota de crédito validada: contra comprobante aceptado del pedido, serie compatible (B→B, F→F), motivo SUNAT, sin exceder el saldo del comprobante'
BEGIN
  DECLARE v_tipo VARCHAR(15); DECLARE v_estado VARCHAR(12); DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_serie_ref CHAR(4); DECLARE v_total DECIMAL(12,2);
  DECLARE v_emitido DECIMAL(12,2); DECLARE v_disponible DECIMAL(12,2); DECLARE v_monto DECIMAL(12,2);
  DECLARE v_es_total BOOLEAN; DECLARE v_motivo_desc VARCHAR(200);
  DECLARE v_serie_id SMALLINT UNSIGNED; DECLARE v_serie CHAR(4); DECLARE v_correl INT UNSIGNED;
  DECLARE v_tasa DECIMAL(5,2); DECLARE v_numero_ref VARCHAR(13);
  DECLARE v_gravada DECIMAL(12,2); DECLARE v_igv DECIMAL(12,2);
  DECLARE v_acotada BOOLEAN DEFAULT 0;
  DECLARE v_nf BOOLEAN DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_nf = 1;

  SELECT tipo, estado_sunat, id_pedido, serie, total, igv_porcentaje, numero_completo
    INTO v_tipo, v_estado, v_pedido, v_serie_ref, v_total, v_tasa, v_numero_ref
    FROM comprobante WHERE id_comprobante = p_id_comprobante_ref FOR UPDATE;
  IF v_nf THEN CALL spi_error(45022, 'El comprobante de referencia no existe'); END IF;
  IF v_tipo NOT IN ('boleta','factura') THEN CALL spi_error(45016, 'La nota de crédito se emite contra una boleta o factura'); END IF;
  IF v_estado NOT IN ('aceptado','observado') THEN
    CALL spi_error(45016, CONCAT('No se emite nota de crédito contra un comprobante ', v_estado, ' (debe estar aceptado por SUNAT)'));
  END IF;
  SELECT es_total, descripcion INTO v_es_total, v_motivo_desc FROM motivo_nota_credito WHERE codigo = p_codigo_motivo AND activo = 1;
  IF v_nf THEN CALL spi_error(45016, 'Motivo de nota de crédito inválido (catálogo SUNAT 09)'); END IF;
  IF NULLIF(TRIM(p_motivo_detalle), '') IS NULL THEN CALL spi_error(45016, 'El sustento de la nota de crédito es obligatorio'); END IF;

  SELECT COALESCE(SUM(total), 0) INTO v_emitido FROM comprobante
   WHERE id_comprobante_ref = p_id_comprobante_ref AND tipo = 'nota_credito' AND estado_sunat NOT IN ('rechazado','anulado') FOR SHARE;
  SET v_disponible = v_total - v_emitido;
  IF p_id_devolucion IS NOT NULL THEN
    SELECT monto_total INTO v_monto FROM devolucion WHERE id_devolucion = p_id_devolucion AND id_pedido = v_pedido;
    IF v_nf THEN CALL spi_error(45016, 'La devolución no pertenece al pedido del comprobante'); END IF;
    IF EXISTS (SELECT 1 FROM comprobante WHERE id_devolucion = p_id_devolucion AND tipo = 'nota_credito' AND estado_sunat NOT IN ('rechazado','anulado')) THEN
      CALL spi_error(45016, 'Esa devolución ya tiene nota de crédito');
    END IF;
    -- Si otra NC ya rebajó el comprobante, la de la devolución se acota a lo que queda (una sola línea)
    IF v_monto > v_disponible THEN
      SET v_monto = v_disponible;
      SET v_acotada = 1;
    END IF;
  ELSE
    SET v_monto = COALESCE(p_monto, v_disponible);
    -- Doble clic: la misma NC (referencia, motivo y monto) hace instantes
    IF EXISTS (SELECT 1 FROM comprobante WHERE id_comprobante_ref = p_id_comprobante_ref AND tipo = 'nota_credito'
                  AND codigo_motivo_nc = p_codigo_motivo AND total = v_monto AND estado_sunat NOT IN ('rechazado','anulado')
                  AND emitido_en > UTC_TIMESTAMP(3) - INTERVAL 2 MINUTE) THEN
      CALL spi_error(45016, 'Ya se emitió una nota de crédito igual hace instantes (posible doble clic)');
    END IF;
  END IF;
  IF v_es_total AND v_monto <> v_disponible THEN
    CALL spi_error(45016, CONCAT('El motivo ', p_codigo_motivo, ' exige anular el saldo completo del comprobante (S/ ', v_disponible, ')'));
  END IF;
  IF v_monto <= 0 OR v_monto > v_disponible THEN
    CALL spi_error(45016, CONCAT('La nota de crédito (S/ ', v_monto, ') supera el saldo del comprobante (S/ ', v_disponible, ')'));
  END IF;

  SELECT id_serie, serie INTO v_serie_id, v_serie FROM serie_comprobante
   WHERE tipo = 'nota_credito' AND activo = 1 AND LEFT(serie, 1) = LEFT(v_serie_ref, 1) ORDER BY id_serie LIMIT 1;
  IF v_nf THEN CALL spi_error(45016, CONCAT('No hay serie de nota de crédito activa que empiece con ', LEFT(v_serie_ref, 1))); END IF;
  CALL spi_siguiente_correlativo(v_serie_id, v_correl);

  -- Cabecera = suma exacta de las líneas (se calcula antes de insertar por el CHECK de cuadre)
  IF p_id_devolucion IS NOT NULL AND NOT v_acotada THEN
    SELECT SUM(monto - fn_igv_incluido(monto, v_tasa)), SUM(fn_igv_incluido(monto, v_tasa)) INTO v_gravada, v_igv
      FROM devolucion_item WHERE id_devolucion = p_id_devolucion;
  ELSE
    SET v_igv = fn_igv_incluido(v_monto, v_tasa);
    SET v_gravada = v_monto - v_igv;
  END IF;

  INSERT INTO comprobante (id_pedido, tipo, id_serie, serie, correlativo, id_comprobante_ref, codigo_motivo_nc, motivo_detalle, id_devolucion,
                           fecha_emision, emisor_ruc, emisor_razon_social, emisor_nombre_comercial, emisor_domicilio_fiscal,
                           cliente_tipo_doc, cliente_num_doc, cliente_nombre, cliente_direccion, cliente_correo,
                           igv_porcentaje, op_gravada, igv, total, creado_por)
  SELECT id_pedido, 'nota_credito', v_serie_id, v_serie, v_correl, id_comprobante, p_codigo_motivo, LEFT(TRIM(p_motivo_detalle), 250), p_id_devolucion,
         fn_hoy_lima(), emisor_ruc, emisor_razon_social, emisor_nombre_comercial, emisor_domicilio_fiscal,
         cliente_tipo_doc, cliente_num_doc, cliente_nombre, cliente_direccion, cliente_correo,
         v_tasa, v_gravada, v_igv, v_monto, fn_actor()
    FROM comprobante WHERE id_comprobante = p_id_comprobante_ref;
  SET p_id_nc = LAST_INSERT_ID();

  IF p_id_devolucion IS NOT NULL AND NOT v_acotada THEN
    INSERT INTO comprobante_item (id_comprobante, orden, id_item_pedido, codigo_producto, descripcion, unidad_medida, cantidad,
                                  precio_unitario, valor_unitario, valor_venta, igv, total_linea)
    SELECT p_id_nc, ROW_NUMBER() OVER (ORDER BY di.id_devolucion_item), di.id_item_pedido, i.sku,
           LEFT(CONCAT('Devolución: ', i.nombre_producto), 250), 'NIU', di.cantidad, i.precio_unitario,
           ROUND((di.monto - fn_igv_incluido(di.monto, v_tasa)) / di.cantidad, 6),
           di.monto - fn_igv_incluido(di.monto, v_tasa), fn_igv_incluido(di.monto, v_tasa), di.monto
      FROM devolucion_item di JOIN item_pedido i ON i.id_item_pedido = di.id_item_pedido
     WHERE di.id_devolucion = p_id_devolucion;
  ELSE
    INSERT INTO comprobante_item (id_comprobante, orden, codigo_producto, descripcion, unidad_medida, cantidad,
                                  precio_unitario, valor_unitario, valor_venta, igv, total_linea)
    VALUES (p_id_nc, 1, 'NC', LEFT(CONCAT(v_motivo_desc, ' - ', v_numero_ref), 250), 'ZZ', 1, v_monto,
            v_monto - fn_igv_incluido(v_monto, v_tasa), v_monto - fn_igv_incluido(v_monto, v_tasa), fn_igv_incluido(v_monto, v_tasa), v_monto);
  END IF;
  CALL spi_encolar_emision(p_id_nc);
  CALL spi_auditar('nota_credito_creada', 'comprobante', p_id_nc, NULL,
                   JSON_OBJECT('referencia', v_numero_ref, 'motivo', p_codigo_motivo, 'monto', v_monto), 'procedimiento');
END $$

DROP PROCEDURE IF EXISTS sp_emitir_nota_credito $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_emitir_nota_credito(
  IN p_id_comprobante_ref BIGINT UNSIGNED, IN p_codigo_motivo CHAR(2), IN p_motivo_detalle VARCHAR(250), IN p_monto DECIMAL(12,2),
  IN p_id_devolucion BIGINT UNSIGNED, IN p_crear_reembolso BOOLEAN, OUT p_id_nota_credito BIGINT UNSIGNED, OUT p_id_reembolso BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Emite una nota de crédito (corrige un comprobante aceptado, que nunca se modifica). Con p_id_devolucion la NC sale de esa devolución y se enlaza a sus reembolsos; si no, opcionalmente solicita el reembolso'
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_monto DECIMAL(12,2); DECLARE v_pago BIGINT UNSIGNED DEFAULT NULL; DECLARE v_disp DECIMAL(12,2);
  DECLARE v_estado_pedido VARCHAR(20); DECLARE v_es_total BOOLEAN; DECLARE v_repone BOOLEAN; DECLARE v_es_ajuste BOOLEAN;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_pago = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    CALL spi_validar_admin();
    SET p_id_reembolso = NULL;
    SET @wanka_ctx_interno = fn_token_interno();
    -- Búsqueda previa FUERA de la transacción: así la instantánea (REPEATABLE READ) nace después del bloqueo del pedido
    SELECT id_pedido INTO v_pedido FROM comprobante WHERE id_comprobante = p_id_comprobante_ref;
    IF v_pedido IS NULL THEN CALL spi_error(45022, 'El comprobante no existe'); END IF;
    START TRANSACTION;
    SELECT estado INTO v_estado_pedido FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
    SELECT es_total, repone_stock INTO v_es_total, v_repone FROM motivo_nota_credito WHERE codigo = p_codigo_motivo AND activo = 1;
    IF v_es_total IS NULL THEN CALL spi_error(45016, 'Motivo de nota de crédito inválido (catálogo SUNAT 09)'); END IF;
    -- Coherencia del motivo con lo que pasó con el pedido
    IF v_repone AND p_id_devolucion IS NULL THEN
      CALL spi_error(45016, 'Las NC por devolución (06/07) salen de una devolución registrada: use sp_devolver_pedido o indique la devolución');
    END IF;
    IF p_codigo_motivo = '01' AND v_estado_pedido NOT IN ('cancelado','devuelto') THEN
      CALL spi_error(45016, 'La anulación de la operación (01) exige el pedido cancelado; para corregir el RUC use 02');
    END IF;
    IF p_codigo_motivo = '02' AND COALESCE(p_crear_reembolso, 0) THEN
      CALL spi_error(45016, 'La anulación por error en el RUC no devuelve dinero: después emita el comprobante correcto');
    END IF;
    SET v_es_ajuste = (v_es_total = 0 AND v_repone = 0 AND p_id_devolucion IS NULL AND v_estado_pedido NOT IN ('cancelado','devuelto'));
    CALL spi_emitir_nota_credito(p_id_comprobante_ref, p_codigo_motivo, p_motivo_detalle, p_monto, p_id_devolucion, p_id_nota_credito);
    IF v_es_ajuste THEN
      -- Rebaja posterior a la venta: el cliente debe menos (no queda "saldo pendiente" si se le devuelve)
      CALL spi_recalcular_ajustes_pedido(v_pedido);
      CALL spi_recalcular_pagos_pedido(v_pedido);
    END IF;
    IF p_id_devolucion IS NOT NULL THEN
      -- Los reembolsos de la devolución ya se solicitaron al registrarla: solo se enlazan a la NC
      UPDATE reembolso SET id_nota_credito = p_id_nota_credito WHERE id_devolucion = p_id_devolucion AND id_nota_credito IS NULL;
    ELSEIF p_crear_reembolso THEN
      SELECT total INTO v_monto FROM comprobante WHERE id_comprobante = p_id_nota_credito;
      CALL spi_repartir_reembolso(v_pedido, v_monto,
                                  CASE WHEN p_codigo_motivo IN ('01','02') THEN 'cancelacion'
                                       WHEN v_es_ajuste THEN 'ajuste_precio' ELSE 'otro' END,
                                  CONCAT('Nota de crédito ', p_id_nota_credito), p_id_nota_credito, NULL, v_disp, p_id_reembolso);
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_tomar_comprobante_para_emitir $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_tomar_comprobante_para_emitir(IN p_worker VARCHAR(64), OUT p_id_comprobante BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Worker de emisión: toma el siguiente trabajo vencido con SKIP LOCKED (varios workers sin pisarse). NULL = nada pendiente'
BEGIN
  DECLARE v_trabajo BIGINT UNSIGNED DEFAULT NULL;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_trabajo = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    SET p_id_comprobante = NULL;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    -- Trabajos cuyo worker murió en el último intento: se descartan y se avisa (si no, quedarían "procesando" para siempre)
    UPDATE cola_emision_comprobante
       SET estado = 'descartado', ultimo_error = LEFT(CONCAT('El worker ', COALESCE(tomado_por, '?'), ' no respondió en el último intento'), 2000)
     WHERE estado = 'procesando' AND tomado_en < UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE AND intentos >= max_intentos;
    IF ROW_COUNT() > 0 THEN
      CALL spi_notificar_admins('emision_descartada', 'Emisión de comprobantes atascada',
                                'Se descartaron trabajos sin respuesta del worker: use sp_reintentar_emision', '/admin/comprobantes', NULL);
    END IF;
    SELECT id_trabajo, id_comprobante INTO v_trabajo, p_id_comprobante
      FROM cola_emision_comprobante
     WHERE intentos < max_intentos
       AND ((estado IN ('pendiente','error') AND proximo_intento_en <= UTC_TIMESTAMP(3))
         OR (estado = 'procesando' AND tomado_en < UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE))
     ORDER BY proximo_intento_en, id_trabajo
     LIMIT 1
       FOR UPDATE SKIP LOCKED;   -- COMPAT-MARIADB: SKIP LOCKED desde 10.6
    IF v_trabajo IS NOT NULL THEN
      UPDATE cola_emision_comprobante SET estado = 'procesando', intentos = intentos + 1, tomado_por = LEFT(p_worker, 64), tomado_en = UTC_TIMESTAMP(3)
       WHERE id_trabajo = v_trabajo;
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_respuesta_ose $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_respuesta_ose(
  IN p_id_comprobante BIGINT UNSIGNED, IN p_resultado VARCHAR(12), IN p_proveedor VARCHAR(40), IN p_id_externo VARCHAR(100),
  IN p_hash VARCHAR(100), IN p_codigo_respuesta VARCHAR(10), IN p_mensaje TEXT,
  IN p_url_pdf VARCHAR(500), IN p_url_xml VARCHAR(500), IN p_url_cdr VARCHAR(500),
  IN p_payload_envio JSON, IN p_payload_respuesta JSON)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Guarda la respuesta del OSE/PSE (copia del JSON enviado y recibido) y mueve la cola: aceptado/observado/rechazado cierran; enviado/error reintentan con backoff'
BEGIN
  DECLARE v_estado VARCHAR(12); DECLARE v_intentos SMALLINT; DECLARE v_max SMALLINT; DECLARE v_pedido BIGINT UNSIGNED;
  DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_correo VARCHAR(254); DECLARE v_numero VARCHAR(13); DECLARE v_tipo VARCHAR(15);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF fn_actor() IS NOT NULL THEN CALL spi_validar_admin(); END IF;
  IF p_resultado IS NULL OR p_resultado NOT IN ('aceptado','observado','rechazado','enviado','error') THEN CALL spi_error(45006, 'Resultado OSE inválido'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT c.estado_sunat, c.id_pedido, c.numero_completo, c.tipo, c.cliente_correo, p.id_usuario
    INTO v_estado, v_pedido, v_numero, v_tipo, v_correo, v_usuario
    FROM comprobante c JOIN pedido p ON p.id_pedido = c.id_pedido WHERE c.id_comprobante = p_id_comprobante FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El comprobante no existe'); END IF;
  SELECT intentos, max_intentos INTO v_intentos, v_max FROM cola_emision_comprobante WHERE id_comprobante = p_id_comprobante FOR UPDATE;
  IF v_estado IN ('aceptado','observado','rechazado','anulado') THEN
    CALL spi_error(45004, CONCAT('El comprobante ya está ', v_estado, ': no se modifica'));
  END IF;

  UPDATE comprobante
     SET estado_sunat = IF(p_resultado = 'error', 'error', p_resultado),
         proveedor_ose = COALESCE(p_proveedor, proveedor_ose), id_externo = COALESCE(p_id_externo, id_externo),
         hash_cpe = COALESCE(p_hash, hash_cpe), codigo_respuesta_sunat = COALESCE(p_codigo_respuesta, codigo_respuesta_sunat),
         mensaje_sunat = COALESCE(p_mensaje, mensaje_sunat),
         url_pdf = COALESCE(p_url_pdf, url_pdf), url_xml = COALESCE(p_url_xml, url_xml), url_cdr = COALESCE(p_url_cdr, url_cdr),
         payload_envio = COALESCE(p_payload_envio, payload_envio), payload_respuesta = COALESCE(p_payload_respuesta, payload_respuesta),
         aceptado_en = IF(p_resultado IN ('aceptado','observado'), UTC_TIMESTAMP(3), aceptado_en)
   WHERE id_comprobante = p_id_comprobante;

  IF p_resultado IN ('aceptado','observado','rechazado') THEN
    UPDATE cola_emision_comprobante SET estado = 'completado', ultimo_error = IF(p_resultado = 'rechazado', p_mensaje, NULL)
     WHERE id_comprobante = p_id_comprobante;
    IF p_resultado IN ('aceptado','observado') THEN
      CALL spi_encolar_correo(v_usuario, v_correo, 'comprobante_emitido',
                              JSON_OBJECT('numero', v_numero, 'tipo', v_tipo, 'url_pdf', p_url_pdf), 4);
    ELSE
      CALL spi_notificar_admins('comprobante_rechazado', CONCAT('Comprobante ', v_numero, ' rechazado'), LEFT(p_mensaje, 300), '/admin/comprobantes', v_pedido);
      IF v_tipo = 'nota_credito' THEN
        -- Una NC rechazada no existe: sus reembolsos aún no pagados se anulan y la rebaja de precio se revierte
        SELECT id_pedido INTO @wanka_x FROM pedido WHERE id_pedido = v_pedido FOR UPDATE;
        UPDATE reembolso SET estado = 'anulado', error = LEFT(CONCAT('NC ', v_numero, ' rechazada por SUNAT'), 300)
         WHERE id_nota_credito = p_id_comprobante AND estado = 'solicitado';
        CALL spi_recalcular_ajustes_pedido(v_pedido);
        CALL spi_recalcular_pagos_pedido(v_pedido);
      END IF;
    END IF;
  ELSE
    -- enviado (SUNAT aún no responde) o error de comunicación: reintento con backoff exponencial (máx. 60 min)
    UPDATE cola_emision_comprobante
       SET estado = IF(v_intentos >= v_max, 'descartado', IF(p_resultado = 'error', 'error', 'pendiente')),
           ultimo_error = IF(p_resultado = 'error', LEFT(p_mensaje, 2000), ultimo_error),
           proximo_intento_en = UTC_TIMESTAMP(3) + INTERVAL LEAST(POW(2, v_intentos), 60) MINUTE
     WHERE id_comprobante = p_id_comprobante;
    IF v_intentos >= v_max THEN
      CALL spi_notificar_admins('emision_descartada', CONCAT('No se pudo emitir ', v_numero), 'Se agotaron los reintentos: revise el OSE', '/admin/comprobantes', v_pedido);
    END IF;
  END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_guardar_archivo_comprobante $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_guardar_archivo_comprobante(
  IN p_id_comprobante BIGINT UNSIGNED, IN p_tipo VARCHAR(3), IN p_mime VARCHAR(60), IN p_contenido LONGBLOB)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Guarda la copia binaria del PDF/XML/CDR (inmutable; repetir el mismo archivo es idempotente)'
BEGIN
  DECLARE v_sha CHAR(64) DEFAULT SHA2(p_contenido, 256);
  DECLARE v_sha_actual CHAR(64) DEFAULT NULL;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_sha_actual = NULL;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
    IF fn_actor() IS NOT NULL THEN CALL spi_validar_admin(); END IF;
    IF p_contenido IS NULL OR LENGTH(p_contenido) = 0 THEN CALL spi_error(45006, 'Archivo vacío'); END IF;
    IF p_tipo IS NULL OR p_tipo NOT IN ('pdf','xml','cdr') THEN CALL spi_error(45006, 'Tipo de archivo inválido: pdf, xml o cdr'); END IF;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SET @wanka_estado_cpe = NULL;
    SELECT estado_sunat INTO @wanka_estado_cpe FROM comprobante WHERE id_comprobante = p_id_comprobante;
    IF @wanka_estado_cpe IS NULL THEN CALL spi_error(45022, 'El comprobante no existe'); END IF;
    IF p_tipo = 'pdf' AND @wanka_estado_cpe IN ('rechazado','anulado') THEN
      CALL spi_error(45004, 'No se guarda la representación impresa de un comprobante rechazado o anulado');
    END IF;
    SELECT sha256 INTO v_sha_actual FROM comprobante_archivo WHERE id_comprobante = p_id_comprobante AND tipo = p_tipo;
    IF v_sha_actual IS NULL THEN
      INSERT INTO comprobante_archivo (id_comprobante, tipo, mime, contenido, tamano_bytes, sha256)
      VALUES (p_id_comprobante, p_tipo, p_mime, p_contenido, LENGTH(p_contenido), v_sha);
    ELSEIF v_sha_actual <> v_sha THEN
      CALL spi_error(45004, 'Ya existe otro archivo de ese tipo para el comprobante: es inmutable');
    END IF;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

DROP PROCEDURE IF EXISTS sp_marcar_comprobante_enviado_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_marcar_comprobante_enviado_correo(IN p_id_comprobante BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Registra que el comprobante se envió por correo al cliente'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE comprobante SET enviado_correo_en = UTC_TIMESTAMP(3) WHERE id_comprobante = p_id_comprobante AND enviado_correo_en IS NULL;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- K. DEVOLUCIONES (reponen stock, originan reembolso y nota de crédito)
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_devolver_pedido $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_devolver_pedido(
  IN p_id_pedido BIGINT UNSIGNED, IN p_items JSON, IN p_motivo VARCHAR(300), IN p_emitir_nota_credito BOOLEAN,
  OUT p_id_devolucion BIGINT UNSIGNED, OUT p_monto_devuelto DECIMAL(12,2), OUT p_id_nota_credito BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Devolución total (p_items NULL) o parcial ([{"id_item_pedido":1,"cantidad":1}]). Repone stock, impide devolver dos veces, solicita reembolsos y emite la NC'
BEGIN
  DECLARE v_estado VARCHAR(20); DECLARE v_usuario BIGINT UNSIGNED; DECLARE v_numero VARCHAR(25);
  DECLARE v_malos INT; DECLARE v_pendiente_total INT; DECLARE v_devuelve_total INT; DECLARE v_tipo VARCHAR(10);
  DECLARE v_fin BOOLEAN DEFAULT 0;
  DECLARE c_item BIGINT UNSIGNED; DECLARE c_cant INT; DECLARE c_var BIGINT UNSIGNED; DECLARE c_tipo VARCHAR(15); DECLARE c_precio DECIMAL(10,2);
  DECLARE v_stock INT; DECLARE v_prev VARCHAR(64);
  DECLARE v_por_reembolsar DECIMAL(12,2); DECLARE v_pago BIGINT UNSIGNED; DECLARE v_disp DECIMAL(12,2); DECLARE v_monto_r DECIMAL(12,2);
  DECLARE v_reembolso BIGINT UNSIGNED; DECLARE v_comprobante BIGINT UNSIGNED DEFAULT NULL; DECLARE v_ult_pago BIGINT UNSIGNED;
  DECLARE v_saldo DECIMAL(12,2); DECLARE v_pendiente DECIMAL(12,2); DECLARE v_a_favor DECIMAL(12,2);
  DECLARE cur CURSOR FOR
    SELECT t.id_item_pedido, t.cantidad, i.id_variante, i.tipo_fabricacion, i.precio_unitario
      FROM tmp_devolucion t JOIN item_pedido i ON i.id_item_pedido = t.id_item_pedido
     ORDER BY COALESCE(i.id_variante, 0), i.id_item_pedido;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;
  BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; DROP TEMPORARY TABLE IF EXISTS tmp_devolucion; RESIGNAL; END;
    CALL spi_validar_admin();
    IF p_motivo IS NULL OR CHAR_LENGTH(TRIM(p_motivo)) < 5 THEN CALL spi_error(45019, 'Indique el motivo de la devolución'); END IF;
    IF p_items IS NOT NULL THEN
      IF JSON_TYPE(p_items) <> 'ARRAY' OR JSON_LENGTH(p_items) = 0 OR JSON_LENGTH(p_items) > 100 THEN
        CALL spi_error(45019, 'p_items debe ser un arreglo JSON con 1 a 100 líneas [{"id_item_pedido":1,"cantidad":1}]');
      END IF;
      IF EXISTS (SELECT 1 FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_item BIGINT UNSIGNED PATH '$.id_item_pedido',
                                                                cantidad_json JSON PATH '$.cantidad')) jt
                  WHERE jt.id_item IS NULL OR COALESCE(JSON_TYPE(jt.cantidad_json), '') NOT IN ('INTEGER','UNSIGNED INTEGER')
                     OR CAST(jt.cantidad_json AS SIGNED) < 1) THEN
        CALL spi_error(45019, 'Cada línea necesita id_item_pedido y una cantidad entera mayor a cero');
      END IF;
    END IF;
    SET p_id_nota_credito = NULL;
    SET @wanka_ctx_interno = fn_token_interno();
    START TRANSACTION;
    SELECT estado, id_usuario, numero INTO v_estado, v_usuario, v_numero FROM pedido WHERE id_pedido = p_id_pedido FOR UPDATE;
    IF v_estado IS NULL THEN CALL spi_error(45022, 'El pedido no existe'); END IF;
    IF v_estado NOT IN ('enviado','entregado') THEN
      CALL spi_error(45019, CONCAT('Solo se devuelve un pedido enviado o entregado (está ', v_estado, '); para otros use la cancelación'));
    END IF;

    DROP TEMPORARY TABLE IF EXISTS tmp_devolucion;
    CREATE TEMPORARY TABLE tmp_devolucion (id_item_pedido BIGINT UNSIGNED PRIMARY KEY, cantidad INT NOT NULL);
    IF p_items IS NULL THEN
      INSERT INTO tmp_devolucion SELECT id_item_pedido, cantidad - cantidad_devuelta FROM item_pedido
       WHERE id_pedido = p_id_pedido AND estado = 'vigente' AND cantidad > cantidad_devuelta;
    ELSE
      INSERT INTO tmp_devolucion
      SELECT jt.id_item, SUM(jt.cantidad) FROM JSON_TABLE(p_items, '$[*]' COLUMNS (id_item BIGINT UNSIGNED PATH '$.id_item_pedido', cantidad INT PATH '$.cantidad')) jt
       GROUP BY jt.id_item;
    END IF;
    SELECT COUNT(*) INTO v_malos FROM tmp_devolucion;
    IF v_malos = 0 THEN CALL spi_error(45019, 'No hay unidades por devolver (¿ya se devolvió todo?)'); END IF;
    SELECT COUNT(*) INTO v_malos FROM tmp_devolucion t LEFT JOIN item_pedido i ON i.id_item_pedido = t.id_item_pedido AND i.id_pedido = p_id_pedido AND i.estado = 'vigente'
     WHERE t.id_item_pedido IS NULL OR t.cantidad IS NULL OR t.cantidad < 1 OR i.id_item_pedido IS NULL OR t.cantidad > i.cantidad - i.cantidad_devuelta;
    IF v_malos > 0 THEN CALL spi_error(45019, 'Hay líneas que no son del pedido o que exceden lo vendido no devuelto (no se devuelve dos veces)'); END IF;

    SELECT COALESCE(SUM(cantidad - cantidad_devuelta), 0) INTO v_pendiente_total FROM item_pedido WHERE id_pedido = p_id_pedido AND estado = 'vigente';
    SELECT SUM(cantidad) INTO v_devuelve_total FROM tmp_devolucion;
    SET v_tipo = IF(v_devuelve_total = v_pendiente_total, 'total', 'parcial');

    INSERT INTO devolucion (numero, id_pedido, tipo, motivo, monto_total, registrado_por)
    SELECT NULL, p_id_pedido, v_tipo, TRIM(p_motivo), SUM(t.cantidad * i.precio_unitario), fn_actor()
      FROM tmp_devolucion t JOIN item_pedido i ON i.id_item_pedido = t.id_item_pedido;
    SET p_id_devolucion = LAST_INSERT_ID();
    SELECT monto_total INTO p_monto_devuelto FROM devolucion WHERE id_devolucion = p_id_devolucion;

    SET v_fin = 0;
    OPEN cur;
    leer: LOOP
      FETCH cur INTO c_item, c_cant, c_var, c_tipo, c_precio;
      IF v_fin THEN LEAVE leer; END IF;
      INSERT INTO devolucion_item (id_devolucion, id_item_pedido, cantidad, monto, repuso_stock)
      VALUES (p_id_devolucion, c_item, c_cant, c_cant * c_precio, c_tipo = 'stock');
      IF c_tipo = 'stock' THEN
        CALL spi_mover_stock(c_var, 'devolucion', c_cant, p_id_pedido, c_item, p_id_devolucion, CONCAT('Devolución ', p_id_devolucion), v_stock);
      END IF;
      SET v_prev = @wanka_ctx_interno; SET @wanka_ctx_interno = fn_token_interno();
      UPDATE item_pedido SET cantidad_devuelta = cantidad_devuelta + c_cant WHERE id_item_pedido = c_item;
      SET @wanka_ctx_interno = v_prev;
    END LOOP leer;
    CLOSE cur;
    SET v_fin = 0;

    -- El valor devuelto ya no se le cobra al cliente: ajusta saldo y estado de pago
    UPDATE pedido SET monto_devuelto = monto_devuelto + p_monto_devuelto WHERE id_pedido = p_id_pedido;
    CALL spi_recalcular_pagos_pedido(p_id_pedido);

    IF v_tipo = 'total' THEN
      CALL spi_cambiar_estado_pedido(p_id_pedido, 'devuelto', TRIM(p_motivo), 1);
    END IF;

    -- Nota de crédito contra el comprobante aceptado (si existe)
    IF p_emitir_nota_credito THEN
      SELECT id_comprobante INTO v_comprobante FROM comprobante
       WHERE id_pedido = p_id_pedido AND tipo IN ('boleta','factura') AND estado_sunat IN ('aceptado','observado') LIMIT 1;
      IF v_comprobante IS NOT NULL THEN
        -- 06 (devolución total) solo si anula todo el saldo del comprobante; si no (p. ej. el envío no se devuelve) 07 por ítem
        SELECT c.total - COALESCE((SELECT SUM(n.total) FROM comprobante n WHERE n.id_comprobante_ref = c.id_comprobante
                                     AND n.tipo = 'nota_credito' AND n.estado_sunat NOT IN ('rechazado','anulado')), 0)
          INTO v_disp FROM comprobante c WHERE c.id_comprobante = v_comprobante;
        IF v_disp > 0 THEN
          CALL spi_emitir_nota_credito(v_comprobante, IF(v_tipo = 'total' AND p_monto_devuelto = v_disp, '06', '07'),
                                       CONCAT('Devolución ', v_numero, ': ', TRIM(p_motivo)), NULL, p_id_devolucion, p_id_nota_credito);
        END IF;
      END IF;
      SET v_fin = 0;
    END IF;

    -- Reembolsos: solo lo que el cliente pagó DE MÁS tras la devolución (si pagó solo un adelanto, quizá nada),
    -- repartido entre los pagos aplicados (del más reciente al más antiguo)
    SELECT saldo INTO v_saldo FROM pedido WHERE id_pedido = p_id_pedido;
    SELECT COALESCE(SUM(r.monto), 0) INTO v_pendiente
      FROM reembolso r JOIN pago p ON p.id_pago = r.id_pago
     WHERE p.id_pedido = p_id_pedido AND p.aplicado_al_pedido = 1 AND r.estado IN ('solicitado','procesando') FOR SHARE;
    SET v_a_favor = GREATEST(-v_saldo - v_pendiente, 0);
    CALL spi_repartir_reembolso(p_id_pedido, LEAST(v_a_favor, p_monto_devuelto), 'devolucion', CONCAT('Devolución ', v_numero),
                                p_id_nota_credito, p_id_devolucion, v_por_reembolsar, v_reembolso);
    SET v_fin = 0;

    CALL spi_auditar('pedido_devuelto', 'devolucion', p_id_devolucion, v_usuario,
                     JSON_OBJECT('pedido', v_numero, 'tipo', v_tipo, 'monto', p_monto_devuelto), 'procedimiento');
    DROP TEMPORARY TABLE IF EXISTS tmp_devolucion;
    COMMIT;
    SET @wanka_ctx_interno = NULL;
  END;
END $$

-- #####################################################################
-- L. ATENCIÓN AL CLIENTE, RESEÑAS
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_registrar_mensaje_contacto $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_mensaje_contacto(
  IN p_id_usuario BIGINT UNSIGNED, IN p_nombre VARCHAR(100), IN p_correo VARCHAR(254), IN p_celular VARCHAR(20),
  IN p_asunto VARCHAR(15), IN p_id_pedido BIGINT UNSIGNED, IN p_mensaje VARCHAR(2000), IN p_acepto_datos BOOLEAN, IN p_version_politica VARCHAR(20),
  OUT p_id_mensaje BIGINT UNSIGNED, OUT p_ticket VARCHAR(25))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Ticket de contacto con correlativo anual; máximo 3 por hora por IP (serializado: dos envíos simultáneos cuentan en orden)'
BEGIN
  DECLARE v_ip VARBINARY(16) DEFAULT fn_ip_sesion();
  DECLARE v_max INT DEFAULT fn_config_entero('contacto_max_por_hora_ip');
  DECLARE v_recientes INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF NOT COALESCE(p_acepto_datos, 0) THEN CALL spi_error(45006, 'Debe aceptar la política de tratamiento de datos'); END IF;
  IF p_id_usuario IS NOT NULL THEN CALL spi_validar_dueno_o_admin(p_id_usuario); END IF;
  IF p_id_pedido IS NOT NULL AND NOT EXISTS (SELECT 1 FROM pedido WHERE id_pedido = p_id_pedido AND id_usuario <=> p_id_usuario) THEN
    CALL spi_error(45006, 'El pedido indicado no corresponde al usuario');
  END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  -- Sin IP conocida todas las solicitudes comparten un mismo cupo (falla cerrado)
  CALL spi_bloquear_frecuencia('contacto_ip', COALESCE(INET6_NTOA(v_ip), 'sin_ip'));
  SELECT COUNT(*) INTO v_recientes FROM mensaje_contacto WHERE ip <=> v_ip AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 HOUR;
  IF v_recientes >= v_max THEN
    CALL spi_error(45010, CONCAT('Límite de ', v_max, ' mensajes por hora alcanzado. Intente más tarde'));
  END IF;
  INSERT INTO mensaje_contacto (ticket, id_usuario, nombre, correo, celular, asunto, id_pedido, mensaje, acepto_datos, ip)
  VALUES (NULL, p_id_usuario, TRIM(p_nombre), fn_normalizar_correo(p_correo), fn_normalizar_telefono(p_celular), p_asunto, p_id_pedido,
          TRIM(p_mensaje), 1, v_ip);
  SET p_id_mensaje = LAST_INSERT_ID();
  SELECT ticket INTO p_ticket FROM mensaje_contacto WHERE id_mensaje = p_id_mensaje;
  INSERT INTO consentimiento_datos (id_usuario, correo, finalidad, version_documento, otorgado, ip)
  VALUES (p_id_usuario, fn_normalizar_correo(p_correo), 'formulario_contacto', COALESCE(p_version_politica, fn_config('politica_privacidad_version')), 1, v_ip);
  CALL spi_notificar_admins('contacto_nuevo', CONCAT('Nuevo mensaje ', p_ticket), CONCAT('Asunto: ', p_asunto), '/admin/contacto', p_id_pedido);
  CALL spi_encolar_correo(p_id_usuario, p_correo, 'contacto_recibido', JSON_OBJECT('ticket', p_ticket), 5);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_responder_mensaje_contacto $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_responder_mensaje_contacto(
  IN p_id_mensaje BIGINT UNSIGNED, IN p_respuesta TEXT, IN p_cerrar BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Respuesta del administrador (queda en el historial respuesta_atencion y se envía por correo)'
BEGIN
  DECLARE v_correo VARCHAR(254); DECLARE v_ticket VARCHAR(25); DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo, ticket, id_usuario INTO v_correo, v_ticket, v_usuario FROM mensaje_contacto WHERE id_mensaje = p_id_mensaje FOR UPDATE;
  IF v_ticket IS NULL THEN CALL spi_error(45022, 'El mensaje no existe'); END IF;
  INSERT INTO respuesta_atencion (id_mensaje, autor, id_usuario, mensaje) VALUES (p_id_mensaje, 'administrador', fn_actor(), p_respuesta);
  UPDATE mensaje_contacto SET estado = IF(p_cerrar, 'cerrado', 'respondido'), atendido_por = fn_actor() WHERE id_mensaje = p_id_mensaje;
  CALL spi_encolar_correo(v_usuario, v_correo, 'contacto_respuesta', JSON_OBJECT('ticket', v_ticket, 'respuesta', LEFT(p_respuesta, 2000)), 4);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_marcar_en_atencion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_marcar_en_atencion(IN p_entidad VARCHAR(10), IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'El administrador toma un mensaje de contacto (en_proceso) o un reclamo (en_atencion). Las tablas no se editan a mano'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_entidad IS NULL OR p_entidad NOT IN ('mensaje','reclamo') THEN CALL spi_error(45006, 'Entidad inválida: mensaje o reclamo'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF p_entidad = 'mensaje' THEN
    UPDATE mensaje_contacto SET estado = 'en_proceso', atendido_por = fn_actor() WHERE id_mensaje = p_id AND estado = 'nuevo';
  ELSE
    UPDATE reclamo SET estado = 'en_atencion' WHERE id_reclamo = p_id AND estado = 'registrado';
  END IF;
  IF ROW_COUNT() = 0 THEN CALL spi_error(45004, 'No existe o ya está en atención, respondido o cerrado'); END IF;
  CALL spi_auditar('atencion_tomada', p_entidad, p_id, NULL, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_reclamo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_reclamo(
  IN p_id_usuario BIGINT UNSIGNED, IN p_nombres VARCHAR(100), IN p_apellidos VARCHAR(100), IN p_tipo_doc VARCHAR(3), IN p_num_doc VARCHAR(12),
  IN p_domicilio VARCHAR(200), IN p_correo VARCHAR(254), IN p_celular VARCHAR(20), IN p_es_menor BOOLEAN, IN p_apoderado VARCHAR(200),
  IN p_tipo_bien VARCHAR(10), IN p_monto DECIMAL(12,2), IN p_descripcion_bien VARCHAR(300), IN p_tipo VARCHAR(10),
  IN p_detalle TEXT, IN p_pedido_consumidor TEXT, IN p_id_pedido BIGINT UNSIGNED, IN p_acepto_datos BOOLEAN,
  OUT p_id_reclamo BIGINT UNSIGNED, OUT p_numero VARCHAR(25), OUT p_fecha_limite DATE)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Libro de Reclamaciones: correlativo anual, fecha límite según configuración (verificar INDECOPI), constancia por correo'
BEGIN
  DECLARE v_ip VARBINARY(16) DEFAULT fn_ip_sesion();
  DECLARE v_max INT DEFAULT fn_config_entero('reclamo_max_por_hora_ip');
  DECLARE v_recientes INT;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF NOT COALESCE(p_acepto_datos, 0) THEN CALL spi_error(45006, 'Debe aceptar la política de tratamiento de datos'); END IF;
  IF p_id_usuario IS NOT NULL THEN CALL spi_validar_dueno_o_admin(p_id_usuario); END IF;
  IF p_id_pedido IS NOT NULL AND (p_id_usuario IS NULL OR NOT EXISTS (SELECT 1 FROM pedido WHERE id_pedido = p_id_pedido AND id_usuario = p_id_usuario)) THEN
    CALL spi_error(45006, 'El pedido indicado no corresponde al usuario (inicie sesión para vincular un pedido)');
  END IF;
  IF NOT fn_documento_valido(p_tipo_doc, UPPER(TRIM(p_num_doc))) THEN CALL spi_error(45006, 'Documento de identidad inválido'); END IF;
  SET p_fecha_limite = fn_fecha_limite(fn_hoy_lima(), fn_config_entero('reclamo_plazo_dias'), fn_config('reclamo_plazo_tipo'));
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  IF v_max > 0 THEN
    CALL spi_bloquear_frecuencia('reclamo_ip', COALESCE(INET6_NTOA(v_ip), 'sin_ip'));
    SELECT COUNT(*) INTO v_recientes FROM reclamo WHERE ip <=> v_ip AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 HOUR;
    IF v_recientes >= v_max THEN CALL spi_error(45010, 'Demasiados reclamos desde esta conexión. Intente más tarde'); END IF;
  END IF;
  INSERT INTO reclamo (numero, id_usuario, nombres, apellidos, tipo_doc, num_doc, domicilio, correo, celular, es_menor_edad, apoderado_nombre,
                       tipo_bien, monto_reclamado, descripcion_bien, tipo, detalle, pedido_consumidor, id_pedido, fecha_limite, acepto_datos, ip)
  VALUES (NULL, p_id_usuario, TRIM(p_nombres), TRIM(p_apellidos), p_tipo_doc, UPPER(TRIM(p_num_doc)), TRIM(p_domicilio),
          fn_normalizar_correo(p_correo), fn_normalizar_telefono(p_celular), COALESCE(p_es_menor, 0), NULLIF(TRIM(p_apoderado), ''),
          p_tipo_bien, p_monto, TRIM(p_descripcion_bien), p_tipo, p_detalle, p_pedido_consumidor, p_id_pedido, p_fecha_limite, 1, v_ip);
  SET p_id_reclamo = LAST_INSERT_ID();
  SELECT numero INTO p_numero FROM reclamo WHERE id_reclamo = p_id_reclamo;
  INSERT INTO consentimiento_datos (id_usuario, correo, finalidad, version_documento, otorgado, ip)
  VALUES (p_id_usuario, fn_normalizar_correo(p_correo), 'libro_reclamaciones', fn_config('politica_privacidad_version'), 1, v_ip);
  CALL spi_notificar_admins('reclamo_nuevo', CONCAT('Nuevo ', p_tipo, ' ', p_numero), CONCAT('Responder antes del ', p_fecha_limite), '/admin/reclamos', p_id_pedido);
  CALL spi_encolar_correo(p_id_usuario, p_correo, 'reclamo_constancia', JSON_OBJECT('numero', p_numero, 'fecha_limite', p_fecha_limite), 2);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_responder_reclamo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_responder_reclamo(IN p_id_reclamo BIGINT UNSIGNED, IN p_respuesta TEXT, IN p_cerrar BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Respuesta del proveedor al reclamo (historial + correo al consumidor)'
BEGIN
  DECLARE v_correo VARCHAR(254); DECLARE v_numero VARCHAR(25); DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_respuesta IS NULL OR CHAR_LENGTH(TRIM(p_respuesta)) < 10 THEN CALL spi_error(45006, 'La respuesta debe tener al menos 10 caracteres'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo, numero, id_usuario INTO v_correo, v_numero, v_usuario FROM reclamo WHERE id_reclamo = p_id_reclamo FOR UPDATE;
  IF v_numero IS NULL THEN CALL spi_error(45022, 'El reclamo no existe'); END IF;
  INSERT INTO respuesta_atencion (id_reclamo, autor, id_usuario, mensaje) VALUES (p_id_reclamo, 'administrador', fn_actor(), p_respuesta);
  UPDATE reclamo SET estado = IF(p_cerrar, 'cerrado', 'respondido'), respondido_por = fn_actor(),
                     respondido_en = COALESCE(respondido_en, UTC_TIMESTAMP(3))
   WHERE id_reclamo = p_id_reclamo;
  CALL spi_encolar_correo(v_usuario, v_correo, 'reclamo_respuesta', JSON_OBJECT('numero', v_numero, 'respuesta', LEFT(p_respuesta, 2000)), 2);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_resena $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_resena(
  IN p_id_usuario BIGINT UNSIGNED, IN p_id_producto BIGINT UNSIGNED, IN p_id_pedido BIGINT UNSIGNED, IN p_calificacion TINYINT UNSIGNED,
  IN p_titulo VARCHAR(100), IN p_comentario VARCHAR(1000), OUT p_id_resena BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Reseña de quien compró y recibió el producto (una por producto); queda pendiente de moderación'
BEGIN
  DECLARE EXIT HANDLER FOR 1062 BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL;
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ya reseñó este producto', MYSQL_ERRNO = 45026; END;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_dueno_o_admin(p_id_usuario);
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  INSERT INTO resena (id_producto, id_usuario, id_pedido, calificacion, titulo, comentario)
  VALUES (p_id_producto, p_id_usuario, p_id_pedido, p_calificacion, NULLIF(TRIM(p_titulo), ''), NULLIF(TRIM(p_comentario), ''));
  SET p_id_resena = LAST_INSERT_ID();
  CALL spi_notificar_admins('resena_por_moderar', 'Reseña por moderar', CONCAT(p_calificacion, ' estrellas'), '/admin/resenas', p_id_pedido);
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_moderar_resena $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_moderar_resena(IN p_id_resena BIGINT UNSIGNED, IN p_estado VARCHAR(10), IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Publica, rechaza u oculta una reseña (la valoración del producto se recalcula por trigger)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_estado NOT IN ('publicada','rechazada','oculta') THEN CALL spi_error(45006, 'Estado inválido: publicada, rechazada u oculta'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE resena SET estado = p_estado, moderado_por = fn_actor(), moderado_en = UTC_TIMESTAMP(3), motivo_moderacion = p_motivo
   WHERE id_resena = p_id_resena;
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'La reseña no existe'); END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- M. SISTEMA: configuración, APIs externas, colas
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_actualizar_configuracion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_actualizar_configuracion(IN p_clave VARCHAR(60), IN p_valor VARCHAR(500))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cambia un parámetro editable (el trigger valida tipo y rango y audita el cambio)'
BEGIN
  DECLARE v_editable BOOLEAN DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT editable INTO v_editable FROM configuracion WHERE clave = p_clave FOR UPDATE;
  IF v_editable IS NULL THEN CALL spi_error(45020, 'Clave de configuración inexistente'); END IF;
  IF NOT v_editable THEN CALL spi_error(45020, 'Esta clave solo la cambia el DBA'); END IF;
  UPDATE configuracion SET valor = TRIM(p_valor) WHERE clave = p_clave;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_registrar_log_api $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_registrar_log_api(
  IN p_proveedor VARCHAR(15), IN p_endpoint VARCHAR(300), IN p_metodo_http VARCHAR(6), IN p_codigo_http SMALLINT UNSIGNED,
  IN p_duracion_ms INT UNSIGNED, IN p_exitoso BOOLEAN, IN p_request JSON, IN p_response JSON, IN p_correlacion VARCHAR(64),
  IN p_id_pedido BIGINT UNSIGNED, IN p_id_comprobante BIGINT UNSIGNED, IN p_id_pago BIGINT UNSIGNED, IN p_error VARCHAR(500),
  OUT p_id_log BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Bitácora de una llamada a API externa. La app enmascara tokens y datos personales; la BD rechaza datos de tarjeta y credenciales (la tabla es inmutable 12 meses)'
BEGIN
  IF p_proveedor IS NULL OR p_proveedor NOT IN ('ose','reniec','sunat_ruc','mercadopago','paypal','courier','correo','otro') THEN
    CALL spi_error(45006, 'Proveedor de API inválido');
  END IF;
  IF p_metodo_http IS NULL OR p_metodo_http NOT IN ('GET','POST','PUT','PATCH','DELETE') THEN CALL spi_error(45006, 'Método HTTP inválido'); END IF;
  IF NULLIF(TRIM(p_endpoint), '') IS NULL THEN CALL spi_error(45006, 'Falta el endpoint'); END IF;
  IF fn_contiene_datos_tarjeta(p_request) OR fn_contiene_datos_tarjeta(p_response) THEN
    CALL spi_error(45031, 'El log contiene datos de tarjeta: enmascare antes de registrar');
  END IF;
  IF fn_contiene_secretos(NULL, p_endpoint) THEN
    CALL spi_error(45006, 'El endpoint contiene un token o secreto en la URL: quítelo antes de registrar');
  END IF;
  IF fn_contiene_secretos(p_request, NULL) OR fn_contiene_secretos(p_response, NULL) THEN
    CALL spi_error(45031, 'El log contiene credenciales (authorization, token, password, secret, api_key...): enmascárelas antes de registrar');
  END IF;
  INSERT INTO log_api_externa (proveedor, endpoint, metodo_http, codigo_http, duracion_ms, exitoso, request_enmascarado, response_enmascarado,
                               correlacion_id, id_pedido, id_comprobante, id_pago, error)
  VALUES (p_proveedor, p_endpoint, p_metodo_http, p_codigo_http, p_duracion_ms, COALESCE(p_exitoso, 0), p_request, p_response,
          p_correlacion, p_id_pedido, p_id_comprobante, p_id_pago, p_error);
  SET p_id_log = LAST_INSERT_ID();
END $$

DROP PROCEDURE IF EXISTS sp_redactar_log_api $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_redactar_log_api(IN p_id_log BIGINT UNSIGNED, IN p_motivo VARCHAR(200))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'SOLO DBA (cuenta wanka_dba + @wanka_autorizo_borrado = SI-AUTORIZO): borra el contenido de un registro de la bitácora que guardó un secreto por error. Queda auditado'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF NOT fn_borrado_dba_autorizado() THEN
    CALL spi_error(45005, 'Solo el DBA de mantenimiento con autorización explícita redacta la bitácora');
  END IF;
  IF p_motivo IS NULL OR CHAR_LENGTH(TRIM(p_motivo)) < 10 THEN CALL spi_error(45006, 'Indique el motivo de la redacción'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SET @wanka_x = NULL;
  SELECT id_log INTO @wanka_x FROM log_api_externa WHERE id_log = p_id_log FOR UPDATE;
  IF @wanka_x IS NULL THEN CALL spi_error(45022, 'El registro no existe'); END IF;
  UPDATE log_api_externa
     SET endpoint = LEFT(SUBSTRING_INDEX(endpoint, '?', 1), 300),
         request_enmascarado = IF(request_enmascarado IS NULL, NULL, JSON_OBJECT('redactado', TRUE)),
         response_enmascarado = IF(response_enmascarado IS NULL, NULL, JSON_OBJECT('redactado', TRUE)),
         error = IF(error IS NULL, NULL, '[redactado]')
   WHERE id_log = p_id_log;
  CALL spi_auditar('log_api_redactado', 'log_api_externa', p_id_log, NULL, JSON_OBJECT('motivo', LEFT(p_motivo, 200)), 'dba');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_obtener_consulta_documento $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_obtener_consulta_documento(
  IN p_tipo VARCHAR(3), IN p_numero VARCHAR(11), OUT p_encontrado BOOLEAN, OUT p_nombre VARCHAR(200),
  OUT p_estado VARCHAR(30), OUT p_condicion VARCHAR(30), OUT p_domicilio VARCHAR(300))
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Lee la caché DNI/RUC de UN documento exacto y vigente (la tienda no puede listar la tabla completa)'
BEGIN
  DECLARE v_numero VARCHAR(11) DEFAULT TRIM(p_numero);
  SET p_encontrado = 0; SET p_nombre = NULL; SET p_estado = NULL; SET p_condicion = NULL; SET p_domicilio = NULL;
  IF p_tipo IS NULL OR p_tipo NOT IN ('DNI','RUC') OR NOT fn_documento_valido(p_tipo, v_numero) THEN
    CALL spi_error(45006, 'Documento inválido para la consulta');
  END IF;
  SELECT 1, nombre_razon_social, estado_contribuyente, condicion_domicilio, domicilio_fiscal
    INTO p_encontrado, p_nombre, p_estado, p_condicion, p_domicilio
    FROM consulta_documento
   WHERE tipo_documento = p_tipo AND numero = v_numero AND exitosa = 1 AND vigente_hasta > UTC_TIMESTAMP(3);
  SET p_encontrado = COALESCE(p_encontrado, 0);
END $$

DROP PROCEDURE IF EXISTS sp_guardar_consulta_documento $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_guardar_consulta_documento(
  IN p_tipo VARCHAR(3), IN p_numero VARCHAR(11), IN p_nombre VARCHAR(200), IN p_estado VARCHAR(30), IN p_condicion VARCHAR(30),
  IN p_domicilio VARCHAR(300), IN p_fuente VARCHAR(40), IN p_exitosa BOOLEAN)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Guarda o renueva la caché de una consulta DNI/RUC (para DNI no se guarda domicilio: minimización de datos)'
BEGIN
  DECLARE v_numero VARCHAR(11) DEFAULT TRIM(p_numero);
  IF p_tipo NOT IN ('DNI','RUC') OR NOT fn_documento_valido(p_tipo, v_numero) THEN CALL spi_error(45006, 'Documento inválido para la consulta'); END IF;
  INSERT INTO consulta_documento (tipo_documento, numero, nombre_razon_social, estado_contribuyente, condicion_domicilio, domicilio_fiscal,
                                  fuente, exitosa, consultado_en, vigente_hasta)
  VALUES (p_tipo, v_numero, p_nombre, IF(p_tipo = 'RUC', p_estado, NULL), IF(p_tipo = 'RUC', p_condicion, NULL),
          IF(p_tipo = 'RUC', p_domicilio, NULL), p_fuente, COALESCE(p_exitosa, 0), UTC_TIMESTAMP(3),
          UTC_TIMESTAMP(3) + INTERVAL fn_config_entero('consulta_documento_vigencia_dias') DAY) AS nuevo
  -- COMPAT-MARIADB: usar VALUES(columna) en lugar del alias "nuevo"
  ON DUPLICATE KEY UPDATE nombre_razon_social = nuevo.nombre_razon_social, estado_contribuyente = nuevo.estado_contribuyente,
                          condicion_domicilio = nuevo.condicion_domicilio, domicilio_fiscal = nuevo.domicilio_fiscal,
                          fuente = nuevo.fuente, exitosa = nuevo.exitosa, consultado_en = nuevo.consultado_en, vigente_hasta = nuevo.vigente_hasta;
END $$

DROP PROCEDURE IF EXISTS sp_tomar_correos_pendientes $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_tomar_correos_pendientes(IN p_worker VARCHAR(20), IN p_limite INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Worker de correo: reserva hasta N correos vencidos (por prioridad) y los devuelve como resultado'
BEGIN
  DECLARE v_token VARCHAR(64) DEFAULT CONCAT(LEFT(COALESCE(p_worker, 'worker'), 20), ':', UUID());
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  IF p_limite IS NULL OR p_limite < 1 OR p_limite > 200 THEN CALL spi_error(45006, 'Límite inválido (1 a 200)'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE cola_correo
     SET estado = 'procesando', tomado_por = v_token, intentos = intentos + 1, actualizado_en = UTC_TIMESTAMP(3)
   WHERE intentos < max_intentos
     AND ((estado IN ('pendiente','error') AND proximo_intento_en <= UTC_TIMESTAMP(3))
       OR (estado = 'procesando' AND actualizado_en < UTC_TIMESTAMP(3) - INTERVAL 10 MINUTE))
   ORDER BY prioridad, proximo_intento_en
   LIMIT p_limite;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
  SELECT id_correo, destinatario, plantilla, contexto, intentos FROM cola_correo WHERE tomado_por = v_token AND estado = 'procesando';
END $$

DROP PROCEDURE IF EXISTS sp_marcar_correo $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_marcar_correo(
  IN p_id_correo BIGINT UNSIGNED, IN p_exitoso BOOLEAN, IN p_error VARCHAR(500), IN p_id_mensaje_proveedor VARCHAR(150))
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Resultado del envío: enviado, o error con reintento exponencial (descartado al agotar intentos)'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE cola_correo
     SET estado = IF(p_exitoso, 'enviado', IF(intentos >= max_intentos, 'descartado', 'error')),
         enviado_en = IF(p_exitoso, UTC_TIMESTAMP(3), NULL),
         ultimo_error = IF(p_exitoso, NULL, LEFT(p_error, 500)),
         id_mensaje_proveedor = COALESCE(p_id_mensaje_proveedor, id_mensaje_proveedor),
         proximo_intento_en = IF(p_exitoso, proximo_intento_en, UTC_TIMESTAMP(3) + INTERVAL LEAST(POW(2, intentos), 60) MINUTE)
   WHERE id_correo = p_id_correo AND estado = 'procesando';
  IF ROW_COUNT() = 0 THEN CALL spi_error(45022, 'El correo no existe o no estaba en proceso'); END IF;
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_marcar_notificacion_leida $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_marcar_notificacion_leida(IN p_id_notificacion BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Marca una notificación propia como leída'
BEGIN
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  UPDATE notificacion SET leida = 1, leida_en = UTC_TIMESTAMP(3)
   WHERE id_notificacion = p_id_notificacion AND leida = 0 AND (id_usuario = fn_actor() OR fn_es_admin(fn_actor()));
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

-- #####################################################################
-- N. TAREAS PROGRAMADAS (las llaman los eventos de 06_eventos.sql)
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_expirar_pedidos_pendientes $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_expirar_pedidos_pendientes(OUT p_cancelados INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cancela pedidos sin pago vencidos (libera stock), salvo que tengan un pago en revisión o confirmado APLICADO. Anula los cobros de pasarela abandonados. Una transacción por pedido'
BEGIN
  DECLARE v_ultimo BIGINT UNSIGNED DEFAULT 0;
  DECLARE v_id BIGINT UNSIGNED;
  DECLARE v_error BOOLEAN;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_id = NULL;
  SET p_cancelados = 0;
  bucle: LOOP
    SET v_id = NULL;
    SELECT id_pedido INTO v_id FROM pedido
     WHERE estado = 'pendiente_pago' AND expira_en < UTC_TIMESTAMP(3) AND id_pedido > v_ultimo
     ORDER BY id_pedido LIMIT 1;
    IF v_id IS NULL THEN LEAVE bucle; END IF;
    SET v_ultimo = v_id;
    SET v_error = 0;
    BEGIN
      DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN
        ROLLBACK; SET v_error = 1;
        CALL spi_auditar('expiracion_fallida', 'pedido', v_id, NULL, NULL, 'evento');
      END;
      SET @wanka_ctx_interno = fn_token_interno();
      START TRANSACTION;
      SELECT id_pedido INTO v_id FROM pedido WHERE id_pedido = v_id AND estado = 'pendiente_pago' FOR UPDATE;
      IF v_id IS NOT NULL
         -- Un pago huérfano (confirmado pero no aplicado) no mantiene vivo el pedido: se reembolsa aparte
         AND NOT EXISTS (SELECT 1 FROM pago WHERE id_pedido = v_id
                            AND (estado = 'en_revision' OR (estado = 'confirmado' AND aplicado_al_pedido = 1)))
         -- Gracia: un cobro de pasarela iniciado hace poco puede estar por confirmarse (evita pagos huérfanos)
         AND NOT EXISTS (SELECT 1 FROM pago WHERE id_pedido = v_id AND estado = 'pendiente'
                            AND creado_en > UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('minutos_gracia_pago_pasarela') MINUTE) THEN
        -- Cobros abandonados: si la pasarela los aprueba después, el webhook los registra como huérfanos
        UPDATE pago SET estado = 'anulado', motivo_rechazo = 'Cobro abandonado: el pedido expiró'
         WHERE id_pedido = v_id AND estado = 'pendiente';
        CALL spi_cambiar_estado_pedido(v_id, 'cancelado', 'Expirado por falta de pago', 1);
        SET p_cancelados = p_cancelados + 1;
      END IF;
      COMMIT;
    END;
    SET v_id = v_ultimo;
  END LOOP bucle;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_expirar_codigos_verificacion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_expirar_codigos_verificacion(OUT p_expirados INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Marca como expirados los códigos vencidos'
BEGIN
  UPDATE codigo_verificacion SET estado = 'expirado', cerrado_en = UTC_TIMESTAMP(3) WHERE estado = 'activo' AND expira_en <= UTC_TIMESTAMP(3);
  SET p_expirados = ROW_COUNT();
END $$

DROP PROCEDURE IF EXISTS sp_vencer_cotizaciones $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_vencer_cotizaciones(OUT p_vencidas INT)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Cotizaciones cotizadas cuya vigencia (día de Lima) ya pasó → vencida'
BEGIN
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE cotizacion SET estado = 'vencida' WHERE estado = 'cotizada' AND vigencia_hasta < fn_hoy_lima();
  SET p_vencidas = ROW_COUNT();
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_mantenimiento_diario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_mantenimiento_diario()
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Carritos abandonados, sesiones vencidas y purga por retención de datos temporales (nunca toca datos de negocio ni auditoría < 12 meses)'
BEGIN
  DECLARE v_carritos INT; DECLARE v_sesiones INT; DECLARE v_codigos INT; DECLARE v_correos INT; DECLARE v_intentos INT;
  DECLARE v_logs INT; DECLARE v_eventos INT; DECLARE v_consultas INT; DECLARE v_notif INT; DECLARE v_control INT; DECLARE v_items INT;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE carrito SET estado = 'abandonado'
   WHERE estado = 'activo' AND actualizado_en < UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('carrito_dias_abandono') DAY;
  SET v_carritos = ROW_COUNT();
  -- Los ítems de carritos abandonados no tienen valor histórico (minimización de datos)
  DELETE ic FROM item_carrito ic JOIN carrito c ON c.id_carrito = ic.id_carrito
   WHERE c.estado = 'abandonado' AND c.actualizado_en < UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('carrito_dias_abandono') DAY;
  SET v_items = ROW_COUNT();
  UPDATE sesion SET cerrada_en = UTC_TIMESTAMP(3), motivo_cierre = 'expirada' WHERE cerrada_en IS NULL AND expira_en < UTC_TIMESTAMP(3);
  DELETE FROM sesion WHERE cerrada_en < UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('sesion_retencion_dias') DAY;
  SET v_sesiones = ROW_COUNT();
  DELETE FROM codigo_verificacion WHERE estado <> 'activo' AND creado_en < UTC_TIMESTAMP(3) - INTERVAL 30 DAY;
  SET v_codigos = ROW_COUNT();
  DELETE FROM cola_correo WHERE estado IN ('enviado','descartado') AND actualizado_en < UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('cola_correo_retencion_dias') DAY;
  SET v_correos = ROW_COUNT();
  DELETE FROM intento_acceso WHERE creado_en < UTC_TIMESTAMP(3) - INTERVAL GREATEST(fn_config_entero('intento_acceso_retencion_meses'), 12) MONTH;
  SET v_intentos = ROW_COUNT();
  DELETE FROM log_api_externa WHERE creado_en < UTC_TIMESTAMP(3) - INTERVAL GREATEST(fn_config_entero('log_api_retencion_meses'), 12) MONTH;
  SET v_logs = ROW_COUNT();
  DELETE FROM evento_pasarela WHERE estado IN ('procesado','ignorado')
     AND recibido_en < UTC_TIMESTAMP(3) - INTERVAL fn_config_entero('evento_pasarela_retencion_dias') DAY;
  SET v_eventos = ROW_COUNT();
  DELETE FROM consulta_documento WHERE vigente_hasta < UTC_TIMESTAMP(3) - INTERVAL 30 DAY;
  SET v_consultas = ROW_COUNT();
  DELETE FROM notificacion WHERE leida = 1 AND leida_en < UTC_TIMESTAMP(3) - INTERVAL 180 DAY;
  SET v_notif = ROW_COUNT();
  DELETE FROM control_frecuencia WHERE creado_en < UTC_TIMESTAMP(3) - INTERVAL 1 DAY;
  SET v_control = ROW_COUNT();
  SET @wanka_ctx_interno = NULL;
  CALL spi_auditar('mantenimiento_diario', NULL, NULL, NULL,
                   JSON_OBJECT('carritos_abandonados', v_carritos, 'items_carrito_purgados', v_items, 'sesiones', v_sesiones,
                               'codigos', v_codigos, 'correos', v_correos, 'intentos_acceso', v_intentos, 'logs_api', v_logs,
                               'eventos_pasarela', v_eventos, 'consultas_documento', v_consultas, 'notificaciones', v_notif,
                               'control_frecuencia', v_control), 'evento');
END $$

DROP PROCEDURE IF EXISTS sp_alertar_vencimientos $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_alertar_vencimientos()
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Avisa a los administradores de reclamos y solicitudes ARCO que vencen en 3 días o menos'
BEGIN
  DECLARE v_reclamos INT; DECLARE v_arco INT;
  SELECT COUNT(*) INTO v_reclamos FROM reclamo WHERE estado IN ('registrado','en_atencion') AND fecha_limite <= fn_hoy_lima() + INTERVAL 3 DAY;
  SELECT COUNT(*) INTO v_arco FROM solicitud_arco WHERE estado IN ('recibida','en_atencion') AND fecha_limite <= fn_hoy_lima() + INTERVAL 3 DAY;
  IF v_reclamos > 0 THEN
    CALL spi_notificar_admins('reclamos_por_vencer', CONCAT(v_reclamos, ' reclamo(s) por vencer'), 'Revise el Libro de Reclamaciones', '/admin/reclamos', NULL);
  END IF;
  IF v_arco > 0 THEN
    CALL spi_notificar_admins('arco_por_vencer', CONCAT(v_arco, ' solicitud(es) ARCO por vencer'), 'Revise las solicitudes ARCO', '/admin/arco', NULL);
  END IF;
END $$


-- #####################################################################
-- O. MANTENIMIENTO ADMINISTRATIVO
-- #####################################################################

DROP PROCEDURE IF EXISTS sp_reintentar_emision $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_reintentar_emision(IN p_id_comprobante BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Vuelve a poner en cola un comprobante con error o cuya emisión se descartó por agotar los reintentos'
BEGIN
  DECLARE v_estado VARCHAR(12) DEFAULT NULL;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT estado_sunat INTO v_estado FROM comprobante WHERE id_comprobante = p_id_comprobante FOR UPDATE;
  IF v_estado IS NULL THEN CALL spi_error(45022, 'El comprobante no existe'); END IF;
  IF v_estado NOT IN ('pendiente','enviado','error') THEN
    CALL spi_error(45004, CONCAT('El comprobante ya está ', v_estado, ': no se reintenta'));
  END IF;
  UPDATE cola_emision_comprobante
     SET estado = 'pendiente', intentos = 0, proximo_intento_en = UTC_TIMESTAMP(3), ultimo_error = NULL, tomado_por = NULL, tomado_en = NULL
   WHERE id_comprobante = p_id_comprobante;
  IF ROW_COUNT() = 0 THEN CALL spi_encolar_emision(p_id_comprobante); END IF;
  CALL spi_auditar('emision_reintentada', 'comprobante', p_id_comprobante, NULL, NULL, 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DROP PROCEDURE IF EXISTS sp_anonimizar_usuario $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE sp_anonimizar_usuario(IN p_id_usuario BIGINT UNSIGNED, IN p_id_solicitud_arco BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Derecho de cancelación (Ley 29733): anonimiza la cuenta y sus direcciones sin borrar filas. Pedidos, comprobantes y reclamos se conservan por obligación legal'
BEGIN
  DECLARE v_correo VARCHAR(254) DEFAULT NULL;
  DECLARE v_doc VARCHAR(12);
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN ROLLBACK; SET @wanka_ctx_interno = NULL; SET @wanka_origen_contrasena = NULL; RESIGNAL; END;
  CALL spi_validar_admin();
  IF p_id_usuario = fn_actor() THEN CALL spi_error(45023, 'No puede anonimizar su propia cuenta'); END IF;
  SET @wanka_ctx_interno = fn_token_interno();
  START TRANSACTION;
  SELECT correo, numero_documento INTO v_correo, v_doc FROM usuario WHERE id_usuario = p_id_usuario FOR UPDATE;
  IF v_correo IS NULL THEN CALL spi_error(45022, 'El usuario no existe'); END IF;
  IF v_correo LIKE '%.invalid' THEN CALL spi_error(45004, 'La cuenta ya está anonimizada o es interna'); END IF;
  IF fn_es_admin(p_id_usuario) THEN CALL spi_error(45023, 'Quite primero el rol de administrador'); END IF;
  IF EXISTS (SELECT 1 FROM pedido p JOIN estado_pedido e ON e.codigo = p.estado
              WHERE p.id_usuario = p_id_usuario AND e.es_final = 0) THEN
    CALL spi_error(45032, 'El cliente tiene pedidos en curso: termínelos o cancélelos antes de anonimizar');
  END IF;
  SET @wanka_origen_contrasena = 'administrador';
  UPDATE usuario
     SET correo = CONCAT('anonimizado+', p_id_usuario, '@bordadoswanka.invalid'), nombres = 'Usuario', apellidos = 'Anonimizado',
         celular = NULL, tipo_documento = NULL, numero_documento = NULL, hash_contrasena = '!anonimizado-por-solicitud-arco',
         estado = 'inhabilitado', inhabilitado_en = COALESCE(inhabilitado_en, UTC_TIMESTAMP(3)), inhabilitado_por = COALESCE(inhabilitado_por, fn_actor()),
         motivo_inhabilitacion = 'Anonimizado por derecho de cancelación (ARCO)', intentos_fallidos = 0, bloqueado_hasta = NULL
   WHERE id_usuario = p_id_usuario;
  SET @wanka_origen_contrasena = NULL;
  UPDATE direccion
     SET alias = 'Anonimizada', nombre_receptor = 'Anonimizado', telefono = '000000000', direccion = 'Anonimizada', referencia = NULL,
         ubigeo = NULL, predeterminada = 0, activo = 0,
         inhabilitado_en = COALESCE(inhabilitado_en, UTC_TIMESTAMP(3)), inhabilitado_por = COALESCE(inhabilitado_por, fn_actor())
   WHERE id_usuario = p_id_usuario;
  CALL spi_cerrar_sesiones_usuario(p_id_usuario, 'revocada');
  UPDATE codigo_verificacion SET estado = 'bloqueado', cerrado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND estado = 'activo';
  UPDATE autenticacion_2fa SET metodo = 'correo', secreto_cifrado = NULL, activo = 0, desactivado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario;
  UPDATE codigo_respaldo_2fa SET invalidado_en = UTC_TIMESTAMP(3) WHERE id_usuario = p_id_usuario AND usado_en IS NULL AND invalidado_en IS NULL;
  DELETE ic FROM item_carrito ic JOIN carrito c ON c.id_carrito = ic.id_carrito WHERE c.id_usuario = p_id_usuario;
  UPDATE carrito SET estado = 'abandonado' WHERE id_usuario = p_id_usuario AND estado = 'activo';
  DELETE FROM favorito WHERE id_usuario = p_id_usuario;
  IF v_doc IS NOT NULL THEN DELETE FROM consulta_documento WHERE numero = v_doc; END IF;
  IF p_id_solicitud_arco IS NOT NULL THEN
    UPDATE solicitud_arco SET estado = 'atendida', atendido_por = fn_actor(), atendido_en = UTC_TIMESTAMP(3),
                              respuesta = COALESCE(respuesta, 'Datos personales anonimizados. Se conservan pedidos y comprobantes por obligación tributaria.')
     WHERE id_solicitud = p_id_solicitud_arco AND estado IN ('recibida','en_atencion');
  END IF;
  CALL spi_auditar('usuario_anonimizado', 'usuario', p_id_usuario, p_id_usuario, JSON_OBJECT('solicitud_arco', p_id_solicitud_arco), 'procedimiento');
  COMMIT;
  SET @wanka_ctx_interno = NULL;
END $$

DELIMITER ;

SELECT 'Funciones y procedimientos listos: continúa con 04_triggers.sql' AS siguiente_paso;
