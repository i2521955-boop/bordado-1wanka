-- =====================================================================
-- BORDADOS WANKA S.A.C. — 04_triggers.sql
-- ---------------------------------------------------------------------
-- Propósito : RED DE SEGURIDAD. Aunque alguien escriba directo en las
--             tablas, no puede romper las reglas:
--   * DELETE físico bloqueado en tablas de negocio para TODOS (incluido el
--     administrador de la app). Solo la cuenta DBA 'wanka_dba', fuera de la
--     app, con SET @wanka_autorizo_borrado = 'SI-AUTORIZO', y queda auditado.
--   * Tablas históricas de solo inserción (kardex, historiales, auditoría,
--     líneas de comprobante, consentimientos, seguimiento...).
--   * Columnas derivadas (stock, montos pagados, estado_pago, valoración)
--     solo cambian desde los procedimientos (contexto interno).
--   * Cambios de estado solo por transiciones permitidas.
--   * Normalización (trim, minúsculas en correos, MAYÚSCULAS en SKU/CE).
--   * Auditoría y avisos (historial de estados, correo en cola + notificación).
-- MySQL exige un trigger por evento (BEFORE INSERT, BEFORE UPDATE...).
-- Un trigger no puede modificar su propia tabla (error 1442): esos casos se
-- resolvieron con columnas generadas únicas o procedimientos.
-- Re-ejecutable: sí (DROP TRIGGER IF EXISTS).
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';

DELIMITER $$

-- ---------------------------------------------------------------------
-- Procedimientos auxiliares de los triggers
-- ---------------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_control_borrado $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_control_borrado(IN p_tabla VARCHAR(40), IN p_id BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Bloquea el DELETE físico (error 45005) salvo DBA autorizado; el borrado del DBA queda auditado'
BEGIN
  IF fn_borrado_dba_autorizado() THEN
    CALL spi_auditar('borrado_fisico_dba', p_tabla, p_id, NULL, JSON_OBJECT('tabla', p_tabla), 'dba');
  ELSE
    CALL spi_error(45005, CONCAT('No se borra en ', p_tabla, ': use el procedimiento de inhabilitar/archivar (borrado lógico)'));
  END IF;
END $$

DROP PROCEDURE IF EXISTS spi_solo_insercion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_solo_insercion(IN p_tabla VARCHAR(40))
NO SQL SQL SECURITY DEFINER
COMMENT 'Error 45004: tabla histórica de solo inserción'
BEGIN
  CALL spi_error(45004, CONCAT(p_tabla, ' es de solo inserción: no se modifica'));
END $$

DROP PROCEDURE IF EXISTS spi_requiere_contexto $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_requiere_contexto(IN p_que VARCHAR(120))
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'Error 45023 si el cambio no viene de un procedimiento de la BD'
BEGIN
  IF NOT fn_contexto_interno() THEN
    CALL spi_error(45023, CONCAT(p_que, ': use el procedimiento correspondiente (sp_*)'));
  END IF;
END $$

-- =====================================================================
-- ACCESO
-- =====================================================================
DROP TRIGGER IF EXISTS trg_rol_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_rol_bu BEFORE UPDATE ON rol FOR EACH ROW
BEGIN
  IF NEW.codigo <> OLD.codigo THEN CALL spi_error(45004, 'El código del rol no se modifica'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_rol_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_rol_bd BEFORE DELETE ON rol FOR EACH ROW
CALL spi_control_borrado('rol', OLD.id_rol) $$

-- USUARIO -------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_usuario_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_usuario_bi BEFORE INSERT ON usuario FOR EACH ROW
BEGIN
  SET NEW.correo = fn_normalizar_correo(NEW.correo);
  SET NEW.nombres = TRIM(NEW.nombres);
  SET NEW.apellidos = TRIM(NEW.apellidos);
  SET NEW.celular = fn_normalizar_telefono(NEW.celular);
  SET NEW.numero_documento = NULLIF(UPPER(TRIM(NEW.numero_documento)), '');
  IF NOT fn_documento_valido(NEW.tipo_documento, NEW.numero_documento) THEN
    CALL spi_error(45006, 'Documento inválido (DNI 8 dígitos, RUC 11 con dígito verificador, CE 6-12 alfanumérico)');
  END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$

DROP TRIGGER IF EXISTS trg_usuario_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_usuario_bu BEFORE UPDATE ON usuario FOR EACH ROW
BEGIN
  SET NEW.correo = fn_normalizar_correo(NEW.correo);
  SET NEW.nombres = TRIM(NEW.nombres);
  SET NEW.apellidos = TRIM(NEW.apellidos);
  SET NEW.celular = fn_normalizar_telefono(NEW.celular);
  SET NEW.numero_documento = NULLIF(UPPER(TRIM(NEW.numero_documento)), '');
  IF NOT (NEW.tipo_documento <=> OLD.tipo_documento AND NEW.numero_documento <=> OLD.numero_documento)
     AND NOT fn_documento_valido(NEW.tipo_documento, NEW.numero_documento) THEN
    CALL spi_error(45006, 'Documento inválido (DNI 8 dígitos, RUC 11 con dígito verificador, CE 6-12 alfanumérico)');
  END IF;
  IF NEW.creado_en <> OLD.creado_en OR NOT (NEW.creado_por <=> OLD.creado_por) THEN
    CALL spi_error(45004, 'Los datos de creación no se modifican');
  END IF;
  -- Un cliente solo modifica su propia fila (protección ante errores de la app que confundan al usuario)
  IF fn_actor() IS NOT NULL AND fn_actor() <> OLD.id_usuario AND NOT fn_es_admin(fn_actor()) THEN
    CALL spi_error(45023, 'No puede modificar los datos de otro usuario');
  END IF;
  IF NEW.id_rol <> OLD.id_rol THEN CALL spi_requiere_contexto('El rol se cambia con sp_cambiar_rol_usuario'); END IF;
  IF NEW.estado <> OLD.estado THEN
    CALL spi_requiere_contexto('El estado de la cuenta cambia con verificación de correo o sp_inhabilitar_usuario/sp_reactivar_usuario');
  END IF;
  IF NOT (NEW.correo_verificado_en <=> OLD.correo_verificado_en) THEN
    CALL spi_requiere_contexto('La verificación del correo se registra con sp_verificar_codigo');
  END IF;
  IF NEW.intentos_fallidos <> OLD.intentos_fallidos OR NOT (NEW.bloqueado_hasta <=> OLD.bloqueado_hasta) THEN
    CALL spi_requiere_contexto('Los intentos y el bloqueo los maneja sp_registrar_intento_acceso / sp_desbloquear_usuario');
  END IF;
  IF NOT (NEW.inhabilitado_en <=> OLD.inhabilitado_en AND NEW.inhabilitado_por <=> OLD.inhabilitado_por
          AND NEW.motivo_inhabilitacion <=> OLD.motivo_inhabilitacion) THEN
    CALL spi_requiere_contexto('Inhabilitar/reactivar usuarios');
  END IF;
  IF NEW.correo <> OLD.correo THEN CALL spi_requiere_contexto('El correo se cambia con verificación (sp_cambiar_correo)'); END IF;
  IF NEW.hash_contrasena <> OLD.hash_contrasena THEN
    -- Por procedimiento: valida el historial (últimas 3) y cierra las sesiones abiertas
    CALL spi_requiere_contexto('La contraseña se cambia con sp_cambiar_contrasena');
    SET NEW.contrasena_cambiada_en = UTC_TIMESTAMP(3);
  END IF;
  IF NOT (NEW.tipo_documento <=> OLD.tipo_documento AND NEW.numero_documento <=> OLD.numero_documento) THEN
    CALL spi_requiere_contexto('El documento se registra con sp_actualizar_documento_usuario');
  END IF;
  IF NOT (NEW.ultimo_acceso_en <=> OLD.ultimo_acceso_en AND NEW.contrasena_cambiada_en <=> OLD.contrasena_cambiada_en) THEN
    CALL spi_requiere_contexto('Fechas de acceso y de cambio de contraseña');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$

DROP TRIGGER IF EXISTS trg_usuario_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_usuario_au AFTER UPDATE ON usuario FOR EACH ROW
BEGIN
  IF NEW.hash_contrasena <> OLD.hash_contrasena THEN
    INSERT INTO historial_contrasena (id_usuario, hash_contrasena, origen)
    VALUES (NEW.id_usuario, NEW.hash_contrasena, COALESCE(@wanka_origen_contrasena, 'cambio'));
  END IF;
  -- Cambios directos (fuera de procedimientos) quedan auditados
  IF NOT fn_contexto_interno() AND (NEW.estado <> OLD.estado OR NEW.id_rol <> OLD.id_rol
       OR NOT (NEW.tipo_documento <=> OLD.tipo_documento AND NEW.numero_documento <=> OLD.numero_documento)) THEN
    CALL spi_auditar('usuario_modificado', 'usuario', NEW.id_usuario, NEW.id_usuario,
                     JSON_OBJECT('estado', JSON_ARRAY(OLD.estado, NEW.estado), 'id_rol', JSON_ARRAY(OLD.id_rol, NEW.id_rol)), 'trigger');
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_usuario_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_usuario_bd BEFORE DELETE ON usuario FOR EACH ROW
CALL spi_control_borrado('usuario', OLD.id_usuario) $$

-- SESION / INTENTO / CÓDIGOS ------------------------------------------
DROP TRIGGER IF EXISTS trg_sesion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_sesion_bu BEFORE UPDATE ON sesion FOR EACH ROW
BEGIN
  IF NEW.token_hash <> OLD.token_hash OR NEW.id_usuario <> OLD.id_usuario OR NEW.creado_en <> OLD.creado_en THEN
    CALL spi_error(45004, 'Token, usuario y fecha de la sesión no se modifican');
  END IF;
  IF OLD.cerrada_en IS NOT NULL AND NOT (NEW.cerrada_en <=> OLD.cerrada_en) THEN
    CALL spi_error(45004, 'Una sesión cerrada no se reabre');
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_intento_acceso_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_intento_acceso_bu BEFORE UPDATE ON intento_acceso FOR EACH ROW
CALL spi_solo_insercion('intento_acceso') $$
DROP TRIGGER IF EXISTS trg_intento_acceso_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_intento_acceso_bd BEFORE DELETE ON intento_acceso FOR EACH ROW
BEGIN
  IF OLD.creado_en >= UTC_TIMESTAMP(3) - INTERVAL 12 MONTH THEN
    CALL spi_error(45005, 'Los intentos de acceso se conservan al menos 12 meses');
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_codigo_verificacion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_codigo_verificacion_bi BEFORE INSERT ON codigo_verificacion FOR EACH ROW
BEGIN
  SET NEW.correo_destino = fn_normalizar_correo(NEW.correo_destino);
  IF NEW.estado <> 'activo' OR NEW.intentos <> 0 OR NEW.usado_en IS NOT NULL THEN
    CALL spi_error(45006, 'Un código nace activo, sin intentos y sin usar');
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_codigo_verificacion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_codigo_verificacion_bu BEFORE UPDATE ON codigo_verificacion FOR EACH ROW
BEGIN
  IF NEW.codigo_hash <> OLD.codigo_hash OR NEW.correo_destino <> OLD.correo_destino OR NEW.proposito <> OLD.proposito
     OR NOT (NEW.id_usuario <=> OLD.id_usuario) OR NEW.creado_en <> OLD.creado_en THEN
    CALL spi_error(45004, 'El código, su destino y su fecha no se modifican');
  END IF;
  IF NEW.expira_en > OLD.expira_en THEN CALL spi_error(45004, 'La vigencia de un código no se puede extender'); END IF;
  IF NEW.intentos < OLD.intentos THEN CALL spi_error(45004, 'Los intentos de un código no disminuyen'); END IF;
  IF OLD.estado <> 'activo' AND NEW.estado <> OLD.estado THEN
    CALL spi_error(45004, CONCAT('Un código ', OLD.estado, ' no vuelve a cambiar de estado'));
  END IF;
  IF NEW.estado = 'usado' AND OLD.expira_en <= UTC_TIMESTAMP(3) THEN
    CALL spi_error(45012, 'El código está vencido');
  END IF;
  IF NEW.estado IN ('expirado','bloqueado','reemplazado') AND NEW.cerrado_en IS NULL THEN
    SET NEW.cerrado_en = UTC_TIMESTAMP(3);
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_codigo_verificacion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_codigo_verificacion_bd BEFORE DELETE ON codigo_verificacion FOR EACH ROW
BEGIN
  IF OLD.estado = 'activo' AND OLD.expira_en > UTC_TIMESTAMP(3) THEN CALL spi_error(45005, 'No se borra un código vigente'); END IF;
END $$

DROP TRIGGER IF EXISTS trg_historial_contrasena_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_historial_contrasena_bu BEFORE UPDATE ON historial_contrasena FOR EACH ROW
CALL spi_solo_insercion('historial_contrasena') $$
DROP TRIGGER IF EXISTS trg_historial_contrasena_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_historial_contrasena_bd BEFORE DELETE ON historial_contrasena FOR EACH ROW
CALL spi_control_borrado('historial_contrasena', OLD.id_historial) $$

DROP TRIGGER IF EXISTS trg_autenticacion_2fa_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_autenticacion_2fa_bu BEFORE UPDATE ON autenticacion_2fa FOR EACH ROW
BEGIN
  IF NEW.ultimo_paso_totp < OLD.ultimo_paso_totp AND NEW.verificado_en <=> OLD.verificado_en THEN
    CALL spi_error(45004, 'El paso TOTP no retrocede (evita reutilizar códigos)');
  END IF;
  IF NOT (NEW.metodo = OLD.metodo AND NEW.secreto_cifrado <=> OLD.secreto_cifrado AND NEW.activo = OLD.activo
          AND NEW.metodo_pendiente <=> OLD.metodo_pendiente AND NEW.secreto_pendiente_cifrado <=> OLD.secreto_pendiente_cifrado) THEN
    CALL spi_requiere_contexto('El segundo factor se configura con sp_configurar_2fa / sp_confirmar_2fa');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_autenticacion_2fa_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_autenticacion_2fa_bd BEFORE DELETE ON autenticacion_2fa FOR EACH ROW
CALL spi_control_borrado('autenticacion_2fa', OLD.id_usuario) $$

DROP TRIGGER IF EXISTS trg_codigo_respaldo_2fa_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_codigo_respaldo_2fa_bu BEFORE UPDATE ON codigo_respaldo_2fa FOR EACH ROW
BEGIN
  IF NEW.codigo_hash <> OLD.codigo_hash OR NEW.id_usuario <> OLD.id_usuario OR NEW.lote <> OLD.lote THEN
    CALL spi_error(45004, 'El código de respaldo no se modifica');
  END IF;
  IF OLD.usado_en IS NOT NULL AND NOT (NEW.usado_en <=> OLD.usado_en) THEN CALL spi_error(45013, 'El código de respaldo ya fue usado'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_codigo_respaldo_2fa_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_codigo_respaldo_2fa_bd BEFORE DELETE ON codigo_respaldo_2fa FOR EACH ROW
CALL spi_control_borrado('codigo_respaldo_2fa', OLD.id_codigo_respaldo) $$

DROP TRIGGER IF EXISTS trg_consentimiento_datos_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_consentimiento_datos_bi BEFORE INSERT ON consentimiento_datos FOR EACH ROW
SET NEW.correo = fn_normalizar_correo(NEW.correo) $$
DROP TRIGGER IF EXISTS trg_consentimiento_datos_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_consentimiento_datos_bu BEFORE UPDATE ON consentimiento_datos FOR EACH ROW
CALL spi_solo_insercion('consentimiento_datos') $$
DROP TRIGGER IF EXISTS trg_consentimiento_datos_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_consentimiento_datos_bd BEFORE DELETE ON consentimiento_datos FOR EACH ROW
CALL spi_control_borrado('consentimiento_datos', OLD.id_consentimiento) $$

DROP TRIGGER IF EXISTS trg_solicitud_arco_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_solicitud_arco_bi BEFORE INSERT ON solicitud_arco FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    CALL spi_siguiente_numero('ARCO', 6, v_num);
    SET NEW.numero = v_num;
  END IF;
  SET NEW.correo = fn_normalizar_correo(NEW.correo);
  SET NEW.numero_documento = UPPER(TRIM(NEW.numero_documento));
  IF NEW.estado <> 'recibida' THEN CALL spi_error(45006, 'Una solicitud ARCO nace en estado recibida'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_solicitud_arco_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_solicitud_arco_bu BEFORE UPDATE ON solicitud_arco FOR EACH ROW
BEGIN
  IF NEW.numero <> OLD.numero OR NEW.creado_en <> OLD.creado_en OR NEW.detalle <> OLD.detalle OR NEW.tipo <> OLD.tipo THEN
    CALL spi_error(45004, 'Número, tipo, detalle y fecha de la solicitud ARCO no se modifican');
  END IF;
  IF OLD.estado IN ('atendida','denegada') AND NEW.estado <> OLD.estado THEN
    CALL spi_error(45004, 'La solicitud ARCO ya fue cerrada');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_solicitud_arco_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_solicitud_arco_bd BEFORE DELETE ON solicitud_arco FOR EACH ROW
CALL spi_control_borrado('solicitud_arco', OLD.id_solicitud) $$

DROP TRIGGER IF EXISTS trg_auditoria_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_auditoria_bu BEFORE UPDATE ON auditoria FOR EACH ROW
CALL spi_solo_insercion('auditoria') $$
DROP TRIGGER IF EXISTS trg_auditoria_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_auditoria_bd BEFORE DELETE ON auditoria FOR EACH ROW
BEGIN
  -- Ni el DBA borra registros con menos de la retención mínima (>= 12 meses)
  IF OLD.creado_en >= UTC_TIMESTAMP(3) - INTERVAL GREATEST(COALESCE(fn_config_entero('auditoria_retencion_meses'), 12), 12) MONTH
     OR NOT fn_borrado_dba_autorizado() THEN
    CALL spi_error(45005, 'La auditoría es inmutable: solo el DBA archiva registros con más de 12 meses');
  END IF;
END $$

-- =====================================================================
-- SISTEMA
-- =====================================================================
DROP PROCEDURE IF EXISTS spi_validar_valor_config $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_valor_config(
  IN p_clave VARCHAR(60), IN p_valor VARCHAR(500), IN p_tipo VARCHAR(10), IN p_min DECIMAL(14,4), IN p_max DECIMAL(14,4), IN p_opciones VARCHAR(200))
NO SQL SQL SECURITY DEFINER
COMMENT 'Valida un valor de configuración por tipo, rango y opciones (error 45020)'
BEGIN
  DECLARE v_ok BOOLEAN DEFAULT 1;
  CASE p_tipo
    WHEN 'entero'   THEN SET v_ok = REGEXP_LIKE(p_valor, '^-?[0-9]{1,12}$', 'c');
    WHEN 'decimal'  THEN SET v_ok = REGEXP_LIKE(p_valor, '^-?[0-9]{1,10}([.][0-9]{1,4})?$', 'c');
    WHEN 'booleano' THEN SET v_ok = p_valor IN ('0','1');
    WHEN 'opcion'   THEN SET v_ok = FIND_IN_SET(p_valor, p_opciones) > 0;
    WHEN 'ruc'      THEN SET v_ok = fn_ruc_valido(p_valor);
    WHEN 'correo'   THEN SET v_ok = fn_correo_valido(p_valor);
    ELSE SET v_ok = CHAR_LENGTH(TRIM(p_valor)) > 0;
  END CASE;
  IF NOT v_ok THEN CALL spi_error(45020, CONCAT('Valor inválido para ', p_clave, ' (tipo ', p_tipo, ')')); END IF;
  IF p_tipo IN ('entero','decimal') THEN
    IF (p_min IS NOT NULL AND CAST(p_valor AS DECIMAL(20,4)) < p_min) OR (p_max IS NOT NULL AND CAST(p_valor AS DECIMAL(20,4)) > p_max) THEN
      CALL spi_error(45020, CONCAT('Valor fuera de rango para ', p_clave, ' [', COALESCE(p_min, '-∞'), ' .. ', COALESCE(p_max, '∞'), ']'));
    END IF;
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_configuracion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_configuracion_bi BEFORE INSERT ON configuracion FOR EACH ROW
BEGIN
  SET NEW.valor = TRIM(NEW.valor);
  CALL spi_validar_valor_config(NEW.clave, NEW.valor, NEW.tipo, NEW.valor_minimo, NEW.valor_maximo, NEW.opciones);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_configuracion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_configuracion_bu BEFORE UPDATE ON configuracion FOR EACH ROW
BEGIN
  IF NEW.clave <> OLD.clave THEN CALL spi_error(45004, 'La clave de configuración no se renombra'); END IF;
  SET NEW.valor = TRIM(NEW.valor);
  CALL spi_validar_valor_config(NEW.clave, NEW.valor, NEW.tipo, NEW.valor_minimo, NEW.valor_maximo, NEW.opciones);
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_configuracion_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_configuracion_au AFTER UPDATE ON configuracion FOR EACH ROW
BEGIN
  IF NEW.valor <> OLD.valor THEN
    CALL spi_auditar('configuracion_cambiada', 'configuracion', NULL, NULL,
                     JSON_OBJECT('clave', NEW.clave, 'antes', OLD.valor, 'despues', NEW.valor), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_configuracion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_configuracion_bd BEFORE DELETE ON configuracion FOR EACH ROW
CALL spi_control_borrado('configuracion', NULL) $$

DROP TRIGGER IF EXISTS trg_secuencia_documento_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_secuencia_documento_bu BEFORE UPDATE ON secuencia_documento FOR EACH ROW
BEGIN
  IF NEW.ultimo < OLD.ultimo OR NEW.prefijo <> OLD.prefijo OR NEW.anio <> OLD.anio THEN
    CALL spi_error(45004, 'Un correlativo no retrocede (evita duplicados)');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_secuencia_documento_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_secuencia_documento_bd BEFORE DELETE ON secuencia_documento FOR EACH ROW
CALL spi_control_borrado('secuencia_documento', NULL) $$

DROP TRIGGER IF EXISTS trg_catalogo_error_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_catalogo_error_bd BEFORE DELETE ON catalogo_error FOR EACH ROW
CALL spi_control_borrado('catalogo_error', OLD.codigo) $$

-- =====================================================================
-- CATÁLOGO
-- =====================================================================
DROP PROCEDURE IF EXISTS spi_validar_categoria_padre $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_validar_categoria_padre(IN p_id_categoria SMALLINT UNSIGNED, IN p_id_padre SMALLINT UNSIGNED)
READS SQL DATA SQL SECURITY DEFINER
COMMENT 'La categoría padre debe existir, estar activa y no formar un ciclo (A → B → A)'
BEGIN
  DECLARE v_actual SMALLINT UNSIGNED DEFAULT p_id_padre;
  DECLARE v_niveles INT DEFAULT 0;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_actual = NULL;
  IF NOT EXISTS (SELECT 1 FROM categoria WHERE id_categoria = p_id_padre AND activo = 1) THEN
    CALL spi_error(45032, 'La categoría padre no existe o está inhabilitada');
  END IF;
  WHILE v_actual IS NOT NULL AND v_niveles < 50 DO
    IF v_actual = p_id_categoria THEN CALL spi_error(45006, 'La jerarquía de categorías formaría un ciclo'); END IF;
    SELECT id_categoria_padre INTO v_actual FROM categoria WHERE id_categoria = v_actual;
    SET v_niveles = v_niveles + 1;
  END WHILE;
END $$

DROP TRIGGER IF EXISTS trg_categoria_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_categoria_bi BEFORE INSERT ON categoria FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  SET NEW.slug = LOWER(TRIM(NEW.slug));
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear una categoría inactiva'); END IF;
  IF NEW.id_categoria_padre IS NOT NULL THEN CALL spi_validar_categoria_padre(NULL, NEW.id_categoria_padre); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_categoria_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_categoria_bu BEFORE UPDATE ON categoria FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  SET NEW.slug = LOWER(TRIM(NEW.slug));
  IF NOT (NEW.id_categoria_padre <=> OLD.id_categoria_padre) AND NEW.id_categoria_padre IS NOT NULL THEN
    CALL spi_validar_categoria_padre(NEW.id_categoria, NEW.id_categoria_padre);
  END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar categorías (sp_inhabilitar_categoria)'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_categoria_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_categoria_bd BEFORE DELETE ON categoria FOR EACH ROW
CALL spi_control_borrado('categoria', OLD.id_categoria) $$

DROP TRIGGER IF EXISTS trg_producto_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_producto_bi BEFORE INSERT ON producto FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  SET NEW.slug = LOWER(TRIM(NEW.slug));
  IF NEW.estado = 'archivado' OR NEW.valoracion_promedio <> 0 OR NEW.total_resenas <> 0 THEN
    CALL spi_requiere_contexto('Un producto nace en borrador o activo y sin reseñas');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM categoria WHERE id_categoria = NEW.id_categoria AND activo = 1) THEN
    CALL spi_error(45032, 'La categoría está inhabilitada');
  END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_producto_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_producto_bu BEFORE UPDATE ON producto FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  SET NEW.slug = LOWER(TRIM(NEW.slug));
  IF NEW.estado <> OLD.estado AND (NEW.estado = 'archivado' OR OLD.estado = 'archivado') THEN
    CALL spi_requiere_contexto('Archivar/reactivar productos (sp_inhabilitar_producto)');
  END IF;
  IF NEW.valoracion_promedio <> OLD.valoracion_promedio OR NEW.total_resenas <> OLD.total_resenas THEN
    CALL spi_requiere_contexto('La valoración la calcula la BD a partir de las reseñas');
  END IF;
  IF NEW.id_categoria <> OLD.id_categoria AND NOT EXISTS (SELECT 1 FROM categoria WHERE id_categoria = NEW.id_categoria AND activo = 1) THEN
    CALL spi_error(45032, 'La categoría está inhabilitada');
  END IF;
  IF NEW.tipo_fabricacion <> OLD.tipo_fabricacion AND EXISTS (SELECT 1 FROM reserva_stock r JOIN variante_producto v ON v.id_variante = r.id_variante
                                                               WHERE v.id_producto = NEW.id_producto AND r.estado = 'activa') THEN
    CALL spi_error(45007, 'No se cambia el tipo de fabricación con reservas activas');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_producto_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_producto_au AFTER UPDATE ON producto FOR EACH ROW
BEGIN
  IF NEW.precio_base <> OLD.precio_base THEN
    CALL spi_auditar('precio_cambiado', 'producto', NEW.id_producto, NULL,
                     JSON_OBJECT('antes', OLD.precio_base, 'despues', NEW.precio_base), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_producto_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_producto_bd BEFORE DELETE ON producto FOR EACH ROW
CALL spi_control_borrado('producto', OLD.id_producto) $$

DROP TRIGGER IF EXISTS trg_variante_producto_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_variante_producto_bi BEFORE INSERT ON variante_producto FOR EACH ROW
BEGIN
  SET NEW.sku = UPPER(TRIM(NEW.sku));
  SET NEW.talla = NULLIF(TRIM(NEW.talla), '');
  SET NEW.color = NULLIF(TRIM(NEW.color), '');
  IF NEW.stock_actual <> 0 OR NEW.stock_reservado <> 0 THEN
    CALL spi_requiere_contexto('El stock inicial se registra con sp_ajustar_stock (queda en el kardex)');
  END IF;
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear una variante inactiva'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_variante_producto_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_variante_producto_bu BEFORE UPDATE ON variante_producto FOR EACH ROW
BEGIN
  SET NEW.sku = UPPER(TRIM(NEW.sku));
  SET NEW.talla = NULLIF(TRIM(NEW.talla), '');
  SET NEW.color = NULLIF(TRIM(NEW.color), '');
  IF NEW.id_producto <> OLD.id_producto THEN CALL spi_error(45004, 'Una variante no cambia de producto'); END IF;
  IF NEW.stock_actual <> OLD.stock_actual OR NEW.stock_reservado <> OLD.stock_reservado THEN
    CALL spi_requiere_contexto('El stock solo cambia con sp_ajustar_stock o por pedidos (kardex)');
  END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar variantes (sp_inhabilitar_variante)'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_variante_producto_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_variante_producto_au AFTER UPDATE ON variante_producto FOR EACH ROW
BEGIN
  DECLARE v_nombre VARCHAR(150);
  -- Alerta de stock bajo solo al cruzar el umbral (no en cada venta)
  IF OLD.stock_disponible > OLD.stock_minimo AND NEW.stock_disponible <= NEW.stock_minimo AND NEW.activo = 1 THEN
    SELECT nombre INTO v_nombre FROM producto WHERE id_producto = NEW.id_producto AND tipo_fabricacion = 'stock';
    IF v_nombre IS NOT NULL THEN
      CALL spi_notificar_admins('stock_bajo', CONCAT('Stock bajo: ', v_nombre, ' (', NEW.sku, ')'),
                                CONCAT('Disponible ', NEW.stock_disponible, ', mínimo ', NEW.stock_minimo), '/admin/inventario', NULL);
    END IF;
  END IF;
  IF NOT (NEW.precio <=> OLD.precio) THEN
    CALL spi_auditar('precio_cambiado', 'variante_producto', NEW.id_variante, NULL, JSON_OBJECT('antes', OLD.precio, 'despues', NEW.precio), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_variante_producto_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_variante_producto_bd BEFORE DELETE ON variante_producto FOR EACH ROW
CALL spi_control_borrado('variante_producto', OLD.id_variante) $$

DROP TRIGGER IF EXISTS trg_imagen_producto_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_imagen_producto_bi BEFORE INSERT ON imagen_producto FOR EACH ROW
BEGIN
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear una imagen inactiva'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_imagen_producto_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_imagen_producto_bu BEFORE UPDATE ON imagen_producto FOR EACH ROW
BEGIN
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar imágenes'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_imagen_producto_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_imagen_producto_bd BEFORE DELETE ON imagen_producto FOR EACH ROW
CALL spi_control_borrado('imagen_producto', OLD.id_imagen) $$

DROP TRIGGER IF EXISTS trg_precio_volumen_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_precio_volumen_bi BEFORE INSERT ON precio_volumen FOR EACH ROW
BEGIN
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear un tramo inactivo'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_precio_volumen_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_precio_volumen_bu BEFORE UPDATE ON precio_volumen FOR EACH ROW
BEGIN
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar tramos de precio'); END IF;
  IF NEW.id_producto <> OLD.id_producto THEN CALL spi_error(45004, 'Un tramo no cambia de producto'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_precio_volumen_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_precio_volumen_au AFTER UPDATE ON precio_volumen FOR EACH ROW
BEGIN
  IF NEW.precio_unitario <> OLD.precio_unitario OR NEW.cantidad_minima <> OLD.cantidad_minima THEN
    CALL spi_auditar('precio_volumen_cambiado', 'precio_volumen', NEW.id_precio_volumen, NULL,
                     JSON_OBJECT('antes', JSON_ARRAY(OLD.cantidad_minima, OLD.precio_unitario), 'despues', JSON_ARRAY(NEW.cantidad_minima, NEW.precio_unitario)), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_precio_volumen_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_precio_volumen_bd BEFORE DELETE ON precio_volumen FOR EACH ROW
CALL spi_control_borrado('precio_volumen', OLD.id_precio_volumen) $$

-- =====================================================================
-- INSUMOS, ENVÍO, DIRECCIONES
-- =====================================================================
DROP TRIGGER IF EXISTS trg_insumo_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_insumo_bi BEFORE INSERT ON insumo FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  IF NEW.stock_actual <> 0 THEN CALL spi_requiere_contexto('El stock inicial del insumo se registra con sp_ajustar_insumo'); END IF;
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear un insumo inactivo'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_insumo_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_insumo_bu BEFORE UPDATE ON insumo FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  IF NEW.stock_actual <> OLD.stock_actual THEN CALL spi_requiere_contexto('El stock de insumos solo cambia con sp_ajustar_insumo'); END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar insumos'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_insumo_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_insumo_bd BEFORE DELETE ON insumo FOR EACH ROW
CALL spi_control_borrado('insumo', OLD.id_insumo) $$

DROP TRIGGER IF EXISTS trg_receta_producto_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_receta_producto_bi BEFORE INSERT ON receta_producto FOR EACH ROW
BEGIN
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_receta_producto_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_receta_producto_bu BEFORE UPDATE ON receta_producto FOR EACH ROW
BEGIN
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_receta_producto_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_receta_producto_bd BEFORE DELETE ON receta_producto FOR EACH ROW
CALL spi_control_borrado('receta_producto', OLD.id_producto) $$

DROP TRIGGER IF EXISTS trg_movimiento_insumo_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_insumo_bi BEFORE INSERT ON movimiento_insumo FOR EACH ROW
CALL spi_requiere_contexto('El kardex de insumos lo escribe sp_ajustar_insumo') $$
DROP TRIGGER IF EXISTS trg_movimiento_insumo_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_insumo_bu BEFORE UPDATE ON movimiento_insumo FOR EACH ROW
CALL spi_solo_insercion('movimiento_insumo') $$
DROP TRIGGER IF EXISTS trg_movimiento_insumo_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_insumo_bd BEFORE DELETE ON movimiento_insumo FOR EACH ROW
CALL spi_control_borrado('movimiento_insumo', OLD.id_movimiento) $$

DROP TRIGGER IF EXISTS trg_zona_envio_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_zona_envio_bi BEFORE INSERT ON zona_envio FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear una zona inactiva'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_zona_envio_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_zona_envio_bu BEFORE UPDATE ON zona_envio FOR EACH ROW
BEGIN
  SET NEW.nombre = TRIM(NEW.nombre);
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar zonas de envío'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_zona_envio_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_zona_envio_au AFTER UPDATE ON zona_envio FOR EACH ROW
BEGIN
  IF NEW.costo <> OLD.costo THEN
    CALL spi_auditar('costo_envio_cambiado', 'zona_envio', NEW.id_zona, NULL, JSON_OBJECT('antes', OLD.costo, 'despues', NEW.costo), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_zona_envio_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_zona_envio_bd BEFORE DELETE ON zona_envio FOR EACH ROW
CALL spi_control_borrado('zona_envio', OLD.id_zona) $$

DROP TRIGGER IF EXISTS trg_direccion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_direccion_bi BEFORE INSERT ON direccion FOR EACH ROW
BEGIN
  SET NEW.telefono = fn_normalizar_telefono(NEW.telefono);
  SET NEW.alias = TRIM(NEW.alias);
  SET NEW.direccion = TRIM(NEW.direccion);
  IF fn_actor() IS NOT NULL AND fn_actor() <> NEW.id_usuario AND NOT fn_es_admin(fn_actor()) THEN
    CALL spi_error(45023, 'No puede registrar direcciones para otro usuario');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM zona_envio WHERE id_zona = NEW.id_zona AND activo = 1) THEN
    CALL spi_error(45028, 'La zona de envío no existe o está inactiva');
  END IF;
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear una dirección inactiva'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_direccion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_direccion_bu BEFORE UPDATE ON direccion FOR EACH ROW
BEGIN
  SET NEW.telefono = fn_normalizar_telefono(NEW.telefono);
  IF NEW.id_usuario <> OLD.id_usuario THEN CALL spi_error(45004, 'Una dirección no cambia de dueño'); END IF;
  IF fn_actor() IS NOT NULL AND fn_actor() <> OLD.id_usuario AND NOT fn_es_admin(fn_actor()) THEN
    CALL spi_error(45023, 'No puede modificar direcciones de otro usuario');
  END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Eliminar/reactivar direcciones (sp_inhabilitar_direccion)'); END IF;
  IF NEW.id_zona <> OLD.id_zona AND NOT EXISTS (SELECT 1 FROM zona_envio WHERE id_zona = NEW.id_zona AND activo = 1) THEN
    CALL spi_error(45028, 'La zona de envío no existe o está inactiva');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_direccion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_direccion_bd BEFORE DELETE ON direccion FOR EACH ROW
CALL spi_control_borrado('direccion', OLD.id_direccion) $$

DROP TRIGGER IF EXISTS trg_courier_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_courier_bi BEFORE INSERT ON courier FOR EACH ROW
BEGIN
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear un courier inactivo'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_courier_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_courier_bu BEFORE UPDATE ON courier FOR EACH ROW
BEGIN
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar couriers'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_courier_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_courier_bd BEFORE DELETE ON courier FOR EACH ROW
CALL spi_control_borrado('courier', OLD.id_courier) $$

-- =====================================================================
-- COTIZACIONES
-- =====================================================================
DROP TRIGGER IF EXISTS trg_cotizacion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cotizacion_bi BEFORE INSERT ON cotizacion FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    CALL spi_siguiente_numero('CT', 4, v_num);
    SET NEW.numero = v_num;
  END IF;
  IF NEW.estado <> 'solicitada' THEN CALL spi_error(45018, 'Una cotización nace en estado solicitada'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_cotizacion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cotizacion_bu BEFORE UPDATE ON cotizacion FOR EACH ROW
BEGIN
  IF NEW.numero <> OLD.numero OR NEW.id_usuario <> OLD.id_usuario OR NEW.creado_en <> OLD.creado_en OR NEW.origen <> OLD.origen THEN
    CALL spi_error(45004, 'Número, cliente, origen y fecha de la cotización no se modifican');
  END IF;
  IF NEW.estado <> OLD.estado AND NOT EXISTS (SELECT 1 FROM transicion_estado_cotizacion
                                               WHERE estado_origen = OLD.estado AND estado_destino = NEW.estado) THEN
    CALL spi_error(45018, CONCAT('Cambio de estado de cotización no permitido: ', OLD.estado, ' -> ', NEW.estado));
  END IF;
  IF OLD.estado IN ('aceptada','convertida','rechazada','vencida') AND
     NOT (NEW.total <=> OLD.total AND NEW.subtotal <=> OLD.subtotal AND NEW.adelanto_porcentaje <=> OLD.adelanto_porcentaje
          AND NEW.vigencia_hasta <=> OLD.vigencia_hasta AND NEW.costo_envio <=> OLD.costo_envio) THEN
    CALL spi_error(45004, 'Una cotización cerrada no cambia sus montos');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_cotizacion_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cotizacion_au AFTER UPDATE ON cotizacion FOR EACH ROW
BEGIN
  IF NEW.estado <> OLD.estado THEN
    CALL spi_auditar('cotizacion_estado', 'cotizacion', NEW.id_cotizacion, NEW.id_usuario,
                     JSON_OBJECT('numero', NEW.numero, 'de', OLD.estado, 'a', NEW.estado), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_cotizacion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cotizacion_bd BEFORE DELETE ON cotizacion FOR EACH ROW
CALL spi_control_borrado('cotizacion', OLD.id_cotizacion) $$

DROP TRIGGER IF EXISTS trg_item_cotizacion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_cotizacion_bi BEFORE INSERT ON item_cotizacion FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = NEW.id_cotizacion AND estado IN ('solicitada','en_revision')) THEN
    CALL spi_error(45018, 'Solo se agregan ítems a una cotización solicitada o en revisión');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_item_cotizacion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_cotizacion_bu BEFORE UPDATE ON item_cotizacion FOR EACH ROW
BEGIN
  IF NEW.id_cotizacion <> OLD.id_cotizacion THEN CALL spi_error(45004, 'Un ítem no cambia de cotización'); END IF;
  IF NOT EXISTS (SELECT 1 FROM cotizacion WHERE id_cotizacion = NEW.id_cotizacion AND estado IN ('solicitada','en_revision')) THEN
    CALL spi_error(45018, 'Los ítems solo se editan mientras la cotización está solicitada o en revisión');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_item_cotizacion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_cotizacion_bd BEFORE DELETE ON item_cotizacion FOR EACH ROW
CALL spi_control_borrado('item_cotizacion', OLD.id_item_cotizacion) $$

DROP TRIGGER IF EXISTS trg_transicion_estado_cotizacion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_transicion_estado_cotizacion_bd BEFORE DELETE ON transicion_estado_cotizacion FOR EACH ROW
CALL spi_control_borrado('transicion_estado_cotizacion', NULL) $$

-- =====================================================================
-- PEDIDOS
-- =====================================================================
DROP TRIGGER IF EXISTS trg_estado_pedido_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_estado_pedido_bd BEFORE DELETE ON estado_pedido FOR EACH ROW
CALL spi_control_borrado('estado_pedido', NULL) $$
DROP TRIGGER IF EXISTS trg_transicion_estado_pedido_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_transicion_estado_pedido_bd BEFORE DELETE ON transicion_estado_pedido FOR EACH ROW
CALL spi_control_borrado('transicion_estado_pedido', NULL) $$

DROP TRIGGER IF EXISTS trg_pedido_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pedido_bi BEFORE INSERT ON pedido FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  DECLARE v_costo DECIMAL(8,2) DEFAULT NULL;
  DECLARE v_dias INT;
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    CALL spi_siguiente_numero(IF(NEW.tipo_venta = 'mayor', 'BW-MAY', 'BW'), 6, v_num);
    SET NEW.numero = v_num;
  END IF;
  IF NEW.estado <> 'pendiente_pago' OR NEW.estado_pago <> 'pendiente' OR NEW.monto_pagado <> 0 OR NEW.monto_reembolsado <> 0 THEN
    CALL spi_error(45006, 'Un pedido nace pendiente de pago y sin pagos');
  END IF;
  SET NEW.entrega_telefono = fn_normalizar_telefono(NEW.entrega_telefono);
  SET NEW.facturacion_num_doc = NULLIF(UPPER(TRIM(NEW.facturacion_num_doc)), '');
  IF NOT fn_documento_valido(NEW.facturacion_tipo_doc, NEW.facturacion_num_doc) THEN
    CALL spi_error(45006, 'Documento de facturación inválido (RUC con dígito verificador)');
  END IF;
  -- Red de seguridad: fuera de los procedimientos, el envío sale de la zona (nunca del navegador)
  IF NOT fn_contexto_interno() THEN
    IF NEW.tipo_entrega = 'domicilio' THEN
      SELECT costo INTO v_costo FROM zona_envio WHERE id_zona = NEW.id_zona AND activo = 1;
      IF v_costo IS NULL THEN CALL spi_error(45028, 'Zona de envío inválida o inactiva'); END IF;
      SET NEW.costo_envio = v_costo;
    ELSE
      SET NEW.costo_envio = 0;
    END IF;
    SET NEW.total = NEW.subtotal - NEW.descuento + NEW.costo_envio;
  END IF;
  IF NEW.tipo_venta = 'mayor' THEN
    SET v_dias = fn_config_entero('dias_minimos_mayor');
    IF NEW.fecha_entrega_solicitada IS NULL OR NEW.fecha_entrega_solicitada < fn_hoy_lima() + INTERVAL v_dias DAY THEN
      CALL spi_error(45009, CONCAT('Los pedidos al por mayor requieren al menos ', v_dias, ' días de anticipación'));
    END IF;
  END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$

DROP TRIGGER IF EXISTS trg_pedido_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pedido_bu BEFORE UPDATE ON pedido FOR EACH ROW
BEGIN
  DECLARE v_aplicable VARCHAR(10) DEFAULT NULL;
  DECLARE v_saldo_cero BOOLEAN;
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_aplicable = NULL;
  IF NEW.numero <> OLD.numero OR NEW.id_usuario <> OLD.id_usuario OR NEW.creado_en <> OLD.creado_en OR NEW.canal <> OLD.canal
     OR NOT (NEW.id_cotizacion <=> OLD.id_cotizacion) OR NOT (NEW.id_pedido_origen <=> OLD.id_pedido_origen) THEN
    CALL spi_error(45004, 'Número, cliente, canal, origen y fecha del pedido no se modifican');
  END IF;
  IF NEW.id_pedido_origen = NEW.id_pedido THEN CALL spi_error(45006, 'Un pedido no es complementario de sí mismo'); END IF;

  -- Estado: solo por procedimiento y solo por transiciones permitidas
  IF NEW.estado <> OLD.estado THEN
    CALL spi_requiere_contexto('El estado se cambia con sp_cambiar_estado_pedido');
    SELECT tipo_entrega_aplicable, requiere_saldo_cero INTO v_aplicable, v_saldo_cero
      FROM transicion_estado_pedido WHERE estado_origen = OLD.estado AND estado_destino = NEW.estado;
    IF v_aplicable IS NULL OR (v_aplicable <> 'ambos' AND v_aplicable <> NEW.tipo_entrega) THEN
      CALL spi_error(45002, CONCAT('Cambio de estado no permitido: ', OLD.estado, ' -> ', NEW.estado));
    END IF;
    IF v_saldo_cero AND fn_config_entero('bloquear_envio_con_saldo') = 1 AND NEW.saldo > 0 THEN
      CALL spi_error(45025, CONCAT('Saldo pendiente S/ ', NEW.saldo, ': no puede pasar a ', NEW.estado));
    END IF;
    IF NEW.estado = 'cancelado' AND NEW.cancelado_en IS NULL THEN SET NEW.cancelado_en = UTC_TIMESTAMP(3); END IF;
  END IF;

  -- Montos de pago: siempre derivados de los pagos
  IF NEW.monto_pagado <> OLD.monto_pagado OR NEW.monto_reembolsado <> OLD.monto_reembolsado OR NEW.estado_pago <> OLD.estado_pago
     OR NEW.monto_devuelto <> OLD.monto_devuelto THEN
    CALL spi_requiere_contexto('monto_pagado, monto_devuelto y estado_pago se derivan de pagos y devoluciones');
  END IF;
  IF NOT (NEW.id_zona <=> OLD.id_zona) THEN CALL spi_requiere_contexto('La zona de envío define el costo: no se cambia a mano'); END IF;
  IF NEW.monto_ajustes <> OLD.monto_ajustes THEN
    CALL spi_requiere_contexto('monto_ajustes se deriva de las notas de crédito y compensaciones');
  END IF;
  -- Fechas del ciclo de vida, plazo de reserva, datos de entrega y de facturación: solo los procedimientos
  IF NOT (NEW.expira_en <=> OLD.expira_en AND NEW.confirmado_en <=> OLD.confirmado_en AND NEW.entregado_en <=> OLD.entregado_en
          AND NEW.cancelado_en <=> OLD.cancelado_en AND NEW.cancelado_por <=> OLD.cancelado_por
          AND NEW.motivo_cancelacion <=> OLD.motivo_cancelacion AND NEW.fecha_entrega_solicitada <=> OLD.fecha_entrega_solicitada
          AND NEW.comprobante_solicitado = OLD.comprobante_solicitado AND NEW.facturacion_tipo_doc <=> OLD.facturacion_tipo_doc
          AND NEW.facturacion_num_doc <=> OLD.facturacion_num_doc AND NEW.facturacion_nombre <=> OLD.facturacion_nombre
          AND NEW.facturacion_direccion <=> OLD.facturacion_direccion AND NEW.id_direccion <=> OLD.id_direccion
          AND NEW.entrega_nombre <=> OLD.entrega_nombre AND NEW.entrega_telefono <=> OLD.entrega_telefono
          AND NEW.entrega_direccion <=> OLD.entrega_direccion AND NEW.entrega_referencia <=> OLD.entrega_referencia
          AND NEW.entrega_distrito <=> OLD.entrega_distrito AND NEW.entrega_provincia <=> OLD.entrega_provincia
          AND NEW.entrega_departamento <=> OLD.entrega_departamento AND NEW.entrega_ubigeo <=> OLD.entrega_ubigeo
          AND NEW.notas <=> OLD.notas AND NEW.moneda = OLD.moneda) THEN
    CALL spi_requiere_contexto('Fechas, plazo, entrega y facturación del pedido (use sp_corregir_facturacion_pedido para la facturación)');
  END IF;

  -- Totales, ítems, modalidad y tipo de venta: solo con el pedido pendiente de pago
  IF NOT (NEW.subtotal = OLD.subtotal AND NEW.total = OLD.total AND NEW.costo_envio = OLD.costo_envio AND NEW.descuento = OLD.descuento
          AND NEW.tipo_venta = OLD.tipo_venta AND NEW.modalidad_pago = OLD.modalidad_pago
          AND NEW.adelanto_porcentaje <=> OLD.adelanto_porcentaje AND NEW.tipo_entrega = OLD.tipo_entrega) THEN
    IF OLD.estado <> 'pendiente_pago' THEN CALL spi_error(45007, 'Los montos y la modalidad no cambian después de confirmar el pedido'); END IF;
    IF (NEW.modalidad_pago <> OLD.modalidad_pago OR NOT (NEW.adelanto_porcentaje <=> OLD.adelanto_porcentaje))
       AND EXISTS (SELECT 1 FROM pago WHERE id_pedido = NEW.id_pedido AND estado IN ('en_revision','confirmado','reembolsado')) THEN
      CALL spi_error(45007, 'La modalidad no cambia si ya hay pagos registrados');
    END IF;
    IF NEW.costo_envio <> OLD.costo_envio OR NEW.tipo_entrega <> OLD.tipo_entrega OR NEW.subtotal <> OLD.subtotal THEN
      CALL spi_requiere_contexto('Totales y envío se recalculan desde los ítems y la zona');
    END IF;
  END IF;
  IF NOT (NEW.entrega_direccion <=> OLD.entrega_direccion AND NEW.entrega_nombre <=> OLD.entrega_nombre
          AND NEW.entrega_telefono <=> OLD.entrega_telefono AND NEW.id_zona <=> OLD.id_zona)
     AND OLD.estado IN ('enviado','entregado','cancelado','devuelto') THEN
    CALL spi_error(45004, 'Los datos de entrega no cambian después del envío');
  END IF;
  SET NEW.entrega_telefono = fn_normalizar_telefono(NEW.entrega_telefono);
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$

DROP TRIGGER IF EXISTS trg_pedido_ai $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pedido_ai AFTER INSERT ON pedido FOR EACH ROW
BEGIN
  INSERT INTO historial_estado_pedido (id_pedido, estado_anterior, estado_nuevo, id_usuario, comentario)
  VALUES (NEW.id_pedido, NULL, NEW.estado, COALESCE(fn_actor(), NEW.id_usuario), 'Pedido creado');
  CALL spi_auditar('pedido_creado', 'pedido', NEW.id_pedido, NEW.id_usuario,
                   JSON_OBJECT('numero', NEW.numero, 'tipo_venta', NEW.tipo_venta, 'canal', NEW.canal), 'trigger');
END $$

DROP TRIGGER IF EXISTS trg_pedido_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pedido_au AFTER UPDATE ON pedido FOR EACH ROW
BEGIN
  DECLARE v_notifica BOOLEAN DEFAULT 0;
  DECLARE v_nombre VARCHAR(40);
  DECLARE v_correo VARCHAR(254);
  IF NEW.estado <> OLD.estado THEN
    INSERT INTO historial_estado_pedido (id_pedido, estado_anterior, estado_nuevo, id_usuario, comentario)
    VALUES (NEW.id_pedido, OLD.estado, NEW.estado, fn_actor(), LEFT(COALESCE(@wanka_comentario_estado, NEW.motivo_cancelacion), 200));
    CALL spi_auditar('pedido_estado', 'pedido', NEW.id_pedido, NEW.id_usuario,
                     JSON_OBJECT('numero', NEW.numero, 'de', OLD.estado, 'a', NEW.estado), 'trigger');
    SELECT notifica_cliente, nombre INTO v_notifica, v_nombre FROM estado_pedido WHERE codigo = NEW.estado;
    IF v_notifica THEN
      SELECT correo INTO v_correo FROM usuario WHERE id_usuario = NEW.id_usuario;
      CALL spi_encolar_correo(NEW.id_usuario, v_correo, CONCAT('pedido_', NEW.estado),
                              JSON_OBJECT('numero', NEW.numero, 'estado', v_nombre, 'total', NEW.total, 'saldo', NEW.saldo), 4);
      CALL spi_notificar(NEW.id_usuario, CONCAT('pedido_', NEW.estado), CONCAT('Tu pedido ', NEW.numero, ': ', v_nombre),
                         NULL, CONCAT('/mi-cuenta/pedidos/', NEW.numero), NEW.id_pedido);
    END IF;
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_pedido_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pedido_bd BEFORE DELETE ON pedido FOR EACH ROW
CALL spi_control_borrado('pedido', OLD.id_pedido) $$

DROP TRIGGER IF EXISTS trg_item_pedido_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_pedido_bi BEFORE INSERT ON item_pedido FOR EACH ROW
BEGIN
  CALL spi_requiere_contexto('Los ítems se agregan con sp_crear_pedido / sp_agregar_item (precio desde la BD)');
  IF NOT EXISTS (SELECT 1 FROM pedido WHERE id_pedido = NEW.id_pedido AND estado = 'pendiente_pago') THEN
    CALL spi_error(45007, 'Los productos solo se agregan mientras el pedido está pendiente de pago');
  END IF;
  IF NEW.estado <> 'vigente' OR NEW.cantidad_devuelta <> 0 THEN CALL spi_error(45006, 'Un ítem nace vigente y sin devoluciones'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_item_pedido_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_pedido_bu BEFORE UPDATE ON item_pedido FOR EACH ROW
BEGIN
  IF NOT (NEW.id_pedido = OLD.id_pedido AND NEW.id_variante <=> OLD.id_variante AND NEW.cantidad = OLD.cantidad
          AND NEW.precio_unitario = OLD.precio_unitario AND NEW.nombre_producto = OLD.nombre_producto AND NEW.sku <=> OLD.sku
          AND NEW.talla <=> OLD.talla AND NEW.color <=> OLD.color AND NEW.personalizacion <=> OLD.personalizacion
          AND NEW.tipo_fabricacion = OLD.tipo_fabricacion AND NEW.origen_precio = OLD.origen_precio) THEN
    CALL spi_error(45004, 'La copia del ítem (producto, cantidad, precio) no se modifica');
  END IF;
  IF NEW.cantidad_devuelta <> OLD.cantidad_devuelta THEN
    CALL spi_requiere_contexto('Las devoluciones se registran con sp_devolver_pedido');
    IF NEW.cantidad_devuelta < OLD.cantidad_devuelta THEN CALL spi_error(45019, 'Las unidades devueltas no disminuyen'); END IF;
  END IF;
  IF NEW.estado <> OLD.estado THEN
    CALL spi_requiere_contexto('Las líneas se retiran con sp_quitar_item');
    IF OLD.estado = 'retirado' THEN CALL spi_error(45004, 'Una línea retirada no se reactiva: agréguela de nuevo'); END IF;
    IF NOT EXISTS (SELECT 1 FROM pedido WHERE id_pedido = NEW.id_pedido AND estado = 'pendiente_pago') THEN
      CALL spi_error(45007, 'Las líneas solo se retiran con el pedido pendiente de pago');
    END IF;
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_item_pedido_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_pedido_bd BEFORE DELETE ON item_pedido FOR EACH ROW
CALL spi_control_borrado('item_pedido', OLD.id_item_pedido) $$

DROP TRIGGER IF EXISTS trg_historial_estado_pedido_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_historial_estado_pedido_bu BEFORE UPDATE ON historial_estado_pedido FOR EACH ROW
CALL spi_solo_insercion('historial_estado_pedido') $$
DROP TRIGGER IF EXISTS trg_historial_estado_pedido_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_historial_estado_pedido_bd BEFORE DELETE ON historial_estado_pedido FOR EACH ROW
CALL spi_control_borrado('historial_estado_pedido', OLD.id_historial) $$

-- Devoluciones, reservas y kardex
DROP TRIGGER IF EXISTS trg_devolucion_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_bi BEFORE INSERT ON devolucion FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  CALL spi_requiere_contexto('Las devoluciones se registran con sp_devolver_pedido');
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    CALL spi_siguiente_numero('DV', 6, v_num);
    SET NEW.numero = v_num;
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_devolucion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_bu BEFORE UPDATE ON devolucion FOR EACH ROW
CALL spi_solo_insercion('devolucion') $$
DROP TRIGGER IF EXISTS trg_devolucion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_bd BEFORE DELETE ON devolucion FOR EACH ROW
CALL spi_control_borrado('devolucion', OLD.id_devolucion) $$
DROP TRIGGER IF EXISTS trg_devolucion_item_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_item_bi BEFORE INSERT ON devolucion_item FOR EACH ROW
CALL spi_requiere_contexto('Las devoluciones se registran con sp_devolver_pedido') $$
DROP TRIGGER IF EXISTS trg_devolucion_item_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_item_bu BEFORE UPDATE ON devolucion_item FOR EACH ROW
CALL spi_solo_insercion('devolucion_item') $$
DROP TRIGGER IF EXISTS trg_devolucion_item_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_devolucion_item_bd BEFORE DELETE ON devolucion_item FOR EACH ROW
CALL spi_control_borrado('devolucion_item', OLD.id_devolucion_item) $$

DROP TRIGGER IF EXISTS trg_reserva_stock_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reserva_stock_bi BEFORE INSERT ON reserva_stock FOR EACH ROW
CALL spi_requiere_contexto('Las reservas las crea la BD al registrar el pedido') $$
DROP TRIGGER IF EXISTS trg_reserva_stock_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reserva_stock_bu BEFORE UPDATE ON reserva_stock FOR EACH ROW
BEGIN
  IF NOT (NEW.id_pedido = OLD.id_pedido AND NEW.id_item_pedido = OLD.id_item_pedido AND NEW.id_variante = OLD.id_variante
          AND NEW.cantidad = OLD.cantidad AND NEW.creado_en = OLD.creado_en) THEN
    CALL spi_error(45004, 'La reserva no se modifica');
  END IF;
  IF NEW.estado <> OLD.estado AND OLD.estado <> 'activa' THEN CALL spi_error(45004, 'Una reserva cerrada no cambia'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_reserva_stock_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reserva_stock_bd BEFORE DELETE ON reserva_stock FOR EACH ROW
CALL spi_control_borrado('reserva_stock', OLD.id_reserva) $$

DROP TRIGGER IF EXISTS trg_movimiento_stock_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_stock_bi BEFORE INSERT ON movimiento_stock FOR EACH ROW
CALL spi_requiere_contexto('El kardex lo escribe la BD (sp_ajustar_stock y flujos de pedido)') $$
DROP TRIGGER IF EXISTS trg_movimiento_stock_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_stock_bu BEFORE UPDATE ON movimiento_stock FOR EACH ROW
CALL spi_solo_insercion('movimiento_stock') $$
DROP TRIGGER IF EXISTS trg_movimiento_stock_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_movimiento_stock_bd BEFORE DELETE ON movimiento_stock FOR EACH ROW
CALL spi_control_borrado('movimiento_stock', OLD.id_movimiento) $$

-- Carrito
DROP TRIGGER IF EXISTS trg_carrito_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_carrito_bu BEFORE UPDATE ON carrito FOR EACH ROW
BEGIN
  IF NEW.id_usuario <> OLD.id_usuario THEN CALL spi_error(45004, 'El carrito no cambia de dueño'); END IF;
  IF OLD.estado = 'convertido' AND NEW.estado <> OLD.estado THEN CALL spi_error(45004, 'Un carrito convertido en pedido no cambia'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_carrito_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_carrito_bd BEFORE DELETE ON carrito FOR EACH ROW
CALL spi_control_borrado('carrito', OLD.id_carrito) $$
DROP TRIGGER IF EXISTS trg_item_carrito_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_carrito_bi BEFORE INSERT ON item_carrito FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM carrito WHERE id_carrito = NEW.id_carrito AND estado = 'activo') THEN
    CALL spi_error(45007, 'Solo se agregan productos a un carrito activo');
  END IF;
  SET NEW.personalizacion = NULLIF(TRIM(NEW.personalizacion), '');
END $$
DROP TRIGGER IF EXISTS trg_item_carrito_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_item_carrito_bu BEFORE UPDATE ON item_carrito FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM carrito WHERE id_carrito = NEW.id_carrito AND estado = 'activo') THEN
    CALL spi_error(45007, 'Solo se modifica un carrito activo');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$

-- Envíos
DROP TRIGGER IF EXISTS trg_envio_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_envio_bi BEFORE INSERT ON envio FOR EACH ROW
BEGIN
  SET NEW.numero_guia = NULLIF(TRIM(NEW.numero_guia), '');
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_envio_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_envio_bu BEFORE UPDATE ON envio FOR EACH ROW
BEGIN
  IF NEW.id_pedido <> OLD.id_pedido THEN CALL spi_error(45004, 'Un envío no cambia de pedido'); END IF;
  IF NOT (NEW.estado = OLD.estado AND NEW.despachado_en <=> OLD.despachado_en AND NEW.entregado_en <=> OLD.entregado_en) THEN
    CALL spi_requiere_contexto('El estado del envío cambia con sp_registrar_seguimiento_envio');
  END IF;
  SET NEW.numero_guia = NULLIF(TRIM(NEW.numero_guia), '');
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_envio_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_envio_bd BEFORE DELETE ON envio FOR EACH ROW
CALL spi_control_borrado('envio', OLD.id_envio) $$
DROP TRIGGER IF EXISTS trg_seguimiento_envio_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_seguimiento_envio_bu BEFORE UPDATE ON seguimiento_envio FOR EACH ROW
CALL spi_solo_insercion('seguimiento_envio') $$
DROP TRIGGER IF EXISTS trg_seguimiento_envio_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_seguimiento_envio_bd BEFORE DELETE ON seguimiento_envio FOR EACH ROW
CALL spi_control_borrado('seguimiento_envio', OLD.id_seguimiento) $$

-- =====================================================================
-- PAGOS Y REEMBOLSOS
-- =====================================================================
DROP TRIGGER IF EXISTS trg_metodo_pago_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_metodo_pago_bu BEFORE UPDATE ON metodo_pago FOR EACH ROW
BEGIN
  IF NEW.codigo <> OLD.codigo OR NEW.tipo <> OLD.tipo THEN CALL spi_error(45004, 'Código y tipo del método no se modifican'); END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar métodos de pago'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_metodo_pago_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_metodo_pago_bd BEFORE DELETE ON metodo_pago FOR EACH ROW
CALL spi_control_borrado('metodo_pago', NULL) $$

DROP TRIGGER IF EXISTS trg_transicion_estado_pago_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_transicion_estado_pago_bd BEFORE DELETE ON transicion_estado_pago FOR EACH ROW
CALL spi_control_borrado('transicion_estado_pago', NULL) $$

DROP TRIGGER IF EXISTS trg_pago_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pago_bi BEFORE INSERT ON pago FOR EACH ROW
BEGIN
  DECLARE v_moneda CHAR(3);
  DECLARE v_tipo VARCHAR(10);
  DECLARE v_req BOOLEAN;
  CALL spi_requiere_contexto('Los pagos se registran con sp_registrar_pago');
  SELECT moneda INTO v_moneda FROM pedido WHERE id_pedido = NEW.id_pedido;
  IF NEW.moneda <> v_moneda THEN CALL spi_error(45017, 'El pago debe estar en la moneda del pedido'); END IF;
  SELECT tipo, requiere_comprobante INTO v_tipo, v_req FROM metodo_pago WHERE codigo = NEW.metodo AND activo = 1;
  IF v_tipo IS NULL THEN CALL spi_error(45017, 'Método de pago inexistente o inactivo'); END IF;
  IF NEW.estado NOT IN ('pendiente','en_revision') OR NEW.monto_reembolsado <> 0 THEN
    CALL spi_error(45017, 'Un pago nace pendiente o en revisión');
  END IF;
  IF v_req AND NEW.voucher_url IS NULL AND NEW.referencia_externa IS NULL THEN
    CALL spi_error(45017, 'Yape, Plin y transferencia exigen voucher o número de operación');
  END IF;
  IF fn_contiene_datos_tarjeta(NEW.datos_pasarela) THEN CALL spi_error(45031, 'Prohibido guardar datos de tarjeta'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$

DROP TRIGGER IF EXISTS trg_pago_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pago_bu BEFORE UPDATE ON pago FOR EACH ROW
BEGIN
  DECLARE v_tipo VARCHAR(10);
  IF NOT (NEW.id_pedido = OLD.id_pedido AND NEW.metodo = OLD.metodo AND NEW.tipo = OLD.tipo AND NEW.monto = OLD.monto
          AND NEW.moneda = OLD.moneda AND NEW.idempotency_key = OLD.idempotency_key AND NEW.creado_en = OLD.creado_en) THEN
    CALL spi_error(45004, 'Pedido, método, tipo, monto y clave del pago no se modifican');
  END IF;
  IF OLD.estado IN ('confirmado','reembolsado') AND NOT (
         NEW.voucher_url <=> OLD.voucher_url AND NEW.referencia_externa <=> OLD.referencia_externa
     AND NEW.datos_pasarela <=> OLD.datos_pasarela AND NEW.aplicado_al_pedido = OLD.aplicado_al_pedido
     AND NEW.validado_por <=> OLD.validado_por AND NEW.confirmado_en <=> OLD.confirmado_en
     AND NEW.monto_cobro <=> OLD.monto_cobro AND NEW.moneda_cobro <=> OLD.moneda_cobro) THEN
    CALL spi_error(45004, 'Un pago confirmado no se modifica: se reembolsa');
  END IF;
  IF NEW.estado <> OLD.estado THEN
    CALL spi_requiere_contexto('El estado del pago cambia con sp_confirmar_pago_manual / sp_rechazar_pago / webhook');
    IF NOT EXISTS (SELECT 1 FROM transicion_estado_pago WHERE estado_origen = OLD.estado AND estado_destino = NEW.estado) THEN
      CALL spi_error(45002, CONCAT('Cambio de estado de pago no permitido: ', OLD.estado, ' -> ', NEW.estado));
    END IF;
    IF NEW.estado = 'confirmado' THEN
      SELECT tipo INTO v_tipo FROM metodo_pago WHERE codigo = NEW.metodo;
      IF v_tipo = 'manual' AND NEW.validado_por IS NULL THEN
        CALL spi_error(45017, 'Yape, Plin, transferencia y efectivo solo los confirma un administrador');
      END IF;
      IF v_tipo = 'pasarela' AND NEW.referencia_externa IS NULL THEN
        CALL spi_error(45017, 'Un pago por pasarela exige la referencia externa de la pasarela');
      END IF;
      IF NEW.confirmado_en IS NULL THEN SET NEW.confirmado_en = UTC_TIMESTAMP(3); END IF;
    END IF;
  END IF;
  IF NEW.monto_reembolsado <> OLD.monto_reembolsado THEN
    CALL spi_requiere_contexto('monto_reembolsado se deriva de los reembolsos completados');
  END IF;
  IF NOT (NEW.datos_pasarela <=> OLD.datos_pasarela) AND fn_contiene_datos_tarjeta(NEW.datos_pasarela) THEN
    CALL spi_error(45031, 'Prohibido guardar datos de tarjeta');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$

DROP TRIGGER IF EXISTS trg_pago_ai $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pago_ai AFTER INSERT ON pago FOR EACH ROW
CALL spi_auditar('pago_registrado', 'pago', NEW.id_pago, NULL,
                 JSON_OBJECT('id_pedido', NEW.id_pedido, 'metodo', NEW.metodo, 'monto', NEW.monto, 'estado', NEW.estado), 'trigger') $$

DROP TRIGGER IF EXISTS trg_pago_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pago_au AFTER UPDATE ON pago FOR EACH ROW
BEGIN
  DECLARE v_usuario BIGINT UNSIGNED;
  DECLARE v_correo VARCHAR(254);
  DECLARE v_numero VARCHAR(25);
  DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  IF NEW.estado <> OLD.estado OR NEW.monto_reembolsado <> OLD.monto_reembolsado OR NEW.aplicado_al_pedido <> OLD.aplicado_al_pedido THEN
    -- Los montos del pedido siempre se derivan de sus pagos
    SET v_prev = @wanka_ctx_interno;
    SET @wanka_ctx_interno = fn_token_interno();
    CALL spi_recalcular_pagos_pedido(NEW.id_pedido);
    SET @wanka_ctx_interno = v_prev;
  END IF;
  IF NEW.estado <> OLD.estado THEN
    SELECT p.id_usuario, u.correo, p.numero INTO v_usuario, v_correo, v_numero
      FROM pedido p JOIN usuario u ON u.id_usuario = p.id_usuario WHERE p.id_pedido = NEW.id_pedido;
    CALL spi_auditar('pago_estado', 'pago', NEW.id_pago, v_usuario,
                     JSON_OBJECT('pedido', v_numero, 'metodo', NEW.metodo, 'monto', NEW.monto, 'de', OLD.estado, 'a', NEW.estado,
                                 'aplicado', NEW.aplicado_al_pedido), 'trigger');
    IF NEW.estado IN ('confirmado','rechazado','fallido','reembolsado') THEN
      CALL spi_encolar_correo(v_usuario, v_correo, CONCAT('pago_', NEW.estado),
                              JSON_OBJECT('pedido', v_numero, 'monto', NEW.monto, 'motivo', NEW.motivo_rechazo), 4);
      CALL spi_notificar(v_usuario, CONCAT('pago_', NEW.estado), CONCAT('Pago de S/ ', NEW.monto, ' ', REPLACE(NEW.estado, '_', ' ')),
                         NEW.motivo_rechazo, CONCAT('/mi-cuenta/pedidos/', v_numero), NEW.id_pedido);
    END IF;
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_pago_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_pago_bd BEFORE DELETE ON pago FOR EACH ROW
CALL spi_control_borrado('pago', OLD.id_pago) $$

DROP TRIGGER IF EXISTS trg_reembolso_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reembolso_bi BEFORE INSERT ON reembolso FOR EACH ROW
BEGIN
  DECLARE v_pedido BIGINT UNSIGNED; DECLARE v_monto DECIMAL(12,2); DECLARE v_otros DECIMAL(12,2);
  CALL spi_requiere_contexto('Los reembolsos se registran con sp_reembolsar_pago');
  SELECT id_pedido, monto INTO v_pedido, v_monto FROM pago WHERE id_pago = NEW.id_pago;
  IF v_pedido <> NEW.id_pedido THEN CALL spi_error(45029, 'El reembolso debe ser del mismo pedido que el pago'); END IF;
  SELECT COALESCE(SUM(monto), 0) INTO v_otros FROM reembolso WHERE id_pago = NEW.id_pago AND estado IN ('solicitado','procesando','completado') FOR SHARE;
  IF v_otros + NEW.monto > v_monto THEN CALL spi_error(45029, 'Los reembolsos superarían el monto del pago'); END IF;
  IF NEW.estado <> 'solicitado' THEN CALL spi_error(45029, 'Un reembolso nace solicitado'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_reembolso_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reembolso_bu BEFORE UPDATE ON reembolso FOR EACH ROW
BEGIN
  IF NOT (NEW.id_pago = OLD.id_pago AND NEW.id_pedido = OLD.id_pedido AND NEW.monto = OLD.monto AND NEW.motivo = OLD.motivo AND NEW.creado_en = OLD.creado_en) THEN
    CALL spi_error(45004, 'Pago, monto y motivo del reembolso no se modifican');
  END IF;
  IF NEW.estado <> OLD.estado THEN
    IF OLD.estado IN ('completado','fallido','anulado') THEN CALL spi_error(45004, CONCAT('El reembolso ya está ', OLD.estado)); END IF;
    IF OLD.estado = 'procesando' AND NEW.estado NOT IN ('completado','fallido') THEN
      CALL spi_error(45002, 'Un reembolso en proceso solo termina completado o fallido');
    END IF;
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_reembolso_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reembolso_au AFTER UPDATE ON reembolso FOR EACH ROW
BEGIN
  DECLARE v_total DECIMAL(12,2); DECLARE v_monto DECIMAL(12,2); DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  IF NEW.estado <> OLD.estado AND NEW.estado = 'completado' THEN
    SELECT COALESCE(SUM(monto), 0) INTO v_total FROM reembolso WHERE id_pago = NEW.id_pago AND estado = 'completado' FOR SHARE;
    SELECT monto INTO v_monto FROM pago WHERE id_pago = NEW.id_pago;
    -- Una compensación sin nota de crédito rebaja lo que el cliente debe (no deja "saldo pendiente")
    IF NEW.motivo = 'ajuste_precio' AND NEW.id_nota_credito IS NULL THEN
      CALL spi_recalcular_ajustes_pedido(NEW.id_pedido);
    END IF;
    SET v_prev = @wanka_ctx_interno;
    SET @wanka_ctx_interno = fn_token_interno();
    UPDATE pago SET monto_reembolsado = v_total, estado = IF(v_total >= v_monto, 'reembolsado', estado) WHERE id_pago = NEW.id_pago;
    SET @wanka_ctx_interno = v_prev;
  END IF;
  IF NEW.estado <> OLD.estado THEN
    CALL spi_auditar('reembolso_estado', 'reembolso', NEW.id_reembolso, NULL,
                     JSON_OBJECT('id_pago', NEW.id_pago, 'monto', NEW.monto, 'de', OLD.estado, 'a', NEW.estado, 'referencia', NEW.referencia_externa), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_reembolso_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reembolso_bd BEFORE DELETE ON reembolso FOR EACH ROW
CALL spi_control_borrado('reembolso', OLD.id_reembolso) $$

DROP TRIGGER IF EXISTS trg_evento_pasarela_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_evento_pasarela_bi BEFORE INSERT ON evento_pasarela FOR EACH ROW
BEGIN
  IF fn_contiene_datos_tarjeta(NEW.payload) THEN CALL spi_error(45031, 'El webhook trae datos de tarjeta: fíltrelos antes de guardar'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_evento_pasarela_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_evento_pasarela_bu BEFORE UPDATE ON evento_pasarela FOR EACH ROW
BEGIN
  IF NOT (NEW.proveedor = OLD.proveedor AND NEW.id_externo = OLD.id_externo AND NEW.recibido_en = OLD.recibido_en) THEN
    CALL spi_error(45004, 'El webhook recibido no se modifica');
  END IF;
  -- Única excepción: una copia con firma válida reemplaza a una con firma inválida aún no procesada
  IF NOT (NEW.payload = OLD.payload AND NEW.firma_valida = OLD.firma_valida AND NEW.tipo <=> OLD.tipo)
     AND NOT (OLD.firma_valida = 0 AND NEW.firma_valida = 1 AND OLD.estado NOT IN ('procesado','ignorado')) THEN
    CALL spi_error(45004, 'El webhook recibido no se modifica');
  END IF;
  IF NOT (NEW.payload = OLD.payload) AND fn_contiene_datos_tarjeta(NEW.payload) THEN
    CALL spi_error(45031, 'El webhook trae datos de tarjeta: fíltrelos antes de guardar');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_evento_pasarela_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_evento_pasarela_bd BEFORE DELETE ON evento_pasarela FOR EACH ROW
BEGIN
  IF OLD.estado NOT IN ('procesado','ignorado') THEN CALL spi_error(45005, 'Solo se purgan webhooks ya procesados'); END IF;
END $$

-- =====================================================================
-- COMPROBANTES
-- =====================================================================
DROP TRIGGER IF EXISTS trg_serie_comprobante_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_serie_comprobante_bu BEFORE UPDATE ON serie_comprobante FOR EACH ROW
BEGIN
  IF NEW.ultimo_correlativo < OLD.ultimo_correlativo THEN CALL spi_error(45004, 'El correlativo de una serie no retrocede'); END IF;
  IF NEW.ultimo_correlativo <> OLD.ultimo_correlativo THEN
    CALL spi_requiere_contexto('El correlativo avanza solo al emitir (un salto manual deja huecos ante SUNAT)');
  END IF;
  IF (NEW.tipo <> OLD.tipo OR NEW.serie <> OLD.serie) AND OLD.ultimo_correlativo > 0 THEN
    CALL spi_error(45004, 'Una serie con comprobantes emitidos no cambia de tipo ni de código');
  END IF;
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar series'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_serie_comprobante_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_serie_comprobante_bd BEFORE DELETE ON serie_comprobante FOR EACH ROW
CALL spi_control_borrado('serie_comprobante', OLD.id_serie) $$
DROP TRIGGER IF EXISTS trg_motivo_nota_credito_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_motivo_nota_credito_bd BEFORE DELETE ON motivo_nota_credito FOR EACH ROW
CALL spi_control_borrado('motivo_nota_credito', NULL) $$

DROP TRIGGER IF EXISTS trg_comprobante_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_bi BEFORE INSERT ON comprobante FOR EACH ROW
BEGIN
  DECLARE v_ref_tipo VARCHAR(15) DEFAULT NULL; DECLARE v_ref_estado VARCHAR(12); DECLARE v_ref_pedido BIGINT UNSIGNED;
  DECLARE v_ref_serie CHAR(4); DECLARE v_ref_total DECIMAL(12,2); DECLARE v_emitido DECIMAL(12,2);
  CALL spi_requiere_contexto('Los comprobantes se emiten con sp_emitir_comprobante / sp_emitir_nota_credito');
  IF NEW.estado_sunat <> 'pendiente' THEN CALL spi_error(45015, 'Un comprobante nace pendiente de envío'); END IF;
  IF NOT EXISTS (SELECT 1 FROM serie_comprobante WHERE id_serie = NEW.id_serie AND tipo = NEW.tipo AND serie = NEW.serie) THEN
    CALL spi_error(45015, 'La serie no corresponde al tipo de comprobante');
  END IF;
  IF NOT fn_ruc_valido(NEW.emisor_ruc) THEN CALL spi_error(45015, 'RUC del emisor inválido'); END IF;
  IF NEW.tipo = 'factura' AND (NOT fn_ruc_valido(NEW.cliente_num_doc) OR NULLIF(TRIM(NEW.cliente_nombre), '') IS NULL) THEN
    CALL spi_error(45015, 'La factura exige RUC válido y razón social del cliente');
  END IF;
  IF NEW.tipo = 'boleta' AND NEW.total > fn_config_decimal('umbral_boleta_dni') AND NEW.cliente_num_doc IS NULL THEN
    CALL spi_error(45015, 'Boleta por encima del umbral sin documento del cliente');
  END IF;
  IF NEW.tipo = 'nota_credito' THEN
    SELECT tipo, estado_sunat, id_pedido, serie, total INTO v_ref_tipo, v_ref_estado, v_ref_pedido, v_ref_serie, v_ref_total
      FROM comprobante WHERE id_comprobante = NEW.id_comprobante_ref;
    IF v_ref_tipo IS NULL OR v_ref_tipo NOT IN ('boleta','factura') THEN CALL spi_error(45016, 'La NC debe referenciar una boleta o factura'); END IF;
    IF v_ref_estado NOT IN ('aceptado','observado') THEN CALL spi_error(45016, 'No se emite NC contra un comprobante no aceptado (pendiente, rechazado o anulado)'); END IF;
    IF v_ref_pedido <> NEW.id_pedido THEN CALL spi_error(45016, 'La NC debe ser del mismo pedido que el comprobante'); END IF;
    IF LEFT(v_ref_serie, 1) <> LEFT(NEW.serie, 1) THEN CALL spi_error(45016, 'Serie incompatible: NC de boleta empieza con B y de factura con F'); END IF;
    IF NOT EXISTS (SELECT 1 FROM motivo_nota_credito WHERE codigo = NEW.codigo_motivo_nc AND activo = 1) THEN
      CALL spi_error(45016, 'Motivo de nota de crédito inválido');
    END IF;
    SELECT COALESCE(SUM(total), 0) INTO v_emitido FROM comprobante
     WHERE id_comprobante_ref = NEW.id_comprobante_ref AND tipo = 'nota_credito' AND estado_sunat NOT IN ('rechazado','anulado') FOR SHARE;
    IF v_emitido + NEW.total > v_ref_total THEN CALL spi_error(45016, 'La suma de notas de crédito supera el total del comprobante'); END IF;
  END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
END $$

DROP TRIGGER IF EXISTS trg_comprobante_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_bu BEFORE UPDATE ON comprobante FOR EACH ROW
BEGIN
  DECLARE v_items DECIMAL(12,2); DECLARE v_igv DECIMAL(12,2);
  IF NOT (NEW.id_pedido = OLD.id_pedido AND NEW.tipo = OLD.tipo AND NEW.id_serie = OLD.id_serie AND NEW.serie = OLD.serie
          AND NEW.correlativo = OLD.correlativo AND NEW.id_comprobante_ref <=> OLD.id_comprobante_ref
          AND NEW.codigo_motivo_nc <=> OLD.codigo_motivo_nc AND NEW.motivo_detalle <=> OLD.motivo_detalle
          AND NEW.id_devolucion <=> OLD.id_devolucion AND NEW.fecha_emision = OLD.fecha_emision
          AND NEW.emisor_ruc = OLD.emisor_ruc AND NEW.emisor_razon_social = OLD.emisor_razon_social
          AND NEW.emisor_domicilio_fiscal = OLD.emisor_domicilio_fiscal AND NEW.emisor_nombre_comercial <=> OLD.emisor_nombre_comercial
          AND NEW.cliente_tipo_doc <=> OLD.cliente_tipo_doc AND NEW.cliente_num_doc <=> OLD.cliente_num_doc
          AND NEW.cliente_nombre = OLD.cliente_nombre AND NEW.cliente_direccion <=> OLD.cliente_direccion
          AND NEW.igv_porcentaje = OLD.igv_porcentaje AND NEW.op_gravada = OLD.op_gravada AND NEW.op_exonerada = OLD.op_exonerada
          AND NEW.op_inafecta = OLD.op_inafecta AND NEW.igv = OLD.igv AND NEW.total = OLD.total AND NEW.moneda = OLD.moneda
          AND NEW.emitido_en = OLD.emitido_en) THEN
    CALL spi_error(45004, 'Un comprobante emitido no se modifica: corríjalo con una nota de crédito');
  END IF;
  IF OLD.estado_sunat IN ('aceptado','observado','rechazado','anulado') AND NOT (
         NEW.estado_sunat = OLD.estado_sunat AND NEW.hash_cpe <=> OLD.hash_cpe AND NEW.payload_envio <=> OLD.payload_envio
     AND NEW.payload_respuesta <=> OLD.payload_respuesta AND NEW.codigo_respuesta_sunat <=> OLD.codigo_respuesta_sunat
     AND (NEW.url_pdf <=> OLD.url_pdf OR OLD.url_pdf IS NULL) AND (NEW.url_xml <=> OLD.url_xml OR OLD.url_xml IS NULL)
     AND (NEW.url_cdr <=> OLD.url_cdr OR OLD.url_cdr IS NULL)) THEN
    CALL spi_error(45004, CONCAT('El comprobante ya está ', OLD.estado_sunat, ': no se modifica (solo nota de crédito)'));
  END IF;
  IF NEW.estado_sunat <> OLD.estado_sunat THEN
    CALL spi_requiere_contexto('El estado del comprobante lo registra sp_registrar_respuesta_ose');
    IF NOT ((OLD.estado_sunat = 'pendiente' AND NEW.estado_sunat IN ('enviado','aceptado','observado','rechazado','error'))
         OR (OLD.estado_sunat = 'enviado'   AND NEW.estado_sunat IN ('aceptado','observado','rechazado','error'))
         OR (OLD.estado_sunat = 'error'     AND NEW.estado_sunat IN ('enviado','aceptado','observado','rechazado'))) THEN
      CALL spi_error(45002, CONCAT('Cambio de estado de comprobante no permitido: ', OLD.estado_sunat, ' -> ', NEW.estado_sunat));
    END IF;
    SELECT COALESCE(SUM(total_linea), 0), COALESCE(SUM(igv), 0) INTO v_items, v_igv FROM comprobante_item WHERE id_comprobante = NEW.id_comprobante;
    IF v_items <> NEW.total OR v_igv <> NEW.igv THEN
      CALL spi_error(45015, 'Las líneas del comprobante no cuadran con la cabecera');
    END IF;
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$

DROP TRIGGER IF EXISTS trg_comprobante_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_au AFTER UPDATE ON comprobante FOR EACH ROW
BEGIN
  IF NEW.estado_sunat <> OLD.estado_sunat THEN
    CALL spi_auditar('comprobante_estado', 'comprobante', NEW.id_comprobante, NULL,
                     JSON_OBJECT('numero', NEW.numero_completo, 'de', OLD.estado_sunat, 'a', NEW.estado_sunat, 'codigo', NEW.codigo_respuesta_sunat), 'trigger');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_comprobante_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_bd BEFORE DELETE ON comprobante FOR EACH ROW
CALL spi_control_borrado('comprobante', OLD.id_comprobante) $$

DROP TRIGGER IF EXISTS trg_comprobante_item_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_item_bi BEFORE INSERT ON comprobante_item FOR EACH ROW
BEGIN
  CALL spi_requiere_contexto('Las líneas del comprobante las genera la BD');
  IF NOT EXISTS (SELECT 1 FROM comprobante WHERE id_comprobante = NEW.id_comprobante AND estado_sunat = 'pendiente') THEN
    CALL spi_error(45004, 'Solo se agregan líneas a un comprobante pendiente de envío');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_comprobante_item_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_item_bu BEFORE UPDATE ON comprobante_item FOR EACH ROW
CALL spi_solo_insercion('comprobante_item') $$
DROP TRIGGER IF EXISTS trg_comprobante_item_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_item_bd BEFORE DELETE ON comprobante_item FOR EACH ROW
CALL spi_control_borrado('comprobante_item', OLD.id_comprobante_item) $$

DROP TRIGGER IF EXISTS trg_comprobante_archivo_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_archivo_bu BEFORE UPDATE ON comprobante_archivo FOR EACH ROW
CALL spi_solo_insercion('comprobante_archivo') $$
DROP TRIGGER IF EXISTS trg_comprobante_archivo_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_comprobante_archivo_bd BEFORE DELETE ON comprobante_archivo FOR EACH ROW
CALL spi_control_borrado('comprobante_archivo', OLD.id_archivo) $$

DROP TRIGGER IF EXISTS trg_cola_emision_comprobante_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cola_emision_comprobante_bu BEFORE UPDATE ON cola_emision_comprobante FOR EACH ROW
BEGIN
  IF NEW.id_comprobante <> OLD.id_comprobante THEN CALL spi_error(45004, 'El trabajo no cambia de comprobante'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_cola_emision_comprobante_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cola_emision_comprobante_bd BEFORE DELETE ON cola_emision_comprobante FOR EACH ROW
CALL spi_control_borrado('cola_emision_comprobante', OLD.id_trabajo) $$

-- =====================================================================
-- ATENCIÓN AL CLIENTE
-- =====================================================================
DROP TRIGGER IF EXISTS trg_mensaje_contacto_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_mensaje_contacto_bi BEFORE INSERT ON mensaje_contacto FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  DECLARE v_max INT DEFAULT fn_config_entero('contacto_max_por_hora_ip');
  SET NEW.correo = fn_normalizar_correo(NEW.correo);
  SET NEW.celular = fn_normalizar_telefono(NEW.celular);
  SET NEW.nombre = TRIM(NEW.nombre);
  -- Red de seguridad del límite (el procedimiento además lo serializa por IP)
  -- Sin IP conocida todas las solicitudes comparten un mismo cupo (falla cerrado)
  IF (SELECT COUNT(*) FROM mensaje_contacto WHERE ip <=> NEW.ip AND creado_en > UTC_TIMESTAMP(3) - INTERVAL 1 HOUR) >= v_max THEN
    CALL spi_error(45010, CONCAT('Límite de ', v_max, ' mensajes por hora excedido'));
  END IF;
  IF NEW.ticket IS NULL OR NEW.ticket = '' THEN
    CALL spi_siguiente_numero('TK', 6, v_num);
    SET NEW.ticket = v_num;
  END IF;
  IF NEW.estado <> 'nuevo' THEN CALL spi_error(45006, 'Un mensaje nace en estado nuevo'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_mensaje_contacto_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_mensaje_contacto_bu BEFORE UPDATE ON mensaje_contacto FOR EACH ROW
BEGIN
  IF NOT (NEW.ticket = OLD.ticket AND NEW.mensaje = OLD.mensaje AND NEW.correo = OLD.correo AND NEW.ip <=> OLD.ip AND NEW.creado_en = OLD.creado_en) THEN
    CALL spi_error(45004, 'El mensaje recibido no se modifica');
  END IF;
  CALL spi_requiere_contexto('Los mensajes se atienden con sp_responder_mensaje_contacto');
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_mensaje_contacto_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_mensaje_contacto_bd BEFORE DELETE ON mensaje_contacto FOR EACH ROW
CALL spi_control_borrado('mensaje_contacto', OLD.id_mensaje) $$

DROP TRIGGER IF EXISTS trg_reclamo_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reclamo_bi BEFORE INSERT ON reclamo FOR EACH ROW
BEGIN
  DECLARE v_num VARCHAR(25);
  SET NEW.correo = fn_normalizar_correo(NEW.correo);
  SET NEW.celular = fn_normalizar_telefono(NEW.celular);
  SET NEW.num_doc = UPPER(TRIM(NEW.num_doc));
  IF NOT fn_documento_valido(NEW.tipo_doc, NEW.num_doc) THEN CALL spi_error(45006, 'Documento del consumidor inválido'); END IF;
  IF NEW.numero IS NULL OR NEW.numero = '' THEN
    CALL spi_siguiente_numero('LR', 6, v_num);
    SET NEW.numero = v_num;
  END IF;
  IF NEW.fecha_limite IS NULL THEN
    SET NEW.fecha_limite = fn_fecha_limite(fn_hoy_lima(), fn_config_entero('reclamo_plazo_dias'), fn_config('reclamo_plazo_tipo'));
  END IF;
  IF NEW.estado <> 'registrado' THEN CALL spi_error(45006, 'Un reclamo nace registrado'); END IF;
END $$
DROP TRIGGER IF EXISTS trg_reclamo_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reclamo_bu BEFORE UPDATE ON reclamo FOR EACH ROW
BEGIN
  IF NOT (NEW.numero = OLD.numero AND NEW.nombres = OLD.nombres AND NEW.apellidos = OLD.apellidos AND NEW.num_doc = OLD.num_doc
          AND NEW.detalle = OLD.detalle AND NEW.pedido_consumidor = OLD.pedido_consumidor AND NEW.tipo = OLD.tipo
          AND NEW.fecha_limite = OLD.fecha_limite AND NEW.creado_en = OLD.creado_en AND NEW.monto_reclamado <=> OLD.monto_reclamado) THEN
    CALL spi_error(45004, 'La hoja de reclamación registrada no se modifica');
  END IF;
  -- Ninguna columna de la hoja se edita a mano: estado y respuesta solo con sp_responder_reclamo
  CALL spi_requiere_contexto('El Libro de Reclamaciones se atiende con sp_responder_reclamo');
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_reclamo_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_reclamo_bd BEFORE DELETE ON reclamo FOR EACH ROW
CALL spi_control_borrado('reclamo', OLD.id_reclamo) $$

DROP TRIGGER IF EXISTS trg_respuesta_atencion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_respuesta_atencion_bu BEFORE UPDATE ON respuesta_atencion FOR EACH ROW
CALL spi_solo_insercion('respuesta_atencion') $$
DROP TRIGGER IF EXISTS trg_respuesta_atencion_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_respuesta_atencion_bd BEFORE DELETE ON respuesta_atencion FOR EACH ROW
CALL spi_control_borrado('respuesta_atencion', OLD.id_respuesta) $$

DROP TRIGGER IF EXISTS trg_banner_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_banner_bi BEFORE INSERT ON banner FOR EACH ROW
BEGIN
  IF NEW.activo = 0 THEN CALL spi_requiere_contexto('Crear un banner inactivo'); END IF;
  SET NEW.creado_por = COALESCE(NEW.creado_por, fn_actor());
  SET NEW.actualizado_por = NEW.creado_por;
END $$
DROP TRIGGER IF EXISTS trg_banner_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_banner_bu BEFORE UPDATE ON banner FOR EACH ROW
BEGIN
  IF NEW.activo <> OLD.activo THEN CALL spi_requiere_contexto('Inhabilitar/reactivar banners'); END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
  SET NEW.actualizado_por = fn_actor();
END $$
DROP TRIGGER IF EXISTS trg_banner_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_banner_bd BEFORE DELETE ON banner FOR EACH ROW
CALL spi_control_borrado('banner', OLD.id_banner) $$

-- RESEÑAS ---------------------------------------------------------------
DROP PROCEDURE IF EXISTS spi_recalcular_valoracion $$
CREATE DEFINER=`wanka_definer`@`localhost` PROCEDURE spi_recalcular_valoracion(IN p_id_producto BIGINT UNSIGNED)
MODIFIES SQL DATA SQL SECURITY DEFINER
COMMENT 'Valoración promedio y total de reseñas publicadas del producto'
BEGIN
  DECLARE v_total INT; DECLARE v_prom DECIMAL(2,1); DECLARE v_prev VARCHAR(64) DEFAULT @wanka_ctx_interno;
  DECLARE EXIT HANDLER FOR SQLEXCEPTION BEGIN SET @wanka_ctx_interno = v_prev; RESIGNAL; END;
  SELECT COUNT(*), COALESCE(ROUND(AVG(calificacion), 1), 0) INTO v_total, v_prom FROM resena WHERE id_producto = p_id_producto AND estado = 'publicada';
  SET v_prev = @wanka_ctx_interno;
  SET @wanka_ctx_interno = fn_token_interno();
  UPDATE producto SET total_resenas = v_total, valoracion_promedio = v_prom WHERE id_producto = p_id_producto;
  SET @wanka_ctx_interno = v_prev;
END $$

DROP TRIGGER IF EXISTS trg_resena_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_resena_bi BEFORE INSERT ON resena FOR EACH ROW
BEGIN
  IF NOT EXISTS (SELECT 1 FROM item_pedido i JOIN pedido pe ON pe.id_pedido = i.id_pedido
                  WHERE pe.id_pedido = NEW.id_pedido AND pe.id_usuario = NEW.id_usuario AND pe.estado = 'entregado'
                    AND i.id_producto = NEW.id_producto AND i.estado = 'vigente') THEN
    CALL spi_error(45026, 'Solo puede reseñar un producto que compró y recibió');
  END IF;
  IF NEW.estado <> 'pendiente' THEN CALL spi_error(45026, 'La reseña nace pendiente de moderación'); END IF;
  SET NEW.titulo = NULLIF(TRIM(NEW.titulo), '');
  SET NEW.comentario = NULLIF(TRIM(NEW.comentario), '');
END $$
DROP TRIGGER IF EXISTS trg_resena_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_resena_bu BEFORE UPDATE ON resena FOR EACH ROW
BEGIN
  IF NOT (NEW.id_producto = OLD.id_producto AND NEW.id_usuario = OLD.id_usuario AND NEW.id_pedido = OLD.id_pedido AND NEW.creado_en = OLD.creado_en) THEN
    CALL spi_error(45004, 'Producto, cliente y pedido de la reseña no se modifican');
  END IF;
  -- Si el cliente edita el contenido, vuelve a moderación
  IF NOT fn_contexto_interno() AND NOT (NEW.calificacion = OLD.calificacion AND NEW.titulo <=> OLD.titulo AND NEW.comentario <=> OLD.comentario) THEN
    SET NEW.estado = 'pendiente', NEW.moderado_por = NULL, NEW.moderado_en = NULL, NEW.motivo_moderacion = NULL;
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$
DROP TRIGGER IF EXISTS trg_resena_ai $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_resena_ai AFTER INSERT ON resena FOR EACH ROW
CALL spi_recalcular_valoracion(NEW.id_producto) $$
DROP TRIGGER IF EXISTS trg_resena_au $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_resena_au AFTER UPDATE ON resena FOR EACH ROW
CALL spi_recalcular_valoracion(NEW.id_producto) $$
DROP TRIGGER IF EXISTS trg_resena_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_resena_bd BEFORE DELETE ON resena FOR EACH ROW
CALL spi_control_borrado('resena', OLD.id_resena) $$

-- =====================================================================
-- COLAS, NOTIFICACIONES, BITÁCORAS
-- =====================================================================
DROP TRIGGER IF EXISTS trg_cola_correo_bi $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cola_correo_bi BEFORE INSERT ON cola_correo FOR EACH ROW
BEGIN
  SET NEW.destinatario = fn_normalizar_correo(NEW.destinatario);
  -- Nunca códigos de verificación ni contraseñas en claro dentro de la cola
  IF NEW.contexto IS NOT NULL AND JSON_CONTAINS_PATH(NEW.contexto, 'one', '$.codigo', '$.code', '$.contrasena', '$.password', '$.token') THEN
    CALL spi_error(45006, 'El contexto del correo no puede llevar códigos, contraseñas ni tokens en claro');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_cola_correo_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_cola_correo_bu BEFORE UPDATE ON cola_correo FOR EACH ROW
BEGIN
  IF NEW.destinatario <> OLD.destinatario OR NEW.plantilla <> OLD.plantilla OR NOT (NEW.contexto <=> OLD.contexto) THEN
    CALL spi_error(45004, 'El contenido de un correo encolado no se modifica');
  END IF;
  SET NEW.actualizado_en = UTC_TIMESTAMP(3);
END $$

DROP TRIGGER IF EXISTS trg_notificacion_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_notificacion_bu BEFORE UPDATE ON notificacion FOR EACH ROW
BEGIN
  IF NOT (NEW.id_usuario = OLD.id_usuario AND NEW.tipo = OLD.tipo AND NEW.titulo = OLD.titulo AND NEW.mensaje <=> OLD.mensaje) THEN
    CALL spi_error(45004, 'Solo se marca la notificación como leída');
  END IF;
END $$

DROP TRIGGER IF EXISTS trg_log_api_externa_bu $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_log_api_externa_bu BEFORE UPDATE ON log_api_externa FOR EACH ROW
BEGIN
  -- Única excepción: sp_redactar_log_api (DBA con @wanka_autorizo_borrado) borra un secreto guardado por error
  IF NOT (fn_borrado_dba_autorizado() AND fn_contexto_interno()) THEN
    CALL spi_solo_insercion('log_api_externa');
  END IF;
END $$
DROP TRIGGER IF EXISTS trg_log_api_externa_bd $$
CREATE DEFINER=`wanka_definer`@`localhost` TRIGGER trg_log_api_externa_bd BEFORE DELETE ON log_api_externa FOR EACH ROW
BEGIN
  IF OLD.creado_en >= UTC_TIMESTAMP(3) - INTERVAL 12 MONTH THEN CALL spi_error(45005, 'La bitácora de APIs se conserva al menos 12 meses'); END IF;
END $$

DELIMITER ;

SELECT 'Triggers listos: continúa con 05_vistas.sql' AS siguiente_paso;
