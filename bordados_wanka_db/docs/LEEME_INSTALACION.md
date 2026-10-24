# Instalación y uso — Base de datos Bordados Wanka (MySQL 8)

## 1. Requisitos

- **MySQL 8.0.16 o superior** (probado en **MySQL 8.4.11 LTS**). Charset `utf8mb4`, colación `utf8mb4_0900_ai_ci`.
- Una cuenta con permisos de instalación (root en local): crea la base, la cuenta técnica `wanka_definer`, roles y cuentas, y objetos con otro `DEFINER` (`SET_ANY_DEFINER` o `SET_USER_ID`).
- phpMyAdmin (opcional) o el cliente `mysql`.
- ⚠️ **XAMPP / WAMP / MAMP suelen traer MariaDB, no MySQL.** Revise `SELECT VERSION();`. Si dice `MariaDB`, vea la sección 10 o use la opción con Docker.

## 2. Orden de los scripts

| Orden | Archivo | Qué hace |
|---|---|---|
| 1 | `sql/00_requisitos_y_entorno.sql` | Verifica la versión, modo estricto, crea la base y la cuenta técnica `wanka_definer` (bloqueada) |
| 2 | `sql/01_esquema_acceso.sql` | Usuarios, roles, sesiones, códigos, 2FA, consentimiento, ARCO, auditoría y el secreto interno de la instalación |
| 3 | `sql/02_esquema_tienda.sql` | Catálogo, inventario, pedidos, pagos, comprobantes, atención, colas |
| 4 | `sql/03_funciones_procedimientos.sql` | Funciones y procedimientos (lógica de negocio) |
| 5 | `sql/04_triggers.sql` | Triggers (red de seguridad) |
| 6 | `sql/05_vistas.sql` | Vistas para la app y reportes |
| 7 | `sql/06_eventos.sql` | Tareas programadas |
| 8 | `sql/07_roles_permisos.sql` | Roles, permisos (por tabla, columna y procedimiento) y cuentas bloqueadas |
| 9 | `sql/08_datos_iniciales.sql` | Configuración, catálogos SUNAT, estados, métodos de pago, series de ejemplo |
| — | `sql/07b_permisos_django_post_migrate.sql` | Opcional, **después** de `python manage.py migrate` |
| — | `sql/99_pruebas.sql` | Pruebas: **solo** en la base `bordados_wanka_test` |

Todos son **re-ejecutables**: si uno falla, corrija la causa y vuelva a ejecutarlo. Para empezar de cero: `./scripts/instalar.sh --reiniciar` o descomente `DROP DATABASE` en el 00.

## 3. Opción A — Docker (recomendada en Mac/Linux/Windows con Docker Desktop)

```bash
cp .env.ejemplo .env
```
Edite `.env` y ponga una clave propia en `MYSQL_ROOT_PASSWORD`. El `.env` nunca se copia ni se sube a git: cada máquina tiene el suyo.

```bash
docker compose up -d
```

```bash
./scripts/instalar.sh
```

- phpMyAdmin: <http://localhost:8080> (usuario `root`, clave de `.env`).
- MySQL: `127.0.0.1:3306`.
- El contenedor ya arranca con `event_scheduler=ON`, `time_zone=+00:00` y modo estricto.

## 4. Opción B — phpMyAdmin (importación manual)

1. Entre como `root` (o una cuenta con los permisos del punto 1).
2. Pestaña **Importar** (a nivel servidor, sin seleccionar base) → elija `00_requisitos_y_entorno.sql` → **Importar**.
3. Repita con `01`, `02`, … `08`, **en orden**. Cada archivo pesa menos de 250 KB (el límite típico de phpMyAdmin es 2 MB).
4. Revise al final que no haya mensajes en rojo. Los `DELIMITER $$` los entiende phpMyAdmin.

> Verificado: los 9 archivos se importaron con el analizador de phpMyAdmin 5.2 y dejaron exactamente los mismos objetos que la instalación por consola.

## 5. Opción C — Consola

```bash
for f in 00_requisitos_y_entorno 01_esquema_acceso 02_esquema_tienda 03_funciones_procedimientos 04_triggers 05_vistas 06_eventos 07_roles_permisos 08_datos_iniciales; do mysql -u root -p --default-character-set=utf8mb4 < "sql/$f.sql" || break; done
```

## 6. Programador de eventos (`event_scheduler`)

Los eventos expiran pedidos sin pago, vencen códigos y cotizaciones, purgan datos temporales y avisan vencimientos.

```sql
SHOW VARIABLES LIKE 'event_scheduler';      -- debe decir ON
SET GLOBAL event_scheduler = ON;             -- hasta el próximo reinicio
SET PERSIST event_scheduler = ON;            -- permanente (MySQL 8)
```
O en `my.cnf` / `my.ini`, sección `[mysqld]`: `event_scheduler = ON`.

## 7. Cuentas, contraseñas y primer administrador

El script **no contiene contraseñas**. Las cuentas se crean **bloqueadas** con una clave aleatoria que nadie conoce. Para habilitarlas, el administrador de la BD ejecuta (con sus propias claves):

```sql
ALTER USER 'wanka_tienda'@'localhost'   IDENTIFIED BY '<CAMBIAR_CLAVE_TIENDA>'   ACCOUNT UNLOCK;  -- app pública
ALTER USER 'wanka_admin'@'localhost'    IDENTIFIED BY '<CAMBIAR_CLAVE_ADMIN>'    ACCOUNT UNLOCK;  -- panel de administración y workers
ALTER USER 'wanka_reportes'@'localhost' IDENTIFIED BY '<CAMBIAR_CLAVE_REPORTES>' ACCOUNT UNLOCK;  -- solo vistas
ALTER USER 'wanka_dba'@'localhost'      IDENTIFIED BY '<CAMBIAR_CLAVE_DBA>'      ACCOUNT UNLOCK;  -- mantenimiento, fuera de la app
```

**Con Docker**, Django se conecta desde fuera del contenedor y MySQL no lo ve como `localhost`. Cree la cuenta para la red de Docker (o `'%'` solo en desarrollo):
```sql
CREATE USER 'wanka_tienda'@'%' IDENTIFIED BY '<CAMBIAR_CLAVE_TIENDA>';
GRANT rol_app_tienda TO 'wanka_tienda'@'%';
SET DEFAULT ROLE rol_app_tienda TO 'wanka_tienda'@'%';
```

`wanka_definer` **nunca** se desbloquea: es solo el dueño de procedimientos, triggers, vistas y eventos.

**Primer administrador** (una sola vez). Genere el hash en Django y créelo con el procedimiento:
```bash
python manage.py shell -c "from django.contrib.auth.hashers import make_password; print(make_password('<CLAVE_DEL_ADMIN>'))"
```
```sql
CALL bordados_wanka.sp_crear_administrador_inicial('admin@<dominio>', '<HASH_GENERADO>', 'Nombre', 'Apellido', @id);
SELECT @id;
```
Luego configure su TOTP (`sp_configurar_2fa` + `sp_confirmar_2fa`): el rol administrador lo exige (`v_administradores_sin_2fa` debe quedar vacía).

**Borrado físico (solo DBA, excepcional).** Aun con `wanka_dba`, los triggers exigen declararlo y lo auditan:
```sql
SET @wanka_autorizo_borrado = 'SI-AUTORIZO';
-- DELETE ... ;
SET @wanka_autorizo_borrado = NULL;
```
El rol DBA **no tiene `DROP`**: así `TRUNCATE` (que no dispara triggers y vaciaría la auditoría sin rastro) queda bloqueado. Para archivar o borrar tablas completas use `root` de forma excepcional y documentada.

**Secreto guardado por error en la bitácora de APIs.** `log_api_externa` es inmutable 12 meses. Si la app llegó a guardar un token, el DBA lo redacta (queda auditado con origen `dba`):
```sql
SET @wanka_autorizo_borrado = 'SI-AUTORIZO';
CALL sp_redactar_log_api(<id_log>, 'Motivo de la redacción (mínimo 10 caracteres)');
SET @wanka_autorizo_borrado = NULL;
```

**Secreto interno de la instalación.** `01_esquema_acceso.sql` crea la tabla `secreto_interno` con 32 bytes aleatorios. Con él los procedimientos calculan la marca de "contexto interno" (sección 8.2). Ninguna cuenta de la app puede leerla. Viaja dentro de las copias de seguridad: trátelas como confidenciales.

## 8. Conexión desde Django

### 8.1 `settings.py`

```python
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.mysql",
        "NAME": "bordados_wanka",
        "USER": "wanka_tienda",            # el panel de administración usa wanka_admin
        "PASSWORD": os.environ["DB_PASSWORD"],
        "HOST": "127.0.0.1",
        "PORT": "3306",
        "CONN_MAX_AGE": 60,
        "OPTIONS": {
            "charset": "utf8mb4",
            "init_command": "SET time_zone = '+00:00', "
                            "sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,ONLY_FULL_GROUP_BY'",
        },
    }
}
USE_TZ = True
TIME_ZONE = "America/Lima"
LANGUAGE_CODE = "es-pe"
CODIGO_PEPPER = os.environ["CODIGO_PEPPER"]     # >= 16 caracteres; nunca en la BD
```

### 8.2 Actor de cada petición (`@app_actor_id`, `@app_ip`)

Los procedimientos y triggers saben **quién** actúa por variables de sesión. Como Django reutiliza conexiones, fíjelas **al inicio de cada petición y límpielas al final**:

```python
from django.db import connection

class ActorBDMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        actor = request.user.pk if request.user.is_authenticated else None
        ip = request.META.get("REMOTE_ADDR")   # detrás de un proxy: la IP real que fija SU proxy (no la que envía el navegador)
        with connection.cursor() as c:
            # @wanka_ctx_interno se limpia por si una conexión reutilizada quedó marcada tras un error
            c.execute("SET @app_actor_id = %s, @app_ip = %s, @wanka_ctx_interno = NULL", [actor, ip])
        try:
            return self.get_response(request)
        finally:
            with connection.cursor() as c:
                c.execute("SET @app_actor_id = NULL, @app_ip = NULL, @wanka_ctx_interno = NULL")
```
Los workers (correo, emisión al OSE, webhooks) dejan `@app_actor_id = NULL` (sistema).

Con el actor fijado, los triggers impiden además que un cliente modifique la fila de **otro** usuario o sus direcciones aunque la app se equivoque de id (protección contra IDOR).

- **`@app_ip`** acepta IPv4 o IPv6. Si llega una lista tipo `X-Forwarded-For`, la BD usa la primera; un texto inválido se guarda como `NULL` sin romper la operación. Sin IP conocida, los límites por IP (inicio de sesión, códigos, contacto, reclamos) **no se desactivan**: todas esas solicitudes comparten un mismo cupo.
- **`@wanka_ctx_interno`**: la app nunca la fija; solo la limpia. Los procedimientos la ponen en `fn_token_interno()` (SHA-256 del secreto de la instalación y del id de conexión) y los triggers exigen ese valor para tocar columnas derivadas (stock, montos pagados, estados, fechas del ciclo de vida...). Como las cuentas de la app no pueden leer el secreto ni ejecutar `fn_token_interno` (ni los `spi_*` internos), **no pueden fabricar la marca**: fijar `@wanka_ctx_interno = 1` ya no sirve para saltarse nada.

### 8.3 Llamar procedimientos y leer sus resultados

Llame los `sp_*` **en modo autocommit** (fuera de `transaction.atomic`): cada procedimiento es su propia transacción y `START TRANSACTION` confirmaría una transacción abierta de Django.

```python
with connection.cursor() as c:
    c.execute("CALL sp_crear_pedido(%s, NULL, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, 'web', @p, @n, @t)",
              [cliente_id, "domicilio", direccion_id, "adelanto", "boleta", None, None, None, None, None, None])
    c.execute("SELECT @p, @n, @t")
    id_pedido, numero, total = c.fetchone()
```

### 8.4 Errores claros (RNF 20)

Los procedimientos fallan con `MYSQL_ERRNO` entre 45001 y 45035. La tabla `catalogo_error` tiene el mensaje sugerido y el código HTTP:

```python
from django.db import DatabaseError    # Django envuelve el error del driver y conserva (errno, mensaje) en args
try:
    ...
except DatabaseError as e:
    codigo = e.args[0] if e.args and isinstance(e.args[0], int) else None
    if codigo and 45000 <= codigo <= 45999:
        mensaje = e.args[1]   # texto del procedimiento, o el amigable de catalogo_error
        ...
    else:
        raise
```

### 8.5 Modelos

- Las tablas de negocio se mapean con `class Meta: managed = False` (el esquema lo define este SQL).
- **`usuario.numero_documento` no se puede leer con SELECT** (ni la tienda ni el admin): deje ese campo fuera del modelo `Usuario` (o use `defer`) y muestre el dato enmascarado de las vistas. El documento completo se obtiene con `sp_ver_documento_completo` (deja constancia del acceso) y se registra con `sp_actualizar_documento_usuario`.
- La caché de RENIEC/SUNAT (`consulta_documento`) no se lista: la tienda consulta un documento exacto con `sp_obtener_consulta_documento`.
- Escrituras directas permitidas (por columnas):
  - Usuario (cliente o admin): solo `nombres`, `apellidos`, `celular`. Contraseña, correo, documento, estado y fechas van por sus procedimientos.
  - Direcciones (cliente y admin) y catálogos (admin).
  - Pedido (admin): solo `fecha_entrega_estimada`. La facturación se corrige con `sp_corregir_facturacion_pedido` (antes de emitir el comprobante).
  - Envío (admin): `id_courier`, `numero_guia`, `costo_real`, `fecha_entrega_estimada`, `observaciones`. El estado cambia con `sp_registrar_seguimiento_envio`.
  - Reclamos y mensajes de contacto: nada directo; use `sp_marcar_en_atencion`, `sp_responder_reclamo` y `sp_responder_mensaje_contacto`.
- Al editar con el ORM use `save(update_fields=[...])`: si un `save()` completo intenta escribir columnas derivadas (stock, montos pagados, valoración) con valores viejos, el trigger lo rechaza (es intencional).
- Tablas propias de Django (`django_session`, `django_migrations`...): ejecute `migrate` con una cuenta con permisos de creación (p. ej. `wanka_dba`) y luego `sql/07b_permisos_django_post_migrate.sql`.

### 8.6 Reglas y firmas que cambiaron en la revisión de errores

| Procedimiento | Qué cambió |
|---|---|
| `sp_crear_pedido_complementario` | Nuevo parámetro `p_fecha_entrega` (5.º; `NULL` = la del pedido original). |
| `sp_cotizar` | `p_fecha_entrega_acordada` (7.º). Con `p_costo_envio = NULL` el envío se cobra al aceptar según la zona de la dirección elegida. |
| `sp_emitir_nota_credito` | `p_id_devolucion` (5.º). Los motivos 06/07 exigen una devolución registrada; 01 exige el pedido cancelado; 02 no reembolsa. Las rebajas (04, 05, 08, 09, 10...) bajan lo que el cliente debe (`pedido.monto_ajustes`). |
| `sp_cambiar_estado_pedido` | Solo administrador y nunca a `cancelado` (eso es `sp_cancelar_pedido`). Un pedido con productos a pedido o personalizados pasa por `en_produccion`. |
| `sp_registrar_pago` | Cuentan también los cobros de pasarela iniciados hace menos de `minutos_gracia_pago_pasarela`. |
| `sp_anular_pago_pendiente` (nuevo) | El cliente abandona un cobro de pasarela pendiente. Si la pasarela lo aprueba después, se registra igual. |
| `sp_confirmar_pago_manual` | Un pago que ya no tiene saldo que cubrir se confirma como **huérfano** (`excede_total`) y figura por reembolsar, en vez de obligar a rechazar dinero real. |
| `sp_reembolsar_pago` | En un pedido vigente solo se reembolsa un excedente (`excedente`) o una compensación (`ajuste_precio`). Si hay comprobante, la compensación va por nota de crédito. |
| `sp_procesar_pago_pasarela` | Acepta `revertido` (contracargo o reembolso desde la pasarela): el evento queda con error y se avisa para revisarlo. Si la operación informada ya pertenece a otro pago devuelve `referencia_duplicada` (antes, error 1062). |
| `sp_registrar_segundo_factor` | Con TOTP exige el paso validado. Los fallos cuentan para el bloqueo de 5 intentos y la cuenta bloqueada no entra (tampoco con códigos de respaldo ni `sp_abrir_sesion`). |
| `sp_configurar_2fa` / `sp_confirmar_2fa` | Administradores: solo TOTP. Reconfigurar deja el secreto nuevo **pendiente** hasta confirmarlo (el actual sigue activo) e invalida los códigos de respaldo anteriores. |
| `sp_generar_codigo_verificacion` | El código va siempre al correo de la cuenta (salvo `cambiar_correo`). Los propósitos `cambiar_correo` y `cambiar_contrasena` exigen la cuenta iniciada. En el flujo anónimo el dueño se deduce del correo. Cupos: 5 por hora y 15 por día por correo **y propósito**, y 20 por hora por IP. |
| `sp_registrar_envio` | Idempotente: si el pedido ya salió devuelve el envío existente. |
| `sp_corregir_facturacion_pedido`, `sp_marcar_en_atencion`, `sp_obtener_consulta_documento`, `sp_redactar_log_api` (nuevos) | Ver secciones 7 y 8.5. |

## 9. Pruebas

```bash
./scripts/instalar.sh --pruebas
```
Crea `bordados_wanka_test` desde cero, instala 00→08 y corre `99_pruebas.sql`. Resultado esperado: **299 ✔ y 0 ✘**. En phpMyAdmin: instale los scripts reemplazando `bordados_wanka` por `bordados_wanka_test` e importe `99_pruebas.sql`.

Concurrencia real (sesiones en paralelo, después de la prueba anterior):
```bash
./scripts/prueba_concurrencia.sh
```
Casos: última unidad entre seis compradores, doble clic al pagar, dos administradores validando el mismo voucher, siete códigos a la vez (máximo 5), dos clientes agregando y quitando la misma variante 150 veces (0 deadlocks) y dos pagos confirmados a la vez mientras otra sesión retiene el pedido (el pedido queda pagado completo).
Los pasos manuales con dos pestañas de phpMyAdmin están al inicio de `99_pruebas.sql`.

## 10. Copias de seguridad (RNF 13)

```bash
mysqldump -u wanka_dba -p --single-transaction --routines --events --triggers --hex-blob --set-gtid-purged=OFF --default-character-set=utf8mb4 bordados_wanka | gzip > respaldos/bordados_wanka_$(date +%F).sql.gz
```
Con Docker:
```bash
docker exec wanka-mysql sh -c 'mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --routines --events --triggers --hex-blob --set-gtid-purged=OFF bordados_wanka' | gzip > respaldos/bordados_wanka_$(date +%F).sql.gz
```

- `--single-transaction`: copia consistente sin bloquear la tienda. `--routines --events --triggers`: incluye la lógica. `--hex-blob`: copia segura de los PDF/XML.
- **Cifrado**: guarde las copias cifradas (p. ej. `gpg --symmetric` o un disco cifrado) y una copia fuera del equipo. Contienen datos personales (Ley 29733).
- **Restauración**: las copias traen `DEFINER=wanka_definer@localhost`; en un servidor nuevo ejecute primero `00_requisitos_y_entorno.sql` (crea esa cuenta) y luego `gunzip < copia.sql.gz | mysql -u root -p bordados_wanka`.
- **Prueba de restauración** (mensual), en una base con otro nombre:
  ```sql
  CREATE DATABASE bordados_wanka_restaurada CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
  GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, TRIGGER, EVENT, SHOW VIEW, CREATE TEMPORARY TABLES
     ON bordados_wanka_restaurada.* TO 'wanka_definer'@'localhost';   -- sin esto fallan las vistas (error 1370)
  ```
  Restaure (`gunzip < copia.sql.gz | mysql -u root -p bordados_wanka_restaurada`), verifique conteos y que `SELECT COUNT(*) FROM v_inconsistencias;` dé 0; luego bórrela y quite el permiso. *(Probado: copia y restauración con datos, PDF/XML en BLOB, 161 triggers, rutinas y vistas, 0 inconsistencias.)*

## 11. Compatibilidad con MariaDB (`COMPAT-MARIADB`)

El objetivo acordado es MySQL 8 y **no se probó en MariaDB**. Si no hay alternativa a XAMPP con MariaDB, estos son los cambios (marcados con `COMPAT-MARIADB` en el SQL):

| MySQL 8 (usado) | En MariaDB |
|---|---|
| Colación `utf8mb4_0900_ai_ci` | `utf8mb4_unicode_520_ci` (o `utf8mb4_uca1400_ai_ci` en 11.x) |
| `REGEXP_LIKE(col, patrón, 'c')` en CHECK y procedimientos | `col REGEXP BINARY 'patrón'` |
| `INSERT ... AS nuevo ON DUPLICATE KEY UPDATE x = nuevo.x` | `ON DUPLICATE KEY UPDATE x = VALUES(x)` |
| `RANDOM_BYTES()` | existe desde 10.10 |
| `JSON_TABLE`, `SKIP LOCKED` | desde 10.6 |
| `JSON` (validado) | alias de `LONGTEXT`: agregar `CHECK (JSON_VALID(col))` |
| `CREATE ROLE` / `SET DEFAULT ROLE` / `IDENTIFIED BY RANDOM PASSWORD` | roles con otra sintaxis; crear cuentas con clave explícita |
| `SET_ANY_DEFINER` | `SUPER` / `SET USER` según la versión |

Alternativa sin cambios: instalar **MySQL 8** (instalador oficial, Laragon con MySQL 8 o el `docker-compose.yml` de este repositorio) y apuntar phpMyAdmin a él.

## 12. Problemas frecuentes

| Mensaje | Causa y solución |
|---|---|
| `ERROR 1449: The user specified as a definer ('wanka_definer'@'localhost') does not exist` | Falta el 00 (o se restauró una copia en otro servidor): ejecute `00_requisitos_y_entorno.sql`. |
| `Access denied; you need (at least one of) the SET_ANY_DEFINER/SET_USER_ID privilege` | Importe como `root` (o con una cuenta con ese privilegio). |
| `ERROR 3819: Check constraint ... is violated` | Un dato no cumple el formato (correo, DNI/RUC, slug, montos...). Lea el nombre de la restricción en `DICCIONARIO_DE_DATOS.md`. |
| `ERROR 450xx` | Regla de negocio: ver `catalogo_error`. |
| `ERROR 45023 ... use el procedimiento correspondiente (sp_*)` | Se intentó cambiar a mano una columna que solo cambian los procedimientos (estado, montos, fechas, stock...). Use el `sp_*` que indica el mensaje. |
| `ERROR 1143: SELECT command denied ... column 'numero_documento'` | El modelo de Django incluye el documento: quítelo o use `defer` (sección 8.5). |
| `ERROR 1370: execute command denied ... routine 'spi_...'` | Es correcto: los `spi_*` son internos; llame al `sp_*` público. |
| Los pedidos sin pagar no expiran | `event_scheduler` está en OFF (sección 6). |
| phpMyAdmin: “archivo demasiado grande” | Suba `upload_max_filesize` / `post_max_size` en `php.ini` (los archivos pesan menos de 250 KB). |
| Fechas con 5 horas de diferencia | Es correcto: la BD guarda UTC; las vistas `*_lima` y Django (`TIME_ZONE = 'America/Lima'`) muestran hora de Lima. |

## 13. Regenerar la documentación

Si cambia el SQL, reinstale y regenere el diccionario y el diagrama ER:
```bash
python3 -I scripts/generar_documentacion.py
```
