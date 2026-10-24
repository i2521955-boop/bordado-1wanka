# PROMPT PARA EL AGENTE — Base de datos MySQL de Bordados Wanka S.A.C.

> Adjunta junto a este prompt: (1) `BORDADOS_WANKA_Requerimientos_y_Backlog.xlsx`, (2) `bordadosdb_tienda.sql` (versión PostgreSQL actual) y (3) `bordadosdb_login.sql` (módulo de login en PostgreSQL). Si falta alguno, dilo al inicio y pregunta antes de continuar.

---

## 0. ROL Y OBJETIVO

Actúa como **arquitecto de bases de datos senior (MySQL 8, comercio electrónico peruano, facturación electrónica SUNAT)**. Debes **auditar, mejorar y migrar a MySQL** la base de datos del sistema web de **Bordados Wanka S.A.C.** (tienda de polleras, fajas y chalecos bordados, Huancayo, Perú).

El resultado debe ser una **base de datos profesional, completa, validada y protegida**, que funcione **sin errores** al importarla en **phpMyAdmin / localhost**, y que cubra **todos** los requerimientos del Excel adjunto y todas las reglas de este documento. No tiene que ser "perfecta", pero debe acercarse lo más posible y estar preparada para crecer.

Se trabaja **solo la base de datos** por ahora (la aplicación Django se construirá después, sprint por sprint, apoyándose en ella).

---

## 1. CONTEXTO DEL PROYECTO

- Proyecto académico con cliente real. Metodología Scrum, 8 sprints hasta fines de enero de 2027.
- Aplicación: Django (patrón MVT) y Python 3.12. **La base de datos pasa de PostgreSQL 18 a MySQL** (motivo: se usará en localhost con phpMyAdmin).
- Roles del sistema: **solo `administrador` y `cliente`** (las funciones del vendedor pasan al administrador; "tester" es rol del equipo, no del sistema).
- Pagos: Mercado Pago (tarjeta), PayPal, y Yape / Plin / transferencia validados por el administrador (más efectivo en venta presencial). Stripe descartado.
- Comprobantes: boleta, factura y nota de crédito mediante un **proveedor autorizado por SUNAT (OSE/PSE)**. La empresa **ya tiene habilitada la emisión electrónica** con su RUC (20615339386), por lo que **se debe poder emitir factura con RUC y razón social del cliente**.
- Moneda PEN, zona horaria America/Lima (UTC−5, sin horario de verano), idioma es-PE.

---

## 2. REGLAS DE NEGOCIO OBLIGATORIAS (dichas por el equipo; tienen prioridad)

1. **Cumplir todos los requisitos del Excel** (58 RF, 52 RNF, 40 HU). Entrega una matriz de trazabilidad (ver §9, entregable 4).
2. **Modalidad de pago elegida por el cliente: pago completo (100 %) o mitad (adelanto 50 %).**
   - Al pagar, el cliente elige una de las dos; el sistema le ofrece las opciones de pago según esa elección.
   - Guardar la elección en el pedido (`modalidad_pago` ENUM `'total','adelanto'`) y el porcentaje aplicado (`adelanto_porcentaje`, tomado de configuración o de la cotización; **editable**, por defecto 50).
   - El pedido pasa a `confirmado` cuando lo pagado confirmado ≥ el monto requerido por la modalidad elegida.
   - Con adelanto, el **saldo** se paga después (pago tipo `saldo`). Propón y documenta una regla para que el pedido **no pase a `enviado`/`entregado` con saldo pendiente** (déjala configurable y marcada como "por confirmar con el gerente").
   - ⚠️ Nota: el Excel dice "total, o adelanto solo en pedidos al por mayor". El equipo ahora indica que el cliente **siempre** elige total o mitad. **Aplica la regla nueva** y deja una clave de configuración `adelanto_permitido_en` (`todos`/`solo_mayor`) para poder volver al criterio del Excel sin cambiar código.
3. **No existe el concepto de "pago tardío" como flujo de negocio** (no es una membresía ni un plan de cuotas). Elimina esa idea de nombres, vistas, comentarios y documentación.
   - Sin embargo, **conserva la salvaguarda técnica**: si una pasarela confirma un cobro cuando el pedido ya estaba cancelado/expirado, **el dinero no debe perderse ni ignorarse**. Modélalo como **"pago huérfano / por reembolsar"** (vista `v_pagos_por_reembolsar`), nunca como "pago tardío". Explícalo en una frase en el documento de cambios.
4. **La base debe almacenar todo lo necesario, pero con calidad.** Nada de datos basura: cada columna con tipo exacto, `NOT NULL` donde corresponda, `CHECK`, `UNIQUE`, llaves foráneas, normalización de textos (trim, minúsculas en correos) y validación de formatos (DNI 8 dígitos, RUC 11 dígitos que empiece por 10/15/16/17/20, CE, teléfono, correo, slugs, series de comprobante). Solo se guarda lo que de verdad se necesita (minimización de datos, Ley 29733).
5. **Estado de los pedidos siempre consultable**: pendientes, en proceso (confirmado / en preparación / en producción), terminados (listo / enviado / entregado), cancelados y devueltos. Historial inmutable de cada cambio de estado con quién lo hizo.
6. **El administrador es un superusuario con CRUD completo** (crear, leer, actualizar, "eliminar"), **pero "eliminar" = inhabilitar**.
   - Productos, variantes, categorías, banners, zonas de envío, insumos, usuarios, direcciones y cualquier catálogo: **borrado lógico** (`activo`/`estado` + `inhabilitado_en` + `inhabilitado_por`). Un producto con ventas **se archiva**, nunca se borra. Los usuarios **se inhabilitan**, nunca se borran.
   - Implementa procedimientos `sp_inhabilitar_*` y `sp_reactivar_*`. Un `DELETE` físico sobre tablas de negocio debe estar **bloqueado por trigger para todos**, incluido el administrador de la aplicación (solo un rol DBA de mantenimiento, no usado por la app, podría borrar; documéntalo).
   - Las tablas históricas (kardex, historial de estados, auditoría, pagos, comprobantes, movimientos) son **solo inserción**.
7. **Códigos de verificación por correo** (login/verificación de correo, recuperar o cambiar contraseña, 2FA por correo si aplica):
   - Generados con **aleatoriedad criptográfica** (el agente debe indicar cómo en MySQL: p. ej. `RANDOM_BYTES()` convertido a número de N dígitos; **no usar `RAND()`**).
   - **Nunca se repite un código vigente**: el procedimiento de generación reintenta hasta que no exista otro código activo igual (índice único sobre el hash del código + estado activo mediante columna generada).
   - **Vigencia máxima: 5 minutos.** Pasado ese tiempo el código queda inutilizable (validación por `expira_en` en el procedimiento de verificación, no solo en la app). Un evento programado marca como `expirado` los vencidos.
   - Uso único (`usado_en`), máximo **5 intentos** por código, máximo **5 solicitudes por hora** por usuario/correo, bloqueo registrado.
   - Guardar **solo el hash** del código (SHA-256 con sal/pepper), nunca el código en claro.
   - ⚠️ El Excel (HU-02) dice 10 minutos; **el equipo indica 5**. Aplica 5 y déjalo en `configuracion` (`codigo_verificacion_minutos` = 5, con tope máximo permitido de 5). Anota la discrepancia para que se corrija el Excel.
   - **Envío del correo**: documenta las dos opciones que le sugirieron al equipo: (A) una cuenta de correo propia de la empresa por SMTP (remitente fijo) y (B) un servicio transaccional. En ambos casos la BD solo necesita la **cola de correos** (`cola_correo`) con reintentos; el envío lo hace la aplicación. Explica brevemente cuál recomiendas para un proyecto local y por qué.
8. **Comprobante electrónico: guardar siempre una copia completa en la BD** para que el administrador, en un apartado, pueda consultar "la copia de lo que se emitió":
   - Cabecera del comprobante **y sus líneas** (tabla `comprobante_item`: descripción, SKU, cantidad, precio unitario, valor de venta, IGV, unidad, tipo de afectación IGV), con **datos del emisor y del cliente congelados** (razón social, RUC, domicilio fiscal, nombre, documento, dirección) tal como estaban al emitir.
   - Guardar el **JSON/XML enviado y la respuesta del OSE/PSE** (`payload_envio`, `payload_respuesta`), hash, URLs de PDF/XML/CDR y, si se decide, el PDF/XML en `LONGBLOB` en una tabla aparte `comprobante_archivo` (justifica la decisión: ruta vs. BLOB).
   - **Cola de emisión** (`cola_emision_comprobante`) con estados, reintentos, backoff y último error, para que la emisión sea asíncrona y reintentable.
   - Factura: exige RUC (11 dígitos válidos) y razón social; boleta: exige DNI si el total supera el umbral configurable (`umbral_boleta_dni`, por defecto 700; **marcar como "verificar con SUNAT/OSE"**).
   - **Notas de crédito validadas por trigger/procedimiento**: referencian un comprobante aceptado del mismo pedido, serie compatible (B→B, F→F), motivo obligatorio (catálogo de motivos SUNAT), la suma de notas no supera el total del comprobante, y **no se puede emitir contra un comprobante rechazado/anulado**.
   - Un comprobante aceptado por SUNAT **no se modifica**: solo se corrige con nota de crédito.
9. **Devolver un pedido repone el stock** (cuando corresponde al producto de tipo `stock`), y debe quedar en el kardex. Cancelar un pedido sin pago libera la reserva; cancelar uno ya confirmado devuelve unidades. Valida que no se pueda devolver dos veces ni reponer más de lo vendido.
10. **El sistema se conecta por APIs**:
   - **APIs propias** (las construirá Django): la BD debe dar soporte con vistas/procedimientos limpios (`sp_*`, `v_*`) para que cada endpoint sea simple.
   - **APIs externas que se consumen**: OSE/PSE (SUNAT) para facturación (obligatoria), **RENIEC/SUNAT para consulta de DNI/RUC** (autocompletar nombre y razón social), pasarelas Mercado Pago y PayPal (webhooks) y, a futuro, el courier.
   - La BD debe tener: tabla de **webhooks recibidos** con idempotencia (`evento_pasarela`), tabla de **bitácora de llamadas a APIs externas** (`log_api_externa`: proveedor, endpoint, método, código HTTP, duración, request/response enmascarados, correlación con pedido/comprobante), y tabla de **caché de consultas de documento** (`consulta_documento`: tipo, número, nombre/razón social, estado, domicilio, consultado_en, vigencia). **No guardar secretos ni tokens en la BD.**
11. **La base debe cubrir "todo lo que se deba prever"**: lo que el Excel pide y lo que un sistema de comercio electrónico serio necesita aunque no esté escrito (ver §4 y §7).

---

## 3. OBJETIVO TÉCNICO: MySQL "puro"

- Versión objetivo: **MySQL 8.0.x / 8.4 LTS, motor InnoDB, `utf8mb4`**, collation `utf8mb4_0900_ai_ci` (insensible a tildes y mayúsculas; reemplaza `citext` y `unaccent`).
- **Código netamente MySQL**: nada de sintaxis PostgreSQL ni extensiones.
- ⚠️ **Verificación de entorno**: XAMPP/WAMP suelen traer **MariaDB**, no MySQL. Al inicio del script incluye una **comprobación de versión** (`SELECT VERSION()`) con un comentario claro y, si es MariaDB, indica qué partes dejarían de funcionar (por ejemplo `RANDOM_BYTES` sí existe en MariaDB ≥ 10.10; CHECK, generated columns e índices funcionales difieren). Prioriza MySQL 8; marca con `-- COMPAT-MARIADB:` lo que se pueda adaptar fácil.
- Importable por **phpMyAdmin** (pestaña SQL con `DELIMITER`) y por línea de comandos `mysql < archivo.sql`. Divide el script en **archivos numerados y pequeños** (< 2 MB cada uno) y que sean **re-ejecutables** (`DROP ... IF EXISTS` controlado al principio, o `CREATE ... IF NOT EXISTS`) sin dejar la base a medias.
- `sql_mode` estricto (`STRICT_TRANS_TABLES, NO_ZERO_DATE, NO_ZERO_IN_DATE, ERROR_FOR_DIVISION_BY_ZERO, ONLY_FULL_GROUP_BY`).
- Todas las fechas se guardan en **UTC** (`DATETIME(3)` o `TIMESTAMP(3)`); las vistas y reportes convierten a Lima con un desplazamiento fijo (−05:00), sin depender de las tablas de zonas horarias de MySQL.

### 3.1 Qué cambia de PostgreSQL a MySQL (resuélvelo todo)

| En PostgreSQL (original) | En MySQL: cómo resolverlo |
|---|---|
| `GENERATED ALWAYS AS IDENTITY` | `BIGINT UNSIGNED AUTO_INCREMENT` |
| Índices únicos **parciales** (`WHERE ...`) | Columna generada (`IF(cond, valor, NULL)`) + `UNIQUE` (los NULL no chocan) |
| `CHECK` con subconsultas / funciones | MySQL no lo permite: moverlo a **triggers** o procedimientos; los `CHECK` simples sí se mantienen (MySQL ≥ 8.0.16) |
| `TIMESTAMPTZ`, `now()` | `DATETIME(3)` en UTC, `UTC_TIMESTAMP(3)` |
| `JSONB` | `JSON` (con columnas generadas indexadas si se consulta por una clave) |
| `INET` | `VARBINARY(16)` con `INET6_ATON/INET6_NTOA` |
| `UUID uuidv7()` | `BINARY(16)` con `UUID_TO_BIN(UUID(),1)` o BIGINT autoincremental |
| `citext` | columna con collation `_ai_ci` |
| `tsvector` + `unaccent` + `pg_trgm` | `FULLTEXT` (InnoDB) + collation `_ai_ci`. Documenta que **no hay tolerancia a errores de tipeo** y propón alternativa (LIKE con prefijo, columna normalizada, o ngram parser) |
| `RAISE EXCEPTION ... USING ERRCODE` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT=..., MYSQL_ERRNO=...` con **catálogo de códigos de error propios** (p. ej. 45001 stock insuficiente) para que Django los traduzca a mensajes claros (RNF 20) |
| `INSERT ... ON CONFLICT` / `RETURNING` | `INSERT ... ON DUPLICATE KEY UPDATE` y `LAST_INSERT_ID(expr)` para correlativos atómicos |
| Trigger `BEFORE INSERT OR UPDATE` | MySQL exige **triggers separados** por evento (BEFORE INSERT, BEFORE UPDATE, etc.) |
| Un trigger que actualiza **la misma tabla** (p. ej. dirección predeterminada única) | Error 1442 en MySQL: resolver con columna generada única o con procedimiento almacenado |
| `SECURITY DEFINER` por función, `SET search_path` | `DEFINER=` y `SQL SECURITY DEFINER` explícitos con usuario de servicio sin login |
| `current_setting('app.actor_id')` | Variable de sesión `@app_actor_id` que Django fija al abrir la conexión/transacción; funciones que la lean con `COALESCE` |
| `pg_cron` / tareas externas | `CREATE EVENT` (requiere `event_scheduler=ON`; documéntalo y deja el script para activarlo) |
| Roles `CREATE ROLE ... NOLOGIN` | `CREATE ROLE` de MySQL 8 + `GRANT` por rol; **sin contraseñas escritas en el script** (usar marcadores `<CAMBIAR>`) |
| `EXPLAIN` / índices parciales | Índices compuestos + columnas generadas; comprobar con `EXPLAIN` |

### 3.2 Arquitectura de escritura (decisión de diseño que debes aplicar)

Los triggers de MySQL tienen límites (no pueden modificar la tabla que los dispara, no controlan transacciones). Por eso:

- **Los flujos críticos pasan por procedimientos almacenados con transacción**: `sp_crear_pedido`, `sp_agregar_item`, `sp_registrar_pago`, `sp_confirmar_pago_manual`, `sp_rechazar_pago`, `sp_cambiar_estado_pedido`, `sp_cancelar_pedido`, `sp_devolver_pedido`, `sp_reembolsar_pago`, `sp_emitir_comprobante`, `sp_emitir_nota_credito`, `sp_aceptar_cotizacion` (la convierte en pedido), `sp_crear_pedido_complementario`, `sp_ajustar_stock`, `sp_ajustar_insumo`, `sp_generar_codigo_verificacion`, `sp_verificar_codigo`, `sp_inhabilitar_*`.
- **Los triggers se usan como red de seguridad** (validaciones de integridad, inmutabilidad, bloqueo de `DELETE`, auditoría), de modo que aunque alguien escriba directo en la tabla no pueda romper las reglas.
- Bloqueo de filas con `SELECT ... FOR UPDATE` **siempre en el mismo orden** (por `id_variante`) para evitar deadlocks, y manejo de reintento ante error 1213.
- Cada procedimiento valida entradas, devuelve resultados claros (`OUT` params) y falla con `SIGNAL` y mensaje comprensible.

---

## 4. ALCANCE FUNCIONAL: módulos y tablas

Parte del script PostgreSQL adjunto (conserva su modelo y reglas, que son correctos en su mayoría) y **complétalo y corrígelo**. Debe haber como mínimo:

**Acceso y seguridad** (reconstruir en MySQL a partir de `bordadosdb_login.sql`): `rol`, `usuario` (con `tipo_documento`/`numero_documento`, estado, intentos fallidos, bloqueado_hasta, `inhabilitado_en`), `sesion`, `intento_acceso`, `codigo_verificacion` (§2.7), `historial_contrasena` (no reutilizar las últimas 3), `autenticacion_2fa` + `codigo_respaldo_2fa` (TOTP obligatorio para administradores; el secreto se guarda cifrado con `AES_ENCRYPT` y clave fuera de la BD, o delega el cifrado a la app y documéntalo), `consentimiento_datos` (versión de política, fecha, IP), `solicitud_arco` (acceso, rectificación, cancelación, oposición; estado y plazo), `auditoria` **inmutable y con retención ≥ 12 meses**.

**Catálogo**: `categoria`, `producto`, `variante_producto`, `imagen_producto`, `precio_volumen`, `favorito`, `resena`, `banner`. Búsqueda `FULLTEXT`. Valoración promedio recalculada por trigger/procedimiento.

**Inventario**: `movimiento_stock` (kardex), reservas, stock mínimo y alertas; `insumo` + `movimiento_insumo` (ingresos, consumos, ajustes, alerta de mínimo). (Opcional recomendado: `receta_producto` para que producir descuente insumos; justifica si lo incluyes.)

**Compra**: `carrito` / `item_carrito` (el precio **nunca** se guarda en el carrito), `direccion`, `zona_envio`, `pedido`, `item_pedido` (con snapshot de nombre, SKU, talla, color, precio, personalización), `transicion_estado_pedido`, `historial_estado_pedido`, `pedido` complementario (`id_pedido_origen`) para HU-29.

**Cotizaciones**: `cotizacion` + `item_cotizacion` (al por mayor y bordado personalizado), vigencia, aceptación → pedido, vencimiento automático.

**Envío**: además de courier y guía en el pedido, tabla `envio` / `seguimiento_envio` con eventos de estado y fechas (HU-12), preparada para una futura API del courier.

**Pagos**: `pago` con máquina de estados (`transicion_estado_pago`), `modalidad`/`tipo` (adelanto, saldo, total), `idempotency_key`, voucher, operación Yape/Plin/banco **única**, validación por administrador con motivo de rechazo, `reembolso` (tabla propia: monto, motivo, quién, referencia, estado) y `evento_pasarela` (webhooks idempotentes). Un pago confirmado **no se modifica**: se reembolsa.

**Comprobantes**: `serie_comprobante`, `comprobante`, `comprobante_item`, `comprobante_archivo`, `cola_emision_comprobante`, `motivo_nota_credito` (catálogo SUNAT).

**Atención al cliente**: `mensaje_contacto` (ticket; máx. 3 por hora por IP), `reclamo` (Libro de Reclamaciones; plazo 30 días, **configurable y marcado "verificar INDECOPI"**), respuestas con historial.

**Sistema**: `configuracion` (con validación de tipo y rango por clave), `secuencia_documento` (numeración sin saltos), `cola_correo`, `notificacion`, `log_api_externa`, `consulta_documento`, `evento_pasarela`.

**Fuera de alcance actual**: cupones (HU-40). Deja el diseño listo para agregarlos (por ejemplo, `pedido.descuento` ya existe) pero **no los implementes**.

---

## 5. REGLAS DE INTEGRIDAD POR FLUJO (todas deben quedar en la BD)

1. **Pedido nuevo**: nace en `pendiente_pago`, sin pagos. El costo de envío sale de la zona, nunca del navegador. Total = subtotal − descuento + envío. Pedido al por mayor exige N días de anticipación (configuración, por defecto 10). No se cobra un pedido vacío.
2. **Ítems**: solo editables con el pedido pendiente de pago; nombre/SKU/talla/color y precio mínimo salen de la BD; respeta precio por volumen; en pedidos que vienen de cotización rige el precio cotizado. Producto inactivo/archivado no se vende.
3. **Stock**: reserva al crear el pedido, descuento al confirmar, liberación al cancelar sin pago, devolución al cancelar/devolver pedido confirmado. Sin sobreventa (bloqueo de fila). Productos `a_pedido` no descuentan stock.
4. **Expiración**: un evento cancela pedidos sin pago pasado el plazo (`horas_reserva_pedido`), salvo que tengan un pago en revisión o confirmado.
5. **Pagos**: máquina de estados; el monto confirmado nunca excede el total del pedido; misma moneda; `monto_pagado` y `estado_pago` del pedido **siempre se derivan** de los pagos confirmados (no se fijan a mano); Yape/Plin/transferencia/efectivo solo los confirma un administrador y exigen voucher u operación; pasarelas exigen referencia externa y llegan por webhook verificado e idempotente.
6. **Confirmación del pedido**: solo con el pago requerido por la modalidad elegida (§2.2).
7. **Estados**: solo transiciones permitidas (tabla única de verdad); `recojo` no pasa por `enviado`; `domicilio` debe pasar por `enviado` antes de `entregado`; todo cambio queda en historial y auditoría y genera aviso (correo en cola + notificación).
8. **Reseñas**: solo quien compró y recibió; una por producto y usuario; moderación del administrador.
9. **Cotizaciones**: flujo `solicitada → en_revision → cotizada → aceptada → convertida` (o `rechazada`/`vencida`); al aceptar se convierte en pedido con los precios cotizados y el adelanto de la cotización.
10. **Contacto/reclamos**: ticket y número correlativos por año, sin saltos; límites de frecuencia.
11. **Numeración**: correlativos por año y por serie, atómicos (sin duplicados ni saltos aun con concurrencia).

---

## 6. SEGURIDAD Y PERMISOS

- Roles MySQL: `rol_app_tienda` (la aplicación pública: CRUD acotado, **sin DELETE físico**), `rol_app_admin` (panel de administración: CRUD completo sobre datos de negocio; "eliminar" solo lógico), `rol_reportes` (solo `SELECT` sobre vistas), `rol_dba_mantenimiento` (único con capacidad de borrado físico, fuera de la app). Principio de mínimo privilegio; los procedimientos críticos con `SQL SECURITY DEFINER`.
- Nada de contraseñas, tokens ni claves en el script (usa marcadores `<CAMBIAR_...>` y comentarios de uso).
- Contraseñas: la BD guarda **solo el hash** (PBKDF2-SHA256 o Argon2 generado por Django); nunca texto plano.
- Datos de tarjeta: **jamás**. `datos_pasarela` no puede contener PAN ni CVV (documenta cómo la app debe filtrarlo).
- DNI/RUC: columnas pensadas para **enmascarar** en las vistas que ve el administrador y limitar quién ve el dato completo (Ley 29733).
- Protección contra inyección: los procedimientos usan parámetros tipados; nada de SQL dinámico con concatenación.
- Bloqueo de cuenta tras 5 intentos fallidos (15 min), registrado en `intento_acceso` y `auditoria`.
- Incluye un bloque de **copias de seguridad** documentado (`mysqldump --single-transaction --routines --events --triggers`) y una nota sobre cifrado y prueba de restauración (RNF 13).

---

## 7. LO QUE DEBES REVISAR Y CORREGIR DEL SCRIPT ORIGINAL (checklist de auditoría)

Revisa el SQL adjunto línea por línea y **lista cada hallazgo** (qué era, por qué era problema, cómo lo corriges). Como mínimo comprueba:

1. Dependencia del script de login: la tienda referencia `usuario`, `rol` y `auditoria` que no están en el archivo; asegúrate de que el nuevo orden de ejecución funcione de punta a punta.
2. **Pago tardío**: cambiar el concepto por "pago huérfano / por reembolsar" (§2.3).
3. **Modalidad de pago** (total/50 %) no existe como dato del pedido; hoy el adelanto solo se deduce de `tipo_venta`.
4. **Falta**: códigos de verificación, historial de contraseñas, sesiones, 2FA, consentimiento y ARCO (si no están en el script de login, créalos).
5. **Comprobante**: no guarda líneas, ni el payload/respuesta del OSE, ni cola de emisión; las notas de crédito no disparan reembolso, ni reposición de stock, ni se vinculan a la devolución.
6. **Reembolsos**: el estado `reembolsado` es del pago, pero no hay registro de quién, cuánto, por qué ni referencia de la pasarela; falta tabla `reembolso`.
7. **Cotización → pedido**: no hay procedimiento que haga la conversión de forma atómica.
8. **Envío**: no hay eventos de seguimiento.
9. **Borrado**: la política actual permite que `wanka_admin` borre históricos; la nueva regla es **inhabilitar**, no borrar.
10. **Rendimiento**: índices en llaves foráneas y consultas críticas; evitar subconsultas correlacionadas en vistas de reportes; paginación; plan de particionado/archivado para tablas que crecen (auditoría, `log_api_externa`, `movimiento_stock`).
11. **Consistencia**: tipos, longitudes y nulidad coherentes entre tablas; columnas de auditoría (`creado_en`, `actualizado_en`, `creado_por`, `actualizado_por`) uniformes; ENUM vs. tabla de catálogo (justifica cada elección).
12. **Concurrencia**: dos compras simultáneas del último ítem, doble clic en "pagar", webhook duplicado, dos administradores validando el mismo voucher, dos solicitudes de código a la vez.
13. **Zona horaria y fechas**: todo en UTC y conversión a Lima en vistas; el "día" de un reporte es el día de Lima.
14. **Redondeo e IGV**: IGV 18 % incluido en precios; `op_gravada + igv = total` exacto a 2 decimales; una sola función para calcularlo.
15. **Idempotencia** de webhooks y de procedimientos que cobran/emiten.
16. Cualquier otro error, riesgo o incoherencia que encuentres: **repórtalo aunque no esté en esta lista**.

---

## 8. PRUEBAS (obligatorias)

Entrega un archivo `99_pruebas.sql` (o varios) que se pueda ejecutar y que verifique con `SELECT` claro **✔ / ✘** (sin dejar datos basura; usa transacciones con `ROLLBACK` o una base `bordados_wanka_test`):

- Flujo feliz completo: registro → carrito → pedido → pago total → confirmación → preparación → listo → entrega → comprobante → reseña.
- Flujo con adelanto 50 %: pago de adelanto → confirmado → pago de saldo → pagado.
- Venta al por mayor: cotización → aceptación → pedido → adelanto.
- Cancelación sin pago (libera reserva) y cancelación/devolución con pago (repone stock, queda por reembolsar, nota de crédito válida).
- Rechazos esperados: stock insuficiente, pago excedido, transición inválida, pago confirmado modificado, DELETE físico, nota de crédito mayor al comprobante, factura sin RUC, boleta > S/ 700 sin documento, mayorista sin anticipación, código de verificación vencido (5 min) / reutilizado / repetido / con más de 5 intentos, más de 3 mensajes por hora, más de 5 códigos por hora.
- Concurrencia (documentada con pasos manuales para dos sesiones de phpMyAdmin/CLI).
- Matriz de permisos por rol (qué puede y qué no).

---

## 9. ENTREGABLES Y FORMATO

1. **Scripts SQL numerados, ejecutables en orden**, con cabecera de propósito y comentarios en español, sin errores de sintaxis en MySQL 8:
   - `00_requisitos_y_entorno.sql` (versión, `sql_mode`, charset, `event_scheduler`)
   - `01_esquema_acceso.sql`
   - `02_esquema_tienda.sql`
   - `03_funciones_procedimientos.sql`
   - `04_triggers.sql`
   - `05_vistas.sql`
   - `06_eventos.sql`
   - `07_roles_permisos.sql`
   - `08_datos_iniciales.sql` (categorías, zonas de envío, configuración, transiciones de estado, series de ejemplo marcadas "reemplazar por las reales del OSE", motivos de nota de crédito, roles `administrador` y `cliente`)
   - `99_pruebas.sql`
2. **`COMPARATIVA_Y_CAMBIOS.md`**: comparativa clara entre la base original (PostgreSQL) y la nueva (MySQL):
   - tabla *"qué se conserva / qué se mejora / qué cambia por MySQL / qué se pierde y cómo se compensa"*;
   - lista de hallazgos del §7 con su solución;
   - decisiones de diseño con su justificación (ENUM vs. catálogo, BLOB vs. ruta, FULLTEXT, etc.).
3. **`DICCIONARIO_DE_DATOS.md`**: cada tabla y columna, tipo, restricción, propósito y qué HU/RF/RNF la usa.
4. **`TRAZABILIDAD_HU_RF_RNF.md`**: para **cada** HU (01–40), RF (1–58) y RNF que tenga impacto en la BD, qué tablas, procedimientos, triggers, vistas o eventos la cubren; marca explícitamente **"no aplica a la BD"** o **"pendiente/decisión abierta"** cuando corresponda.
5. **Diagrama ER** en Mermaid (`erDiagram`) dividido por módulos para que sea legible.
6. **`LEEME_INSTALACION.md`**: pasos exactos para importar en phpMyAdmin / CLI, orden de scripts, cómo activar `event_scheduler`, cómo crear los usuarios con contraseñas propias, cómo configurar las variables de sesión (`@app_actor_id`) desde Django, cómo ejecutar las pruebas y cómo hacer la copia de seguridad.
7. **Lista de decisiones abiertas** (las del Excel: moneda de PayPal, proveedor OSE/PSE, umbral de boleta con DNI, domicilio fiscal vs. local, plazo del libro de reclamaciones, adelanto 50 %, courier y su API, registro del banco de datos ante la autoridad) y de las discrepancias de este prompt (5 vs. 10 minutos del código; total/mitad en todos los pedidos vs. solo mayor).

---

## 10. REGLAS DE TRABAJO PARA EL AGENTE

- **No inventes** datos reales (series, credenciales, endpoints, montos legales). Usa marcadores y márcalos como "por verificar".
- Si algo del Excel contradice este prompt, **gana este prompt** (son las decisiones más recientes del equipo) y **lo señalas** en el documento de decisiones abiertas.
- Si una instrucción no se puede cumplir en MySQL tal cual, **explícalo**, aplica la alternativa más cercana y documenta el trade-off. Nunca lo omitas en silencio.
- **Prueba lo que escribes**: si tienes acceso a una instancia MySQL 8, ejecuta los scripts en orden y corrige hasta que corran sin errores; si no, haz una revisión sintáctica minuciosa y dilo.
- Trabaja por etapas y muéstrame un **resumen al final de cada etapa** (esquema → lógica → seguridad → pruebas → documentación). No me pidas confirmación por cada detalle; **pregunta solo** si una decisión cambia el modelo de datos de forma importante.
- Escribe todo (comentarios, nombres de tablas y columnas, mensajes de error y documentación) **en español**, con nombres coherentes en `snake_case`.
- Prefiere **claridad y robustez** sobre ingenio. Cada objeto de la base debe poder explicarse en una línea.

---

**Empieza confirmando qué archivos recibiste, tu plan de etapas y las preguntas críticas (máximo 5). Luego ejecuta.**
