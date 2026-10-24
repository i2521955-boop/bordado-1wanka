-- =====================================================================
-- BORDADOS WANKA S.A.C. — 01_esquema_acceso.sql
-- ---------------------------------------------------------------------
-- Propósito : módulo de ACCESO Y SEGURIDAD (reconstruido en MySQL a partir
--             de los requisitos del §4 del prompt; el script original
--             bordadosdb_login.sql no se recibió).
-- Tablas    : rol, usuario, sesion, intento_acceso, codigo_verificacion,
--             historial_contrasena, autenticacion_2fa, codigo_respaldo_2fa,
--             consentimiento_datos, solicitud_arco, auditoria, secreto_interno.
-- Convenciones de todo el esquema:
--   * Fechas en UTC con DATETIME(3); las vistas convierten a Lima (−05:00).
--   * Booleanos como BOOLEAN (TINYINT(1)) con CHECK (0/1).
--   * IPs en VARBINARY(16) (INET6_ATON / INET6_NTOA).
--   * Hashes en CHAR(64) ascii_bin (SHA-256 en hexadecimal).
--   * REGEXP_LIKE(..., 'c') = comparación sensible a mayúsculas (la
--     colación por defecto ai_ci es insensible).
--   * "Eliminar" = inhabilitar (activo/estado + inhabilitado_en/por).
-- Re-ejecutable: sí (CREATE TABLE IF NOT EXISTS). Para reinstalar desde
--             cero usa scripts/instalar.sh --reiniciar.
-- COMPAT-MARIADB: REGEXP_LIKE(col, patrón, 'c') → col REGEXP BINARY patrón;
--   DEFAULT (UTC_TIMESTAMP(3)) funciona desde 10.2; colación utf8mb4_0900_ai_ci → utf8mb4_unicode_520_ci.
-- =====================================================================
USE bordados_wanka;
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;
SET SESSION time_zone = '+00:00';

-- ---------------------------------------------------------------------
-- ROL: solo 'administrador' y 'cliente'
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS rol (
  id_rol          TINYINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador del rol',
  codigo          VARCHAR(20)  NOT NULL COMMENT 'Código interno: administrador | cliente',
  nombre          VARCHAR(40)  NOT NULL COMMENT 'Nombre visible del rol',
  descripcion     VARCHAR(200) NULL     COMMENT 'Descripción del alcance del rol',
  requiere_2fa    BOOLEAN      NOT NULL DEFAULT 0 COMMENT '1 = el rol debe usar segundo factor (TOTP obligatorio para administradores)',
  activo          BOOLEAN      NOT NULL DEFAULT 1 COMMENT 'Borrado lógico',
  creado_en       DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en  DATETIME(3)  NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_rol),
  UNIQUE KEY uq_rol_codigo (codigo),
  CONSTRAINT ck_rol_codigo   CHECK (codigo IN ('administrador','cliente')),
  CONSTRAINT ck_rol_bool     CHECK (requiere_2fa IN (0,1) AND activo IN (0,1))
) ENGINE=InnoDB COMMENT='Roles del sistema (solo administrador y cliente). RF de acceso / HU de login';

-- ---------------------------------------------------------------------
-- USUARIO
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuario (
  id_usuario             BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador del usuario',
  id_rol                 TINYINT UNSIGNED NOT NULL COMMENT 'Rol (FK rol)',
  correo                 VARCHAR(254)     NOT NULL COMMENT 'Correo de acceso, normalizado (trim + minúsculas); único',
  hash_contrasena        VARCHAR(255)     NOT NULL COMMENT 'Hash generado por Django (PBKDF2-SHA256 / Argon2); nunca texto plano. "!" = sin contraseña utilizable',
  nombres                VARCHAR(80)      NOT NULL COMMENT 'Nombres',
  apellidos              VARCHAR(80)      NOT NULL COMMENT 'Apellidos',
  nombre_completo        VARCHAR(161) AS (CONCAT_WS(' ', nombres, apellidos)) VIRTUAL COMMENT 'Nombres + apellidos (calculado)',
  celular                VARCHAR(16)      NULL COMMENT 'Celular, solo dígitos con + opcional (9 a 15 dígitos)',
  tipo_documento         ENUM('DNI','RUC','CE') NULL COMMENT 'Tipo de documento (opcional; se pide al facturar)',
  numero_documento       VARCHAR(12)      NULL COMMENT 'Número de documento: DNI 8 dígitos, RUC 11 (10/15/16/17/20 + dígito verificador), CE 6-12 alfanum.',
  estado                 ENUM('pendiente_verificacion','activo','inhabilitado') NOT NULL DEFAULT 'pendiente_verificacion' COMMENT 'Estado de la cuenta. Inhabilitado = borrado lógico',
  correo_verificado_en   DATETIME(3)      NULL COMMENT 'Cuándo verificó su correo con código',
  intentos_fallidos      TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Intentos de acceso fallidos consecutivos',
  bloqueado_hasta        DATETIME(3)      NULL COMMENT 'Bloqueo temporal por intentos fallidos (UTC)',
  ultimo_acceso_en       DATETIME(3)      NULL COMMENT 'Último acceso exitoso',
  contrasena_cambiada_en DATETIME(3)      NULL COMMENT 'Último cambio de contraseña',
  inhabilitado_en        DATETIME(3)      NULL COMMENT 'Cuándo se inhabilitó',
  inhabilitado_por       BIGINT UNSIGNED  NULL COMMENT 'Quién la inhabilitó (FK usuario)',
  motivo_inhabilitacion  VARCHAR(200)     NULL COMMENT 'Motivo de la inhabilitación',
  creado_en              DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en         DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  creado_por             BIGINT UNSIGNED  NULL COMMENT 'Actor que creó (@app_actor_id)',
  actualizado_por        BIGINT UNSIGNED  NULL COMMENT 'Actor que modificó (@app_actor_id)',
  PRIMARY KEY (id_usuario),
  UNIQUE KEY uq_usuario_correo (correo),
  KEY idx_usuario_documento (tipo_documento, numero_documento),   -- no único: no revela si un DNI ya es cliente ni permite "ocuparlo"
  KEY idx_usuario_rol_estado (id_rol, estado),
  CONSTRAINT fk_usuario_rol              FOREIGN KEY (id_rol)           REFERENCES rol (id_rol),
  CONSTRAINT fk_usuario_inhabilitado_por FOREIGN KEY (inhabilitado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT fk_usuario_creado_por       FOREIGN KEY (creado_por)       REFERENCES usuario (id_usuario),
  CONSTRAINT fk_usuario_actualizado_por  FOREIGN KEY (actualizado_por)  REFERENCES usuario (id_usuario),
  CONSTRAINT ck_usuario_correo_formato CHECK (REGEXP_LIKE(correo, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c')),
  CONSTRAINT ck_usuario_correo_normal  CHECK (CAST(correo AS BINARY) = CAST(LOWER(TRIM(correo)) AS BINARY)),
  CONSTRAINT ck_usuario_hash           CHECK (CHAR_LENGTH(hash_contrasena) >= 20 AND
                                              REGEXP_LIKE(hash_contrasena, '^(pbkdf2_sha256|pbkdf2_sha1|argon2|bcrypt_sha256|bcrypt|scrypt)[$]|^!', 'c')),
  CONSTRAINT ck_usuario_nombres        CHECK (CHAR_LENGTH(TRIM(nombres)) >= 2 AND CHAR_LENGTH(TRIM(apellidos)) >= 2),
  CONSTRAINT ck_usuario_celular        CHECK (celular IS NULL OR REGEXP_LIKE(celular, '^[+]?[0-9]{9,15}$', 'c')),
  CONSTRAINT ck_usuario_documento      CHECK (
         (tipo_documento IS NULL AND numero_documento IS NULL)
      OR (tipo_documento = 'DNI' AND REGEXP_LIKE(numero_documento, '^[0-9]{8}$', 'c'))
      OR (tipo_documento = 'RUC' AND REGEXP_LIKE(numero_documento, '^(10|15|16|17|20)[0-9]{9}$', 'c'))
      OR (tipo_documento = 'CE'  AND REGEXP_LIKE(numero_documento, '^[A-Z0-9]{6,12}$', 'c'))),
  CONSTRAINT ck_usuario_inhabilitado   CHECK ((estado = 'inhabilitado') = (inhabilitado_en IS NOT NULL)),
  CONSTRAINT ck_usuario_verificado     CHECK (estado <> 'activo' OR correo_verificado_en IS NOT NULL),
  CONSTRAINT ck_usuario_intentos       CHECK (intentos_fallidos <= 50)
) ENGINE=InnoDB COMMENT='Usuarios (administradores y clientes). Nunca se borran: se inhabilitan. Ley 29733: solo datos necesarios';

-- ---------------------------------------------------------------------
-- SESION: registro de sesiones/dispositivos (complementa django_session)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sesion (
  id_sesion            BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador de la sesión',
  id_usuario           BIGINT UNSIGNED NOT NULL COMMENT 'Usuario (FK)',
  token_hash           CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'SHA-256 de la clave de sesión (nunca la clave en claro)',
  ip                   VARBINARY(16)   NULL COMMENT 'IP de origen (INET6_ATON)',
  user_agent           VARCHAR(255)    NULL COMMENT 'Navegador / dispositivo (recortado)',
  creado_en            DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Inicio (UTC)',
  ultima_actividad_en  DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última actividad (UTC)',
  expira_en            DATETIME(3)     NOT NULL COMMENT 'Expiración absoluta (UTC)',
  cerrada_en           DATETIME(3)     NULL COMMENT 'Cierre (UTC)',
  motivo_cierre        ENUM('logout','expirada','revocada','cambio_contrasena','inhabilitacion') NULL COMMENT 'Motivo del cierre',
  PRIMARY KEY (id_sesion),
  UNIQUE KEY uq_sesion_token (token_hash),
  KEY idx_sesion_usuario (id_usuario, cerrada_en),
  KEY idx_sesion_expira (cerrada_en, expira_en),
  CONSTRAINT fk_sesion_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_sesion_token   CHECK (REGEXP_LIKE(token_hash, '^[0-9a-f]{64}$', 'c')),
  CONSTRAINT ck_sesion_fechas  CHECK (expira_en > creado_en),
  CONSTRAINT ck_sesion_cierre  CHECK ((cerrada_en IS NULL) = (motivo_cierre IS NULL))
) ENGINE=InnoDB COMMENT='Sesiones abiertas/cerradas por usuario (auditoría de accesos y cierre remoto)';

-- ---------------------------------------------------------------------
-- INTENTO_ACCESO: solo inserción
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS intento_acceso (
  id_intento        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  correo_intentado  VARCHAR(254)    NOT NULL COMMENT 'Correo escrito (normalizado)',
  id_usuario        BIGINT UNSIGNED NULL COMMENT 'Usuario si existe (FK)',
  ip                VARBINARY(16)   NULL COMMENT 'IP de origen',
  user_agent        VARCHAR(255)    NULL COMMENT 'Navegador',
  exitoso           BOOLEAN         NOT NULL COMMENT '1 = acceso concedido',
  resultado         ENUM('ok','requiere_2fa','credenciales_invalidas','usuario_inexistente','cuenta_bloqueada',
                         'bloqueada_ahora','cuenta_inhabilitada','correo_no_verificado','segundo_factor_fallido','ip_bloqueada') NOT NULL COMMENT 'Resultado del intento',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_intento),
  KEY idx_intento_correo (correo_intentado, creado_en),
  KEY idx_intento_ip (ip, creado_en),
  KEY idx_intento_usuario (id_usuario, creado_en),
  KEY idx_intento_fecha (creado_en),
  CONSTRAINT fk_intento_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_intento_exitoso CHECK (exitoso IN (0,1) AND (exitoso = 1) = (resultado IN ('ok','requiere_2fa')))
) ENGINE=InnoDB COMMENT='Bitácora de intentos de acceso (solo inserción; retención configurable >= 12 meses)';

-- ---------------------------------------------------------------------
-- CODIGO_VERIFICACION: códigos por correo (§2.7)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS codigo_verificacion (
  id_codigo       BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario      BIGINT UNSIGNED  NULL COMMENT 'Usuario dueño del código (FK)',
  correo_destino  VARCHAR(254)     NOT NULL COMMENT 'Correo al que se envió (normalizado)',
  proposito       ENUM('verificar_correo','iniciar_sesion','recuperar_contrasena','cambiar_contrasena','cambiar_correo','segundo_factor') NOT NULL COMMENT 'Para qué sirve el código',
  codigo_hash     CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'SHA-256(pepper + código). El código en claro NUNCA se guarda',
  estado          ENUM('activo','usado','expirado','bloqueado','reemplazado') NOT NULL DEFAULT 'activo' COMMENT 'Ciclo de vida',
  intentos        TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT 'Intentos fallidos de verificación',
  max_intentos    TINYINT UNSIGNED NOT NULL DEFAULT 5 COMMENT 'Tope de intentos (máx. 5)',
  hash_vigente    CHAR(64) CHARACTER SET ascii COLLATE ascii_bin AS (IF(estado = 'activo', codigo_hash, NULL)) STORED COMMENT 'Solo tiene valor si está activo: el índice único impide dos códigos vigentes iguales',
  ip              VARBINARY(16)    NULL COMMENT 'IP que lo solicitó',
  creado_en       DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Generación (UTC)',
  expira_en       DATETIME(3)      NOT NULL COMMENT 'Vencimiento (máx. 5 minutos después de creado_en)',
  usado_en        DATETIME(3)      NULL COMMENT 'Uso exitoso (uso único)',
  cerrado_en      DATETIME(3)      NULL COMMENT 'Cuándo dejó de estar activo por expiración, bloqueo o reemplazo',
  PRIMARY KEY (id_codigo),
  UNIQUE KEY uq_codigo_vigente (hash_vigente),
  KEY idx_codigo_correo (correo_destino, proposito, creado_en),
  KEY idx_codigo_usuario (id_usuario, creado_en),
  KEY idx_codigo_estado (estado, expira_en),
  CONSTRAINT fk_codigo_usuario     FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_codigo_hash        CHECK (REGEXP_LIKE(codigo_hash, '^[0-9a-f]{64}$', 'c')),
  CONSTRAINT ck_codigo_vigencia    CHECK (expira_en > creado_en AND TIMESTAMPDIFF(SECOND, creado_en, expira_en) <= 300),
  CONSTRAINT ck_codigo_intentos    CHECK (max_intentos BETWEEN 1 AND 5 AND intentos <= max_intentos),
  CONSTRAINT ck_codigo_usado       CHECK ((estado = 'usado') = (usado_en IS NOT NULL)),
  CONSTRAINT ck_codigo_correo      CHECK (REGEXP_LIKE(correo_destino, '^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$', 'c'))
) ENGINE=InnoDB COMMENT='Códigos de verificación por correo: aleatorios (RANDOM_BYTES), solo hash, 5 min, uso único, 5 intentos, 5 por hora. HU-02';

-- ---------------------------------------------------------------------
-- HISTORIAL_CONTRASENA: solo inserción
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS historial_contrasena (
  id_historial     BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario       BIGINT UNSIGNED NOT NULL COMMENT 'Usuario (FK)',
  hash_contrasena  VARCHAR(255)    NOT NULL COMMENT 'Hash que tuvo el usuario (para impedir reutilizar las últimas 3)',
  origen           ENUM('registro','cambio','recuperacion','administrador') NOT NULL COMMENT 'Cómo se fijó',
  creado_en        DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_historial),
  KEY idx_historial_usuario (id_usuario, creado_en),
  CONSTRAINT fk_historial_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario)
) ENGINE=InnoDB COMMENT='Historial de hashes de contraseña (la app compara la nueva contra las 3 últimas con check_password)';

-- ---------------------------------------------------------------------
-- AUTENTICACION_2FA y CODIGO_RESPALDO_2FA
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS autenticacion_2fa (
  id_usuario        BIGINT UNSIGNED NOT NULL COMMENT 'Usuario (PK y FK)',
  metodo            ENUM('totp','correo') NOT NULL DEFAULT 'totp' COMMENT 'Segundo factor: TOTP (app autenticadora) o código por correo',
  secreto_cifrado   VARBINARY(512)  NULL COMMENT 'Secreto TOTP cifrado POR LA APLICACIÓN (Fernet/AES-GCM, clave fuera de la BD)',
  activo            BOOLEAN         NOT NULL DEFAULT 0 COMMENT '1 = segundo factor en uso',
  verificado_en     DATETIME(3)     NULL COMMENT 'Cuándo se confirmó la configuración',
  ultimo_paso_totp  BIGINT UNSIGNED NULL COMMENT 'Último paso TOTP aceptado (evita reutilizar el mismo código)',
  ultimo_uso_en     DATETIME(3)     NULL COMMENT 'Último uso exitoso',
  desactivado_en    DATETIME(3)     NULL COMMENT 'Cuándo se desactivó',
  metodo_pendiente  ENUM('totp','correo') NULL COMMENT 'Reconfiguración en curso: el 2FA actual sigue activo hasta confirmar la nueva',
  secreto_pendiente_cifrado VARBINARY(512) NULL COMMENT 'Secreto TOTP nuevo (cifrado por la app) pendiente de confirmar',
  pendiente_desde   DATETIME(3)     NULL COMMENT 'Desde cuándo hay una reconfiguración pendiente',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  actualizado_en    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  PRIMARY KEY (id_usuario),
  CONSTRAINT fk_2fa_usuario   FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_2fa_secreto   CHECK (metodo <> 'totp' OR secreto_cifrado IS NOT NULL),
  CONSTRAINT ck_2fa_pendiente CHECK ((metodo_pendiente IS NULL) = (pendiente_desde IS NULL)
                                     AND (metodo_pendiente IS NULL OR metodo_pendiente <> 'totp' OR secreto_pendiente_cifrado IS NOT NULL)),
  CONSTRAINT ck_2fa_activo    CHECK (activo IN (0,1) AND (activo = 0 OR verificado_en IS NOT NULL))
) ENGINE=InnoDB COMMENT='Configuración de segundo factor (TOTP obligatorio para administradores)';

CREATE TABLE IF NOT EXISTS codigo_respaldo_2fa (
  id_codigo_respaldo BIGINT UNSIGNED  NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario         BIGINT UNSIGNED  NOT NULL COMMENT 'Usuario (FK)',
  lote               SMALLINT UNSIGNED NOT NULL COMMENT 'Número de generación (al regenerar se invalida el lote anterior)',
  codigo_hash        CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'SHA-256(pepper + código)',
  usado_en           DATETIME(3)      NULL COMMENT 'Uso (uso único)',
  invalidado_en      DATETIME(3)      NULL COMMENT 'Invalidado por regeneración o desactivación',
  creado_en          DATETIME(3)      NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  PRIMARY KEY (id_codigo_respaldo),
  UNIQUE KEY uq_respaldo_codigo (id_usuario, codigo_hash),
  KEY idx_respaldo_lote (id_usuario, lote),
  CONSTRAINT fk_respaldo_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_respaldo_hash    CHECK (REGEXP_LIKE(codigo_hash, '^[0-9a-f]{64}$', 'c'))
) ENGINE=InnoDB COMMENT='Códigos de respaldo del 2FA (solo hash, uso único)';

-- ---------------------------------------------------------------------
-- CONSENTIMIENTO_DATOS: solo inserción (revocar = nueva fila otorgado=0)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS consentimiento_datos (
  id_consentimiento BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  id_usuario        BIGINT UNSIGNED NULL COMMENT 'Usuario registrado (FK) o NULL si es visitante',
  correo            VARCHAR(254)    NULL COMMENT 'Correo del visitante (si no tiene cuenta)',
  finalidad         ENUM('politica_privacidad','terminos_condiciones','publicidad','formulario_contacto','libro_reclamaciones') NOT NULL COMMENT 'Finalidad aceptada',
  version_documento VARCHAR(20)     NOT NULL COMMENT 'Versión de la política/términos aceptada',
  otorgado          BOOLEAN         NOT NULL COMMENT '1 = acepta, 0 = revoca',
  ip                VARBINARY(16)   NULL COMMENT 'IP',
  user_agent        VARCHAR(255)    NULL COMMENT 'Navegador',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  PRIMARY KEY (id_consentimiento),
  KEY idx_consentimiento_usuario (id_usuario, finalidad, creado_en),
  KEY idx_consentimiento_correo (correo, finalidad),
  CONSTRAINT fk_consentimiento_usuario FOREIGN KEY (id_usuario) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_consentimiento_titular CHECK (id_usuario IS NOT NULL OR correo IS NOT NULL),
  CONSTRAINT ck_consentimiento_bool    CHECK (otorgado IN (0,1))
) ENGINE=InnoDB COMMENT='Consentimientos de tratamiento de datos (Ley 29733): versión, fecha e IP. Solo inserción';

-- ---------------------------------------------------------------------
-- SOLICITUD_ARCO: derechos de acceso, rectificación, cancelación, oposición
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS solicitud_arco (
  id_solicitud      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  numero            VARCHAR(25)     NOT NULL COMMENT 'Correlativo anual ARCO-AAAA-NNNNNN',
  id_usuario        BIGINT UNSIGNED NULL COMMENT 'Usuario titular si tiene cuenta (FK)',
  nombres           VARCHAR(160)    NOT NULL COMMENT 'Nombre del titular',
  tipo_documento    ENUM('DNI','RUC','CE') NOT NULL COMMENT 'Documento del titular',
  numero_documento  VARCHAR(12)     NOT NULL COMMENT 'Número de documento',
  correo            VARCHAR(254)    NOT NULL COMMENT 'Correo de respuesta',
  tipo              ENUM('acceso','rectificacion','cancelacion','oposicion') NOT NULL COMMENT 'Derecho ejercido',
  detalle           TEXT            NOT NULL COMMENT 'Qué solicita',
  estado            ENUM('recibida','en_atencion','atendida','denegada') NOT NULL DEFAULT 'recibida' COMMENT 'Estado',
  fecha_limite      DATE            NOT NULL COMMENT 'Fecha límite de respuesta (día de Lima; plazo configurable, por verificar)',
  respuesta         TEXT            NULL COMMENT 'Respuesta dada al titular',
  atendido_por      BIGINT UNSIGNED NULL COMMENT 'Administrador que atendió (FK)',
  atendido_en       DATETIME(3)     NULL COMMENT 'Fecha de atención (UTC)',
  ip                VARBINARY(16)   NULL COMMENT 'IP',
  creado_en         DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Recepción (UTC)',
  actualizado_en    DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Última modificación (UTC)',
  actualizado_por   BIGINT UNSIGNED NULL COMMENT 'Actor de la última modificación',
  PRIMARY KEY (id_solicitud),
  UNIQUE KEY uq_arco_numero (numero),
  KEY idx_arco_estado (estado, fecha_limite),
  CONSTRAINT fk_arco_usuario        FOREIGN KEY (id_usuario)      REFERENCES usuario (id_usuario),
  CONSTRAINT fk_arco_atendido_por   FOREIGN KEY (atendido_por)    REFERENCES usuario (id_usuario),
  CONSTRAINT fk_arco_actualizado    FOREIGN KEY (actualizado_por) REFERENCES usuario (id_usuario),
  CONSTRAINT ck_arco_detalle        CHECK (CHAR_LENGTH(TRIM(detalle)) >= 10),
  CONSTRAINT ck_arco_atencion       CHECK (estado NOT IN ('atendida','denegada') OR (respuesta IS NOT NULL AND atendido_en IS NOT NULL)),
  CONSTRAINT ck_arco_documento      CHECK (
         (tipo_documento = 'DNI' AND REGEXP_LIKE(numero_documento, '^[0-9]{8}$', 'c'))
      OR (tipo_documento = 'RUC' AND REGEXP_LIKE(numero_documento, '^(10|15|16|17|20)[0-9]{9}$', 'c'))
      OR (tipo_documento = 'CE'  AND REGEXP_LIKE(numero_documento, '^[A-Z0-9]{6,12}$', 'c')))
) ENGINE=InnoDB COMMENT='Solicitudes de derechos ARCO (Ley 29733) con estado y plazo';

-- ---------------------------------------------------------------------
-- AUDITORIA: inmutable, retención mínima 12 meses
-- ---------------------------------------------------------------------
-- Sin llaves foráneas a propósito: el registro debe sobrevivir a cualquier
-- cambio y la tabla queda lista para particionar por fecha (las tablas
-- particionadas de InnoDB no admiten FK). Ver plan en COMPARATIVA_Y_CAMBIOS.md.
CREATE TABLE IF NOT EXISTS auditoria (
  id_auditoria        BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT 'Identificador',
  creado_en           DATETIME(3)     NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Momento (UTC)',
  id_usuario_actor    BIGINT UNSIGNED NULL COMMENT 'Quién hizo la acción (@app_actor_id); NULL = sistema',
  id_usuario_afectado BIGINT UNSIGNED NULL COMMENT 'Usuario afectado, si aplica',
  evento              VARCHAR(60)     NOT NULL COMMENT 'Código del evento (pedido_estado, pago_estado, usuario_inhabilitado...)',
  entidad             VARCHAR(40)     NULL COMMENT 'Tabla o entidad afectada',
  id_entidad          BIGINT UNSIGNED NULL COMMENT 'Id de la fila afectada',
  detalle             JSON            NULL COMMENT 'Detalle del cambio (sin contraseñas, tokens ni datos de tarjeta)',
  ip                  VARBINARY(16)   NULL COMMENT 'IP (si la app la informa en @app_ip)',
  origen              ENUM('app','procedimiento','trigger','evento','dba') NOT NULL DEFAULT 'procedimiento' COMMENT 'Capa que registró el evento',
  usuario_bd          VARCHAR(100)    NULL COMMENT 'Cuenta MySQL que ejecutó (USER())',
  PRIMARY KEY (id_auditoria),
  KEY idx_auditoria_entidad (entidad, id_entidad, creado_en),
  KEY idx_auditoria_evento (evento, creado_en),
  KEY idx_auditoria_afectado (id_usuario_afectado, creado_en),
  KEY idx_auditoria_actor (id_usuario_actor, creado_en),
  KEY idx_auditoria_fecha (creado_en)
) ENGINE=InnoDB COMMENT='Auditoría inmutable (solo inserción). Retención >= 12 meses; borrado solo por DBA y solo de filas más antiguas';

-- ---------------------------------------------------------------------
-- SECRETO_INTERNO: secreto aleatorio de la instalación
-- ---------------------------------------------------------------------
-- Con él se calcula la marca de "contexto interno" (fn_token_interno), que
-- solo pueden fijar los procedimientos de la BD. Ninguna cuenta de la app
-- tiene SELECT sobre esta tabla (ver 07_roles_permisos.sql).
CREATE TABLE IF NOT EXISTS secreto_interno (
  id_secreto  TINYINT UNSIGNED NOT NULL DEFAULT 1 COMMENT 'Siempre 1 (una sola fila)',
  secreto     CHAR(64) CHARACTER SET ascii COLLATE ascii_bin NOT NULL COMMENT 'SHA-256 de 32 bytes aleatorios generados al instalar',
  creado_en   DATETIME(3) NOT NULL DEFAULT (UTC_TIMESTAMP(3)) COMMENT 'Creación (UTC)',
  PRIMARY KEY (id_secreto),
  CONSTRAINT ck_secreto_unico CHECK (id_secreto = 1),
  CONSTRAINT ck_secreto_hex   CHECK (REGEXP_LIKE(secreto, '^[0-9a-f]{64}$', 'c'))
) ENGINE=InnoDB COMMENT='Secreto por instalación para la marca de contexto interno. Solo lo leen wanka_definer y el DBA';
INSERT IGNORE INTO secreto_interno (id_secreto, secreto) VALUES (1, SHA2(RANDOM_BYTES(32), 256));

SELECT 'Esquema de acceso listo: continúa con 02_esquema_tienda.sql' AS siguiente_paso;
