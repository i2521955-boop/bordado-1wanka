# Diccionario de datos — Bordados Wanka S.A.C. (MySQL 8)

> Generado automáticamente desde `information_schema` con `scripts/generar_documentacion.py`. No editar a mano: cambie el `COMMENT` en el SQL y regenere.

Base: `bordados_wanka` · 64 tablas · 42 vistas · 149 procedimientos · 30 funciones · 161 triggers · 5 eventos

Convenciones: fechas en UTC (`DATETIME(3)`), las vistas convierten a Lima; `∅` = sin valor por defecto; **Clave** PRI = llave primaria, UNI = única, MUL = índice/llave foránea. La columna **Referencia** usa las secciones del prompt (§) y los códigos HU/RF/RNF citados; el resto de la trazabilidad está en `TRAZABILIDAD_HU_RF_RNF.md`.

## Índice

- **Acceso y seguridad**: [rol](#rol), [usuario](#usuario), [sesion](#sesion), [intento_acceso](#intento_acceso), [codigo_verificacion](#codigo_verificacion), [historial_contrasena](#historial_contrasena), [autenticacion_2fa](#autenticacion_2fa), [codigo_respaldo_2fa](#codigo_respaldo_2fa), [consentimiento_datos](#consentimiento_datos), [solicitud_arco](#solicitud_arco), [auditoria](#auditoria), [secreto_interno](#secreto_interno)
- **Sistema e integraciones**: [configuracion](#configuracion), [secuencia_documento](#secuencia_documento), [catalogo_error](#catalogo_error), [control_frecuencia](#control_frecuencia), [cola_correo](#cola_correo), [notificacion](#notificacion), [log_api_externa](#log_api_externa), [consulta_documento](#consulta_documento)
- **Catálogo**: [categoria](#categoria), [producto](#producto), [variante_producto](#variante_producto), [imagen_producto](#imagen_producto), [precio_volumen](#precio_volumen), [favorito](#favorito), [resena](#resena), [banner](#banner)
- **Inventario e insumos**: [reserva_stock](#reserva_stock), [movimiento_stock](#movimiento_stock), [insumo](#insumo), [movimiento_insumo](#movimiento_insumo), [receta_producto](#receta_producto)
- **Compra y pedidos**: [carrito](#carrito), [item_carrito](#item_carrito), [zona_envio](#zona_envio), [direccion](#direccion), [estado_pedido](#estado_pedido), [transicion_estado_pedido](#transicion_estado_pedido), [pedido](#pedido), [item_pedido](#item_pedido), [historial_estado_pedido](#historial_estado_pedido), [devolucion](#devolucion), [devolucion_item](#devolucion_item)
- **Cotizaciones**: [cotizacion](#cotizacion), [item_cotizacion](#item_cotizacion), [transicion_estado_cotizacion](#transicion_estado_cotizacion)
- **Envíos**: [courier](#courier), [envio](#envio), [seguimiento_envio](#seguimiento_envio)
- **Pagos y reembolsos**: [metodo_pago](#metodo_pago), [pago](#pago), [transicion_estado_pago](#transicion_estado_pago), [reembolso](#reembolso), [evento_pasarela](#evento_pasarela)
- **Comprobantes electrónicos**: [serie_comprobante](#serie_comprobante), [motivo_nota_credito](#motivo_nota_credito), [comprobante](#comprobante), [comprobante_item](#comprobante_item), [comprobante_archivo](#comprobante_archivo), [cola_emision_comprobante](#cola_emision_comprobante)
- **Atención al cliente**: [mensaje_contacto](#mensaje_contacto), [reclamo](#reclamo), [respuesta_atencion](#respuesta_atencion)
- [Vistas](#vistas) · [Procedimientos y funciones](#procedimientos-y-funciones) · [Eventos](#eventos)


## Acceso y seguridad

### rol

Roles del sistema (solo administrador y cliente). RF de acceso / HU de login

**Referencia:** §1 roles administrador/cliente; §6

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_rol` | tinyint unsigned | no | AUTO_INCREMENT | PRI | Identificador del rol |
| `codigo` | varchar(20) | no | ∅ | UNI | Código interno: administrador \| cliente |
| `nombre` | varchar(40) | no | ∅ |  | Nombre visible del rol |
| `descripcion` | varchar(200) | sí | ∅ |  | Descripción del alcance del rol |
| `requiere_2fa` | tinyint(1) | no | 0 |  | 1 = el rol debe usar segundo factor (TOTP obligatorio para administradores) |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_rol_bool`: `((requiere_2fa in (0,1)) and (activo in (0,1)))`
- `ck_rol_codigo`: `(codigo in ('administrador','cliente'))`

**Índices**: `PRIMARY` (único: id_rol); `uq_rol_codigo` (único: codigo)

**Triggers**: `trg_rol_bu` (BEFORE UPDATE), `trg_rol_bd` (BEFORE DELETE)

### usuario

Usuarios (administradores y clientes). Nunca se borran: se inhabilitan. Ley 29733: solo datos necesarios

**Referencia:** §4 acceso; §2.4 validación de documentos; §2.6 inhabilitar; Ley 29733

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_usuario` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador del usuario |
| `id_rol` | tinyint unsigned | no | ∅ | MUL | Rol (FK rol) |
| `correo` | varchar(254) | no | ∅ | UNI | Correo de acceso, normalizado (trim + minúsculas); único |
| `hash_contrasena` | varchar(255) | no | ∅ |  | Hash generado por Django (PBKDF2-SHA256 / Argon2); nunca texto plano. "!" = sin contraseña utilizable |
| `nombres` | varchar(80) | no | ∅ |  | Nombres |
| `apellidos` | varchar(80) | no | ∅ |  | Apellidos |
| `nombre_completo` | varchar(161) | sí | GENERADA: `concat_ws(' ',nombres,apellidos)` |  | Nombres + apellidos (calculado) |
| `celular` | varchar(16) | sí | ∅ |  | Celular, solo dígitos con + opcional (9 a 15 dígitos) |
| `tipo_documento` | enum('DNI','RUC','CE') | sí | ∅ | MUL | Tipo de documento (opcional; se pide al facturar) |
| `numero_documento` | varchar(12) | sí | ∅ |  | Número de documento: DNI 8 dígitos, RUC 11 (10/15/16/17/20 + dígito verificador), CE 6-12 alfanum. |
| `estado` | enum('pendiente_verificacion','activo','inhabilitado') | no | pendiente_verificacion |  | Estado de la cuenta. Inhabilitado = borrado lógico |
| `correo_verificado_en` | datetime(3) | sí | ∅ |  | Cuándo verificó su correo con código |
| `intentos_fallidos` | tinyint unsigned | no | 0 |  | Intentos de acceso fallidos consecutivos |
| `bloqueado_hasta` | datetime(3) | sí | ∅ |  | Bloqueo temporal por intentos fallidos (UTC) |
| `ultimo_acceso_en` | datetime(3) | sí | ∅ |  | Último acceso exitoso |
| `contrasena_cambiada_en` | datetime(3) | sí | ∅ |  | Último cambio de contraseña |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó (FK usuario) |
| `motivo_inhabilitacion` | varchar(200) | sí | ∅ |  | Motivo de la inhabilitación |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó (@app_actor_id) |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó (@app_actor_id) |

**Restricciones CHECK**

- `ck_usuario_celular`: `((celular is null) or regexp_like(celular,'^[+]?[0-9]{9,15}$','c'))`
- `ck_usuario_correo_formato`: `regexp_like(correo,'^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$','c')`
- `ck_usuario_correo_normal`: `(cast(correo as char charset binary) = cast(lower(trim(correo)) as char charset binary))`
- `ck_usuario_documento`: `(((tipo_documento is null) and (numero_documento is null)) or ((tipo_documento = 'DNI') and regexp_like(numero_documento,'^[0-9]{8}$','c')) or ((tipo_documento = 'RUC') and regexp_like(numero_documento,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')) or ((tipo_documento = 'CE') and regexp_like(numero_documento,'^[A-Z0-9]{6,12}$','c')))`
- `ck_usuario_hash`: `((char_length(hash_contrasena) >= 20) and regexp_like(hash_contrasena,'^(pbkdf2_sha256\|pbkdf2_sha1\|argon2\|bcrypt_sha256\|bcrypt\|scrypt)[$]\|^!','c'))`
- `ck_usuario_inhabilitado`: `((estado = 'inhabilitado') = (inhabilitado_en is not null))`
- `ck_usuario_intentos`: `(intentos_fallidos <= 50)`
- `ck_usuario_nombres`: `((char_length(trim(nombres)) >= 2) and (char_length(trim(apellidos)) >= 2))`
- `ck_usuario_verificado`: `((estado <> 'activo') or (correo_verificado_en is not null))`

**Llaves foráneas**

- `fk_usuario_actualizado_por`: (actualizado_por) → `usuario`(id_usuario)
- `fk_usuario_creado_por`: (creado_por) → `usuario`(id_usuario)
- `fk_usuario_inhabilitado_por`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_usuario_rol`: (id_rol) → `rol`(id_rol)

**Índices**: `fk_usuario_actualizado_por` (normal: actualizado_por); `fk_usuario_creado_por` (normal: creado_por); `fk_usuario_inhabilitado_por` (normal: inhabilitado_por); `idx_usuario_documento` (normal: tipo_documento, numero_documento); `idx_usuario_rol_estado` (normal: id_rol, estado); `PRIMARY` (único: id_usuario); `uq_usuario_correo` (único: correo)

**Triggers**: `trg_usuario_bi` (BEFORE INSERT), `trg_usuario_bu` (BEFORE UPDATE), `trg_usuario_bd` (BEFORE DELETE), `trg_usuario_au` (AFTER UPDATE)

### sesion

Sesiones abiertas/cerradas por usuario (auditoría de accesos y cierre remoto)

**Referencia:** §4 acceso (sesiones y cierre remoto)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_sesion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador de la sesión |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Usuario (FK) |
| `token_hash` | char(64) | no | ∅ | UNI | SHA-256 de la clave de sesión (nunca la clave en claro) |
| `ip` | varbinary(16) | sí | ∅ |  | IP de origen (INET6_ATON) |
| `user_agent` | varchar(255) | sí | ∅ |  | Navegador / dispositivo (recortado) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Inicio (UTC) |
| `ultima_actividad_en` | datetime(3) | no | utc_timestamp(3) |  | Última actividad (UTC) |
| `expira_en` | datetime(3) | no | ∅ |  | Expiración absoluta (UTC) |
| `cerrada_en` | datetime(3) | sí | ∅ | MUL | Cierre (UTC) |
| `motivo_cierre` | enum('logout','expirada','revocada','cambio_contrasena','inhabilitacion') | sí | ∅ |  | Motivo del cierre |

**Restricciones CHECK**

- `ck_sesion_cierre`: `((cerrada_en is null) = (motivo_cierre is null))`
- `ck_sesion_fechas`: `(expira_en > creado_en)`
- `ck_sesion_token`: `regexp_like(token_hash,'^[0-9a-f]{64}$','c')`

**Llaves foráneas**

- `fk_sesion_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_sesion_expira` (normal: cerrada_en, expira_en); `idx_sesion_usuario` (normal: id_usuario, cerrada_en); `PRIMARY` (único: id_sesion); `uq_sesion_token` (único: token_hash)

**Triggers**: `trg_sesion_bu` (BEFORE UPDATE)

### intento_acceso

Bitácora de intentos de acceso (solo inserción; retención configurable >= 12 meses)

**Referencia:** §6 bloqueo tras 5 intentos (15 min)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_intento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `correo_intentado` | varchar(254) | no | ∅ | MUL | Correo escrito (normalizado) |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario si existe (FK) |
| `ip` | varbinary(16) | sí | ∅ | MUL | IP de origen |
| `user_agent` | varchar(255) | sí | ∅ |  | Navegador |
| `exitoso` | tinyint(1) | no | ∅ |  | 1 = acceso concedido |
| `resultado` | enum('ok','requiere_2fa','credenciales_invalidas','usuario_inexistente','cuenta_bloqueada','bloqueada_ahora','cuenta_inhabilitada','correo_no_verificado','segundo_factor_fallido','ip_bloqueada') | no | ∅ |  | Resultado del intento |
| `creado_en` | datetime(3) | no | utc_timestamp(3) | MUL | Momento (UTC) |

**Restricciones CHECK**

- `ck_intento_exitoso`: `((exitoso in (0,1)) and ((exitoso = 1) = (resultado in ('ok','requiere_2fa'))))`

**Llaves foráneas**

- `fk_intento_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_intento_correo` (normal: correo_intentado, creado_en); `idx_intento_fecha` (normal: creado_en); `idx_intento_ip` (normal: ip, creado_en); `idx_intento_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_intento)

**Triggers**: `trg_intento_acceso_bu` (BEFORE UPDATE), `trg_intento_acceso_bd` (BEFORE DELETE)

### codigo_verificacion

Códigos de verificación por correo: aleatorios (RANDOM_BYTES), solo hash, 5 min, uso único, 5 intentos, 5 por hora. HU-02

**Referencia:** §2.7 códigos por correo; HU-02 (Excel dice 10 min, se aplica 5)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_codigo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario dueño del código (FK) |
| `correo_destino` | varchar(254) | no | ∅ | MUL | Correo al que se envió (normalizado) |
| `proposito` | enum('verificar_correo','iniciar_sesion','recuperar_contrasena','cambiar_contrasena','cambiar_correo','segundo_factor') | no | ∅ |  | Para qué sirve el código |
| `codigo_hash` | char(64) | no | ∅ |  | SHA-256(pepper + código). El código en claro NUNCA se guarda |
| `estado` | enum('activo','usado','expirado','bloqueado','reemplazado') | no | activo | MUL | Ciclo de vida |
| `intentos` | tinyint unsigned | no | 0 |  | Intentos fallidos de verificación |
| `max_intentos` | tinyint unsigned | no | 5 |  | Tope de intentos (máx. 5) |
| `hash_vigente` | char(64) | sí | GENERADA: `if((estado = 'activo'),codigo_hash,NULL)` | UNI | Solo tiene valor si está activo: el índice único impide dos códigos vigentes iguales |
| `ip` | varbinary(16) | sí | ∅ |  | IP que lo solicitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Generación (UTC) |
| `expira_en` | datetime(3) | no | ∅ |  | Vencimiento (máx. 5 minutos después de creado_en) |
| `usado_en` | datetime(3) | sí | ∅ |  | Uso exitoso (uso único) |
| `cerrado_en` | datetime(3) | sí | ∅ |  | Cuándo dejó de estar activo por expiración, bloqueo o reemplazo |

**Restricciones CHECK**

- `ck_codigo_correo`: `regexp_like(correo_destino,'^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$','c')`
- `ck_codigo_hash`: `regexp_like(codigo_hash,'^[0-9a-f]{64}$','c')`
- `ck_codigo_intentos`: `((max_intentos between 1 and 5) and (intentos <= max_intentos))`
- `ck_codigo_usado`: `((estado = 'usado') = (usado_en is not null))`
- `ck_codigo_vigencia`: `((expira_en > creado_en) and (timestampdiff(SECOND,creado_en,expira_en) <= 300))`

**Llaves foráneas**

- `fk_codigo_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_codigo_correo` (normal: correo_destino, proposito, creado_en); `idx_codigo_estado` (normal: estado, expira_en); `idx_codigo_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_codigo); `uq_codigo_vigente` (único: hash_vigente)

**Triggers**: `trg_codigo_verificacion_bi` (BEFORE INSERT), `trg_codigo_verificacion_bu` (BEFORE UPDATE), `trg_codigo_verificacion_bd` (BEFORE DELETE)

### historial_contrasena

Historial de hashes de contraseña (la app compara la nueva contra las 3 últimas con check_password)

**Referencia:** §4 no reutilizar las últimas 3

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_historial` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Usuario (FK) |
| `hash_contrasena` | varchar(255) | no | ∅ |  | Hash que tuvo el usuario (para impedir reutilizar las últimas 3) |
| `origen` | enum('registro','cambio','recuperacion','administrador') | no | ∅ |  | Cómo se fijó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Llaves foráneas**

- `fk_historial_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_historial_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_historial)

**Triggers**: `trg_historial_contrasena_bu` (BEFORE UPDATE), `trg_historial_contrasena_bd` (BEFORE DELETE)

### autenticacion_2fa

Configuración de segundo factor (TOTP obligatorio para administradores)

**Referencia:** §4 TOTP obligatorio para administradores

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_usuario` | bigint unsigned | no | ∅ | PRI | Usuario (PK y FK) |
| `metodo` | enum('totp','correo') | no | totp |  | Segundo factor: TOTP (app autenticadora) o código por correo |
| `secreto_cifrado` | varbinary(512) | sí | ∅ |  | Secreto TOTP cifrado POR LA APLICACIÓN (Fernet/AES-GCM, clave fuera de la BD) |
| `activo` | tinyint(1) | no | 0 |  | 1 = segundo factor en uso |
| `verificado_en` | datetime(3) | sí | ∅ |  | Cuándo se confirmó la configuración |
| `ultimo_paso_totp` | bigint unsigned | sí | ∅ |  | Último paso TOTP aceptado (evita reutilizar el mismo código) |
| `ultimo_uso_en` | datetime(3) | sí | ∅ |  | Último uso exitoso |
| `desactivado_en` | datetime(3) | sí | ∅ |  | Cuándo se desactivó |
| `metodo_pendiente` | enum('totp','correo') | sí | ∅ |  | Reconfiguración en curso: el 2FA actual sigue activo hasta confirmar la nueva |
| `secreto_pendiente_cifrado` | varbinary(512) | sí | ∅ |  | Secreto TOTP nuevo (cifrado por la app) pendiente de confirmar |
| `pendiente_desde` | datetime(3) | sí | ∅ |  | Desde cuándo hay una reconfiguración pendiente |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_2fa_activo`: `((activo in (0,1)) and ((activo = 0) or (verificado_en is not null)))`
- `ck_2fa_pendiente`: `(((metodo_pendiente is null) = (pendiente_desde is null)) and ((metodo_pendiente is null) or (metodo_pendiente <> 'totp') or (secreto_pendiente_cifrado is not null)))`
- `ck_2fa_secreto`: `((metodo <> 'totp') or (secreto_cifrado is not null))`

**Llaves foráneas**

- `fk_2fa_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `PRIMARY` (único: id_usuario)

**Triggers**: `trg_autenticacion_2fa_bu` (BEFORE UPDATE), `trg_autenticacion_2fa_bd` (BEFORE DELETE)

### codigo_respaldo_2fa

Códigos de respaldo del 2FA (solo hash, uso único)

**Referencia:** §4 2FA

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_codigo_respaldo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Usuario (FK) |
| `lote` | smallint unsigned | no | ∅ |  | Número de generación (al regenerar se invalida el lote anterior) |
| `codigo_hash` | char(64) | no | ∅ |  | SHA-256(pepper + código) |
| `usado_en` | datetime(3) | sí | ∅ |  | Uso (uso único) |
| `invalidado_en` | datetime(3) | sí | ∅ |  | Invalidado por regeneración o desactivación |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |

**Restricciones CHECK**

- `ck_respaldo_hash`: `regexp_like(codigo_hash,'^[0-9a-f]{64}$','c')`

**Llaves foráneas**

- `fk_respaldo_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_respaldo_lote` (normal: id_usuario, lote); `PRIMARY` (único: id_codigo_respaldo); `uq_respaldo_codigo` (único: id_usuario, codigo_hash)

**Triggers**: `trg_codigo_respaldo_2fa_bu` (BEFORE UPDATE), `trg_codigo_respaldo_2fa_bd` (BEFORE DELETE)

### consentimiento_datos

Consentimientos de tratamiento de datos (Ley 29733): versión, fecha e IP. Solo inserción

**Referencia:** §4 consentimiento (Ley 29733)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_consentimiento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario registrado (FK) o NULL si es visitante |
| `correo` | varchar(254) | sí | ∅ | MUL | Correo del visitante (si no tiene cuenta) |
| `finalidad` | enum('politica_privacidad','terminos_condiciones','publicidad','formulario_contacto','libro_reclamaciones') | no | ∅ |  | Finalidad aceptada |
| `version_documento` | varchar(20) | no | ∅ |  | Versión de la política/términos aceptada |
| `otorgado` | tinyint(1) | no | ∅ |  | 1 = acepta, 0 = revoca |
| `ip` | varbinary(16) | sí | ∅ |  | IP |
| `user_agent` | varchar(255) | sí | ∅ |  | Navegador |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Restricciones CHECK**

- `ck_consentimiento_bool`: `(otorgado in (0,1))`
- `ck_consentimiento_titular`: `((id_usuario is not null) or (correo is not null))`

**Llaves foráneas**

- `fk_consentimiento_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_consentimiento_correo` (normal: correo, finalidad); `idx_consentimiento_usuario` (normal: id_usuario, finalidad, creado_en); `PRIMARY` (único: id_consentimiento)

**Triggers**: `trg_consentimiento_datos_bi` (BEFORE INSERT), `trg_consentimiento_datos_bu` (BEFORE UPDATE), `trg_consentimiento_datos_bd` (BEFORE DELETE)

### solicitud_arco

Solicitudes de derechos ARCO (Ley 29733) con estado y plazo

**Referencia:** §4 derechos ARCO (Ley 29733)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_solicitud` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `numero` | varchar(25) | no | ∅ | UNI | Correlativo anual ARCO-AAAA-NNNNNN |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario titular si tiene cuenta (FK) |
| `nombres` | varchar(160) | no | ∅ |  | Nombre del titular |
| `tipo_documento` | enum('DNI','RUC','CE') | no | ∅ |  | Documento del titular |
| `numero_documento` | varchar(12) | no | ∅ |  | Número de documento |
| `correo` | varchar(254) | no | ∅ |  | Correo de respuesta |
| `tipo` | enum('acceso','rectificacion','cancelacion','oposicion') | no | ∅ |  | Derecho ejercido |
| `detalle` | text | no | ∅ |  | Qué solicita |
| `estado` | enum('recibida','en_atencion','atendida','denegada') | no | recibida | MUL | Estado |
| `fecha_limite` | date | no | ∅ |  | Fecha límite de respuesta (día de Lima; plazo configurable, por verificar) |
| `respuesta` | text | sí | ∅ |  | Respuesta dada al titular |
| `atendido_por` | bigint unsigned | sí | ∅ | MUL | Administrador que atendió (FK) |
| `atendido_en` | datetime(3) | sí | ∅ |  | Fecha de atención (UTC) |
| `ip` | varbinary(16) | sí | ∅ |  | IP |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Recepción (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor de la última modificación |

**Restricciones CHECK**

- `ck_arco_atencion`: `((estado not in ('atendida','denegada')) or ((respuesta is not null) and (atendido_en is not null)))`
- `ck_arco_detalle`: `(char_length(trim(detalle)) >= 10)`
- `ck_arco_documento`: `(((tipo_documento = 'DNI') and regexp_like(numero_documento,'^[0-9]{8}$','c')) or ((tipo_documento = 'RUC') and regexp_like(numero_documento,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')) or ((tipo_documento = 'CE') and regexp_like(numero_documento,'^[A-Z0-9]{6,12}$','c')))`

**Llaves foráneas**

- `fk_arco_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_arco_atendido_por`: (atendido_por) → `usuario`(id_usuario)
- `fk_arco_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_arco_actualizado` (normal: actualizado_por); `fk_arco_atendido_por` (normal: atendido_por); `fk_arco_usuario` (normal: id_usuario); `idx_arco_estado` (normal: estado, fecha_limite); `PRIMARY` (único: id_solicitud); `uq_arco_numero` (único: numero)

**Triggers**: `trg_solicitud_arco_bi` (BEFORE INSERT), `trg_solicitud_arco_bu` (BEFORE UPDATE), `trg_solicitud_arco_bd` (BEFORE DELETE)

### auditoria

Auditoría inmutable (solo inserción). Retención >= 12 meses; borrado solo por DBA y solo de filas más antiguas

**Referencia:** §4 auditoría inmutable, retención >= 12 meses; §2.5

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_auditoria` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `creado_en` | datetime(3) | no | utc_timestamp(3) | MUL | Momento (UTC) |
| `id_usuario_actor` | bigint unsigned | sí | ∅ | MUL | Quién hizo la acción (@app_actor_id); NULL = sistema |
| `id_usuario_afectado` | bigint unsigned | sí | ∅ | MUL | Usuario afectado, si aplica |
| `evento` | varchar(60) | no | ∅ | MUL | Código del evento (pedido_estado, pago_estado, usuario_inhabilitado...) |
| `entidad` | varchar(40) | sí | ∅ | MUL | Tabla o entidad afectada |
| `id_entidad` | bigint unsigned | sí | ∅ |  | Id de la fila afectada |
| `detalle` | json | sí | ∅ |  | Detalle del cambio (sin contraseñas, tokens ni datos de tarjeta) |
| `ip` | varbinary(16) | sí | ∅ |  | IP (si la app la informa en @app_ip) |
| `origen` | enum('app','procedimiento','trigger','evento','dba') | no | procedimiento |  | Capa que registró el evento |
| `usuario_bd` | varchar(100) | sí | ∅ |  | Cuenta MySQL que ejecutó (USER()) |

**Índices**: `idx_auditoria_actor` (normal: id_usuario_actor, creado_en); `idx_auditoria_afectado` (normal: id_usuario_afectado, creado_en); `idx_auditoria_entidad` (normal: entidad, id_entidad, creado_en); `idx_auditoria_evento` (normal: evento, creado_en); `idx_auditoria_fecha` (normal: creado_en); `PRIMARY` (único: id_auditoria)

**Triggers**: `trg_auditoria_bu` (BEFORE UPDATE), `trg_auditoria_bd` (BEFORE DELETE)

### secreto_interno

Secreto por instalación para la marca de contexto interno. Solo lo leen wanka_definer y el DBA

**Referencia:** Seguridad: marca de contexto interno no falsificable (solo la leen los procedimientos)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_secreto` | tinyint unsigned | no | 1 | PRI | Siempre 1 (una sola fila) |
| `secreto` | char(64) | no | ∅ |  | SHA-256 de 32 bytes aleatorios generados al instalar |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |

**Restricciones CHECK**

- `ck_secreto_hex`: `regexp_like(secreto,'^[0-9a-f]{64}$','c')`
- `ck_secreto_unico`: `(id_secreto = 1)`

**Índices**: `PRIMARY` (único: id_secreto)


## Sistema e integraciones

### configuracion

Parámetros del negocio validados por tipo y rango (cambios auditados)

**Referencia:** §4 sistema; §2.2 adelanto; §2.7 minutos del código; §2.8 umbral de boleta

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `clave` | varchar(60) | no | ∅ | PRI | Clave única (snake_case) |
| `valor` | varchar(500) | no | ∅ |  | Valor como texto; se valida por tipo y rango (trigger) |
| `tipo` | enum('entero','decimal','texto','booleano','opcion','ruc','correo') | no | ∅ |  | Tipo de dato esperado |
| `valor_minimo` | decimal(14,4) | sí | ∅ |  | Mínimo permitido (numéricos) |
| `valor_maximo` | decimal(14,4) | sí | ∅ |  | Máximo permitido (numéricos) |
| `opciones` | varchar(200) | sí | ∅ |  | Valores permitidos separados por coma (tipo opcion) |
| `descripcion` | varchar(250) | no | ∅ |  | Para qué sirve |
| `editable` | tinyint(1) | no | 1 |  | 0 = solo DBA |
| `por_verificar` | tinyint(1) | no | 0 |  | 1 = valor provisional, confirmar con SUNAT/INDECOPI/gerente |
| `nota_verificacion` | varchar(250) | sí | ∅ |  | Con quién o qué hay que verificarlo |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor de la última modificación (FK usuario) |

**Restricciones CHECK**

- `ck_config_bool`: `((editable in (0,1)) and (por_verificar in (0,1)))`
- `ck_config_clave`: `regexp_like(clave,'^[a-z][a-z0-9_]{2,59}$','c')`
- `ck_config_opcion`: `((tipo <> 'opcion') or (opciones is not null))`
- `ck_config_rango`: `((valor_minimo is null) or (valor_maximo is null) or (valor_minimo <= valor_maximo))`

**Llaves foráneas**

- `fk_config_actualizado`: (actualizado_por) → `usuario`(id_usuario)

**Índices**: `fk_config_actualizado` (normal: actualizado_por); `PRIMARY` (único: clave)

**Triggers**: `trg_configuracion_bi` (BEFORE INSERT), `trg_configuracion_bu` (BEFORE UPDATE), `trg_configuracion_bd` (BEFORE DELETE), `trg_configuracion_au` (AFTER UPDATE)

### secuencia_documento

Correlativos por año sin saltos (transaccionales, a diferencia de AUTO_INCREMENT)

**Referencia:** §5.10-11 correlativos sin saltos

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `prefijo` | varchar(12) | no | ∅ | PRI | Prefijo del correlativo (BW, BW-MAY, CT, TK, LR, DV, ARCO) |
| `anio` | smallint unsigned | no | ∅ | PRI | Año (calendario de Lima) |
| `ultimo` | int unsigned | no | 0 |  | Último número entregado |

**Restricciones CHECK**

- `ck_secuencia_anio`: `(anio between 2024 and 2200)`

**Índices**: `PRIMARY` (único: prefijo, anio)

**Triggers**: `trg_secuencia_documento_bu` (BEFORE UPDATE), `trg_secuencia_documento_bd` (BEFORE DELETE)

### catalogo_error

Catálogo de errores propios para que Django los traduzca a mensajes claros

**Referencia:** §3.1 SIGNAL con códigos propios; RNF 20

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `codigo` | smallint unsigned | no | ∅ | PRI | MYSQL_ERRNO devuelto por SIGNAL (45001..45099) |
| `nombre` | varchar(60) | no | ∅ | UNI | Nombre técnico |
| `mensaje_usuario` | varchar(200) | no | ∅ |  | Mensaje sugerido para mostrar en la app (RNF 20) |
| `http_sugerido` | smallint unsigned | no | 400 |  | Código HTTP sugerido para la API |

**Restricciones CHECK**

- `ck_error_rango`: `(codigo between 45000 and 45999)`

**Índices**: `PRIMARY` (único: codigo); `uq_error_nombre` (único: nombre)

**Triggers**: `trg_catalogo_error_bd` (BEFORE DELETE)

### control_frecuencia

Filas de bloqueo para serializar límites de frecuencia concurrentes (SELECT ... FOR UPDATE)

**Referencia:** §5.10 límites de frecuencia; §7.12 concurrencia

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `ambito` | varchar(30) | no | ∅ | PRI | Qué se limita (contacto_ip, codigo_correo, reclamo_ip...) |
| `clave` | varchar(254) | no | ∅ | PRI | Sujeto limitado (IP en texto, correo...) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Primera vez que se vio |

**Índices**: `PRIMARY` (único: ambito, clave)

### cola_correo

Cola de correos con reintentos (el envío lo hace la app por SMTP o servicio transaccional). RNF 18

**Referencia:** §2.7 envío de correos; RNF 18

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_correo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Destinatario registrado (FK) |
| `destinatario` | varchar(254) | no | ∅ |  | Correo destino (normalizado) |
| `plantilla` | varchar(60) | no | ∅ |  | Plantilla de la app (pedido_confirmado, ...) |
| `contexto` | json | sí | ∅ |  | Datos para la plantilla. Nunca códigos de verificación ni contraseñas |
| `prioridad` | tinyint unsigned | no | 5 |  | 1 = más urgente |
| `estado` | enum('pendiente','procesando','enviado','error','descartado') | no | pendiente | MUL | Estado |
| `intentos` | smallint unsigned | no | 0 |  | Intentos de envío |
| `max_intentos` | smallint unsigned | no | 5 |  | Tope de intentos |
| `proximo_intento_en` | datetime(3) | no | utc_timestamp(3) |  | No antes de (backoff) |
| `ultimo_error` | varchar(500) | sí | ∅ |  | Último error SMTP/API |
| `id_mensaje_proveedor` | varchar(150) | sí | ∅ |  | Id devuelto por el servidor de correo |
| `tomado_por` | varchar(64) | sí | ∅ |  | Worker que lo tomó |
| `enviado_en` | datetime(3) | sí | ∅ |  | Envío (UTC) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_cola_correo_destino`: `regexp_like(destinatario,'^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$','c')`
- `ck_cola_correo_enviado`: `((estado = 'enviado') = (enviado_en is not null))`
- `ck_cola_correo_intentos`: `((intentos <= max_intentos) and (prioridad between 1 and 9))`

**Llaves foráneas**

- `fk_cola_correo_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_cola_correo` (normal: estado, prioridad, proximo_intento_en); `idx_cola_correo_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_correo)

**Triggers**: `trg_cola_correo_bi` (BEFORE INSERT), `trg_cola_correo_bu` (BEFORE UPDATE)

### notificacion

Notificaciones dentro del sistema

**Referencia:** §5.7 avisos al cliente

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_notificacion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Destinatario (FK) |
| `tipo` | varchar(40) | no | ∅ |  | Tipo (pedido_confirmado, stock_bajo, ...) |
| `titulo` | varchar(120) | no | ∅ |  | Título |
| `mensaje` | varchar(300) | sí | ∅ |  | Mensaje |
| `enlace` | varchar(300) | sí | ∅ |  | Ruta dentro del sistema |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido relacionado (FK) |
| `leida` | tinyint(1) | no | 0 |  | 1 = leída |
| `leida_en` | datetime(3) | sí | ∅ |  | Cuándo se leyó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |

**Restricciones CHECK**

- `ck_notificacion_leida`: `((leida in (0,1)) and ((leida = 1) = (leida_en is not null)))`

**Llaves foráneas**

- `fk_notificacion_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_notificacion_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_notificacion_pedido` (normal: id_pedido); `idx_notificacion_usuario` (normal: id_usuario, leida, creado_en); `PRIMARY` (único: id_notificacion)

**Triggers**: `trg_notificacion_bu` (BEFORE UPDATE)

### log_api_externa

Bitácora de llamadas a APIs externas (solo inserción; retención configurable)

**Referencia:** §2.10 bitácora de APIs externas

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_log` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `creado_en` | datetime(3) | no | utc_timestamp(3) | MUL | Momento de la llamada (UTC) |
| `proveedor` | enum('ose','reniec','sunat_ruc','mercadopago','paypal','courier','correo','otro') | no | ∅ | MUL | API externa |
| `endpoint` | varchar(300) | no | ∅ |  | Ruta llamada (sin tokens en la URL) |
| `metodo_http` | enum('GET','POST','PUT','PATCH','DELETE') | no | ∅ |  | Método HTTP |
| `codigo_http` | smallint unsigned | sí | ∅ |  | Código HTTP (NULL = sin respuesta / timeout) |
| `duracion_ms` | int unsigned | sí | ∅ |  | Duración en milisegundos |
| `exitoso` | tinyint(1) | no | ∅ |  | 1 = respuesta exitosa |
| `request_enmascarado` | json | sí | ∅ |  | Petición con datos sensibles enmascarados |
| `response_enmascarado` | json | sí | ∅ |  | Respuesta con datos sensibles enmascarados |
| `correlacion_id` | varchar(64) | sí | ∅ | MUL | Id de correlación (traza) |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido relacionado |
| `id_comprobante` | bigint unsigned | sí | ∅ | MUL | Comprobante relacionado |
| `id_pago` | bigint unsigned | sí | ∅ |  | Pago relacionado |
| `error` | varchar(500) | sí | ∅ |  | Error |

**Restricciones CHECK**

- `ck_log_api_codigo`: `((codigo_http is null) or (codigo_http between 100 and 599))`
- `ck_log_api_exitoso`: `(exitoso in (0,1))`

**Índices**: `idx_log_api_comprobante` (normal: id_comprobante); `idx_log_api_correlacion` (normal: correlacion_id); `idx_log_api_fecha` (normal: creado_en); `idx_log_api_pedido` (normal: id_pedido); `idx_log_api_proveedor` (normal: proveedor, creado_en); `PRIMARY` (único: id_log)

**Triggers**: `trg_log_api_externa_bu` (BEFORE UPDATE), `trg_log_api_externa_bd` (BEFORE DELETE)

### consulta_documento

Caché de consultas DNI/RUC (RENIEC/SUNAT) para autocompletar nombre y razón social

**Referencia:** §2.10 caché RENIEC/SUNAT

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_consulta` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `tipo_documento` | enum('DNI','RUC') | no | ∅ | MUL | Tipo consultado |
| `numero` | varchar(11) | no | ∅ |  | Número consultado |
| `nombre_razon_social` | varchar(200) | sí | ∅ |  | Nombre (DNI) o razón social (RUC) |
| `estado_contribuyente` | varchar(30) | sí | ∅ |  | RUC: ACTIVO, BAJA... |
| `condicion_domicilio` | varchar(30) | sí | ∅ |  | RUC: HABIDO, NO HABIDO... |
| `domicilio_fiscal` | varchar(300) | sí | ∅ |  | RUC: domicilio fiscal (no se guarda domicilio de personas por DNI) |
| `fuente` | varchar(40) | no | ∅ |  | Proveedor de la consulta |
| `exitosa` | tinyint(1) | no | ∅ |  | 1 = se encontró |
| `consultado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |
| `vigente_hasta` | datetime(3) | no | ∅ | MUL | Hasta cuándo se usa la caché (UTC) |

**Restricciones CHECK**

- `ck_consulta_numero`: `(((tipo_documento = 'DNI') and regexp_like(numero,'^[0-9]{8}$','c')) or ((tipo_documento = 'RUC') and regexp_like(numero,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')))`
- `ck_consulta_vigencia`: `((vigente_hasta > consultado_en) and (exitosa in (0,1)))`

**Índices**: `idx_consulta_vigencia` (normal: vigente_hasta); `PRIMARY` (único: id_consulta); `uq_consulta_documento` (único: tipo_documento, numero)


## Catálogo

### categoria

Categorías de productos (polleras, fajas, chalecos)

**Referencia:** §4 catálogo

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_categoria` | smallint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_categoria_padre` | smallint unsigned | sí | ∅ | MUL | Categoría padre (subcategorías) |
| `nombre` | varchar(60) | no | ∅ | UNI | Nombre visible (único, sin distinguir tildes/mayúsculas) |
| `slug` | varchar(80) | no | ∅ | UNI | URL amigable: minúsculas, números y guiones |
| `descripcion` | varchar(200) | sí | ∅ |  | Descripción corta |
| `icono` | varchar(40) | sí | ∅ |  | Nombre del ícono |
| `orden` | smallint | no | 0 |  | Orden en el menú |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_categoria_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_categoria_nombre`: `(char_length(trim(nombre)) >= 2)`
- `ck_categoria_slug`: `regexp_like(slug,'^[a-z0-9]+(-[a-z0-9]+)*$','c')`

**Llaves foráneas**

- `fk_categoria_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_categoria_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_categoria_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_categoria_padre`: (id_categoria_padre) → `categoria`(id_categoria)

**Índices**: `fk_categoria_actualizado` (normal: actualizado_por); `fk_categoria_creado` (normal: creado_por); `fk_categoria_inhabilitado` (normal: inhabilitado_por); `fk_categoria_padre` (normal: id_categoria_padre); `PRIMARY` (único: id_categoria); `uq_categoria_nombre` (único: nombre); `uq_categoria_slug` (único: slug)

**Triggers**: `trg_categoria_bi` (BEFORE INSERT), `trg_categoria_bu` (BEFORE UPDATE), `trg_categoria_bd` (BEFORE DELETE)

### producto

Productos. Un producto con ventas se archiva, nunca se borra

**Referencia:** §4 catálogo; búsqueda FULLTEXT; §2.6 archivar

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_producto` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_categoria` | smallint unsigned | no | ∅ | MUL | Categoría (FK) |
| `nombre` | varchar(150) | no | ∅ | MUL | Nombre comercial |
| `slug` | varchar(180) | no | ∅ | UNI | URL amigable única |
| `descripcion` | text | sí | ∅ |  | Descripción (búsqueda FULLTEXT) |
| `precio_base` | decimal(10,2) | no | ∅ |  | Precio de lista en PEN, IGV incluido |
| `tipo_fabricacion` | enum('stock','a_pedido') | no | stock |  | stock = se vende de inventario; a_pedido = se fabrica (no descuenta stock) |
| `dias_produccion` | smallint unsigned | no | 0 |  | Días de fabricación (a_pedido) |
| `permite_personalizacion` | tinyint(1) | no | 0 |  | 1 = acepta texto/bordado personalizado |
| `unidad_medida_sunat` | char(3) | no | NIU |  | Unidad de medida SUNAT (catálogo 03): NIU = unidad (bienes) |
| `codigo_afectacion_igv` | char(2) | no | 10 |  | Afectación IGV SUNAT (catálogo 07): 10 = gravado |
| `destacado` | tinyint(1) | no | 0 |  | Aparece en portada |
| `estado` | enum('borrador','activo','archivado') | no | borrador | MUL | Solo "activo" se vende. Archivado = borrado lógico |
| `valoracion_promedio` | decimal(2,1) | no | 0.0 |  | Promedio de reseñas publicadas (lo mantiene un trigger) |
| `total_resenas` | int unsigned | no | 0 |  | Reseñas publicadas (lo mantiene un trigger) |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se archivó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo archivó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_producto_archivado`: `((estado = 'archivado') = (inhabilitado_en is not null))`
- `ck_producto_bool`: `((destacado in (0,1)) and (permite_personalizacion in (0,1)))`
- `ck_producto_dias`: `((tipo_fabricacion = 'stock') or (dias_produccion > 0))`
- `ck_producto_nombre`: `(char_length(trim(nombre)) >= 3)`
- `ck_producto_precio`: `(precio_base > 0)`
- `ck_producto_slug`: `regexp_like(slug,'^[a-z0-9]+(-[a-z0-9]+)*$','c')`
- `ck_producto_sunat`: `(regexp_like(unidad_medida_sunat,'^[A-Z0-9]{2,3}$','c') and regexp_like(codigo_afectacion_igv,'^[0-9]{2}$','c'))`
- `ck_producto_valor`: `(valoracion_promedio between 0 and 5)`

**Llaves foráneas**

- `fk_producto_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_producto_categoria`: (id_categoria) → `categoria`(id_categoria)
- `fk_producto_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_producto_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_producto_actualizado` (normal: actualizado_por); `fk_producto_categoria` (normal: id_categoria); `fk_producto_creado` (normal: creado_por); `fk_producto_inhabilitado` (normal: inhabilitado_por); `ft_producto_busqueda` (FULLTEXT: nombre, descripcion); `idx_producto_catalogo` (normal: estado, id_categoria, destacado); `PRIMARY` (único: id_producto); `uq_producto_slug` (único: slug)

**Triggers**: `trg_producto_bi` (BEFORE INSERT), `trg_producto_bu` (BEFORE UPDATE), `trg_producto_bd` (BEFORE DELETE), `trg_producto_au` (AFTER UPDATE)

### variante_producto

Variantes (talla/color) con stock y kardex. HU de catálogo e inventario

**Referencia:** §4 catálogo e inventario

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_variante` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_producto` | bigint unsigned | no | ∅ | MUL | Producto (FK) |
| `sku` | varchar(40) | no | ∅ | UNI | Código interno único en MAYÚSCULAS (A-Z, 0-9, guion) |
| `talla` | varchar(20) | sí | ∅ |  | Talla |
| `color` | varchar(30) | sí | ∅ |  | Color |
| `talla_clave` | varchar(20) | sí | GENERADA: `coalesce(talla,'')` |  | Talla normalizada para el índice único |
| `color_clave` | varchar(30) | sí | GENERADA: `coalesce(color,'')` |  | Color normalizado para el índice único |
| `precio` | decimal(10,2) | sí | ∅ |  | Precio propio con IGV; NULL = usa precio_base del producto |
| `stock_actual` | int | no | 0 |  | Unidades físicas (solo cambia vía procedimientos con kardex) |
| `stock_reservado` | int | no | 0 |  | Unidades reservadas por pedidos sin pagar |
| `stock_disponible` | int | sí | GENERADA: `(stock_actual - stock_reservado)` |  | Disponible para vender |
| `stock_minimo` | int | no | 0 |  | Umbral de alerta de stock bajo |
| `activo` | tinyint(1) | no | 1 | MUL | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_variante_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_variante_precio`: `((precio is null) or (precio > 0))`
- `ck_variante_sku`: `regexp_like(sku,'^[A-Z0-9][A-Z0-9-]{2,39}$','c')`
- `ck_variante_stock`: `((stock_actual >= 0) and (stock_reservado >= 0) and (stock_reservado <= stock_actual) and (stock_minimo >= 0))`

**Llaves foráneas**

- `fk_variante_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_variante_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_variante_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_variante_producto`: (id_producto) → `producto`(id_producto)

**Índices**: `fk_variante_actualizado` (normal: actualizado_por); `fk_variante_creado` (normal: creado_por); `fk_variante_inhabilitado` (normal: inhabilitado_por); `idx_variante_stock` (normal: activo, stock_actual, stock_minimo); `PRIMARY` (único: id_variante); `uq_variante_combinacion` (único: id_producto, talla_clave, color_clave); `uq_variante_producto` (único: id_variante, id_producto); `uq_variante_sku` (único: sku)

**Triggers**: `trg_variante_producto_bi` (BEFORE INSERT), `trg_variante_producto_bu` (BEFORE UPDATE), `trg_variante_producto_bd` (BEFORE DELETE), `trg_variante_producto_au` (AFTER UPDATE)

### imagen_producto

Galería de imágenes por producto/variante

**Referencia:** §4 catálogo

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_imagen` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_producto` | bigint unsigned | no | ∅ | MUL | Producto (FK) |
| `id_variante` | bigint unsigned | sí | ∅ | MUL | Variante concreta (opcional; debe ser del mismo producto) |
| `url` | varchar(500) | no | ∅ |  | Ruta /media/... o URL https |
| `texto_alt` | varchar(150) | sí | ∅ |  | Texto alternativo (accesibilidad) |
| `orden` | smallint | no | 0 |  | Orden en la galería |
| `principal` | tinyint(1) | no | 0 |  | 1 = imagen principal (una por producto) |
| `principal_clave` | bigint unsigned | sí | GENERADA: `if(((principal = 1) and (activo = 1)),id_producto,NULL)` | UNI | Índice único: una sola principal activa por producto |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_imagen_activo`: `((activo in (0,1)) and (principal in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_imagen_url`: `regexp_like(url,'^(https://\|/)[^[:space:]]+$','c')`

**Llaves foráneas**

- `fk_imagen_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_imagen_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_imagen_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_imagen_producto`: (id_producto) → `producto`(id_producto)
- `fk_imagen_variante`: (id_variante, id_producto) → `variante_producto`(id_variante, id_producto)

**Índices**: `fk_imagen_actualizado` (normal: actualizado_por); `fk_imagen_creado` (normal: creado_por); `fk_imagen_inhabilitado` (normal: inhabilitado_por); `fk_imagen_variante` (normal: id_variante, id_producto); `idx_imagen_producto` (normal: id_producto, activo, orden); `PRIMARY` (único: id_imagen); `uq_imagen_principal` (único: principal_clave)

**Triggers**: `trg_imagen_producto_bi` (BEFORE INSERT), `trg_imagen_producto_bu` (BEFORE UPDATE), `trg_imagen_producto_bd` (BEFORE DELETE)

### precio_volumen

Precios por volumen (venta al por mayor). Una línea que alcanza un tramo convierte el pedido en "mayor"

**Referencia:** §4 catálogo; §5.2 precio por volumen (venta al por mayor)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_precio_volumen` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_producto` | bigint unsigned | no | ∅ | MUL | Producto (FK) |
| `cantidad_minima` | int unsigned | no | ∅ |  | Desde cuántas unidades (por línea) aplica |
| `precio_unitario` | decimal(10,2) | no | ∅ |  | Precio unitario con IGV en ese tramo |
| `cantidad_activa` | int unsigned | sí | GENERADA: `if((activo = 1),cantidad_minima,NULL)` |  | Índice único solo para tramos activos |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_pvol_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_pvol_cantidad`: `(cantidad_minima >= 2)`
- `ck_pvol_precio`: `(precio_unitario > 0)`

**Llaves foráneas**

- `fk_pvol_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_pvol_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_pvol_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_pvol_producto`: (id_producto) → `producto`(id_producto)

**Índices**: `fk_pvol_actualizado` (normal: actualizado_por); `fk_pvol_creado` (normal: creado_por); `fk_pvol_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: id_precio_volumen); `uq_precio_volumen_tramo` (único: id_producto, cantidad_activa)

**Triggers**: `trg_precio_volumen_bi` (BEFORE INSERT), `trg_precio_volumen_bu` (BEFORE UPDATE), `trg_precio_volumen_bd` (BEFORE DELETE), `trg_precio_volumen_au` (AFTER UPDATE)

### favorito

Lista de deseos (estado de interfaz: se quita con sp_alternar_favorito)

**Referencia:** §4 catálogo (lista de deseos)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_usuario` | bigint unsigned | no | ∅ | PRI | Cliente (FK) |
| `id_producto` | bigint unsigned | no | ∅ | PRI | Producto (FK) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Cuándo lo marcó |

**Llaves foráneas**

- `fk_favorito_producto`: (id_producto) → `producto`(id_producto)
- `fk_favorito_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `idx_favorito_producto` (normal: id_producto); `PRIMARY` (único: id_usuario, id_producto)

### resena

Reseñas: solo quien compró y recibió; una por producto y usuario; moderadas

**Referencia:** §5.8 reseñas

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_resena` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_producto` | bigint unsigned | no | ∅ | MUL | Producto (FK) |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Cliente (FK) |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido entregado que lo habilita (FK) |
| `calificacion` | tinyint unsigned | no | ∅ |  | Estrellas 1 a 5 |
| `titulo` | varchar(100) | sí | ∅ |  | Título |
| `comentario` | varchar(1000) | sí | ∅ |  | Comentario |
| `estado` | enum('pendiente','publicada','rechazada','oculta') | no | pendiente |  | Moderación del administrador |
| `moderado_por` | bigint unsigned | sí | ∅ | MUL | Administrador que moderó (FK) |
| `moderado_en` | datetime(3) | sí | ∅ |  | Cuándo se moderó |
| `motivo_moderacion` | varchar(200) | sí | ∅ |  | Motivo de rechazo u ocultamiento |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_resena_calificacion`: `(calificacion between 1 and 5)`
- `ck_resena_moderacion`: `((estado = 'pendiente') or (moderado_en is not null))`
- `ck_resena_motivo`: `((estado not in ('rechazada','oculta')) or (motivo_moderacion is not null))`

**Llaves foráneas**

- `fk_resena_moderado`: (moderado_por) → `usuario`(id_usuario)
- `fk_resena_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_resena_producto`: (id_producto) → `producto`(id_producto)
- `fk_resena_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_resena_moderado` (normal: moderado_por); `fk_resena_pedido` (normal: id_pedido); `fk_resena_usuario` (normal: id_usuario); `idx_resena_producto` (normal: id_producto, estado); `PRIMARY` (único: id_resena); `uq_resena_usuario_producto` (único: id_producto, id_usuario)

**Triggers**: `trg_resena_bi` (BEFORE INSERT), `trg_resena_bu` (BEFORE UPDATE), `trg_resena_bd` (BEFORE DELETE), `trg_resena_ai` (AFTER INSERT), `trg_resena_au` (AFTER UPDATE)

### banner

Banners de portada

**Referencia:** §4 catálogo (portada)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_banner` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `titulo` | varchar(120) | no | ∅ |  | Título |
| `subtitulo` | varchar(200) | sí | ∅ |  | Subtítulo |
| `imagen_url` | varchar(500) | no | ∅ |  | Imagen |
| `enlace` | varchar(300) | sí | ∅ |  | Enlace al hacer clic |
| `texto_boton` | varchar(40) | sí | ∅ |  | Texto del botón |
| `orden` | smallint | no | 0 |  | Orden |
| `vigente_desde` | datetime(3) | sí | ∅ |  | Desde (UTC) |
| `vigente_hasta` | datetime(3) | sí | ∅ |  | Hasta (UTC) |
| `activo` | tinyint(1) | no | 1 | MUL | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_banner_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_banner_url`: `regexp_like(imagen_url,'^(https://\|/)[^[:space:]]+$','c')`
- `ck_banner_vigencia`: `((vigente_hasta is null) or (vigente_desde is null) or (vigente_hasta > vigente_desde))`

**Llaves foráneas**

- `fk_banner_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_banner_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_banner_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_banner_actualizado` (normal: actualizado_por); `fk_banner_creado` (normal: creado_por); `fk_banner_inhabilitado` (normal: inhabilitado_por); `idx_banner_vigencia` (normal: activo, vigente_desde, vigente_hasta); `PRIMARY` (único: id_banner)

**Triggers**: `trg_banner_bi` (BEFORE INSERT), `trg_banner_bu` (BEFORE UPDATE), `trg_banner_bd` (BEFORE DELETE)


## Inventario e insumos

### reserva_stock

Reservas de stock por ítem de pedido; la suma de activas = variante.stock_reservado

**Referencia:** §5.3 reservas de stock

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_reserva` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `id_item_pedido` | bigint unsigned | no | ∅ | UNI | Ítem (FK, una reserva por ítem) |
| `id_variante` | bigint unsigned | no | ∅ | MUL | Variante reservada (FK) |
| `cantidad` | int unsigned | no | ∅ |  | Unidades reservadas |
| `estado` | enum('activa','consumida','liberada') | no | activa |  | activa → consumida (venta) o liberada (cancelación/expiración) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `cerrada_en` | datetime(3) | sí | ∅ |  | Cuándo se consumió o liberó |

**Restricciones CHECK**

- `ck_reserva_cantidad`: `(cantidad > 0)`
- `ck_reserva_cierre`: `((estado = 'activa') = (cerrada_en is null))`

**Llaves foráneas**

- `fk_reserva_item`: (id_item_pedido) → `item_pedido`(id_item_pedido)
- `fk_reserva_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_reserva_variante`: (id_variante) → `variante_producto`(id_variante)

**Índices**: `idx_reserva_pedido` (normal: id_pedido, estado); `idx_reserva_variante` (normal: id_variante, estado); `PRIMARY` (único: id_reserva); `uq_reserva_item` (único: id_item_pedido)

**Triggers**: `trg_reserva_stock_bi` (BEFORE INSERT), `trg_reserva_stock_bu` (BEFORE UPDATE), `trg_reserva_stock_bd` (BEFORE DELETE)

### movimiento_stock

Kardex de productos terminados (solo inserción)

**Referencia:** §4 kardex; §2.9 devoluciones reponen stock

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_movimiento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_variante` | bigint unsigned | no | ∅ | MUL | Variante (FK) |
| `tipo` | enum('ingreso','reserva','liberacion_reserva','venta','devolucion','ajuste') | no | ∅ |  | Tipo de movimiento |
| `cantidad` | int | no | ∅ |  | Unidades (positivas; en ajuste puede ser negativa) |
| `stock_actual_resultante` | int | no | ∅ |  | Stock físico después del movimiento |
| `stock_reservado_resultante` | int | no | ∅ |  | Stock reservado después del movimiento |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido relacionado (FK) |
| `id_item_pedido` | bigint unsigned | sí | ∅ | MUL | Ítem relacionado (FK) |
| `id_devolucion` | bigint unsigned | sí | ∅ | MUL | Devolución relacionada (FK) |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Actor (NULL = sistema) |
| `motivo` | varchar(200) | sí | ∅ |  | Motivo |
| `creado_en` | datetime(3) | no | utc_timestamp(3) | MUL | Momento (UTC) |

**Restricciones CHECK**

- `ck_movstock_cantidad`: `((cantidad <> 0) and ((tipo = 'ajuste') or (cantidad > 0)))`
- `ck_movstock_resultado`: `((stock_actual_resultante >= 0) and (stock_reservado_resultante >= 0) and (stock_reservado_resultante <= stock_actual_resultante))`

**Llaves foráneas**

- `fk_movstock_devolucion`: (id_devolucion) → `devolucion`(id_devolucion)
- `fk_movstock_item`: (id_item_pedido) → `item_pedido`(id_item_pedido)
- `fk_movstock_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_movstock_usuario`: (id_usuario) → `usuario`(id_usuario)
- `fk_movstock_variante`: (id_variante) → `variante_producto`(id_variante)

**Índices**: `fk_movstock_devolucion` (normal: id_devolucion); `fk_movstock_item` (normal: id_item_pedido); `fk_movstock_usuario` (normal: id_usuario); `idx_movstock_fecha` (normal: creado_en); `idx_movstock_pedido` (normal: id_pedido); `idx_movstock_variante` (normal: id_variante, creado_en); `PRIMARY` (único: id_movimiento)

**Triggers**: `trg_movimiento_stock_bi` (BEFORE INSERT), `trg_movimiento_stock_bu` (BEFORE UPDATE), `trg_movimiento_stock_bd` (BEFORE DELETE)

### insumo

Insumos de producción con stock mínimo y alertas. HU-13

**Referencia:** HU-13 insumos

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_insumo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `nombre` | varchar(120) | no | ∅ | UNI | Nombre (único) |
| `tipo` | enum('hilo','tela','bastidor','otro') | no | ∅ |  | Tipo de insumo |
| `unidad` | enum('unidad','metro','centimetro','cono','madeja','rollo','kilogramo','gramo','par') | no | ∅ |  | Unidad de medida |
| `stock_actual` | decimal(12,3) | no | 0.000 |  | Existencia (solo cambia vía sp_ajustar_insumo con kardex) |
| `stock_minimo` | decimal(12,3) | no | 0.000 |  | Umbral de alerta |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_insumo_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_insumo_stock`: `((stock_actual >= 0) and (stock_minimo >= 0))`

**Llaves foráneas**

- `fk_insumo_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_insumo_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_insumo_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_insumo_actualizado` (normal: actualizado_por); `fk_insumo_creado` (normal: creado_por); `fk_insumo_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: id_insumo); `uq_insumo_nombre` (único: nombre)

**Triggers**: `trg_insumo_bi` (BEFORE INSERT), `trg_insumo_bu` (BEFORE UPDATE), `trg_insumo_bd` (BEFORE DELETE)

### movimiento_insumo

Kardex de insumos (solo inserción). HU-13

**Referencia:** HU-13 kardex de insumos

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_movimiento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_insumo` | bigint unsigned | no | ∅ | MUL | Insumo (FK) |
| `tipo` | enum('ingreso','consumo','ajuste') | no | ∅ |  | Tipo de movimiento |
| `cantidad` | decimal(12,3) | no | ∅ |  | Cantidad (positiva; en ajuste puede ser negativa) |
| `stock_resultante` | decimal(12,3) | no | ∅ |  | Existencia después del movimiento |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido que lo consumió (FK) |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Actor (NULL = sistema) |
| `motivo` | varchar(200) | sí | ∅ |  | Motivo |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Restricciones CHECK**

- `ck_movinsumo_cantidad`: `((cantidad <> 0) and ((tipo = 'ajuste') or (cantidad > 0)) and (stock_resultante >= 0))`

**Llaves foráneas**

- `fk_movinsumo_insumo`: (id_insumo) → `insumo`(id_insumo)
- `fk_movinsumo_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_movinsumo_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_movinsumo_usuario` (normal: id_usuario); `idx_movinsumo_insumo` (normal: id_insumo, creado_en); `idx_movinsumo_pedido` (normal: id_pedido); `PRIMARY` (único: id_movimiento)

**Triggers**: `trg_movimiento_insumo_bi` (BEFORE INSERT), `trg_movimiento_insumo_bu` (BEFORE UPDATE), `trg_movimiento_insumo_bd` (BEFORE DELETE)

### receta_producto

Receta: insumos por unidad producida (opcional; permite descontar insumos al producir)

**Referencia:** §4 (opcional recomendado) receta para descontar insumos

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_producto` | bigint unsigned | no | ∅ | PRI | Producto fabricado (FK) |
| `id_insumo` | bigint unsigned | no | ∅ | PRI | Insumo usado (FK) |
| `cantidad_por_unidad` | decimal(12,3) | no | ∅ |  | Cantidad de insumo por unidad producida |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_receta_cantidad`: `((cantidad_por_unidad > 0) and (activo in (0,1)))`

**Llaves foráneas**

- `fk_receta_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_receta_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_receta_insumo`: (id_insumo) → `insumo`(id_insumo)
- `fk_receta_producto`: (id_producto) → `producto`(id_producto)

**Índices**: `fk_receta_actualizado` (normal: actualizado_por); `fk_receta_creado` (normal: creado_por); `idx_receta_insumo` (normal: id_insumo); `PRIMARY` (único: id_producto, id_insumo)

**Triggers**: `trg_receta_producto_bi` (BEFORE INSERT), `trg_receta_producto_bu` (BEFORE UPDATE), `trg_receta_producto_bd` (BEFORE DELETE)


## Compra y pedidos

### carrito

Carrito de compras (sin precios)

**Referencia:** §4 compra (el precio nunca se guarda en el carrito)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_carrito` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Cliente (FK) |
| `estado` | enum('activo','convertido','abandonado') | no | activo | MUL | Un solo carrito activo por cliente |
| `activo_clave` | bigint unsigned | sí | GENERADA: `if((estado = 'activo'),id_usuario,NULL)` | UNI | Índice único: un carrito activo por cliente |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido generado al convertir (FK) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_carrito_pedido`: `((estado <> 'convertido') or (id_pedido is not null))`

**Llaves foráneas**

- `fk_carrito_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_carrito_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_carrito_pedido` (normal: id_pedido); `idx_carrito_abandono` (normal: estado, actualizado_en); `idx_carrito_usuario` (normal: id_usuario, estado); `PRIMARY` (único: id_carrito); `uq_carrito_activo` (único: activo_clave)

**Triggers**: `trg_carrito_bu` (BEFORE UPDATE), `trg_carrito_bd` (BEFORE DELETE)

### item_carrito

Ítems del carrito (estado de interfaz: se quitan con sp_quitar_item_carrito)

**Referencia:** §4 compra

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_item_carrito` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_carrito` | bigint unsigned | no | ∅ | MUL | Carrito (FK) |
| `id_variante` | bigint unsigned | no | ∅ | MUL | Variante (FK) |
| `cantidad` | int unsigned | no | ∅ |  | Unidades |
| `personalizacion` | varchar(500) | sí | ∅ |  | Texto del bordado personalizado |
| `agregado_en` | datetime(3) | no | utc_timestamp(3) |  | Cuándo se agregó (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_icar_cantidad`: `((cantidad > 0) and (cantidad <= 100000))`

**Llaves foráneas**

- `fk_icar_carrito`: (id_carrito) → `carrito`(id_carrito)
- `fk_icar_variante`: (id_variante) → `variante_producto`(id_variante)

**Índices**: `idx_item_carrito_variante` (normal: id_variante); `PRIMARY` (único: id_item_carrito); `uq_item_carrito` (único: id_carrito, id_variante)

**Triggers**: `trg_item_carrito_bi` (BEFORE INSERT), `trg_item_carrito_bu` (BEFORE UPDATE)

### zona_envio

Zonas de envío y su costo

**Referencia:** §5.1 costo de envío desde la zona

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_zona` | smallint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `nombre` | varchar(80) | no | ∅ | UNI | Nombre de la zona (único) |
| `costo` | decimal(8,2) | no | ∅ |  | Costo de envío en PEN con IGV (fuente única del costo de envío) |
| `dias_estimados` | smallint unsigned | no | 1 |  | Días hábiles estimados de entrega |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_zona_activo`: `((activo in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_zona_costo`: `(costo >= 0)`

**Llaves foráneas**

- `fk_zona_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_zona_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_zona_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_zona_actualizado` (normal: actualizado_por); `fk_zona_creado` (normal: creado_por); `fk_zona_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: id_zona); `uq_zona_nombre` (único: nombre)

**Triggers**: `trg_zona_envio_bi` (BEFORE INSERT), `trg_zona_envio_bu` (BEFORE UPDATE), `trg_zona_envio_bd` (BEFORE DELETE), `trg_zona_envio_au` (AFTER UPDATE)

### direccion

Direcciones de entrega del cliente

**Referencia:** §4 compra; §3.1 predeterminada única

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_direccion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Cliente dueño (FK) |
| `alias` | varchar(40) | no | ∅ |  | Casa, trabajo... |
| `nombre_receptor` | varchar(120) | no | ∅ |  | Quién recibe |
| `telefono` | varchar(16) | no | ∅ |  | Teléfono de contacto |
| `direccion` | varchar(200) | no | ∅ |  | Calle, número, interior |
| `referencia` | varchar(200) | sí | ∅ |  | Referencia para el repartidor |
| `distrito` | varchar(80) | no | ∅ |  | Distrito |
| `provincia` | varchar(80) | no | ∅ |  | Provincia |
| `departamento` | varchar(80) | no | ∅ |  | Departamento |
| `ubigeo` | char(6) | sí | ∅ |  | Código UBIGEO INEI (útil para la API del courier) |
| `id_zona` | smallint unsigned | no | ∅ | MUL | Zona de envío (define el costo) |
| `predeterminada` | tinyint(1) | no | 0 |  | 1 = dirección por defecto |
| `predeterminada_clave` | bigint unsigned | sí | GENERADA: `if(((predeterminada = 1) and (activo = 1)),id_usuario,NULL)` | UNI | Índice único: una sola predeterminada activa por cliente |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_direccion_activo`: `((activo in (0,1)) and (predeterminada in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_direccion_telefono`: `regexp_like(telefono,'^[+]?[0-9]{9,15}$','c')`
- `ck_direccion_textos`: `((char_length(trim(direccion)) >= 5) and (char_length(trim(nombre_receptor)) >= 3))`
- `ck_direccion_ubigeo`: `((ubigeo is null) or regexp_like(ubigeo,'^[0-9]{6}$','c'))`

**Llaves foráneas**

- `fk_direccion_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_direccion_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_direccion_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)
- `fk_direccion_usuario`: (id_usuario) → `usuario`(id_usuario)
- `fk_direccion_zona`: (id_zona) → `zona_envio`(id_zona)

**Índices**: `fk_direccion_actualizado` (normal: actualizado_por); `fk_direccion_creado` (normal: creado_por); `fk_direccion_inhabilitado` (normal: inhabilitado_por); `fk_direccion_zona` (normal: id_zona); `idx_direccion_usuario` (normal: id_usuario, activo); `PRIMARY` (único: id_direccion); `uq_direccion_predeterminada` (único: predeterminada_clave)

**Triggers**: `trg_direccion_bi` (BEFORE INSERT), `trg_direccion_bu` (BEFORE UPDATE), `trg_direccion_bd` (BEFORE DELETE)

### estado_pedido

Catálogo de estados del pedido con su grupo (pendiente, en proceso, terminado, cancelado, devuelto)

**Referencia:** §2.5 estados consultables por grupo

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `codigo` | varchar(20) | no | ∅ | PRI | Código del estado |
| `nombre` | varchar(40) | no | ∅ |  | Nombre visible para el cliente |
| `grupo` | enum('pendiente','en_proceso','terminado','cancelado','devuelto') | no | ∅ |  | Agrupación para consultas (§2.5) |
| `orden` | tinyint unsigned | no | ∅ | UNI | Orden en la línea de tiempo |
| `es_final` | tinyint(1) | no | 0 |  | 1 = no admite más cambios salvo devolución |
| `notifica_cliente` | tinyint(1) | no | 1 |  | 1 = genera correo + notificación al entrar |
| `descripcion` | varchar(200) | sí | ∅ |  | Qué significa |

**Restricciones CHECK**

- `ck_estado_pedido_bool`: `((es_final in (0,1)) and (notifica_cliente in (0,1)))`
- `ck_estado_pedido_codigo`: `regexp_like(codigo,'^[a-z_]{3,20}$','c')`

**Índices**: `PRIMARY` (único: codigo); `uq_estado_pedido_orden` (único: orden)

**Triggers**: `trg_estado_pedido_bd` (BEFORE DELETE)

### transicion_estado_pedido

Flujo de estados permitido (única fuente de verdad para cliente y administrador)

**Referencia:** §5.7 transiciones permitidas

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `estado_origen` | varchar(20) | no | ∅ | PRI | Desde (FK estado_pedido) |
| `estado_destino` | varchar(20) | no | ∅ | PRI | Hacia (FK estado_pedido) |
| `tipo_entrega_aplicable` | enum('ambos','recojo','domicilio') | no | ambos |  | Recojo no pasa por enviado; domicilio debe pasar por enviado |
| `automatica` | tinyint(1) | no | 0 |  | 1 = solo la hace el sistema (confirmación por pago) |
| `permitido_cliente` | tinyint(1) | no | 0 |  | 1 = el propio cliente puede hacerla (cancelar su pedido sin pagar) |
| `requiere_saldo_cero` | tinyint(1) | no | 0 |  | 1 = exige saldo 0 si config bloquear_envio_con_saldo = 1 |
| `descripcion` | varchar(150) | sí | ∅ |  | Explicación |

**Restricciones CHECK**

- `ck_tep_bool`: `((automatica in (0,1)) and (permitido_cliente in (0,1)) and (requiere_saldo_cero in (0,1)))`

**Llaves foráneas**

- `fk_tep_destino`: (estado_destino) → `estado_pedido`(codigo)
- `fk_tep_origen`: (estado_origen) → `estado_pedido`(codigo)

**Índices**: `idx_transicion_destino` (normal: estado_destino); `PRIMARY` (único: estado_origen, estado_destino)

**Triggers**: `trg_transicion_estado_pedido_bd` (BEFORE DELETE)

### pedido

Pedidos. Estado siempre consultable por grupo; montos de pago derivados de los pagos

**Referencia:** §2.2 modalidad total/adelanto; §5.1; §5.4-7; HU-29 complementario

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_pedido` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `numero` | varchar(25) | no | ∅ | UNI | Correlativo anual BW-AAAA-NNNNNN / BW-MAY-AAAA-NNNNNN |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Cliente (FK) |
| `id_pedido_origen` | bigint unsigned | sí | ∅ | MUL | Pedido original si es complementario (HU-29) |
| `id_cotizacion` | bigint unsigned | sí | ∅ | UNI | Cotización de la que nace (una cotización = un pedido) |
| `tipo_venta` | enum('menor','mayor') | no | menor |  | mayor = alguna línea alcanzó precio por volumen o viene de cotización al por mayor |
| `canal` | enum('web','presencial') | no | web |  | Canal de venta |
| `estado` | varchar(20) | no | pendiente_pago | MUL | Estado (FK estado_pedido); solo cambia por transiciones permitidas |
| `estado_pago` | enum('pendiente','parcial','pagado','reembolsado') | no | pendiente |  | DERIVADO de los pagos (no se fija a mano) |
| `modalidad_pago` | enum('total','adelanto') | no | total |  | Elegida por el cliente: pago completo o adelanto |
| `adelanto_porcentaje` | decimal(5,2) | sí | ∅ |  | Porcentaje de adelanto aplicado (NULL si total). Por defecto config adelanto_porcentaje (50) o el de la cotización |
| `tipo_entrega` | enum('recojo','domicilio') | no | ∅ |  | Recojo en tienda o envío a domicilio |
| `id_direccion` | bigint unsigned | sí | ∅ | MUL | Dirección de origen de la copia de entrega |
| `id_zona` | smallint unsigned | sí | ∅ | MUL | Zona de envío (define costo_envio) |
| `entrega_nombre` | varchar(120) | sí | ∅ |  | Copia: quién recibe |
| `entrega_telefono` | varchar(16) | sí | ∅ |  | Copia: teléfono |
| `entrega_direccion` | varchar(200) | sí | ∅ |  | Copia: dirección |
| `entrega_referencia` | varchar(200) | sí | ∅ |  | Copia: referencia |
| `entrega_distrito` | varchar(80) | sí | ∅ |  | Copia: distrito |
| `entrega_provincia` | varchar(80) | sí | ∅ |  | Copia: provincia |
| `entrega_departamento` | varchar(80) | sí | ∅ |  | Copia: departamento |
| `entrega_ubigeo` | char(6) | sí | ∅ |  | Copia: UBIGEO |
| `comprobante_solicitado` | enum('boleta','factura') | no | boleta |  | Comprobante que pidió el cliente |
| `facturacion_tipo_doc` | enum('DNI','RUC','CE') | sí | ∅ |  | Documento para el comprobante (RUC obligatorio en factura) |
| `facturacion_num_doc` | varchar(12) | sí | ∅ |  | Número de documento para el comprobante |
| `facturacion_nombre` | varchar(200) | sí | ∅ |  | Nombre o razón social para el comprobante |
| `facturacion_direccion` | varchar(250) | sí | ∅ |  | Domicilio fiscal / dirección para el comprobante |
| `moneda` | char(3) | no | PEN |  | Moneda del pedido (PEN) |
| `subtotal` | decimal(12,2) | no | 0.00 |  | Suma de ítems (IGV incluido) |
| `descuento` | decimal(12,2) | no | 0.00 |  | Descuento (reservado para cupones, HU-40 fuera de alcance) |
| `costo_envio` | decimal(12,2) | no | 0.00 |  | Costo de envío tomado de la zona (nunca del navegador) |
| `total` | decimal(12,2) | no | 0.00 |  | subtotal − descuento + envío |
| `monto_pagado` | decimal(12,2) | no | 0.00 |  | DERIVADO: pagos confirmados aplicados |
| `monto_reembolsado` | decimal(12,2) | no | 0.00 |  | DERIVADO: reembolsos completados de esos pagos |
| `monto_devuelto` | decimal(12,2) | no | 0.00 |  | DERIVADO: valor de los productos devueltos (devoluciones registradas) |
| `monto_ajustes` | decimal(12,2) | no | 0.00 |  | DERIVADO: rebajas posteriores a la venta (nota de crédito de descuento/disminución o compensación reembolsada sin comprobante) |
| `monto_neto_pagado` | decimal(12,2) | sí | GENERADA: `(monto_pagado - monto_reembolsado)` |  | Pagado − reembolsado |
| `saldo` | decimal(12,2) | sí | GENERADA: `(((total - monto_devuelto) - monto_ajustes) - (monto_pagado - monto_reembolsado))` |  | Lo que falta pagar; negativo = saldo a favor del cliente (reembolso pendiente) |
| `monto_requerido` | decimal(12,2) | sí | GENERADA: `if((modalidad_pago = 'total'),total,round(((total * adelanto_porcentaje) / 100),2))` |  | Monto que confirma el pedido según la modalidad |
| `fecha_entrega_solicitada` | date | sí | ∅ |  | Fecha pedida por el cliente (obligatoria y con anticipación en mayor) |
| `fecha_entrega_estimada` | date | sí | ∅ |  | Fecha estimada por la tienda |
| `notas` | varchar(500) | sí | ∅ |  | Notas del cliente |
| `expira_en` | datetime(3) | sí | ∅ |  | Hasta cuándo se reserva el stock sin pago (UTC) |
| `confirmado_en` | datetime(3) | sí | ∅ |  | Cuándo se confirmó (pago requerido recibido) |
| `entregado_en` | datetime(3) | sí | ∅ |  | Cuándo se entregó |
| `cancelado_en` | datetime(3) | sí | ∅ |  | Cuándo se canceló |
| `cancelado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo canceló (NULL = sistema) |
| `motivo_cancelacion` | varchar(200) | sí | ∅ |  | Motivo de cancelación |
| `creado_en` | datetime(3) | no | utc_timestamp(3) | MUL | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_pedido_cancelado`: `((estado = 'cancelado') = (cancelado_en is not null))`
- `ck_pedido_documento`: `(((facturacion_tipo_doc is null) and (facturacion_num_doc is null)) or ((facturacion_tipo_doc = 'DNI') and regexp_like(facturacion_num_doc,'^[0-9]{8}$','c')) or ((facturacion_tipo_doc = 'RUC') and regexp_like(facturacion_num_doc,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')) or ((facturacion_tipo_doc = 'CE') and regexp_like(facturacion_num_doc,'^[A-Z0-9]{6,12}$','c')))`
- `ck_pedido_entrega`: `(((tipo_entrega = 'recojo') and (costo_envio = 0)) or ((tipo_entrega = 'domicilio') and (id_zona is not null) and (entrega_nombre is not null) and (entrega_telefono is not null) and (entrega_direccion is not null) and (entrega_distrito is not null)))`
- `ck_pedido_factura`: `((comprobante_solicitado <> 'factura') or ((facturacion_tipo_doc = 'RUC') and (facturacion_num_doc is not null) and (facturacion_nombre is not null)))`
- `ck_pedido_modalidad`: `(((modalidad_pago = 'total') and (adelanto_porcentaje is null)) or ((modalidad_pago = 'adelanto') and (adelanto_porcentaje > 0) and (adelanto_porcentaje < 100)))`
- `ck_pedido_moneda`: `(moneda = 'PEN')`
- `ck_pedido_montos`: `((subtotal >= 0) and (descuento >= 0) and (costo_envio >= 0) and (descuento <= subtotal))`
- `ck_pedido_no_vacio`: `((estado in ('pendiente_pago','cancelado')) or (subtotal > 0))`
- `ck_pedido_pagos`: `((monto_pagado >= 0) and (monto_reembolsado >= 0) and (monto_reembolsado <= monto_pagado) and ((monto_pagado - monto_reembolsado) <= total) and (monto_devuelto >= 0) and (monto_ajustes >= 0) and ((monto_devuelto + monto_ajustes) <= total))`
- `ck_pedido_telefono`: `((entrega_telefono is null) or regexp_like(entrega_telefono,'^[+]?[0-9]{9,15}$','c'))`
- `ck_pedido_total`: `(total = ((subtotal - descuento) + costo_envio))`

**Llaves foráneas**

- `fk_pedido_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_pedido_cancelado`: (cancelado_por) → `usuario`(id_usuario)
- `fk_pedido_cotizacion`: (id_cotizacion) → `cotizacion`(id_cotizacion)
- `fk_pedido_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_pedido_direccion`: (id_direccion) → `direccion`(id_direccion)
- `fk_pedido_estado`: (estado) → `estado_pedido`(codigo)
- `fk_pedido_origen`: (id_pedido_origen) → `pedido`(id_pedido)
- `fk_pedido_usuario`: (id_usuario) → `usuario`(id_usuario)
- `fk_pedido_zona`: (id_zona) → `zona_envio`(id_zona)

**Índices**: `fk_pedido_actualizado` (normal: actualizado_por); `fk_pedido_cancelado` (normal: cancelado_por); `fk_pedido_creado` (normal: creado_por); `fk_pedido_direccion` (normal: id_direccion); `fk_pedido_zona` (normal: id_zona); `idx_pedido_estado` (normal: estado, creado_en); `idx_pedido_expira` (normal: estado, expira_en); `idx_pedido_fecha` (normal: creado_en); `idx_pedido_origen` (normal: id_pedido_origen); `idx_pedido_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_pedido); `uq_pedido_cotizacion` (único: id_cotizacion); `uq_pedido_numero` (único: numero)

**Triggers**: `trg_pedido_bi` (BEFORE INSERT), `trg_pedido_bu` (BEFORE UPDATE), `trg_pedido_bd` (BEFORE DELETE), `trg_pedido_ai` (AFTER INSERT), `trg_pedido_au` (AFTER UPDATE)

### item_pedido

Ítems del pedido con copia (snapshot) de nombre, SKU, talla, color, precio y personalización

**Referencia:** §5.2 copia de datos y precio desde la BD

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_item_pedido` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `id_variante` | bigint unsigned | sí | ∅ | MUL | Variante vendida (NULL = pieza personalizada de cotización) |
| `id_producto` | bigint unsigned | sí | ∅ | MUL | Producto (para reportes) |
| `nombre_producto` | varchar(150) | no | ∅ |  | Copia del nombre al comprar |
| `sku` | varchar(40) | sí | ∅ |  | Copia del SKU |
| `talla` | varchar(20) | sí | ∅ |  | Copia de la talla |
| `color` | varchar(30) | sí | ∅ |  | Copia del color |
| `tipo_fabricacion` | enum('stock','a_pedido','personalizado') | no | ∅ |  | Copia: define si reserva/descuenta/repone stock |
| `cantidad` | int unsigned | no | ∅ |  | Unidades |
| `precio_lista` | decimal(10,2) | sí | ∅ |  | Precio de lista al comprar (informativo) |
| `precio_unitario` | decimal(10,2) | no | ∅ |  | Precio aplicado con IGV (lista, volumen o cotizado; sale de la BD) |
| `origen_precio` | enum('lista','volumen','cotizacion') | no | ∅ |  | De dónde salió el precio |
| `subtotal` | decimal(12,2) | sí | GENERADA: `(cantidad * precio_unitario)` |  | cantidad × precio |
| `personalizacion` | varchar(500) | sí | ∅ |  | Texto del bordado personalizado |
| `cantidad_devuelta` | int unsigned | no | 0 |  | Unidades devueltas/anuladas (impide devolver dos veces) |
| `estado` | enum('vigente','retirado') | no | vigente |  | retirado = el cliente lo quitó antes de pagar (borrado lógico; el kardex conserva la reserva y su liberación) |
| `retirado_en` | datetime(3) | sí | ∅ |  | Cuándo se retiró |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |

**Restricciones CHECK**

- `ck_item_cantidad`: `((cantidad > 0) and (cantidad <= 100000) and (cantidad_devuelta <= cantidad))`
- `ck_item_precio`: `((precio_unitario > 0) and ((precio_lista is null) or (precio_lista > 0)))`
- `ck_item_retirado`: `(((estado = 'retirado') = (retirado_en is not null)) and ((estado = 'vigente') or (cantidad_devuelta = 0)))`
- `ck_item_tipo`: `((id_variante is null) = (tipo_fabricacion = 'personalizado'))`

**Llaves foráneas**

- `fk_item_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_item_producto`: (id_producto) → `producto`(id_producto)
- `fk_item_variante`: (id_variante) → `variante_producto`(id_variante)

**Índices**: `idx_item_pedido_estado` (normal: id_pedido, estado, id_variante); `idx_item_producto` (normal: id_producto); `idx_item_variante` (normal: id_variante); `PRIMARY` (único: id_item_pedido)

**Triggers**: `trg_item_pedido_bi` (BEFORE INSERT), `trg_item_pedido_bu` (BEFORE UPDATE), `trg_item_pedido_bd` (BEFORE DELETE)

### historial_estado_pedido

Historial inmutable de cambios de estado con quién lo hizo

**Referencia:** §2.5 historial inmutable

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_historial` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `estado_anterior` | varchar(20) | sí | ∅ | MUL | Estado previo (NULL al crear) |
| `estado_nuevo` | varchar(20) | no | ∅ | MUL | Estado nuevo |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Quién lo cambió (NULL = sistema) |
| `comentario` | varchar(200) | sí | ∅ |  | Comentario / motivo |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Llaves foráneas**

- `fk_hist_anterior`: (estado_anterior) → `estado_pedido`(codigo)
- `fk_hist_nuevo`: (estado_nuevo) → `estado_pedido`(codigo)
- `fk_hist_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_hist_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_hist_anterior` (normal: estado_anterior); `fk_hist_nuevo` (normal: estado_nuevo); `fk_hist_usuario` (normal: id_usuario); `idx_historial_pedido` (normal: id_pedido, creado_en); `PRIMARY` (único: id_historial)

**Triggers**: `trg_historial_estado_pedido_bu` (BEFORE UPDATE), `trg_historial_estado_pedido_bd` (BEFORE DELETE)

### devolucion

Devoluciones de pedidos entregados/enviados (reponen stock y originan reembolso y nota de crédito)

**Referencia:** §2.9 devoluciones

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_devolucion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `numero` | varchar(25) | no | ∅ | UNI | Correlativo anual DV-AAAA-NNNNNN |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido devuelto (FK) |
| `tipo` | enum('total','parcial') | no | ∅ |  | Devolución de todo o parte del pedido |
| `motivo` | varchar(300) | no | ∅ |  | Motivo |
| `monto_total` | decimal(12,2) | no | ∅ |  | Valor de lo devuelto (con IGV) |
| `registrado_por` | bigint unsigned | sí | ∅ | MUL | Administrador que la registró |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Restricciones CHECK**

- `ck_devolucion_monto`: `(monto_total >= 0)`
- `ck_devolucion_motivo`: `(char_length(trim(motivo)) >= 5)`

**Llaves foráneas**

- `fk_devolucion_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_devolucion_registrado`: (registrado_por) → `usuario`(id_usuario)

**Índices**: `fk_devolucion_registrado` (normal: registrado_por); `idx_devolucion_pedido` (normal: id_pedido); `PRIMARY` (único: id_devolucion); `uq_devolucion_numero` (único: numero)

**Triggers**: `trg_devolucion_bi` (BEFORE INSERT), `trg_devolucion_bu` (BEFORE UPDATE), `trg_devolucion_bd` (BEFORE DELETE)

### devolucion_item

Detalle de unidades devueltas

**Referencia:** §2.9 no devolver dos veces

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_devolucion_item` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_devolucion` | bigint unsigned | no | ∅ | MUL | Devolución (FK) |
| `id_item_pedido` | bigint unsigned | no | ∅ | MUL | Ítem devuelto (FK) |
| `cantidad` | int unsigned | no | ∅ |  | Unidades devueltas |
| `monto` | decimal(12,2) | no | ∅ |  | cantidad × precio aplicado |
| `repuso_stock` | tinyint(1) | no | ∅ |  | 1 = se repuso stock (solo productos de tipo stock) |

**Restricciones CHECK**

- `ck_devitem_cantidad`: `((cantidad > 0) and (monto >= 0) and (repuso_stock in (0,1)))`

**Llaves foráneas**

- `fk_devitem_devolucion`: (id_devolucion) → `devolucion`(id_devolucion)
- `fk_devitem_item`: (id_item_pedido) → `item_pedido`(id_item_pedido)

**Índices**: `idx_devitem_item` (normal: id_item_pedido); `PRIMARY` (único: id_devolucion_item); `uq_devolucion_item` (único: id_devolucion, id_item_pedido)

**Triggers**: `trg_devolucion_item_bi` (BEFORE INSERT), `trg_devolucion_item_bu` (BEFORE UPDATE), `trg_devolucion_item_bd` (BEFORE DELETE)


## Cotizaciones

### cotizacion

Cotizaciones (al por mayor y personalizadas) con vigencia y conversión a pedido

**Referencia:** HU-28 / HU-17 / HU-18; §5.9

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_cotizacion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `numero` | varchar(25) | no | ∅ | UNI | Correlativo anual CT-AAAA-NNNN |
| `id_usuario` | bigint unsigned | no | ∅ | MUL | Cliente que solicita (FK) |
| `origen` | enum('mayor','personalizado') | no | mayor |  | Venta al por mayor o bordado personalizado |
| `estado` | enum('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') | no | solicitada | MUL | Flujo: solicitada → en_revision → cotizada → aceptada → convertida |
| `descripcion` | text | no | ∅ |  | Lo que pide el cliente |
| `imagen_referencia_url` | varchar(500) | sí | ∅ |  | Imagen de referencia del diseño |
| `fecha_entrega_solicitada` | date | sí | ∅ |  | Fecha deseada (día de Lima) |
| `subtotal` | decimal(12,2) | sí | ∅ |  | Suma de ítems cotizados (con IGV) |
| `costo_envio` | decimal(12,2) | sí | ∅ |  | Envío cotizado; NULL = al aceptar se cobra la tarifa de la zona de la dirección elegida |
| `total` | decimal(12,2) | sí | ∅ |  | Total cotizado |
| `adelanto_porcentaje` | decimal(5,2) | sí | ∅ |  | Adelanto que se pedirá al convertir (editable; por defecto config) |
| `vigencia_hasta` | date | sí | ∅ |  | Último día de vigencia (día de Lima) |
| `respuesta` | text | sí | ∅ |  | Respuesta del administrador |
| `motivo_rechazo` | varchar(300) | sí | ∅ |  | Motivo si se rechaza |
| `id_admin` | bigint unsigned | sí | ∅ | MUL | Administrador que cotizó (FK) |
| `cotizado_en` | datetime(3) | sí | ∅ |  | Cuándo se cotizó |
| `aceptado_en` | datetime(3) | sí | ∅ |  | Cuándo la aceptó el cliente |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_cotizacion_adelanto`: `((adelanto_porcentaje is null) or ((adelanto_porcentaje > 0) and (adelanto_porcentaje <= 100)))`
- `ck_cotizacion_cotizada`: `((estado not in ('cotizada','aceptada','convertida','vencida')) or ((total is not null) and (vigencia_hasta is not null) and (adelanto_porcentaje is not null) and (cotizado_en is not null)))`
- `ck_cotizacion_desc`: `(char_length(trim(descripcion)) >= 10)`
- `ck_cotizacion_imagen`: `((imagen_referencia_url is null) or regexp_like(imagen_referencia_url,'^(https://\|/)[^[:space:]]+$','c'))`
- `ck_cotizacion_montos`: `((subtotal is null) or ((subtotal >= 0) and (coalesce(costo_envio,0) >= 0) and (total = (subtotal + coalesce(costo_envio,0)))))`
- `ck_cotizacion_rechazo`: `((estado <> 'rechazada') or (motivo_rechazo is not null))`

**Llaves foráneas**

- `fk_cotizacion_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_cotizacion_admin`: (id_admin) → `usuario`(id_usuario)
- `fk_cotizacion_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_cotizacion_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_cotizacion_actualizado` (normal: actualizado_por); `fk_cotizacion_admin` (normal: id_admin); `fk_cotizacion_creado` (normal: creado_por); `idx_cotizacion_estado` (normal: estado, vigencia_hasta); `idx_cotizacion_usuario` (normal: id_usuario, creado_en); `PRIMARY` (único: id_cotizacion); `uq_cotizacion_numero` (único: numero)

**Triggers**: `trg_cotizacion_bi` (BEFORE INSERT), `trg_cotizacion_bu` (BEFORE UPDATE), `trg_cotizacion_bd` (BEFORE DELETE), `trg_cotizacion_au` (AFTER UPDATE)

### item_cotizacion

Ítems de una cotización

**Referencia:** HU-28 / HU-17 / HU-18

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_item_cotizacion` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_cotizacion` | bigint unsigned | no | ∅ | MUL | Cotización (FK) |
| `id_variante` | bigint unsigned | sí | ∅ | MUL | Variante del catálogo (NULL = pieza personalizada fuera de catálogo) |
| `descripcion` | varchar(250) | no | ∅ |  | Descripción de la pieza |
| `cantidad` | int unsigned | no | ∅ |  | Unidades |
| `precio_unitario` | decimal(10,2) | sí | ∅ |  | Precio cotizado con IGV (lo fija el administrador) |
| `subtotal` | decimal(12,2) | sí | GENERADA: `(cantidad * precio_unitario)` |  | cantidad × precio |
| `personalizacion` | varchar(500) | sí | ∅ |  | Detalle del bordado |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_icot_cantidad`: `((cantidad > 0) and (cantidad <= 100000))`
- `ck_icot_precio`: `((precio_unitario is null) or (precio_unitario > 0))`

**Llaves foráneas**

- `fk_icot_cotizacion`: (id_cotizacion) → `cotizacion`(id_cotizacion)
- `fk_icot_variante`: (id_variante) → `variante_producto`(id_variante)

**Índices**: `fk_icot_variante` (normal: id_variante); `idx_item_cotizacion` (normal: id_cotizacion); `PRIMARY` (único: id_item_cotizacion)

**Triggers**: `trg_item_cotizacion_bi` (BEFORE INSERT), `trg_item_cotizacion_bu` (BEFORE UPDATE), `trg_item_cotizacion_bd` (BEFORE DELETE)

### transicion_estado_cotizacion

Transiciones permitidas de cotización (fuente única de verdad)

**Referencia:** §5.9 flujo de cotización

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `estado_origen` | enum('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') | no | ∅ | PRI | Desde |
| `estado_destino` | enum('solicitada','en_revision','cotizada','aceptada','rechazada','vencida','convertida') | no | ∅ | PRI | Hacia |
| `descripcion` | varchar(150) | sí | ∅ |  | Explicación |

**Índices**: `PRIMARY` (único: estado_origen, estado_destino)

**Triggers**: `trg_transicion_estado_cotizacion_bd` (BEFORE DELETE)


## Envíos

### courier

Empresas de transporte (courier y su API: decisión abierta)

**Referencia:** §4 envío; API del courier (decisión abierta)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_courier` | smallint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `nombre` | varchar(60) | no | ∅ | UNI | Empresa de transporte o "Reparto propio" |
| `url_seguimiento` | varchar(300) | sí | ∅ |  | Plantilla de URL de rastreo con {guia} |
| `tiene_api` | tinyint(1) | no | 0 |  | 1 = integrado por API (futuro) |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_courier_activo`: `((activo in (0,1)) and (tiene_api in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_courier_url`: `((url_seguimiento is null) or regexp_like(url_seguimiento,'^https://','c'))`

**Llaves foráneas**

- `fk_courier_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_courier_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_courier_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_courier_actualizado` (normal: actualizado_por); `fk_courier_creado` (normal: creado_por); `fk_courier_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: id_courier); `uq_courier_nombre` (único: nombre)

**Triggers**: `trg_courier_bi` (BEFORE INSERT), `trg_courier_bu` (BEFORE UPDATE), `trg_courier_bd` (BEFORE DELETE)

### envio

Envíos del pedido (preparado para la futura API del courier)

**Referencia:** HU-12 seguimiento de envío

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_envio` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `id_courier` | smallint unsigned | sí | ∅ | MUL | Courier (FK) |
| `numero_guia` | varchar(60) | sí | ∅ |  | Número de guía del courier |
| `estado` | enum('preparando','despachado','en_transito','en_reparto','entregado','incidencia','devuelto') | no | preparando | MUL | Estado del envío |
| `costo_real` | decimal(8,2) | sí | ∅ |  | Costo que cobró el courier (control interno) |
| `fecha_entrega_estimada` | date | sí | ∅ |  | Fecha estimada (día de Lima) |
| `despachado_en` | datetime(3) | sí | ∅ |  | Cuándo salió |
| `entregado_en` | datetime(3) | sí | ∅ |  | Cuándo se entregó |
| `observaciones` | varchar(300) | sí | ∅ |  | Observaciones |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_envio_costo`: `((costo_real is null) or (costo_real >= 0))`
- `ck_envio_entrega`: `((estado <> 'entregado') or (entregado_en is not null))`

**Llaves foráneas**

- `fk_envio_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_envio_courier`: (id_courier) → `courier`(id_courier)
- `fk_envio_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_envio_pedido`: (id_pedido) → `pedido`(id_pedido)

**Índices**: `fk_envio_actualizado` (normal: actualizado_por); `fk_envio_creado` (normal: creado_por); `idx_envio_estado` (normal: estado, actualizado_en); `idx_envio_pedido` (normal: id_pedido); `PRIMARY` (único: id_envio); `uq_envio_guia` (único: id_courier, numero_guia)

**Triggers**: `trg_envio_bi` (BEFORE INSERT), `trg_envio_bu` (BEFORE UPDATE), `trg_envio_bd` (BEFORE DELETE)

### seguimiento_envio

Eventos de seguimiento del envío (solo inserción). HU-12

**Referencia:** HU-12 eventos de seguimiento

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_seguimiento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_envio` | bigint unsigned | no | ∅ | MUL | Envío (FK) |
| `estado` | enum('preparando','despachado','en_transito','en_reparto','entregado','incidencia','devuelto') | no | ∅ |  | Estado reportado |
| `descripcion` | varchar(300) | sí | ∅ |  | Detalle del evento |
| `ubicacion` | varchar(120) | sí | ∅ |  | Ciudad / agencia |
| `ocurrido_en` | datetime(3) | no | ∅ |  | Cuándo ocurrió (UTC) |
| `origen` | enum('admin','api_courier','sistema') | no | admin |  | Quién informó |
| `id_evento_externo` | varchar(100) | sí | ∅ |  | Id del evento en el courier (idempotencia) |
| `registrado_por` | bigint unsigned | sí | ∅ | MUL | Actor (FK) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Registro (UTC) |

**Llaves foráneas**

- `fk_seguimiento_envio`: (id_envio) → `envio`(id_envio)
- `fk_seguimiento_usuario`: (registrado_por) → `usuario`(id_usuario)

**Índices**: `fk_seguimiento_usuario` (normal: registrado_por); `idx_seguimiento_envio` (normal: id_envio, ocurrido_en); `PRIMARY` (único: id_seguimiento); `uq_seguimiento_externo` (único: id_envio, id_evento_externo)

**Triggers**: `trg_seguimiento_envio_bu` (BEFORE UPDATE), `trg_seguimiento_envio_bd` (BEFORE DELETE)


## Pagos y reembolsos

### metodo_pago

Métodos de pago (Mercado Pago, PayPal, Yape, Plin, transferencia, efectivo)

**Referencia:** §1 Mercado Pago, PayPal, Yape, Plin, transferencia, efectivo

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `codigo` | varchar(20) | no | ∅ | PRI | Código del método |
| `nombre` | varchar(40) | no | ∅ |  | Nombre visible |
| `tipo` | enum('pasarela','manual') | no | ∅ |  | pasarela = confirma webhook; manual = valida un administrador |
| `requiere_comprobante` | tinyint(1) | no | 0 |  | 1 = exige voucher o N.º de operación (Yape, Plin, transferencia) |
| `canal` | enum('web','presencial','ambos') | no | ambos |  | Dónde se puede usar |
| `orden` | tinyint unsigned | no | 0 |  | Orden en pantalla |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo inhabilitó |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_metodo_activo`: `((activo in (0,1)) and (requiere_comprobante in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_metodo_codigo`: `regexp_like(codigo,'^[a-z_]{3,20}$','c')`

**Llaves foráneas**

- `fk_metodo_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_metodo_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_metodo_actualizado` (normal: actualizado_por); `fk_metodo_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: codigo)

**Triggers**: `trg_metodo_pago_bu` (BEFORE UPDATE), `trg_metodo_pago_bd` (BEFORE DELETE)

### pago

Pagos con máquina de estados. Un pago confirmado no se modifica: se reembolsa

**Referencia:** §2.2; §2.3 pago huérfano; §5.5-6

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_pago` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `metodo` | varchar(20) | no | ∅ | MUL | Método (FK metodo_pago) |
| `tipo` | enum('adelanto','saldo','total') | no | ∅ |  | Adelanto (modalidad 50 %), saldo o pago total |
| `monto` | decimal(12,2) | no | ∅ |  | Monto aplicado al pedido en su moneda (PEN) |
| `moneda` | char(3) | no | PEN |  | Debe ser la moneda del pedido |
| `moneda_cobro` | char(3) | sí | ∅ |  | Moneda que cobró la pasarela si difiere (p. ej. USD en PayPal) |
| `monto_cobro` | decimal(12,2) | sí | ∅ |  | Monto cobrado por la pasarela en moneda_cobro |
| `tipo_cambio` | decimal(10,6) | sí | ∅ |  | Tipo de cambio aplicado |
| `estado` | enum('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') | no | pendiente | MUL | Máquina de estados (transicion_estado_pago) |
| `aplicado_al_pedido` | tinyint(1) | no | 1 |  | 0 = pago huérfano: se confirmó con el pedido cancelado/expirado o excedía el total (por reembolsar) |
| `motivo_no_aplicado` | enum('pedido_cancelado','pedido_expirado','excede_total') | sí | ∅ |  | Por qué no se aplicó al pedido |
| `referencia_externa` | varchar(100) | sí | ∅ |  | Id de la pasarela o N.º de operación Yape/Plin/banco |
| `idempotency_key` | varchar(100) | no | ∅ | UNI | Clave única por intento de cobro (evita doble cobro por doble clic o reintentos) |
| `voucher_url` | varchar(500) | sí | ∅ |  | Captura del voucher (Yape/Plin/transferencia) |
| `datos_pasarela` | json | sí | ∅ |  | Respuesta filtrada de la pasarela. NUNCA número de tarjeta ni CVV |
| `validado_por` | bigint unsigned | sí | ∅ | MUL | Administrador que validó o rechazó (FK) |
| `validado_en` | datetime(3) | sí | ∅ |  | Cuándo se validó |
| `motivo_rechazo` | varchar(300) | sí | ∅ |  | Motivo del rechazo |
| `ip` | varbinary(16) | sí | ∅ |  | IP del cliente |
| `confirmado_en` | datetime(3) | sí | ∅ | MUL | Cuándo se confirmó |
| `monto_reembolsado` | decimal(12,2) | no | 0.00 |  | DERIVADO: reembolsos completados |
| `operacion_clave` | varchar(125) | sí | GENERADA: `if(((referencia_externa is not null) and (estado in ('pendiente','en_revision','confirmado','reembolsado'))),concat(metodo,':',referencia_externa),NULL)` | UNI | Índice único: una operación no se usa dos veces |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que creó |
| `actualizado_por` | bigint unsigned | sí | ∅ | MUL | Actor que modificó |

**Restricciones CHECK**

- `ck_pago_aplicado`: `((aplicado_al_pedido in (0,1)) and ((aplicado_al_pedido = 1) = (motivo_no_aplicado is null)))`
- `ck_pago_cobro`: `(((moneda_cobro is null) = (monto_cobro is null)) and ((monto_cobro is null) or (monto_cobro > 0)) and ((tipo_cambio is null) or (tipo_cambio > 0)))`
- `ck_pago_confirmado`: `((estado not in ('confirmado','reembolsado')) or (confirmado_en is not null))`
- `ck_pago_idempotencia`: `((char_length(idempotency_key) >= 16) and regexp_like(idempotency_key,'^[A-Za-z0-9._:-]+$','c'))`
- `ck_pago_moneda`: `((moneda = 'PEN') and ((moneda_cobro is null) or (moneda_cobro in ('PEN','USD'))))`
- `ck_pago_monto`: `((monto > 0) and (monto_reembolsado >= 0) and (monto_reembolsado <= monto))`
- `ck_pago_rechazo`: `((estado <> 'rechazado') or (motivo_rechazo is not null))`
- `ck_pago_reembolsado`: `((estado <> 'reembolsado') or (monto_reembolsado = monto))`
- `ck_pago_voucher`: `((voucher_url is null) or regexp_like(voucher_url,'^(https://\|/)[^[:space:]]+$','c'))`

**Llaves foráneas**

- `fk_pago_actualizado`: (actualizado_por) → `usuario`(id_usuario)
- `fk_pago_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_pago_metodo`: (metodo) → `metodo_pago`(codigo)
- `fk_pago_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_pago_validado`: (validado_por) → `usuario`(id_usuario)

**Índices**: `fk_pago_actualizado` (normal: actualizado_por); `fk_pago_creado` (normal: creado_por); `fk_pago_metodo` (normal: metodo); `fk_pago_validado` (normal: validado_por); `idx_pago_confirmado` (normal: confirmado_en); `idx_pago_estado` (normal: estado, creado_en); `idx_pago_pedido` (normal: id_pedido, estado); `PRIMARY` (único: id_pago); `uq_pago_idempotencia` (único: idempotency_key); `uq_pago_operacion` (único: operacion_clave)

**Triggers**: `trg_pago_bi` (BEFORE INSERT), `trg_pago_bu` (BEFORE UPDATE), `trg_pago_bd` (BEFORE DELETE), `trg_pago_ai` (AFTER INSERT), `trg_pago_au` (AFTER UPDATE)

### transicion_estado_pago

Transiciones permitidas de un pago

**Referencia:** §4 máquina de estados del pago

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `estado_origen` | enum('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') | no | ∅ | PRI | Desde |
| `estado_destino` | enum('pendiente','en_revision','confirmado','rechazado','fallido','anulado','reembolsado') | no | ∅ | PRI | Hacia |
| `descripcion` | varchar(150) | sí | ∅ |  | Explicación |

**Índices**: `PRIMARY` (único: estado_origen, estado_destino)

**Triggers**: `trg_transicion_estado_pago_bd` (BEFORE DELETE)

### reembolso

Reembolsos: quién, cuánto, por qué y referencia de la pasarela

**Referencia:** §4 reembolsos; §7.6

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_reembolso` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pago` | bigint unsigned | no | ∅ | MUL | Pago que se devuelve (FK) |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK, coherente con el pago) |
| `monto` | decimal(12,2) | no | ∅ |  | Monto a devolver (PEN) |
| `motivo` | enum('cancelacion','devolucion','pago_huerfano','excedente','error_cobro','ajuste_precio','otro') | no | ∅ |  | Motivo (ajuste_precio = descuento o compensación posterior a la venta) |
| `detalle` | varchar(300) | sí | ∅ |  | Detalle |
| `estado` | enum('solicitado','procesando','completado','fallido','anulado') | no | solicitado | MUL | Estado del reembolso |
| `medio` | enum('pasarela','yape','plin','transferencia','efectivo') | no | ∅ |  | Por dónde se devuelve |
| `referencia_externa` | varchar(100) | sí | ∅ |  | Id del reembolso en la pasarela o N.º de operación |
| `id_nota_credito` | bigint unsigned | sí | ∅ | MUL | Nota de crédito asociada (FK) |
| `id_devolucion` | bigint unsigned | sí | ∅ | MUL | Devolución asociada (FK) |
| `solicitado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo solicitó |
| `procesado_por` | bigint unsigned | sí | ∅ | MUL | Quién lo completó |
| `completado_en` | datetime(3) | sí | ∅ |  | Cuándo se completó |
| `error` | varchar(300) | sí | ∅ |  | Error si falló |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_reembolso_completado`: `((estado = 'completado') = (completado_en is not null))`
- `ck_reembolso_fallido`: `((estado <> 'fallido') or (error is not null))`
- `ck_reembolso_monto`: `(monto > 0)`

**Llaves foráneas**

- `fk_reembolso_devolucion`: (id_devolucion) → `devolucion`(id_devolucion)
- `fk_reembolso_nc`: (id_nota_credito) → `comprobante`(id_comprobante)
- `fk_reembolso_pago`: (id_pago) → `pago`(id_pago)
- `fk_reembolso_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_reembolso_procesado`: (procesado_por) → `usuario`(id_usuario)
- `fk_reembolso_solicitado`: (solicitado_por) → `usuario`(id_usuario)

**Índices**: `fk_reembolso_devolucion` (normal: id_devolucion); `fk_reembolso_nc` (normal: id_nota_credito); `fk_reembolso_procesado` (normal: procesado_por); `fk_reembolso_solicitado` (normal: solicitado_por); `idx_reembolso_estado` (normal: estado, creado_en); `idx_reembolso_pago` (normal: id_pago, estado); `idx_reembolso_pedido` (normal: id_pedido); `PRIMARY` (único: id_reembolso)

**Triggers**: `trg_reembolso_bi` (BEFORE INSERT), `trg_reembolso_bu` (BEFORE UPDATE), `trg_reembolso_bd` (BEFORE DELETE), `trg_reembolso_au` (AFTER UPDATE)

### evento_pasarela

Webhooks recibidos (idempotentes: cada evento se procesa una sola vez)

**Referencia:** §2.10 webhooks idempotentes

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_evento` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `proveedor` | enum('mercadopago','paypal','ose','courier') | no | ∅ | MUL | Quién envió el webhook |
| `id_externo` | varchar(150) | no | ∅ |  | Id del evento en el proveedor (idempotencia) |
| `tipo` | varchar(80) | sí | ∅ |  | Tipo de evento (payment.updated, ...) |
| `payload` | json | no | ∅ |  | Cuerpo recibido (sin datos de tarjeta) |
| `firma_valida` | tinyint(1) | no | ∅ |  | 1 = la app verificó la firma del webhook |
| `estado` | enum('recibido','procesado','ignorado','error') | no | recibido | MUL | Procesamiento |
| `intentos` | smallint unsigned | no | 0 |  | Veces que llegó/procesó |
| `error` | text | sí | ∅ |  | Error de procesamiento |
| `id_pago` | bigint unsigned | sí | ∅ | MUL | Pago afectado (FK) |
| `id_comprobante` | bigint unsigned | sí | ∅ | MUL | Comprobante afectado (FK) |
| `recibido_en` | datetime(3) | no | utc_timestamp(3) |  | Recepción (UTC) |
| `procesado_en` | datetime(3) | sí | ∅ |  | Procesamiento (UTC) |

**Restricciones CHECK**

- `ck_evento_firma`: `(firma_valida in (0,1))`

**Llaves foráneas**

- `fk_evento_comprobante`: (id_comprobante) → `comprobante`(id_comprobante)
- `fk_evento_pago`: (id_pago) → `pago`(id_pago)

**Índices**: `fk_evento_comprobante` (normal: id_comprobante); `fk_evento_pago` (normal: id_pago); `idx_evento_estado` (normal: estado, recibido_en); `PRIMARY` (único: id_evento); `uq_evento_proveedor` (único: proveedor, id_externo)

**Triggers**: `trg_evento_pasarela_bi` (BEFORE INSERT), `trg_evento_pasarela_bu` (BEFORE UPDATE), `trg_evento_pasarela_bd` (BEFORE DELETE)


## Comprobantes electrónicos

### serie_comprobante

Series de comprobantes y su correlativo atómico

**Referencia:** §2.8 series (reemplazar por las reales del OSE)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_serie` | smallint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `tipo` | enum('boleta','factura','nota_credito') | no | ∅ | MUL | Tipo de comprobante |
| `serie` | char(4) | no | ∅ |  | Serie (B### boleta, F### factura; NC: B### si anula boletas, F### si anula facturas) |
| `ultimo_correlativo` | int unsigned | no | 0 |  | Último correlativo usado |
| `por_verificar` | tinyint(1) | no | 1 |  | 1 = serie de ejemplo: reemplazar por la real del OSE |
| `activo` | tinyint(1) | no | 1 |  | Borrado lógico |
| `inhabilitado_en` | datetime(3) | sí | ∅ |  | Cuándo se inhabilitó |
| `inhabilitado_por` | bigint unsigned | sí | ∅ | MUL | Quién la inhabilitó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_serie_activo`: `((activo in (0,1)) and (por_verificar in (0,1)) and ((activo = 0) = (inhabilitado_en is not null)))`
- `ck_serie_correlativo`: `(ultimo_correlativo <= 99999999)`
- `ck_serie_formato`: `(((tipo = 'boleta') and regexp_like(serie,'^B[A-Z0-9]{3}$','c')) or ((tipo = 'factura') and regexp_like(serie,'^F[A-Z0-9]{3}$','c')) or ((tipo = 'nota_credito') and regexp_like(serie,'^[BF][A-Z0-9]{3}$','c')))`

**Llaves foráneas**

- `fk_serie_inhabilitado`: (inhabilitado_por) → `usuario`(id_usuario)

**Índices**: `fk_serie_inhabilitado` (normal: inhabilitado_por); `PRIMARY` (único: id_serie); `uq_serie_tipo` (único: tipo, serie)

**Triggers**: `trg_serie_comprobante_bu` (BEFORE UPDATE), `trg_serie_comprobante_bd` (BEFORE DELETE)

### motivo_nota_credito

Catálogo SUNAT N.º 09: tipos de nota de crédito

**Referencia:** §2.8 catálogo SUNAT 09

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `codigo` | char(2) | no | ∅ | PRI | Código SUNAT (catálogo 09) |
| `descripcion` | varchar(200) | no | ∅ |  | Descripción SUNAT |
| `es_total` | tinyint(1) | no | 0 |  | 1 = la NC debe ser por el total pendiente del comprobante |
| `repone_stock` | tinyint(1) | no | 0 |  | 1 = corresponde a una devolución de mercadería |
| `activo` | tinyint(1) | no | 1 |  | Disponible para usar |

**Restricciones CHECK**

- `ck_motivo_nc`: `(regexp_like(codigo,'^[0-9]{2}$','c') and (es_total in (0,1)) and (repone_stock in (0,1)) and (activo in (0,1)))`

**Índices**: `PRIMARY` (único: codigo)

**Triggers**: `trg_motivo_nota_credito_bd` (BEFORE DELETE)

### comprobante

Comprobantes electrónicos con copia completa de lo emitido (emisor y cliente congelados, payloads del OSE)

**Referencia:** §2.8 copia completa de lo emitido

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_comprobante` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_pedido` | bigint unsigned | no | ∅ | MUL | Pedido (FK) |
| `tipo` | enum('boleta','factura','nota_credito') | no | ∅ | MUL | Tipo de comprobante |
| `codigo_tipo_sunat` | char(2) | sí | GENERADA: `(case tipo when 'factura' then '01' when 'boleta' then '03' else '07' end)` |  | Catálogo 01 SUNAT: 01 factura, 03 boleta, 07 nota de crédito |
| `id_serie` | smallint unsigned | no | ∅ | MUL | Serie usada (FK) |
| `serie` | char(4) | no | ∅ |  | Copia de la serie |
| `correlativo` | int unsigned | no | ∅ |  | Correlativo dentro de la serie |
| `numero_completo` | varchar(13) | sí | GENERADA: `concat(serie,'-',lpad(correlativo,8,'0'))` |  | Serie-correlativo (F001-00000001) |
| `id_comprobante_ref` | bigint unsigned | sí | ∅ | MUL | Comprobante que corrige la nota de crédito (FK) |
| `codigo_motivo_nc` | char(2) | sí | ∅ | MUL | Motivo de la NC (FK catálogo 09) |
| `motivo_detalle` | varchar(250) | sí | ∅ |  | Sustento de la NC |
| `id_devolucion` | bigint unsigned | sí | ∅ | MUL | Devolución que originó la NC (FK) |
| `fecha_emision` | date | no | ∅ | MUL | Fecha de emisión (día de Lima) |
| `emisor_ruc` | char(11) | no | ∅ |  | Copia: RUC del emisor |
| `emisor_razon_social` | varchar(200) | no | ∅ |  | Copia: razón social del emisor |
| `emisor_nombre_comercial` | varchar(200) | sí | ∅ |  | Copia: nombre comercial |
| `emisor_domicilio_fiscal` | varchar(300) | no | ∅ |  | Copia: domicilio fiscal del emisor |
| `cliente_tipo_doc` | enum('DNI','RUC','CE') | sí | ∅ |  | Copia: tipo de documento del cliente (NULL = sin documento, solo boleta bajo el umbral) |
| `cliente_num_doc` | varchar(12) | sí | ∅ |  | Copia: número de documento |
| `cliente_nombre` | varchar(200) | no | ∅ |  | Copia: nombre o razón social |
| `cliente_direccion` | varchar(300) | sí | ∅ |  | Copia: dirección / domicilio fiscal |
| `cliente_correo` | varchar(254) | sí | ∅ |  | Copia: correo de envío |
| `moneda` | char(3) | no | PEN |  | Moneda |
| `igv_porcentaje` | decimal(5,2) | no | ∅ |  | Tasa de IGV aplicada (copia) |
| `op_gravada` | decimal(12,2) | no | ∅ |  | Operaciones gravadas (sin IGV) |
| `op_exonerada` | decimal(12,2) | no | 0.00 |  | Operaciones exoneradas |
| `op_inafecta` | decimal(12,2) | no | 0.00 |  | Operaciones inafectas |
| `igv` | decimal(12,2) | no | ∅ |  | IGV |
| `total` | decimal(12,2) | no | ∅ |  | Importe total |
| `estado_sunat` | enum('pendiente','enviado','aceptado','observado','rechazado','anulado','error') | no | pendiente | MUL | Estado ante SUNAT/OSE |
| `proveedor_ose` | varchar(40) | sí | ∅ |  | Proveedor OSE/PSE usado |
| `id_externo` | varchar(100) | sí | ∅ |  | Id del comprobante en el OSE/PSE |
| `hash_cpe` | varchar(100) | sí | ∅ |  | Hash / código de resumen del CPE |
| `codigo_respuesta_sunat` | varchar(10) | sí | ∅ |  | Código de respuesta del CDR |
| `mensaje_sunat` | text | sí | ∅ |  | Mensaje de SUNAT/OSE |
| `url_pdf` | varchar(500) | sí | ∅ |  | URL del PDF en el OSE |
| `url_xml` | varchar(500) | sí | ∅ |  | URL del XML firmado |
| `url_cdr` | varchar(500) | sí | ∅ |  | URL del CDR |
| `payload_envio` | json | sí | ∅ |  | JSON enviado al OSE (copia exacta) |
| `payload_respuesta` | json | sí | ∅ |  | Respuesta del OSE (copia exacta) |
| `enviado_correo_en` | datetime(3) | sí | ∅ |  | Cuándo se envió al cliente |
| `aceptado_en` | datetime(3) | sí | ∅ |  | Cuándo lo aceptó SUNAT/OSE |
| `pedido_activo_clave` | bigint unsigned | sí | GENERADA: `if(((tipo in ('boleta','factura')) and (estado_sunat not in ('rechazado','anulado'))),id_pedido,NULL)` | UNI | Índice único: una sola boleta/factura vigente por pedido (idempotencia de emisión) |
| `emitido_en` | datetime(3) | no | utc_timestamp(3) |  | Registro (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |
| `creado_por` | bigint unsigned | sí | ∅ | MUL | Actor que emitió |

**Restricciones CHECK**

- `ck_comprobante_aceptado`: `((estado_sunat not in ('aceptado','observado')) or (aceptado_en is not null))`
- `ck_comprobante_correlativo`: `(correlativo between 1 and 99999999)`
- `ck_comprobante_cuadre`: `((((op_gravada + op_exonerada) + op_inafecta) + igv) = total)`
- `ck_comprobante_documento`: `(((cliente_tipo_doc is null) and (cliente_num_doc is null)) or ((cliente_tipo_doc = 'DNI') and regexp_like(cliente_num_doc,'^[0-9]{8}$','c')) or ((cliente_tipo_doc = 'RUC') and regexp_like(cliente_num_doc,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')) or ((cliente_tipo_doc = 'CE') and regexp_like(cliente_num_doc,'^[A-Z0-9]{6,12}$','c')))`
- `ck_comprobante_factura`: `((tipo <> 'factura') or ((cliente_tipo_doc = 'RUC') and (cliente_num_doc is not null)))`
- `ck_comprobante_moneda`: `(moneda = 'PEN')`
- `ck_comprobante_montos`: `((op_gravada >= 0) and (op_exonerada >= 0) and (op_inafecta >= 0) and (igv >= 0) and (total > 0))`
- `ck_comprobante_nc`: `(((tipo = 'nota_credito') = (id_comprobante_ref is not null)) and ((tipo <> 'nota_credito') or ((codigo_motivo_nc is not null) and (motivo_detalle is not null))))`
- `ck_comprobante_ruc`: `regexp_like(emisor_ruc,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')`
- `ck_comprobante_serie`: `(((tipo = 'boleta') and (serie like 'B%')) or ((tipo = 'factura') and (serie like 'F%')) or ((tipo = 'nota_credito') and ((serie like 'B%') or (serie like 'F%'))))`

**Llaves foráneas**

- `fk_comprobante_creado`: (creado_por) → `usuario`(id_usuario)
- `fk_comprobante_devolucion`: (id_devolucion) → `devolucion`(id_devolucion)
- `fk_comprobante_motivo`: (codigo_motivo_nc) → `motivo_nota_credito`(codigo)
- `fk_comprobante_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_comprobante_ref`: (id_comprobante_ref) → `comprobante`(id_comprobante)
- `fk_comprobante_serie`: (id_serie) → `serie_comprobante`(id_serie)

**Índices**: `fk_comprobante_creado` (normal: creado_por); `fk_comprobante_devolucion` (normal: id_devolucion); `fk_comprobante_motivo` (normal: codigo_motivo_nc); `fk_comprobante_serie` (normal: id_serie); `idx_comprobante_estado` (normal: estado_sunat, emitido_en); `idx_comprobante_fecha` (normal: fecha_emision); `idx_comprobante_pedido` (normal: id_pedido); `idx_comprobante_ref` (normal: id_comprobante_ref); `PRIMARY` (único: id_comprobante); `uq_comprobante_numero` (único: tipo, serie, correlativo); `uq_comprobante_pedido_activo` (único: pedido_activo_clave)

**Triggers**: `trg_comprobante_bi` (BEFORE INSERT), `trg_comprobante_bu` (BEFORE UPDATE), `trg_comprobante_bd` (BEFORE DELETE), `trg_comprobante_au` (AFTER UPDATE)

### comprobante_item

Líneas del comprobante tal como se emitieron (solo inserción)

**Referencia:** §2.8 líneas del comprobante

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_comprobante_item` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_comprobante` | bigint unsigned | no | ∅ | MUL | Comprobante (FK) |
| `orden` | smallint unsigned | no | ∅ |  | N.º de línea |
| `id_item_pedido` | bigint unsigned | sí | ∅ | MUL | Ítem del pedido de origen (NULL en la línea de envío) |
| `codigo_producto` | varchar(40) | sí | ∅ |  | SKU o código interno |
| `descripcion` | varchar(250) | no | ∅ |  | Descripción impresa |
| `unidad_medida` | char(3) | no | NIU |  | Unidad SUNAT (NIU bienes, ZZ servicios) |
| `cantidad` | decimal(12,3) | no | ∅ |  | Cantidad |
| `precio_unitario` | decimal(12,2) | no | ∅ |  | Precio unitario con IGV |
| `valor_unitario` | decimal(16,6) | no | ∅ |  | Valor unitario sin IGV |
| `valor_venta` | decimal(12,2) | no | ∅ |  | Valor de venta de la línea (sin IGV) |
| `igv` | decimal(12,2) | no | ∅ |  | IGV de la línea |
| `total_linea` | decimal(12,2) | no | ∅ |  | Total de la línea con IGV |
| `codigo_afectacion_igv` | char(2) | no | 10 |  | Tipo de afectación IGV (catálogo 07) |

**Restricciones CHECK**

- `ck_citem_cuadre`: `((valor_venta + igv) = total_linea)`
- `ck_citem_montos`: `((cantidad > 0) and (precio_unitario > 0) and (valor_unitario > 0) and (valor_venta > 0) and (igv >= 0))`

**Llaves foráneas**

- `fk_citem_comprobante`: (id_comprobante) → `comprobante`(id_comprobante)
- `fk_citem_item`: (id_item_pedido) → `item_pedido`(id_item_pedido)

**Índices**: `idx_comprobante_item_pedido` (normal: id_item_pedido); `PRIMARY` (único: id_comprobante_item); `uq_comprobante_item_orden` (único: id_comprobante, orden)

**Triggers**: `trg_comprobante_item_bi` (BEFORE INSERT), `trg_comprobante_item_bu` (BEFORE UPDATE), `trg_comprobante_item_bd` (BEFORE DELETE)

### comprobante_archivo

PDF/XML/CDR del comprobante en BLOB, tabla aparte para no cargar la cabecera (solo inserción)

**Referencia:** §2.8 PDF/XML/CDR en BLOB

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_archivo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_comprobante` | bigint unsigned | no | ∅ | MUL | Comprobante (FK) |
| `tipo` | enum('pdf','xml','cdr') | no | ∅ |  | Tipo de archivo |
| `mime` | varchar(60) | no | ∅ |  | Tipo MIME |
| `contenido` | longblob | no | ∅ |  | Copia binaria del archivo (respaldo si la URL del OSE deja de funcionar) |
| `tamano_bytes` | int unsigned | no | ∅ |  | Tamaño |
| `sha256` | char(64) | no | ∅ |  | Huella del contenido (integridad) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Registro (UTC) |

**Restricciones CHECK**

- `ck_archivo_sha`: `regexp_like(sha256,'^[0-9a-f]{64}$','c')`
- `ck_archivo_tamano`: `((tamano_bytes > 0) and (tamano_bytes <= 16777216))`

**Llaves foráneas**

- `fk_archivo_comprobante`: (id_comprobante) → `comprobante`(id_comprobante)

**Índices**: `PRIMARY` (único: id_archivo); `uq_archivo_tipo` (único: id_comprobante, tipo)

**Triggers**: `trg_comprobante_archivo_bu` (BEFORE UPDATE), `trg_comprobante_archivo_bd` (BEFORE DELETE)

### cola_emision_comprobante

Cola de emisión asíncrona y reintentable hacia el OSE/PSE

**Referencia:** §2.8 emisión asíncrona y reintentable

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_trabajo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_comprobante` | bigint unsigned | no | ∅ | UNI | Comprobante a emitir (FK, uno por comprobante) |
| `estado` | enum('pendiente','procesando','completado','error','descartado') | no | pendiente | MUL | Estado del trabajo |
| `intentos` | smallint unsigned | no | 0 |  | Intentos realizados |
| `max_intentos` | smallint unsigned | no | 8 |  | Tope de intentos |
| `proximo_intento_en` | datetime(3) | no | utc_timestamp(3) |  | No antes de (backoff exponencial) |
| `ultimo_error` | text | sí | ∅ |  | Último error |
| `tomado_por` | varchar(64) | sí | ∅ |  | Worker que lo tomó |
| `tomado_en` | datetime(3) | sí | ∅ |  | Cuándo lo tomó |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Creación (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_cola_emision_intentos`: `((intentos <= max_intentos) and (max_intentos between 1 and 50))`

**Llaves foráneas**

- `fk_cola_emision_comprobante`: (id_comprobante) → `comprobante`(id_comprobante)

**Índices**: `idx_cola_emision` (normal: estado, proximo_intento_en); `PRIMARY` (único: id_trabajo); `uq_cola_emision_comprobante` (único: id_comprobante)

**Triggers**: `trg_cola_emision_comprobante_bu` (BEFORE UPDATE), `trg_cola_emision_comprobante_bd` (BEFORE DELETE)


## Atención al cliente

### mensaje_contacto

Mensajes de contacto como tickets (máx. 3 por hora por IP)

**Referencia:** §4 contacto (máx. 3 por hora por IP)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_mensaje` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `ticket` | varchar(25) | no | ∅ | UNI | Correlativo anual TK-AAAA-NNNNNN |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario si estaba logueado (FK) |
| `nombre` | varchar(100) | no | ∅ |  | Nombre |
| `correo` | varchar(254) | no | ∅ |  | Correo (normalizado) |
| `celular` | varchar(16) | sí | ∅ |  | Celular |
| `asunto` | enum('producto','pedido','mayor','sugerencia','otro') | no | ∅ |  | Asunto |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido relacionado (FK) |
| `mensaje` | varchar(2000) | no | ∅ |  | Mensaje (mín. 10 caracteres) |
| `acepto_datos` | tinyint(1) | no | ∅ |  | Aceptó la política de datos (obligatorio) |
| `ip` | varbinary(16) | sí | ∅ | MUL | IP (límite 3 por hora) |
| `estado` | enum('nuevo','en_proceso','respondido','cerrado') | no | nuevo | MUL | Estado del ticket |
| `atendido_por` | bigint unsigned | sí | ∅ | MUL | Administrador asignado (FK) |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Recepción (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_mensaje_celular`: `((celular is null) or regexp_like(celular,'^[+]?[0-9]{9,15}$','c'))`
- `ck_mensaje_correo`: `regexp_like(correo,'^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$','c')`
- `ck_mensaje_datos`: `(acepto_datos = 1)`
- `ck_mensaje_texto`: `((char_length(trim(mensaje)) >= 10) and (char_length(trim(nombre)) >= 2))`

**Llaves foráneas**

- `fk_mensaje_atendido`: (atendido_por) → `usuario`(id_usuario)
- `fk_mensaje_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_mensaje_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_mensaje_atendido` (normal: atendido_por); `fk_mensaje_pedido` (normal: id_pedido); `fk_mensaje_usuario` (normal: id_usuario); `idx_mensaje_estado` (normal: estado, creado_en); `idx_mensaje_ip` (normal: ip, creado_en); `PRIMARY` (único: id_mensaje); `uq_mensaje_ticket` (único: ticket)

**Triggers**: `trg_mensaje_contacto_bi` (BEFORE INSERT), `trg_mensaje_contacto_bu` (BEFORE UPDATE), `trg_mensaje_contacto_bd` (BEFORE DELETE)

### reclamo

Libro de Reclamaciones virtual (plazo configurable, verificar INDECOPI)

**Referencia:** §4 Libro de Reclamaciones (plazo: verificar INDECOPI)

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_reclamo` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `numero` | varchar(25) | no | ∅ | UNI | Correlativo anual LR-AAAA-NNNNNN |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario si estaba logueado (FK) |
| `nombres` | varchar(100) | no | ∅ |  | Nombres del consumidor |
| `apellidos` | varchar(100) | no | ∅ |  | Apellidos del consumidor |
| `tipo_doc` | enum('DNI','RUC','CE') | no | ∅ |  | Documento |
| `num_doc` | varchar(12) | no | ∅ |  | Número de documento |
| `domicilio` | varchar(200) | no | ∅ |  | Domicilio |
| `correo` | varchar(254) | no | ∅ |  | Correo (normalizado) |
| `celular` | varchar(16) | no | ∅ |  | Teléfono |
| `es_menor_edad` | tinyint(1) | no | 0 |  | 1 = consumidor menor de edad |
| `apoderado_nombre` | varchar(200) | sí | ∅ |  | Padre/madre/apoderado si es menor |
| `tipo_bien` | enum('producto','servicio') | no | ∅ |  | Bien contratado |
| `monto_reclamado` | decimal(12,2) | sí | ∅ |  | Monto reclamado |
| `descripcion_bien` | varchar(300) | no | ∅ |  | Descripción del bien |
| `tipo` | enum('reclamo','queja') | no | ∅ |  | Reclamo o queja |
| `detalle` | text | no | ∅ |  | Detalle |
| `pedido_consumidor` | text | no | ∅ |  | Lo que pide el consumidor |
| `id_pedido` | bigint unsigned | sí | ∅ | MUL | Pedido relacionado (FK) |
| `estado` | enum('registrado','en_atencion','respondido','cerrado') | no | registrado | MUL | Estado |
| `fecha_limite` | date | no | ∅ |  | Fecha límite de respuesta (plazo configurable: verificar INDECOPI) |
| `respondido_por` | bigint unsigned | sí | ∅ | MUL | Quién respondió (FK) |
| `respondido_en` | datetime(3) | sí | ∅ |  | Cuándo respondió |
| `acepto_datos` | tinyint(1) | no | ∅ |  | Aceptó la política de datos |
| `ip` | varbinary(16) | sí | ∅ | MUL | IP |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Registro (UTC) |
| `actualizado_en` | datetime(3) | no | utc_timestamp(3) |  | Última modificación (UTC) |

**Restricciones CHECK**

- `ck_reclamo_correo`: `regexp_like(correo,'^[a-z0-9._%+-]+@[a-z0-9-]+([.][a-z0-9-]+)*[.][a-z]{2,24}$','c')`
- `ck_reclamo_datos`: `(acepto_datos = 1)`
- `ck_reclamo_documento`: `(((tipo_doc = 'DNI') and regexp_like(num_doc,'^[0-9]{8}$','c')) or ((tipo_doc = 'RUC') and regexp_like(num_doc,'^(10\|15\|16\|17\|20)[0-9]{9}$','c')) or ((tipo_doc = 'CE') and regexp_like(num_doc,'^[A-Z0-9]{6,12}$','c')))`
- `ck_reclamo_menor`: `((es_menor_edad in (0,1)) and ((es_menor_edad = 0) or (apoderado_nombre is not null)))`
- `ck_reclamo_monto`: `((monto_reclamado is null) or (monto_reclamado >= 0))`
- `ck_reclamo_respuesta`: `((estado not in ('respondido','cerrado')) or (respondido_en is not null))`

**Llaves foráneas**

- `fk_reclamo_pedido`: (id_pedido) → `pedido`(id_pedido)
- `fk_reclamo_respondido`: (respondido_por) → `usuario`(id_usuario)
- `fk_reclamo_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_reclamo_pedido` (normal: id_pedido); `fk_reclamo_respondido` (normal: respondido_por); `fk_reclamo_usuario` (normal: id_usuario); `idx_reclamo_estado` (normal: estado, fecha_limite); `idx_reclamo_ip` (normal: ip, creado_en); `PRIMARY` (único: id_reclamo); `uq_reclamo_numero` (único: numero)

**Triggers**: `trg_reclamo_bi` (BEFORE INSERT), `trg_reclamo_bu` (BEFORE UPDATE), `trg_reclamo_bd` (BEFORE DELETE)

### respuesta_atencion

Historial de respuestas de tickets y reclamos (solo inserción)

**Referencia:** §4 respuestas con historial

| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |
|---|---|---|---|---|---|
| `id_respuesta` | bigint unsigned | no | AUTO_INCREMENT | PRI | Identificador |
| `id_mensaje` | bigint unsigned | sí | ∅ | MUL | Ticket de contacto (FK) — exactamente uno de los dos |
| `id_reclamo` | bigint unsigned | sí | ∅ | MUL | Reclamo (FK) — exactamente uno de los dos |
| `autor` | enum('administrador','cliente') | no | ∅ |  | Quién escribe |
| `id_usuario` | bigint unsigned | sí | ∅ | MUL | Usuario autor (FK) |
| `mensaje` | text | no | ∅ |  | Texto de la respuesta |
| `creado_en` | datetime(3) | no | utc_timestamp(3) |  | Momento (UTC) |

**Restricciones CHECK**

- `ck_respuesta_destino`: `((id_mensaje is null) <> (id_reclamo is null))`
- `ck_respuesta_texto`: `(char_length(trim(mensaje)) >= 2)`

**Llaves foráneas**

- `fk_respuesta_mensaje`: (id_mensaje) → `mensaje_contacto`(id_mensaje)
- `fk_respuesta_reclamo`: (id_reclamo) → `reclamo`(id_reclamo)
- `fk_respuesta_usuario`: (id_usuario) → `usuario`(id_usuario)

**Índices**: `fk_respuesta_usuario` (normal: id_usuario); `idx_respuesta_mensaje` (normal: id_mensaje, creado_en); `idx_respuesta_reclamo` (normal: id_reclamo, creado_en); `PRIMARY` (único: id_respuesta)

**Triggers**: `trg_respuesta_atencion_bu` (BEFORE UPDATE), `trg_respuesta_atencion_bd` (BEFORE DELETE)


## Vistas

| Vista | Columnas |
|---|---|
| `v_administradores_sin_2fa` | id_usuario, nombre_completo, correo |
| `v_auditoria` | id_auditoria, fecha_lima, evento, entidad, id_entidad, actor, id_usuario_afectado, detalle, origen, usuario_bd, ip |
| `v_banners_vigentes` | id_banner, titulo, subtitulo, imagen_url, enlace, texto_boton, orden |
| `v_catalogo_productos` | id_producto, slug, nombre, descripcion, id_categoria, categoria, categoria_slug, tipo_fabricacion, dias_produccion, permite_personalizacion, destacado, precio_desde, precio_base, stock_disponible, disponible, imagen_principal, valoracion_promedio, total_resenas, tiene_precio_volumen |
| `v_clientes_resumen` | id_usuario, nombre_completo, correo, celular, tipo_documento, numero_documento, estado, pedidos, total_compras, ultimo_pedido_lima, registrado_lima |
| `v_cola_emision` | id_trabajo, id_comprobante, numero_completo, tipo, estado_sunat, estado, intentos, max_intentos, proximo_intento_lima, ultimo_error, tomado_por |
| `v_comprobante_copia_completa` | id_comprobante, id_pedido, tipo, codigo_tipo_sunat, serie, correlativo, numero_completo, fecha_emision, emisor_ruc, emisor_razon_social, emisor_nombre_comercial, emisor_domicilio_fiscal, cliente_tipo_doc, cliente_num_doc, cliente_nombre, cliente_direccion, cliente_correo, moneda, igv_porcentaje, op_gravada, op_exonerada, op_inafecta, igv, total, id_comprobante_ref, codigo_motivo_nc, motivo_nc, motivo_detalle, estado_sunat, proveedor_ose, id_externo, hash_cpe, codigo_respuesta_sunat, mensaje_sunat, url_pdf, url_xml, url_cdr, payload_envio, payload_respuesta, registrado_lima, aceptado_lima |
| `v_comprobante_items` | id_comprobante, numero_completo, orden, codigo_producto, descripcion, unidad_medida, cantidad, precio_unitario, valor_unitario, valor_venta, igv, total_linea, codigo_afectacion_igv |
| `v_comprobantes` | id_comprobante, id_pedido, pedido, tipo, codigo_tipo_sunat, numero_completo, fecha_emision, cliente_tipo_doc, cliente_num_doc, cliente_nombre, moneda, op_gravada, igv, total, estado_sunat, codigo_respuesta_sunat, mensaje_sunat, comprobante_referencia, codigo_motivo_nc, motivo_detalle, url_pdf, url_xml, url_cdr, tiene_copia_archivo, registrado_lima, aceptado_lima, enviado_correo_lima |
| `v_configuracion_por_verificar` | clave, valor, descripcion, nota_verificacion |
| `v_correos_pendientes` | id_correo, destinatario, plantilla, prioridad, estado, intentos, max_intentos, proximo_intento_lima, ultimo_error |
| `v_cotizaciones` | id_cotizacion, numero, id_usuario, cliente, origen, estado, descripcion, fecha_entrega_solicitada, subtotal, costo_envio, total, adelanto_porcentaje, vigencia_hasta, aceptable, pedido, solicitado_lima, cotizado_lima |
| `v_envios_seguimiento` | id_envio, id_pedido, pedido, courier, numero_guia, url_seguimiento, estado, fecha_entrega_estimada, despachado_lima, entregado_lima, ultimo_evento, ultima_ubicacion, ultimo_evento_lima |
| `v_eventos_pasarela_con_error` | id_evento, proveedor, id_externo, tipo, estado, intentos, error, id_pago, firma_valida, recibido_lima |
| `v_historial_contrasena_reciente` | id_usuario, hash_contrasena, creado_en |
| `v_historial_pedido` | id_historial, id_pedido, numero, estado_anterior, estado_nuevo, estado_nombre, realizado_por, comentario, fecha_lima |
| `v_inconsistencias` | control, id, detalle |
| `v_ingresos_diarios` | fecha, metodo, pagos, cobrado, reembolsado, neto |
| `v_insumos_stock_bajo` | id_insumo, nombre, tipo, unidad, stock_actual, stock_minimo |
| `v_kardex` | id_movimiento, fecha_lima, id_variante, sku, producto, talla, color, tipo, cantidad, stock_actual_resultante, stock_reservado_resultante, disponible_resultante, pedido, devolucion, realizado_por, motivo |
| `v_kardex_insumos` | id_movimiento, fecha_lima, id_insumo, insumo, unidad, tipo, cantidad, stock_resultante, pedido, realizado_por, motivo |
| `v_mensajes_contacto_pendientes` | id_mensaje, ticket, nombre, correo, asunto, id_pedido, extracto, estado, recibido_lima |
| `v_notas_credito_pendientes` | id_comprobante, numero_completo, id_pedido, pedido, motivo, motivo_sunat_sugerido, monto_sugerido, id_devolucion, estado_sunat |
| `v_notas_credito_saldo` | id_comprobante, numero_completo, tipo, estado_sunat, total, notas_credito, saldo_disponible |
| `v_pagos_por_reembolsar` | id_pago, id_pedido, pedido, estado_pedido, cliente, cliente_correo, metodo, monto, referencia_externa, reembolso_en_curso_o_hecho, pendiente_de_reembolsar, motivo, id_devolucion, confirmado_lima |
| `v_pagos_por_validar` | id_pago, id_pedido, pedido, cliente, metodo, metodo_nombre, tipo, monto, numero_operacion, voucher_url, saldo_pedido, registrado_lima |
| `v_pedido_detalle` | id_item_pedido, id_pedido, numero, id_variante, id_producto, nombre_producto, sku, talla, color, tipo_fabricacion, cantidad, cantidad_devuelta, precio_lista, precio_unitario, origen_precio, subtotal, personalizacion |
| `v_pedidos_estado` | id_pedido, numero, id_usuario, cliente, cliente_correo, estado, estado_nombre, estado_grupo, estado_orden, estado_pago, modalidad_pago, adelanto_porcentaje, monto_requerido, tipo_venta, canal, tipo_entrega, comprobante_solicitado, subtotal, descuento, costo_envio, total, monto_pagado, monto_reembolsado, monto_neto_pagado, monto_devuelto, monto_ajustes, saldo, saldo_a_favor_cliente, fecha_entrega_solicitada, fecha_entrega_estimada, creado_lima, expira_lima, confirmado_lima, entregado_lima, cancelado_lima, motivo_cancelacion, id_pedido_origen, id_cotizacion |
| `v_precios_volumen` | id_producto, producto, cantidad_minima, precio_unitario |
| `v_productos_mas_vendidos` | id_producto, nombre, categoria, unidades, ingresos, pedidos |
| `v_reclamos_pendientes` | id_reclamo, numero, tipo, consumidor, tipo_doc, num_doc, estado, fecha_limite, dias_restantes, registrado_lima |
| `v_reembolsos` | id_reembolso, id_pago, id_pedido, pedido, monto, motivo, detalle, estado, medio, referencia_externa, nota_credito, devolucion, solicitado_por, procesado_por, solicitado_lima, completado_lima, error |
| `v_resenas_publicadas` | id_resena, id_producto, calificacion, titulo, comentario, autor, creado_lima |
| `v_reservas_activas` | id_reserva, id_pedido, numero, id_variante, sku, cantidad, reservado_lima, expira_lima |
| `v_resumen_estados_pedido` | estado_grupo, estado, estado_nombre, orden, pedidos, monto_total |
| `v_solicitudes_arco_pendientes` | id_solicitud, numero, tipo, nombres, tipo_documento, numero_documento, estado, fecha_limite, dias_restantes, recibida_lima |
| `v_stock_bajo` | id_variante, id_producto, producto, sku, talla, color, stock_actual, stock_reservado, stock_disponible, stock_minimo |
| `v_transiciones_pedido` | estado_origen, origen_nombre, estado_destino, destino_nombre, tipo_entrega_aplicable, automatica, permitido_cliente, requiere_saldo_cero, descripcion |
| `v_usuarios` | id_usuario, rol, nombre_completo, correo, celular, tipo_documento, numero_documento, estado, bloqueado, tiene_2fa, ultimo_acceso_lima, registrado_lima, inhabilitado_lima |
| `v_variantes_disponibles` | id_variante, id_producto, producto, sku, talla, color, precio, stock_disponible, disponible |
| `v_ventas_diarias` | fecha, tipo_venta, canal, pedidos, subtotal, envio, devuelto, ajustes, total_neto |
| `v_ventas_por_categoria` | id_categoria, categoria, unidades, ingresos |

## Procedimientos y funciones

Prefijos: `fn_` función · `sp_` procedimiento público (una transacción) · `spi_` interno (sin transacción, lo usan otros procedimientos y los triggers).

| Nombre | Tipo | Parámetros | Descripción |
|---|---|---|---|
| `fn_actor` | función | → bigint unsigned | Usuario que actúa en esta sesión (@app_actor_id fijado por Django). NULL = sistema |
| `fn_borrado_dba_autorizado` | función | → tinyint(1) | 1 solo si la sesión es de la cuenta DBA de mantenimiento (wanka_dba) y declaró @wanka_autorizo_borrado = 'SI-AUTORIZO' |
| `fn_config` | función | → varchar(500), IN p_clave varchar(60) | Valor de configuración como texto; error 45020 si la clave no existe |
| `fn_config_decimal` | función | → decimal(14,4), IN p_clave varchar(60) | Valor de configuración decimal |
| `fn_config_entero` | función | → bigint, IN p_clave varchar(60) | Valor de configuración entero |
| `fn_contexto_interno` | función | → tinyint(1) | 1 si el cambio viene de un procedimiento de la BD (columnas derivadas: stock, montos pagados, valoraciones). La marca no se puede falsificar desde la app |
| `fn_contiene_datos_tarjeta` | función | → tinyint(1), IN p_json json | Defensa en profundidad: 1 si el JSON trae claves de tarjeta (PAN, CVV...) o un número con prefijo de tarjeta que pasa Luhn. Falla cerrado ante JSON enormes |
| `fn_contiene_secretos` | función | → tinyint(1), IN p_json json, IN p_url varchar(500) | 1 si el JSON trae claves de credenciales (authorization, token, password, secret, api_key...) o la URL lleva un secreto en la consulta |
| `fn_correo_valido` | función | → tinyint(1), IN p_correo varchar(300) | Formato de correo (ASCII, ya normalizado) |
| `fn_documento_valido` | función | → tinyint(1), IN p_tipo varchar(3), IN p_numero varchar(20) | DNI 8 dígitos, RUC válido (con dígito verificador), CE 6-12 alfanumérico en mayúsculas; ambos NULL = válido |
| `fn_enmascarar_correo` | función | → varchar(254), IN p_correo varchar(254) | jo***@dominio.com |
| `fn_enmascarar_documento` | función | → varchar(20), IN p_numero varchar(20) | Muestra solo los 3 últimos caracteres (Ley 29733) |
| `fn_enmascarar_telefono` | función | → varchar(20), IN p_tel varchar(20) | Muestra solo los 3 últimos dígitos |
| `fn_es_admin` | función | → tinyint(1), IN p_id_usuario bigint unsigned | 1 si el usuario es administrador activo |
| `fn_fecha_limite` | función | → date, IN p_desde date, IN p_dias int, IN p_tipo varchar(20) | Fecha límite por días calendario o hábiles |
| `fn_generar_digitos` | función | → varchar(9), IN p_digitos tinyint unsigned | Código numérico con aleatoriedad criptográfica: RANDOM_BYTES(4) + muestreo por rechazo (sin sesgo de módulo). Nunca RAND() |
| `fn_hash_codigo` | función | → char(64), IN p_pepper varchar(200), IN p_codigo varchar(64) | SHA-256(pepper : código). El pepper vive en la configuración de Django, nunca en la BD |
| `fn_hoy_lima` | función | → date | Fecha actual en Lima |
| `fn_igv_incluido` | función | → decimal(12,2), IN p_total decimal(12,2), IN p_tasa decimal(5,2) | ÚNICA función de IGV: IGV contenido en un importe que ya lo incluye, redondeado a 2 decimales. Base = importe − IGV (cuadre exacto) |
| `fn_ip_sesion` | función | → varbinary(16) | IP del cliente informada por Django en @app_ip (binario INET6_ATON). Texto inválido = NULL (nunca rompe la operación) |
| `fn_luhn_valido` | función | → tinyint(1), IN p_numero varchar(30) | Algoritmo de Luhn (detección de números de tarjeta) |
| `fn_normalizar_correo` | función | → varchar(300), IN p_correo varchar(300) | Correo sin espacios y en minúsculas |
| `fn_normalizar_telefono` | función | → varchar(40), IN p_tel varchar(40) | Deja solo dígitos y el + inicial |
| `fn_precio_unitario` | función | → decimal(10,2), IN p_id_variante bigint unsigned, IN p_cantidad int unsigned | Precio que se cobra por unidad: el menor entre el de lista (variante o producto) y el de volumen alcanzado |
| `fn_precio_volumen` | función | → decimal(10,2), IN p_id_producto bigint unsigned, IN p_cantidad int unsigned | Precio del mayor tramo de volumen alcanzado por la cantidad; NULL si no alcanza ninguno |
| `fn_ruc_valido` | función | → tinyint(1), IN p_ruc varchar(20) | RUC de 11 dígitos, prefijo 10/15/16/17/20 y dígito verificador (módulo 11) correcto |
| `fn_sumar_dias_habiles` | función | → date, IN p_fecha date, IN p_dias int | Suma días hábiles (lunes a viernes). No descuenta feriados: verificar si la norma los exige |
| `fn_tasa_igv` | función | → decimal(5,2) | Tasa de IGV vigente (configuración igv_porcentaje) |
| `fn_token_interno` | función | → char(64) | Marca de contexto interno de esta conexión: SHA-256(secreto de la instalación, id de conexión). INVOKER: solo funciona dentro de los procedimientos/triggers (wanka_definer) |
| `fn_utc_a_lima` | función | → datetime(3), IN p_fecha datetime(3) | Convierte UTC a hora de Lima (UTC−5 fijo, Perú no usa horario de verano) |
| `spi_activo_publico` | procedimiento | IN p_entidad varchar(30), IN p_id bigint unsigned, IN p_activar tinyint(1), IN p_motivo varchar(200) | Transacción común de los sp_inhabilitar_* / sp_reactivar_* |
| `spi_agregar_item_interno` | procedimiento | IN p_id_pedido bigint unsigned, IN p_id_variante bigint unsigned, IN p_cantidad int, IN p_personalizacion varchar(500), IN p_precio_forzado decimal(10,2), IN p_descripcion varchar(250), OUT p_id_item bigint unsigned | Agrega un ítem con copia de datos y precio desde la BD (lista, volumen o cotizado), reserva stock y recalcula |
| `spi_auditar` | procedimiento | IN p_evento varchar(60), IN p_entidad varchar(40), IN p_id_entidad bigint unsigned, IN p_id_afectado bigint unsigned, IN p_detalle json, IN p_origen varchar(15) | Inserta un registro de auditoría con actor, IP y cuenta MySQL |
| `spi_bloquear_frecuencia` | procedimiento | IN p_ambito varchar(30), IN p_clave varchar(254) | Bloquea (FOR UPDATE) la fila del sujeto limitado para que dos solicitudes simultáneas cuenten en serie |
| `spi_bloquear_pedido_editable` | procedimiento | IN p_id_pedido bigint unsigned | Bloquea el pedido y exige: dueño o admin, pendiente de pago, sin cotización y sin pagos en curso |
| `spi_cambiar_activo` | procedimiento | IN p_entidad varchar(30), IN p_id bigint unsigned, IN p_activar tinyint(1), IN p_motivo varchar(200) | Inhabilita/reactiva una fila de catálogo con sentencias estáticas por entidad (sin SQL dinámico) y audita |
| `spi_cambiar_estado_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_estado_nuevo varchar(20), IN p_comentario varchar(200), IN p_es_sistema tinyint(1) | Valida la transición (tabla transicion_estado_pedido, tipo de entrega, permisos, saldo) y aplica sus efectos de stock/insumos |
| `spi_cerrar_reservas_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_accion varchar(10), IN p_id_item bigint unsigned, IN p_motivo varchar(200) | Consume (venta) o libera las reservas activas del pedido (o de un ítem), bloqueando variantes en orden ascendente |
| `spi_cerrar_sesiones_usuario` | procedimiento | IN p_id_usuario bigint unsigned, IN p_motivo varchar(20) | Cierra todas las sesiones abiertas de un usuario |
| `spi_consumir_insumos_pedido` | procedimiento | IN p_id_pedido bigint unsigned | Descuenta insumos según receta_producto × cantidades vigentes del pedido (una sola vez por pedido) |
| `spi_control_borrado` | procedimiento | IN p_tabla varchar(40), IN p_id bigint unsigned | Bloquea el DELETE físico (error 45005) salvo DBA autorizado; el borrado del DBA queda auditado |
| `spi_crear_pedido` | procedimiento | IN p_id_usuario bigint unsigned, IN p_items json, IN p_tipo_entrega varchar(10), IN p_id_direccion bigint unsigned, IN p_modalidad varchar(10), IN p_comprobante varchar(10), IN p_fact_tipo varchar(3), IN p_fact_num varchar(12), IN p_fact_nombre varchar(200), IN p_fact_dir varchar(250), IN p_fecha_entrega date, IN p_notas varchar(500), IN p_canal varchar(10), IN p_id_pedido_origen bigint unsigned, IN p_costo_envio_forzado decimal(12,2), OUT p_id_pedido bigint unsigned | Cuerpo de sp_crear_pedido / sp_crear_pedido_complementario (sin transacción propia) |
| `spi_crear_reembolso` | procedimiento | IN p_id_pago bigint unsigned, IN p_monto decimal(12,2), IN p_motivo varchar(20), IN p_detalle varchar(300), IN p_medio varchar(15), IN p_id_nota_credito bigint unsigned, IN p_id_devolucion bigint unsigned, OUT p_id_reembolso bigint unsigned | Solicita un reembolso validando que la suma de reembolsos vigentes no supere lo cobrado |
| `spi_emitir_nota_credito` | procedimiento | IN p_id_comprobante_ref bigint unsigned, IN p_codigo_motivo char(2), IN p_motivo_detalle varchar(250), IN p_monto decimal(12,2), IN p_id_devolucion bigint unsigned, OUT p_id_nc bigint unsigned | Nota de crédito validada: contra comprobante aceptado del pedido, serie compatible (B→B, F→F), motivo SUNAT, sin exceder el saldo del comprobante |
| `spi_encolar_correo` | procedimiento | IN p_id_usuario bigint unsigned, IN p_destinatario varchar(254), IN p_plantilla varchar(60), IN p_contexto json, IN p_prioridad tinyint unsigned | Encola un correo (lo envía la app). Ignora destinos .invalid (cliente de mostrador) |
| `spi_encolar_emision` | procedimiento | IN p_id_comprobante bigint unsigned | Crea el trabajo de emisión asíncrona |
| `spi_error` | procedimiento | IN p_codigo smallint unsigned, IN p_mensaje varchar(500) | Lanza SIGNAL 45000 con MYSQL_ERRNO del catálogo de errores y mensaje (máx. 128 caracteres) |
| `spi_insertar_pedido` | procedimiento | IN p_id_usuario bigint unsigned, IN p_tipo_venta varchar(5), IN p_canal varchar(10), IN p_tipo_entrega varchar(10), IN p_id_direccion bigint unsigned, IN p_id_pedido_copia bigint unsigned, IN p_modalidad varchar(10), IN p_adelanto_pct decimal(5,2), IN p_comprobante varchar(10), IN p_fact_tipo varchar(3), IN p_fact_num varchar(12), IN p_fact_nombre varchar(200), IN p_fact_dir varchar(250), IN p_fecha_entrega date, IN p_notas varchar(500), IN p_id_cotizacion bigint unsigned, IN p_id_pedido_origen bigint unsigned, IN p_costo_envio_forzado decimal(12,2), OUT p_id_pedido bigint unsigned | Crea la cabecera del pedido: copia de entrega, costo de envío desde la zona, modalidad de pago, datos de comprobante |
| `spi_mover_insumo` | procedimiento | IN p_id_insumo bigint unsigned, IN p_tipo varchar(10), IN p_cantidad decimal(12,3), IN p_id_pedido bigint unsigned, IN p_motivo varchar(200), OUT p_stock decimal(12,3) | Único punto que cambia el stock de insumos (bloqueo de fila + kardex) |
| `spi_mover_stock` | procedimiento | IN p_id_variante bigint unsigned, IN p_tipo varchar(20), IN p_cantidad int, IN p_id_pedido bigint unsigned, IN p_id_item_pedido bigint unsigned, IN p_id_devolucion bigint unsigned, IN p_motivo varchar(200), OUT p_stock_actual int | Único punto que cambia el stock: bloquea la fila (sin sobreventa), valida, actualiza y escribe el kardex |
| `spi_notificar` | procedimiento | IN p_id_usuario bigint unsigned, IN p_tipo varchar(40), IN p_titulo varchar(120), IN p_mensaje varchar(300), IN p_enlace varchar(300), IN p_id_pedido bigint unsigned | Notificación dentro del sistema para un usuario |
| `spi_notificar_admins` | procedimiento | IN p_tipo varchar(40), IN p_titulo varchar(120), IN p_mensaje varchar(300), IN p_enlace varchar(300), IN p_id_pedido bigint unsigned | Notificación para todos los administradores activos |
| `spi_recalcular_ajustes_pedido` | procedimiento | IN p_id_pedido bigint unsigned | Deriva monto_ajustes: notas de crédito vigentes que rebajan el precio (motivo no total y sin devolución de mercadería) + compensaciones reembolsadas sin nota de crédito |
| `spi_recalcular_pagos_pedido` | procedimiento | IN p_id_pedido bigint unsigned | Deriva monto_pagado, monto_reembolsado y estado_pago desde los pagos; confirma el pedido si se alcanzó el monto de la modalidad |
| `spi_recalcular_pedido` | procedimiento | IN p_id_pedido bigint unsigned | Subtotal = suma de ítems vigentes; total = subtotal − descuento + envío |
| `spi_recalcular_tipo_venta` | procedimiento | IN p_id_pedido bigint unsigned | Si alguna línea vigente tiene precio por volumen el pedido es "mayor" (exige anticipación) |
| `spi_recalcular_valoracion` | procedimiento | IN p_id_producto bigint unsigned | Valoración promedio y total de reseñas publicadas del producto |
| `spi_registrar_fallo_acceso` | procedimiento | IN p_id_usuario bigint unsigned, IN p_que varchar(30), OUT p_bloqueado_hasta datetime(3) | Cuenta un fallo de contraseña, segundo factor o código de respaldo; al llegar al tope bloquea la cuenta (la fila de usuario debe estar bloqueada FOR UPDATE) |
| `spi_repartir_reembolso` | procedimiento | IN p_id_pedido bigint unsigned, IN p_monto decimal(12,2), IN p_motivo varchar(20), IN p_detalle varchar(300), IN p_id_nota_credito bigint unsigned, IN p_id_devolucion bigint unsigned, OUT p_monto_solicitado decimal(12,2), OUT p_id_primer_reembolso bigint unsigned | Reparte un monto a devolver entre los pagos confirmados APLICADOS al pedido (del más reciente al más antiguo) creando reembolsos solicitados |
| `spi_reponer_stock_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_motivo varchar(200) | Cancelación de un pedido ya confirmado: devuelve al stock las unidades vendidas no devueltas y marca los ítems como anulados |
| `spi_requiere_contexto` | procedimiento | IN p_que varchar(120) | Error 45023 si el cambio no viene de un procedimiento de la BD |
| `spi_reservar_item` | procedimiento | IN p_id_item_pedido bigint unsigned | Reserva el stock de un ítem de tipo stock y registra la reserva |
| `spi_siguiente_correlativo` | procedimiento | IN p_id_serie smallint unsigned, OUT p_correlativo int unsigned | Siguiente correlativo de una serie activa (atómico con LAST_INSERT_ID(expr)) |
| `spi_siguiente_numero` | procedimiento | IN p_prefijo varchar(12), IN p_ancho tinyint unsigned, OUT p_numero varchar(25) | Correlativo anual atómico y sin saltos: PREFIJO-AAAA-000001 (bloquea la fila de la secuencia hasta el fin de la transacción) |
| `spi_solo_insercion` | procedimiento | IN p_tabla varchar(40) | Error 45004: tabla histórica de solo inserción |
| `spi_validar_admin` | procedimiento |  | Error 45023 si el actor no es administrador activo |
| `spi_validar_categoria_padre` | procedimiento | IN p_id_categoria smallint unsigned, IN p_id_padre smallint unsigned | La categoría padre debe existir, estar activa y no formar un ciclo (A → B → A) |
| `spi_validar_dueno_o_admin` | procedimiento | IN p_id_usuario bigint unsigned | Error 45023 si el actor no es el dueño del recurso ni administrador |
| `spi_validar_pedido_completo` | procedimiento | IN p_id_pedido bigint unsigned | Reglas que dependen del total o del tipo de venta: pedido no vacío, boleta > umbral con documento, adelanto permitido |
| `spi_validar_valor_config` | procedimiento | IN p_clave varchar(60), IN p_valor varchar(500), IN p_tipo varchar(10), IN p_min decimal(14,4), IN p_max decimal(14,4), IN p_opciones varchar(200) | Valida un valor de configuración por tipo, rango y opciones (error 45020) |
| `spi_validar_variante_vendible` | procedimiento | IN p_id_variante bigint unsigned | Error 45008 si la variante o su producto no están a la venta |
| `sp_abrir_sesion` | procedimiento | IN p_id_usuario bigint unsigned, IN p_token_hash char(64), IN p_user_agent varchar(255), IN p_minutos int, OUT p_id_sesion bigint unsigned | Registra una sesión (solo el SHA-256 del token) |
| `sp_aceptar_cotizacion` | procedimiento | IN p_id_cotizacion bigint unsigned, IN p_tipo_entrega varchar(10), IN p_id_direccion bigint unsigned, IN p_modalidad_pago varchar(10), IN p_comprobante varchar(10), IN p_fact_tipo_doc varchar(3), IN p_fact_num_doc varchar(12), IN p_fact_nombre varchar(200), IN p_fact_direccion varchar(250), IN p_notas varchar(500), OUT p_id_pedido bigint unsigned, OUT p_numero varchar(25), OUT p_total decimal(12,2) | Acepta una cotización vigente y la convierte ATÓMICAMENTE en pedido con los precios y el adelanto cotizados |
| `sp_actualizar_configuracion` | procedimiento | IN p_clave varchar(60), IN p_valor varchar(500) | Cambia un parámetro editable (el trigger valida tipo y rango y audita el cambio) |
| `sp_actualizar_documento_usuario` | procedimiento | IN p_id_usuario bigint unsigned, IN p_tipo varchar(3), IN p_numero varchar(12) | Registra o corrige el documento del cliente validando DNI/RUC (con dígito verificador)/CE |
| `sp_agregar_item` | procedimiento | IN p_id_pedido bigint unsigned, IN p_id_variante bigint unsigned, IN p_cantidad int, IN p_personalizacion varchar(500), OUT p_total decimal(12,2) | Agrega una línea a un pedido pendiente de pago (precio y datos salen de la BD; reserva stock) |
| `sp_agregar_item_carrito` | procedimiento | IN p_id_usuario bigint unsigned, IN p_id_variante bigint unsigned, IN p_cantidad int, IN p_personalizacion varchar(500), OUT p_disponible int | Fija la cantidad de una variante en el carrito activo (lo crea si no existe). No guarda precios. Devuelve el disponible informativo |
| `sp_ajustar_insumo` | procedimiento | IN p_id_insumo bigint unsigned, IN p_tipo varchar(10), IN p_cantidad decimal(12,3), IN p_motivo varchar(200), IN p_id_pedido bigint unsigned, OUT p_stock decimal(12,3) | Ingreso, consumo o ajuste de insumos (kardex de insumos) |
| `sp_ajustar_stock` | procedimiento | IN p_id_variante bigint unsigned, IN p_tipo varchar(10), IN p_cantidad int, IN p_motivo varchar(200), OUT p_stock_actual int | Ingreso o ajuste manual de stock por el administrador (queda en el kardex) |
| `sp_alertar_vencimientos` | procedimiento |  | Avisa a los administradores de reclamos y solicitudes ARCO que vencen en 3 días o menos |
| `sp_alternar_favorito` | procedimiento | IN p_id_usuario bigint unsigned, IN p_id_producto bigint unsigned, OUT p_es_favorito tinyint(1) | Marca o desmarca un favorito (estado de interfaz) |
| `sp_anonimizar_usuario` | procedimiento | IN p_id_usuario bigint unsigned, IN p_id_solicitud_arco bigint unsigned | Derecho de cancelación (Ley 29733): anonimiza la cuenta y sus direcciones sin borrar filas. Pedidos, comprobantes y reclamos se conservan por obligación legal |
| `sp_anular_pago_pendiente` | procedimiento | IN p_id_pago bigint unsigned, IN p_motivo varchar(300) | El cliente (o un administrador) abandona un cobro de pasarela pendiente. Si la pasarela lo aprueba después, el webhook lo registra igual (huérfano si ya no hace falta) |
| `sp_atender_solicitud_arco` | procedimiento | IN p_id_solicitud bigint unsigned, IN p_estado varchar(15), IN p_respuesta text | Administrador atiende o deniega una solicitud ARCO |
| `sp_cambiar_contrasena` | procedimiento | IN p_id_usuario bigint unsigned, IN p_nuevo_hash varchar(255), IN p_origen varchar(15) | Cambia la contraseña (hash de Django). En "recuperacion" exige un código de recuperación enviado al correo de la cuenta y usado en los últimos 10 min. Cierra sesiones |
| `sp_cambiar_correo` | procedimiento | IN p_id_usuario bigint unsigned, IN p_nuevo_correo varchar(254) | Cambia el correo de acceso solo si el nuevo correo fue verificado con un código "cambiar_correo" en los últimos 10 minutos. Avisa al correo anterior |
| `sp_cambiar_estado_cotizacion` | procedimiento | IN p_id_cotizacion bigint unsigned, IN p_estado varchar(15), IN p_motivo varchar(300) | Pasa a en_revision (admin) o rechazada (admin; o el cliente si ya está cotizada) |
| `sp_cambiar_estado_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_estado varchar(20), IN p_comentario varchar(200) | El administrador cambia el estado según las transiciones permitidas (historial, auditoría y aviso al cliente por trigger). Para cancelar: sp_cancelar_pedido |
| `sp_cambiar_rol_usuario` | procedimiento | IN p_id_usuario bigint unsigned, IN p_codigo_rol varchar(20) | Cambia el rol (solo administrador). No permite dejar el sistema sin administradores |
| `sp_cancelar_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_motivo varchar(200) | Cancela: sin pago libera la reserva; confirmado devuelve unidades al stock. Lo pagado queda en v_pagos_por_reembolsar |
| `sp_cerrar_sesion` | procedimiento | IN p_token_hash char(64), IN p_motivo varchar(20) | Cierra una sesión por su hash |
| `sp_cerrar_sesiones_usuario` | procedimiento | IN p_id_usuario bigint unsigned | Cierra todas las sesiones del usuario (él mismo o un administrador) |
| `sp_completar_reembolso` | procedimiento | IN p_id_reembolso bigint unsigned, IN p_exitoso tinyint(1), IN p_referencia_externa varchar(100), IN p_error varchar(300) | Cierra un reembolso (completado o fallido). Al completarse, el trigger actualiza el pago y el pedido |
| `sp_configurar_2fa` | procedimiento | IN p_id_usuario bigint unsigned, IN p_metodo varchar(10), IN p_secreto_cifrado varbinary(512) | Guarda el secreto TOTP YA CIFRADO por la app. Si ya hay un 2FA activo, el nuevo queda PENDIENTE (el actual sigue protegiendo la cuenta) hasta sp_confirmar_2fa. Administradores: solo TOTP |
| `sp_confirmar_2fa` | procedimiento | IN p_id_usuario bigint unsigned, IN p_paso_totp bigint unsigned | Activa el 2FA (o la reconfiguración pendiente) después de que la app validó el primer código. Al reconfigurar invalida los códigos de respaldo anteriores |
| `sp_confirmar_pago_manual` | procedimiento | IN p_id_pago bigint unsigned, OUT p_estado_pedido varchar(20) | Un administrador valida un Yape/Plin/transferencia/efectivo. Si dos lo intentan a la vez, el segundo recibe "ya fue validado" |
| `sp_consumir_insumos_pedido` | procedimiento | IN p_id_pedido bigint unsigned | Descuenta los insumos de un pedido según la receta (una sola vez) |
| `sp_corregir_facturacion_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_comprobante varchar(10), IN p_fact_tipo_doc varchar(3), IN p_fact_num_doc varchar(12), IN p_fact_nombre varchar(200), IN p_fact_direccion varchar(250) | Corrige boleta/factura y los datos del receptor (dueño o admin) mientras el pedido no tenga comprobante vigente |
| `sp_cotizar` | procedimiento | IN p_id_cotizacion bigint unsigned, IN p_precios json, IN p_costo_envio decimal(12,2), IN p_adelanto_pct decimal(5,2), IN p_vigencia_dias int, IN p_respuesta text, IN p_fecha_entrega_acordada date, OUT p_total decimal(12,2) | El administrador fija precios ([{"id_item_cotizacion":1,"precio_unitario":45.00}]), envío (NULL = tarifa de la zona al aceptar), adelanto, vigencia y (opcional) la fecha de entrega acordada |
| `sp_crear_administrador_inicial` | procedimiento | IN p_correo varchar(254), IN p_hash_contrasena varchar(255), IN p_nombres varchar(80), IN p_apellidos varchar(80), OUT p_id_usuario bigint unsigned | Crea el PRIMER administrador (solo si no existe ninguno). El hash lo genera Django (make_password) |
| `sp_crear_pedido` | procedimiento | IN p_id_usuario bigint unsigned, IN p_items json, IN p_tipo_entrega varchar(10), IN p_id_direccion bigint unsigned, IN p_modalidad_pago varchar(10), IN p_comprobante varchar(10), IN p_fact_tipo_doc varchar(3), IN p_fact_num_doc varchar(12), IN p_fact_nombre varchar(200), IN p_fact_direccion varchar(250), IN p_fecha_entrega date, IN p_notas varchar(500), IN p_canal varchar(10), OUT p_id_pedido bigint unsigned, OUT p_numero varchar(25), OUT p_total decimal(12,2) | Crea un pedido pendiente de pago desde el carrito (p_items NULL) o desde JSON [{"id_variante":1,"cantidad":2,"personalizacion":"..."}]. Reintenta ante deadlock |
| `sp_crear_pedido_complementario` | procedimiento | IN p_id_pedido_origen bigint unsigned, IN p_items json, IN p_modalidad_pago varchar(10), IN p_notas varchar(500), IN p_fecha_entrega date, OUT p_id_pedido bigint unsigned, OUT p_numero varchar(25), OUT p_total decimal(12,2) | HU-29: pedido complementario de uno ya confirmado; hereda entrega y comprobante (y la fecha si p_fecha_entrega es NULL). Envío gratis si el original aún no salió (configurable) |
| `sp_definir_direccion_predeterminada` | procedimiento | IN p_id_direccion bigint unsigned | Deja una sola dirección predeterminada por cliente (reemplaza al trigger del original, que en MySQL daría error 1442) |
| `sp_definir_imagen_principal` | procedimiento | IN p_id_imagen bigint unsigned | Marca la imagen principal del producto (en MySQL un trigger no puede tocar su propia tabla: por eso es procedimiento) |
| `sp_definir_modalidad_pago` | procedimiento | IN p_id_pedido bigint unsigned, IN p_modalidad varchar(10), IN p_porcentaje decimal(5,2), OUT p_monto_requerido decimal(12,2) | El cliente elige pago total o adelanto antes de pagar. El porcentaje lo toma de la cotización o la configuración; solo un administrador puede fijar otro |
| `sp_desactivar_2fa` | procedimiento | IN p_id_usuario bigint unsigned | Desactiva el 2FA. Un administrador no puede desactivar el suyo (es obligatorio); otro administrador sí puede restablecerlo |
| `sp_desbloquear_usuario` | procedimiento | IN p_id_usuario bigint unsigned | Quita el bloqueo temporal por intentos fallidos |
| `sp_devolver_pedido` | procedimiento | IN p_id_pedido bigint unsigned, IN p_items json, IN p_motivo varchar(300), IN p_emitir_nota_credito tinyint(1), OUT p_id_devolucion bigint unsigned, OUT p_monto_devuelto decimal(12,2), OUT p_id_nota_credito bigint unsigned | Devolución total (p_items NULL) o parcial ([{"id_item_pedido":1,"cantidad":1}]). Repone stock, impide devolver dos veces, solicita reembolsos y emite la NC |
| `sp_emitir_comprobante` | procedimiento | IN p_id_pedido bigint unsigned, OUT p_id_comprobante bigint unsigned, OUT p_ya_existia tinyint(1) | Arma la boleta/factura con copia completa (emisor, cliente, líneas, IGV) y la encola para el OSE. Idempotente: un comprobante vigente por pedido |
| `sp_emitir_nota_credito` | procedimiento | IN p_id_comprobante_ref bigint unsigned, IN p_codigo_motivo char(2), IN p_motivo_detalle varchar(250), IN p_monto decimal(12,2), IN p_id_devolucion bigint unsigned, IN p_crear_reembolso tinyint(1), OUT p_id_nota_credito bigint unsigned, OUT p_id_reembolso bigint unsigned | Emite una nota de crédito (corrige un comprobante aceptado, que nunca se modifica). Con p_id_devolucion la NC sale de esa devolución y se enlaza a sus reembolsos; si no, opcionalmente solicita el reembolso |
| `sp_expirar_codigos_verificacion` | procedimiento | OUT p_expirados int | Marca como expirados los códigos vencidos |
| `sp_expirar_pedidos_pendientes` | procedimiento | OUT p_cancelados int | Cancela pedidos sin pago vencidos (libera stock), salvo que tengan un pago en revisión o confirmado APLICADO. Anula los cobros de pasarela abandonados. Una transacción por pedido |
| `sp_generar_codigos_respaldo_2fa` | procedimiento | IN p_id_usuario bigint unsigned, IN p_pepper varchar(200), IN p_cantidad tinyint unsigned | Genera códigos de respaldo (se muestran UNA vez en el resultado; se guarda solo el hash) e invalida el lote anterior |
| `sp_generar_codigo_verificacion` | procedimiento | IN p_id_usuario bigint unsigned, IN p_correo_destino varchar(254), IN p_proposito varchar(30), IN p_pepper varchar(200), OUT p_codigo varchar(9), OUT p_expira_en datetime(3), OUT p_id_codigo bigint unsigned | Genera un código aleatorio (RANDOM_BYTES), guarda solo su hash, vence en <= 5 min, reemplaza al anterior. Cupos: por correo y propósito (hora y día) y por IP. Salvo cambiar_correo, solo se envía al correo de la cuenta |
| `sp_guardar_archivo_comprobante` | procedimiento | IN p_id_comprobante bigint unsigned, IN p_tipo varchar(3), IN p_mime varchar(60), IN p_contenido longblob | Guarda la copia binaria del PDF/XML/CDR (inmutable; repetir el mismo archivo es idempotente) |
| `sp_guardar_consulta_documento` | procedimiento | IN p_tipo varchar(3), IN p_numero varchar(11), IN p_nombre varchar(200), IN p_estado varchar(30), IN p_condicion varchar(30), IN p_domicilio varchar(300), IN p_fuente varchar(40), IN p_exitosa tinyint(1) | Guarda o renueva la caché de una consulta DNI/RUC (para DNI no se guarda domicilio: minimización de datos) |
| `sp_inhabilitar_banner` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Inhabilita un banner |
| `sp_inhabilitar_categoria` | procedimiento | IN p_id smallint unsigned, IN p_motivo varchar(200) | Inhabilita una categoría (sin productos activos) |
| `sp_inhabilitar_courier` | procedimiento | IN p_id smallint unsigned, IN p_motivo varchar(200) | Inhabilita un courier |
| `sp_inhabilitar_direccion` | procedimiento | IN p_id bigint unsigned | El cliente "elimina" una dirección (borrado lógico) |
| `sp_inhabilitar_imagen` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Inhabilita una imagen de producto |
| `sp_inhabilitar_insumo` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Inhabilita un insumo |
| `sp_inhabilitar_metodo_pago` | procedimiento | IN p_codigo varchar(20), IN p_motivo varchar(200) | Deja de ofrecer un método de pago |
| `sp_inhabilitar_precio_volumen` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Inhabilita un tramo de precio por volumen |
| `sp_inhabilitar_producto` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Archiva un producto (con o sin ventas nunca se borra) y sus variantes dejan de venderse |
| `sp_inhabilitar_serie_comprobante` | procedimiento | IN p_id smallint unsigned, IN p_motivo varchar(200) | Inhabilita una serie de comprobantes |
| `sp_inhabilitar_usuario` | procedimiento | IN p_id_usuario bigint unsigned, IN p_motivo varchar(200) | Inhabilita una cuenta (nunca se borra): cierra sesiones, invalida códigos. No permite inhabilitarse a sí mismo ni al último administrador |
| `sp_inhabilitar_variante` | procedimiento | IN p_id bigint unsigned, IN p_motivo varchar(200) | Inhabilita una variante (deja de venderse; el historial se conserva) |
| `sp_inhabilitar_zona_envio` | procedimiento | IN p_id smallint unsigned, IN p_motivo varchar(200) | Inhabilita una zona de envío (los pedidos existentes conservan su copia) |
| `sp_mantenimiento_diario` | procedimiento |  | Carritos abandonados, sesiones vencidas y purga por retención de datos temporales (nunca toca datos de negocio ni auditoría < 12 meses) |
| `sp_marcar_comprobante_enviado_correo` | procedimiento | IN p_id_comprobante bigint unsigned | Registra que el comprobante se envió por correo al cliente |
| `sp_marcar_correo` | procedimiento | IN p_id_correo bigint unsigned, IN p_exitoso tinyint(1), IN p_error varchar(500), IN p_id_mensaje_proveedor varchar(150) | Resultado del envío: enviado, o error con reintento exponencial (descartado al agotar intentos) |
| `sp_marcar_en_atencion` | procedimiento | IN p_entidad varchar(10), IN p_id bigint unsigned | El administrador toma un mensaje de contacto (en_proceso) o un reclamo (en_atencion). Las tablas no se editan a mano |
| `sp_marcar_notificacion_leida` | procedimiento | IN p_id_notificacion bigint unsigned | Marca una notificación propia como leída |
| `sp_moderar_resena` | procedimiento | IN p_id_resena bigint unsigned, IN p_estado varchar(10), IN p_motivo varchar(200) | Publica, rechaza u oculta una reseña (la valoración del producto se recalcula por trigger) |
| `sp_obtener_consulta_documento` | procedimiento | IN p_tipo varchar(3), IN p_numero varchar(11), OUT p_encontrado tinyint(1), OUT p_nombre varchar(200), OUT p_estado varchar(30), OUT p_condicion varchar(30), OUT p_domicilio varchar(300) | Lee la caché DNI/RUC de UN documento exacto y vigente (la tienda no puede listar la tabla completa) |
| `sp_procesar_pago_pasarela` | procedimiento | IN p_id_evento bigint unsigned, IN p_metodo varchar(20), IN p_idempotency_key varchar(100), IN p_referencia_externa varchar(100), IN p_estado_externo varchar(15), IN p_monto decimal(12,2), IN p_moneda_cobro char(3), IN p_monto_cobro decimal(12,2), IN p_tipo_cambio decimal(10,6), IN p_datos json, OUT p_resultado varchar(25) | Aplica un webhook verificado (aprobado/rechazado/pendiente). Si el pedido ya estaba cancelado, el cobro se guarda como pago huérfano por reembolsar |
| `sp_quitar_item` | procedimiento | IN p_id_pedido bigint unsigned, IN p_id_item_pedido bigint unsigned, OUT p_total decimal(12,2) | Retira una línea de un pedido pendiente de pago (borrado lógico) y libera su reserva |
| `sp_quitar_item_carrito` | procedimiento | IN p_id_usuario bigint unsigned, IN p_id_variante bigint unsigned | Quita una variante del carrito activo (estado de interfaz, sin valor histórico: borrado físico permitido solo aquí) |
| `sp_reactivar_banner` | procedimiento | IN p_id bigint unsigned | Reactiva un banner |
| `sp_reactivar_categoria` | procedimiento | IN p_id smallint unsigned | Reactiva una categoría |
| `sp_reactivar_courier` | procedimiento | IN p_id smallint unsigned | Reactiva un courier |
| `sp_reactivar_direccion` | procedimiento | IN p_id bigint unsigned | Reactiva una dirección |
| `sp_reactivar_imagen` | procedimiento | IN p_id bigint unsigned | Reactiva una imagen |
| `sp_reactivar_insumo` | procedimiento | IN p_id bigint unsigned | Reactiva un insumo |
| `sp_reactivar_metodo_pago` | procedimiento | IN p_codigo varchar(20) | Vuelve a ofrecer un método de pago |
| `sp_reactivar_precio_volumen` | procedimiento | IN p_id bigint unsigned | Reactiva un tramo de precio por volumen |
| `sp_reactivar_producto` | procedimiento | IN p_id bigint unsigned | Saca un producto del archivo (vuelve a "activo") |
| `sp_reactivar_serie_comprobante` | procedimiento | IN p_id smallint unsigned | Reactiva una serie de comprobantes |
| `sp_reactivar_usuario` | procedimiento | IN p_id_usuario bigint unsigned | Reactiva una cuenta inhabilitada (activa si ya verificó su correo; si no, pendiente de verificación) |
| `sp_reactivar_variante` | procedimiento | IN p_id bigint unsigned | Reactiva una variante |
| `sp_reactivar_zona_envio` | procedimiento | IN p_id smallint unsigned | Reactiva una zona de envío |
| `sp_rechazar_pago` | procedimiento | IN p_id_pago bigint unsigned, IN p_motivo varchar(300) | Un administrador rechaza un pago manual con motivo (se avisa al cliente por trigger) |
| `sp_redactar_log_api` | procedimiento | IN p_id_log bigint unsigned, IN p_motivo varchar(200) | SOLO DBA (cuenta wanka_dba + @wanka_autorizo_borrado = SI-AUTORIZO): borra el contenido de un registro de la bitácora que guardó un secreto por error. Queda auditado |
| `sp_reembolsar_pago` | procedimiento | IN p_id_pago bigint unsigned, IN p_monto decimal(12,2), IN p_motivo varchar(20), IN p_detalle varchar(300), IN p_medio varchar(15), IN p_id_nota_credito bigint unsigned, OUT p_id_reembolso bigint unsigned | El administrador solicita devolver dinero de un pago confirmado (p_monto NULL = todo lo disponible). En un pedido vigente solo se reembolsa un excedente o una compensación (ajuste_precio) |
| `sp_registrar_consentimiento` | procedimiento | IN p_id_usuario bigint unsigned, IN p_correo varchar(254), IN p_finalidad varchar(30), IN p_version varchar(20), IN p_otorgado tinyint(1), IN p_user_agent varchar(255) | Registra aceptación o revocación de un consentimiento (nueva fila; nunca se edita) |
| `sp_registrar_envio` | procedimiento | IN p_id_pedido bigint unsigned, IN p_id_courier smallint unsigned, IN p_numero_guia varchar(60), IN p_fecha_estimada date, IN p_costo_real decimal(8,2), IN p_observaciones varchar(300), OUT p_id_envio bigint unsigned | Despacha un pedido a domicilio: crea el envío, su primer evento y pasa el pedido de listo a enviado (respeta la regla de saldo). Idempotente: si ya salió, devuelve el envío existente |
| `sp_registrar_evento_pasarela` | procedimiento | IN p_proveedor varchar(20), IN p_id_externo varchar(150), IN p_tipo varchar(80), IN p_payload json, IN p_firma_valida tinyint(1), OUT p_id_evento bigint unsigned, OUT p_ya_procesado tinyint(1) | Guarda un webhook una sola vez (proveedor + id externo). Si ya se procesó, p_ya_procesado = 1 y la app no debe repetir nada |
| `sp_registrar_intento_acceso` | procedimiento | IN p_correo varchar(254), IN p_contrasena_correcta tinyint(1), IN p_user_agent varchar(255), OUT p_resultado varchar(30), OUT p_id_usuario bigint unsigned, OUT p_bloqueado_hasta datetime(3), OUT p_requiere_2fa tinyint(1) | Registra el intento de login (Django verifica la contraseña). 5 fallos = bloqueo 15 min; demasiados fallos desde una IP = ip_bloqueada. No lanza error: devuelve el resultado |
| `sp_registrar_log_api` | procedimiento | IN p_proveedor varchar(15), IN p_endpoint varchar(300), IN p_metodo_http varchar(6), IN p_codigo_http smallint unsigned, IN p_duracion_ms int unsigned, IN p_exitoso tinyint(1), IN p_request json, IN p_response json, IN p_correlacion varchar(64), IN p_id_pedido bigint unsigned, IN p_id_comprobante bigint unsigned, IN p_id_pago bigint unsigned, IN p_error varchar(500), OUT p_id_log bigint unsigned | Bitácora de una llamada a API externa. La app enmascara tokens y datos personales; la BD rechaza datos de tarjeta y credenciales (la tabla es inmutable 12 meses) |
| `sp_registrar_mensaje_contacto` | procedimiento | IN p_id_usuario bigint unsigned, IN p_nombre varchar(100), IN p_correo varchar(254), IN p_celular varchar(20), IN p_asunto varchar(15), IN p_id_pedido bigint unsigned, IN p_mensaje varchar(2000), IN p_acepto_datos tinyint(1), IN p_version_politica varchar(20), OUT p_id_mensaje bigint unsigned, OUT p_ticket varchar(25) | Ticket de contacto con correlativo anual; máximo 3 por hora por IP (serializado: dos envíos simultáneos cuentan en orden) |
| `sp_registrar_pago` | procedimiento | IN p_id_pedido bigint unsigned, IN p_metodo varchar(20), IN p_monto decimal(12,2), IN p_idempotency_key varchar(100), IN p_referencia_externa varchar(100), IN p_voucher_url varchar(500), IN p_datos_pasarela json, IN p_moneda_cobro char(3), IN p_monto_cobro decimal(12,2), IN p_tipo_cambio decimal(10,6), OUT p_id_pago bigint unsigned, OUT p_estado varchar(15), OUT p_duplicado tinyint(1) | Registra un intento de pago. Idempotente por idempotency_key (doble clic). Manual → en_revision; pasarela → pendiente hasta el webhook |
| `sp_registrar_reclamo` | procedimiento | IN p_id_usuario bigint unsigned, IN p_nombres varchar(100), IN p_apellidos varchar(100), IN p_tipo_doc varchar(3), IN p_num_doc varchar(12), IN p_domicilio varchar(200), IN p_correo varchar(254), IN p_celular varchar(20), IN p_es_menor tinyint(1), IN p_apoderado varchar(200), IN p_tipo_bien varchar(10), IN p_monto decimal(12,2), IN p_descripcion_bien varchar(300), IN p_tipo varchar(10), IN p_detalle text, IN p_pedido_consumidor text, IN p_id_pedido bigint unsigned, IN p_acepto_datos tinyint(1), OUT p_id_reclamo bigint unsigned, OUT p_numero varchar(25), OUT p_fecha_limite date | Libro de Reclamaciones: correlativo anual, fecha límite según configuración (verificar INDECOPI), constancia por correo |
| `sp_registrar_resena` | procedimiento | IN p_id_usuario bigint unsigned, IN p_id_producto bigint unsigned, IN p_id_pedido bigint unsigned, IN p_calificacion tinyint unsigned, IN p_titulo varchar(100), IN p_comentario varchar(1000), OUT p_id_resena bigint unsigned | Reseña de quien compró y recibió el producto (una por producto); queda pendiente de moderación |
| `sp_registrar_respuesta_ose` | procedimiento | IN p_id_comprobante bigint unsigned, IN p_resultado varchar(12), IN p_proveedor varchar(40), IN p_id_externo varchar(100), IN p_hash varchar(100), IN p_codigo_respuesta varchar(10), IN p_mensaje text, IN p_url_pdf varchar(500), IN p_url_xml varchar(500), IN p_url_cdr varchar(500), IN p_payload_envio json, IN p_payload_respuesta json | Guarda la respuesta del OSE/PSE (copia del JSON enviado y recibido) y mueve la cola: aceptado/observado/rechazado cierran; enviado/error reintentan con backoff |
| `sp_registrar_seguimiento_envio` | procedimiento | IN p_id_envio bigint unsigned, IN p_estado varchar(15), IN p_descripcion varchar(300), IN p_ubicacion varchar(120), IN p_ocurrido_en datetime(3), IN p_origen varchar(15), IN p_id_evento_externo varchar(100), OUT p_duplicado tinyint(1) | Agrega un evento de seguimiento (idempotente por id de evento del courier). "entregado" cierra el pedido |
| `sp_registrar_segundo_factor` | procedimiento | IN p_id_usuario bigint unsigned, IN p_paso_totp bigint unsigned, IN p_correcto tinyint(1), IN p_user_agent varchar(255), OUT p_resultado varchar(30) | Resultado del 2FA (Django valida el TOTP). Respeta el bloqueo, cuenta los fallos para bloquear la cuenta y evita reutilizar el mismo paso TOTP |
| `sp_registrar_solicitud_arco` | procedimiento | IN p_id_usuario bigint unsigned, IN p_nombres varchar(160), IN p_tipo_documento varchar(3), IN p_numero_documento varchar(12), IN p_correo varchar(254), IN p_tipo varchar(15), IN p_detalle text, OUT p_id_solicitud bigint unsigned, OUT p_numero varchar(25), OUT p_fecha_limite date | Solicitud ARCO con correlativo y fecha límite (plazos configurables, por verificar) |
| `sp_registrar_usuario` | procedimiento | IN p_correo varchar(254), IN p_hash_contrasena varchar(255), IN p_nombres varchar(80), IN p_apellidos varchar(80), IN p_celular varchar(20), IN p_version_politica varchar(20), IN p_acepta_publicidad tinyint(1), OUT p_id_usuario bigint unsigned | Registro de cliente: cuenta pendiente de verificación + historial de contraseña + consentimientos (versión, fecha, IP) |
| `sp_reintentar_emision` | procedimiento | IN p_id_comprobante bigint unsigned | Vuelve a poner en cola un comprobante con error o cuya emisión se descartó por agotar los reintentos |
| `sp_responder_mensaje_contacto` | procedimiento | IN p_id_mensaje bigint unsigned, IN p_respuesta text, IN p_cerrar tinyint(1) | Respuesta del administrador (queda en el historial respuesta_atencion y se envía por correo) |
| `sp_responder_reclamo` | procedimiento | IN p_id_reclamo bigint unsigned, IN p_respuesta text, IN p_cerrar tinyint(1) | Respuesta del proveedor al reclamo (historial + correo al consumidor) |
| `sp_solicitar_cotizacion` | procedimiento | IN p_id_usuario bigint unsigned, IN p_origen varchar(15), IN p_descripcion text, IN p_items json, IN p_fecha_entrega date, IN p_imagen_url varchar(500), OUT p_id_cotizacion bigint unsigned, OUT p_numero varchar(25) | Solicitud de cotización. p_items: [{"id_variante":3,"descripcion":"...","cantidad":20,"personalizacion":"..."}] |
| `sp_tomar_comprobante_para_emitir` | procedimiento | IN p_worker varchar(64), OUT p_id_comprobante bigint unsigned | Worker de emisión: toma el siguiente trabajo vencido con SKIP LOCKED (varios workers sin pisarse). NULL = nada pendiente |
| `sp_tomar_correos_pendientes` | procedimiento | IN p_worker varchar(20), IN p_limite int | Worker de correo: reserva hasta N correos vencidos (por prioridad) y los devuelve como resultado |
| `sp_usar_codigo_respaldo_2fa` | procedimiento | IN p_id_usuario bigint unsigned, IN p_codigo varchar(12), IN p_pepper varchar(200), OUT p_ok tinyint(1) | Consume un código de respaldo (uso único). Exige 2FA activo, respeta el bloqueo, cuenta los fallos y audita el uso |
| `sp_vencer_cotizaciones` | procedimiento | OUT p_vencidas int | Cotizaciones cotizadas cuya vigencia (día de Lima) ya pasó → vencida |
| `sp_verificar_codigo` | procedimiento | IN p_correo_destino varchar(254), IN p_proposito varchar(30), IN p_codigo varchar(12), IN p_pepper varchar(200), OUT p_resultado varchar(20), OUT p_intentos_restantes tinyint, OUT p_id_usuario bigint unsigned | Verifica un código: vencido / usado / bloqueado / inválido / ok. El vencimiento se valida aquí (no solo en la app). Persiste los intentos |
| `sp_ver_documento_completo` | procedimiento | IN p_id_usuario bigint unsigned, OUT p_tipo varchar(3), OUT p_numero varchar(12) | Devuelve el documento completo de un cliente y deja constancia del acceso (las vistas solo muestran el dato enmascarado) |

## Eventos

| Evento | Frecuencia | Descripción |
|---|---|---|
| `ev_alertar_vencimientos` | cada 1 day | 08:00 Lima: avisa reclamos y solicitudes ARCO por vencer |
| `ev_expirar_codigos` | cada 1 minute | Marca como expirados los códigos de verificación vencidos (la verificación igual valida expira_en) |
| `ev_expirar_pedidos` | cada 5 minute | Cancela pedidos sin pago vencidos (horas_reserva_pedido) y libera su stock |
| `ev_mantenimiento_diario` | cada 1 day | 03:00 Lima: carritos abandonados, sesiones vencidas y purga por retención de datos temporales |
| `ev_vencer_cotizaciones` | cada 1 day | 00:10 Lima: cotizaciones cuya vigencia terminó pasan a vencida |
