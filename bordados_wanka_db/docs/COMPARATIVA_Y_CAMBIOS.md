# Comparativa y cambios: PostgreSQL original → MySQL 8 (Bordados Wanka S.A.C.)

**Base original auditada:** `docs/original_postgresql_tienda.sql` (script de tienda en PostgreSQL, 1 080 líneas).
**No se recibieron:** `bordadosdb_login.sql` ni el Excel de requerimientos. El módulo de acceso se reconstruyó con lo que pide el §4 del prompt, y la trazabilidad marca qué falta confirmar contra el Excel.

## 1. Resumen

| | Original (PostgreSQL) | Nuevo (MySQL 8.4) |
|---|---|---|
| Tablas | 31 (más las de login, que faltaban) | **64** (12 de acceso + 52 de tienda) |
| Vistas | 6 | **42** (con datos enmascarados y fechas de Lima) |
| Funciones / procedimientos | 21 funciones PL/pgSQL (incluye las de trigger) | **30 funciones + 149 procedimientos** (108 `sp_` públicos con transacción, 41 `spi_` internos) |
| Triggers | 26 (11 usaban funciones del login ausente) | **161** (MySQL exige uno por evento) |
| Restricciones | CHECK en línea y 47 referencias FK (2 agregadas con `ALTER TABLE`) | **166 CHECK, 150 FK**, índices únicos sobre columnas generadas |
| Tareas programadas | funciones para pg_cron (sin programar) | **5 eventos** `CREATE EVENT` |
| Seguridad | sin roles definidos en el script | **4 roles** con permisos por tabla, columna y procedimiento; 4 cuentas bloqueadas; cuenta técnica `DEFINER` sin login; marca de contexto interno no falsificable |
| Pruebas | ninguna | **299 casos ✔** + 7 escenarios de concurrencia real + importación por phpMyAdmin verificada |

## 2. Qué se conserva, qué se mejora, qué cambia por MySQL y qué se pierde

| Tema | Se conserva | Se mejora | Cambia por MySQL | Se pierde → cómo se compensa |
|---|---|---|---|---|
| Modelo de catálogo | categorías, productos, variantes, imágenes, precio por volumen, favoritos | borrado lógico uniforme (`activo` + `inhabilitado_en/por`), SKU en mayúsculas, auditoría de cambios de precio | `IDENTITY` → `AUTO_INCREMENT`; índice único parcial de imagen principal → columna generada `principal_clave` + `UNIQUE` | — |
| Búsqueda | búsqueda sin tildes | — | `tsvector` + `unaccent` → `FULLTEXT` + colación `utf8mb4_0900_ai_ci` (verificado: “unico” encuentra “único”) | **tolerancia a errores de tipeo** (`pg_trgm`) → ver §6.3 |
| Inventario | kardex de solo inserción, bloqueo de fila sin sobreventa | reservas explícitas por ítem (`reserva_stock`), kardex enlazado a ítem y devolución, bloqueo en orden ascendente | `SELECT ... FOR UPDATE` igual; `%ROWTYPE` → variables | — |
| Pedidos | número correlativo anual, costo de envío desde la zona, anticipación para mayoristas, fórmula del total, flujo de estados en tabla | modalidad **total/adelanto**, estados con grupo consultable, transiciones con tipo de entrega/saldo/permisos, ítems con copia y precio calculado por la BD, retiro lógico de líneas | `CHECK` con subconsultas → triggers/procedimientos; trigger que toca su propia tabla (error 1442) → procedimientos | — |
| Pagos | máquina de estados, `idempotency_key`, operación única Yape/Plin, validación por administrador | idempotencia obligatoria, montos derivados por trigger, **pago huérfano** en lugar de rechazo, reembolsos con tabla propia, datos de tarjeta bloqueados | `JSONB` → `JSON`; `INET` → `VARBINARY(16)`; índice parcial → columna generada `operacion_clave` | — |
| Comprobantes | series, correlativo, estado SUNAT, URLs | **copia completa** (emisor y cliente congelados, líneas, payloads del OSE), cola de emisión con reintentos, NC validada, archivos en BLOB | `RETURNING` → `LAST_INSERT_ID(expr)` | — |
| Atención al cliente | tickets, Libro de Reclamaciones, límite por IP | límite serializado (sin carrera), historial de respuestas, plazos configurables | `citext` → colación `_ai_ci` + normalización a minúsculas | — |
| Fechas | `TIMESTAMPTZ` | todo en UTC, vistas en hora de Lima | `DATETIME(3)` en UTC + `fn_utc_a_lima` (−05:00 fijo) | zona con nombre → Perú no usa horario de verano, el desplazamiento fijo es exacto |
| Seguridad | `SECURITY DEFINER` (implícito) | cuenta técnica bloqueada como DEFINER, roles de mínimo privilegio, enmascarado de DNI/RUC | `current_setting('app.actor_id')` → `@app_actor_id`; roles NOLOGIN → `CREATE ROLE` | — |
| Errores | `RAISE EXCEPTION ... ERRCODE` | **catálogo de errores** 45001–45035 con mensaje y HTTP sugerido (RNF 20) | `SIGNAL SQLSTATE '45000' SET MYSQL_ERRNO` | — |
| Integridad diferida | FK circulares con `ALTER TABLE` | se eliminó la redundancia (`cotizacion.id_pedido`) | — | restricciones diferidas (no existen en MySQL) → cuadres verificados al final de cada procedimiento y en `v_inconsistencias` |
| Transacciones en triggers | lógica de stock dentro de triggers | flujos críticos en procedimientos con transacción; triggers como red de seguridad | triggers sin control de transacción | — |

## 3. Equivalencias PostgreSQL → MySQL aplicadas (§3.1)

| PostgreSQL | MySQL (cómo quedó) | Dónde |
|---|---|---|
| `GENERATED ALWAYS AS IDENTITY` | `BIGINT UNSIGNED AUTO_INCREMENT` (catálogos pequeños `SMALLINT/TINYINT UNSIGNED`) | 01, 02 |
| Índices únicos parciales | columna generada `IF(cond, valor, NULL)` + `UNIQUE` (los NULL no chocan): `hash_vigente`, `principal_clave`, `predeterminada_clave`, `activo_clave`, `operacion_clave`, `pedido_activo_clave`, `cantidad_activa` (el original impedía repetir una variante en el pedido; ahora se permite para cotizaciones con distinta personalización, ver §10) | 01, 02 |
| `CHECK` con subconsultas/funciones | triggers y procedimientos (dígito verificador del RUC, transiciones, sumas de NC, compras para reseñar) | 04, 03 |
| `CHECK` simples | se mantienen (MySQL ≥ 8.0.16); `REGEXP_LIKE(..., 'c')` para que sean sensibles a mayúsculas (la colación `ai_ci` no lo es) | 01, 02 |
| `TIMESTAMPTZ`, `now()` | `DATETIME(3)` en UTC con `DEFAULT (UTC_TIMESTAMP(3))`; `actualizado_en` lo fija un trigger (no depende de la zona de la sesión) | todo |
| `JSONB` | `JSON` | pagos, comprobantes, auditoría, colas |
| `INET` | `VARBINARY(16)` con `INET6_ATON/INET6_NTOA` | IPs |
| `uuidv7()` | `BIGINT UNSIGNED AUTO_INCREMENT` (más simple de indexar y de usar en Django) | evento_pasarela, cola_correo |
| `citext` | colación `utf8mb4_0900_ai_ci` + trigger que normaliza (trim + minúsculas) + `CHECK` binario | correos |
| `tsvector` / `unaccent` / `pg_trgm` | `FULLTEXT (nombre, descripcion)` con colación sin tildes | producto |
| `RAISE EXCEPTION ... USING ERRCODE` | `SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT, MYSQL_ERRNO` vía `spi_error` | 03, 04 |
| `INSERT ... ON CONFLICT ... RETURNING` | `INSERT ... ON DUPLICATE KEY UPDATE ultimo = LAST_INSERT_ID(ultimo + 1)` | `spi_siguiente_numero`, `spi_siguiente_correlativo` |
| Trigger `BEFORE INSERT OR UPDATE` | un trigger por evento (`_bi`, `_bu`, `_ai`, `_au`, `_bd`) | 04 |
| Trigger que actualiza su propia tabla (dirección predeterminada) | índice único sobre columna generada + `sp_definir_direccion_predeterminada` (también imagen principal) | 02, 03 |
| `SECURITY DEFINER`, `search_path` | `DEFINER=wanka_definer@localhost` + `SQL SECURITY DEFINER` en todos los objetos; la cuenta está bloqueada | 00, 03–06 |
| `current_setting('app.actor_id')` | `@app_actor_id` (y `@app_ip`) que fija Django; `fn_actor()` y `fn_ip_sesion()` | 03 |
| `pg_cron` | `CREATE EVENT` (requiere `event_scheduler=ON`) | 06 |
| `CREATE ROLE ... NOLOGIN` | `CREATE ROLE` + `GRANT`; cuentas con `IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK` (sin contraseñas en el script) | 07 |

## 4. Hallazgos de la auditoría (§7) y su solución

| # | Qué era | Por qué era un problema | Cómo se corrigió |
|---|---|---|---|
| 1 | La tienda usaba `usuario`, `rol`, `auditoria`, `fn_prohibir_delete` y `fn_solo_insercion`, y hacía `ALTER TABLE usuario`, pero nada de eso estaba en el archivo. | El script no corría solo; el orden de ejecución dependía de un archivo ausente. | `01_esquema_acceso.sql` crea todo el módulo de acceso; orden único 00→08 probado de punta a punta por consola y por phpMyAdmin. |
| 2 | Concepto de “pago tardío”. En el original, además, `fn_pago_before` **rechazaba** confirmar un pago de un pedido cancelado. | Si la pasarela confirmaba un cobro real después de cancelado/expirado el pedido, el webhook fallaba: el dinero quedaba sin registrar. | No existe “pago tardío”. El cobro se registra como **pago huérfano** (`aplicado_al_pedido = 0`, `motivo_no_aplicado`) y aparece en `v_pagos_por_reembolsar` hasta que se reembolsa. En una frase: *un cobro que llega cuando el pedido ya no está vigente no se pierde ni se ignora: se guarda como pago huérfano y queda pendiente de reembolso.* |
| 3 | La modalidad de pago no existía; el adelanto se deducía de `tipo_venta = 'mayor'`. | No se podía ofrecer “pagar todo o la mitad” a cualquier cliente. | `pedido.modalidad_pago` (`total`/`adelanto`), `adelanto_porcentaje` (de configuración o de la cotización, editable por el administrador), `monto_requerido` calculado; confirmación automática al alcanzarlo; `adelanto_permitido_en` (`todos`/`solo_mayor`) para volver al criterio del Excel sin tocar código. |
| 4 | Faltaban códigos de verificación, historial de contraseñas, sesiones, 2FA, consentimiento y ARCO. | Requisitos de seguridad y de la Ley 29733 sin soporte. | Tablas y procedimientos del módulo de acceso (ver §5 de este documento). |
| 5 | El comprobante no guardaba líneas, payload ni respuesta del OSE; no había cola; la NC no se vinculaba a devolución ni a reembolso; `UNIQUE (serie, correlativo)` sin el tipo; la NC no validaba su serie; el emisor no quedaba congelado. | No había “copia de lo emitido”; la emisión no era reintentable; podían emitirse NC inválidas. | `comprobante` con emisor/cliente congelados y payloads; `comprobante_item`; `comprobante_archivo` (BLOB); `cola_emision_comprobante` con backoff; NC validada por procedimiento y trigger (aceptado, mismo pedido, B→B/F→F, motivo SUNAT, suma ≤ total); `UNIQUE (tipo, serie, correlativo)`; aceptado = inmutable. |
| 6 | “Reembolsado” era solo un estado del pago. | No había quién, cuánto, por qué ni referencia de la pasarela; no admitía reembolsos parciales. | Tabla `reembolso` con estados, medio, referencia, NC y devolución asociadas; `pago.monto_reembolsado` derivado por trigger. |
| 7 | No había conversión cotización → pedido; además `cotizacion.id_pedido` y `pedido.id_cotizacion` duplicaban la relación (FK circular). | Conversión no atómica; datos que podían contradecirse. | `sp_aceptar_cotizacion` crea el pedido con precios y adelanto cotizados en una transacción; se dejó solo `pedido.id_cotizacion UNIQUE`. |
| 8 | Courier y guía como columnas del pedido; sin eventos. | No había seguimiento (HU-12) ni preparación para la API del courier. | `courier`, `envio`, `seguimiento_envio` (idempotente por id de evento externo); el evento “entregado” cierra el pedido. |
| 9 | El DELETE se bloqueaba solo en algunas tablas; catálogos sin columnas de borrado lógico; `ON DELETE CASCADE` en ítems; nombres `activa`/`activo` mezclados. | Se podían borrar históricos y catálogos con ventas. | DELETE bloqueado por trigger en todas las tablas de negocio (también para el admin de la app); solo `wanka_dba` con `@wanka_autorizo_borrado = 'SI-AUTORIZO'`, y queda auditado. `sp_inhabilitar_*`/`sp_reactivar_*`; sin cascadas; nombre único `activo`. |
| 10 | Índices parciales propios de PostgreSQL; vista con `ORDER BY`; sin plan para tablas que crecen. | En MySQL no existen índices parciales; ordenar dentro de una vista es inútil. | Índices compuestos para cada consulta crítica (verificados con `EXPLAIN`, ver §7); vistas sin `ORDER BY` (la app pagina); plan de particionado/archivado (§7). |
| 11 | Columnas de auditoría incompletas; tipos y nulidad desiguales; strings con `CHECK IN` en vez de ENUM o catálogo. | Difícil de mantener y de explicar. | `creado_en/por`, `actualizado_en/por` uniformes (los fija un trigger desde `@app_actor_id`); criterio ENUM vs. catálogo documentado (§6.1). |
| 12 | Bucles de stock sin orden (`FOR r IN SELECT ...` sin `ORDER BY`); `idempotency_key` admitía NULL; límite de mensajes sin serializar; sin reintento ante deadlock. | Riesgo de deadlocks, doble cobro y carreras. | Bloqueo pedido → pago → variantes ascendentes; reintento automático ante 1213 en `sp_crear_pedido`; `idempotency_key` obligatoria; `control_frecuencia` con `FOR UPDATE`. **Probado con sesiones paralelas** (§8). |
| 13 | Fechas con zona; día del reporte implícito. | En MySQL `TIMESTAMP` depende de la zona de la sesión. | UTC en todas las columnas; vistas con sufijo `_lima`; `fn_hoy_lima()` para vigencias y plazos. |
| 14 | `fn_igv_incluido` existía pero el comprobante no tenía líneas ni cuadre por línea. | Diferencias de céntimos entre cabecera y detalle. | Una sola función `fn_igv_incluido(total, tasa)`; IGV por línea; cabecera = suma exacta de líneas; `CHECK op_gravada + igv = total` en cabecera y en cada línea. |
| 15 | Webhooks con `UNIQUE (proveedor, id_externo)` pero sin procedimiento idempotente; emisión sin idempotencia. | Reprocesar un webhook o un clic duplicado podía duplicar efectos. | `sp_registrar_evento_pasarela` + `sp_procesar_pago_pasarela` (devuelve `duplicado`, `ya_confirmado`, `monto_distinto`...); `sp_registrar_pago` idempotente; `sp_emitir_comprobante` idempotente (una boleta/factura vigente por pedido). |
| 16 | **Otros hallazgos** (abajo) | | |

### 4.1 Otros hallazgos encontrados

| Hallazgo en el original | Riesgo | Solución |
|---|---|---|
| El estado `devuelto` no reponía stock (solo `cancelado` lo hacía). | Inventario descuadrado tras cada devolución. | `sp_devolver_pedido` repone stock por ítem, registra `devolucion`/`devolucion_item`, impide devolver dos veces (`cantidad_devuelta`), solicita reembolsos y emite NC. |
| El precio, nombre y SKU del ítem los insertaba la aplicación. | Un cliente podía manipular el precio. | El precio sale de la BD (`fn_precio_unitario`: lista, volumen o cotizado); `item_pedido` solo se inserta desde procedimientos. |
| El RUC se validaba solo como 11 dígitos. | RUC inexistentes en facturas. | Prefijos 10/15/16/17/20 + **dígito verificador módulo 11** (`fn_ruc_valido`). |
| `fn_ajustar_insumo` no bloqueaba la fila ni guardaba el saldo; el consumo bajo cero caía en un error genérico. | Carreras y mensajes poco claros. | `spi_mover_insumo` con `FOR UPDATE`, saldo en el kardex, error 45001 claro y alerta al cruzar el mínimo. |
| `CHECK (estado <> 'cancelado' OR cancelado_en IS NOT NULL)` era de una sola vía. | Fecha de cancelación en pedidos no cancelados. | Igualdad bidireccional en todos los pares estado/fecha (`(estado = 'cancelado') = (cancelado_en IS NOT NULL)`). |
| Yape/Plin exigían solo voucher (no aceptaban número de operación). | Rechazo de pagos válidos. | Voucher **o** número de operación; la operación es única por método. |
| `datos_pasarela` decía “nunca datos de tarjeta” solo en un comentario. | Riesgo PCI. | `fn_contiene_datos_tarjeta` (claves PAN/CVV + Luhn con prefijos de tarjeta) en procedimientos y triggers. |
| `v_clientes_resumen` mostraba DNI, correo y celular completos. | Exposición de datos personales (Ley 29733). | Vistas con datos enmascarados; dato completo solo con `sp_ver_documento_completo`, que queda auditado. |
| La reseña no tenía campos de moderación. | No se podía moderar ni ocultar con motivo. | `estado` con moderación, `moderado_por/en`, motivo; la valoración solo cuenta publicadas. |
| El límite de 3 mensajes por hora se contaba sin bloqueo. | Dos envíos simultáneos pasaban ambos. | Serialización por IP (`control_frecuencia`) + trigger de respaldo. |
| La expiración de pedidos solo excluía pagos “en revisión”. | Un cobro de pasarela posterior era rechazado. | Expiración por pedido y con transacción propia; el cobro posterior queda como pago huérfano. |
| El borrado de ítems de un pedido pendiente era físico. | Se perdía la trazabilidad de la reserva. | Retiro lógico (`estado = 'retirado'`) con liberación de reserva en el kardex. |

## 5. Reglas del equipo aplicadas (§2)

- **Modalidad total o mitad** para todos los pedidos (configurable a `solo_mayor`). Confirmación automática cuando lo pagado y confirmado ≥ `monto_requerido`. Regla propuesta (por confirmar con el gerente): con `bloquear_envio_con_saldo = 1` el pedido no pasa a `enviado` ni a `entregado` con saldo pendiente (sí puede llegar a `listo`).
- **Pago huérfano / por reembolsar** en lugar de “pago tardío” (ver hallazgo 2).
- **Calidad de datos**: tipos exactos, `NOT NULL`, `CHECK`, `UNIQUE`, FK, normalización (trim, minúsculas en correos, mayúsculas en SKU/CE), validación de DNI/RUC/CE/teléfono/correo/slug/series; minimización (DNI consultado no guarda domicilio; carritos abandonados se purgan).
- **Estados consultables** por grupo (`estado_pedido.grupo`: pendiente, en proceso, terminado, cancelado, devuelto) e historial inmutable con autor.
- **Administrador con CRUD completo**, eliminar = inhabilitar; DELETE bloqueado para todos salvo el DBA de mantenimiento.
- **Códigos por correo**: `RANDOM_BYTES` con muestreo por rechazo (sin sesgo), nunca `RAND()`; solo hash SHA-256 con pepper (que vive en Django); vigencia 5 min validada en el procedimiento; uso único; 5 intentos; 5 por hora; un código vigente nunca se repite (índice único); el bloqueo queda en auditoría. El Excel decía 10 min: anotado para corregirlo.
- **Copia completa del comprobante** y NC validadas; un comprobante aceptado no se modifica.
- **Devoluciones** que reponen stock, sin devolver dos veces.
- **APIs**: `evento_pasarela`, `log_api_externa` (rechaza tokens en la URL y datos de tarjeta), `consulta_documento` (caché RENIEC/SUNAT); sin secretos ni tokens en la BD.

## 6. Decisiones de diseño

### 6.1 ENUM vs. tabla de catálogo

| Dato | Elección | Por qué |
|---|---|---|
| Estado del pedido | **Catálogo** `estado_pedido` + `transicion_estado_pedido` | Tiene atributos de negocio (grupo, orden, nombre visible, si notifica) y reglas por transición (tipo de entrega, saldo, cliente, automática). |
| Método de pago | **Catálogo** `metodo_pago` | El administrador puede desactivar un método sin tocar código; define si es pasarela o manual y si exige voucher. |
| Motivo de NC | **Catálogo** `motivo_nota_credito` | Es un catálogo oficial de SUNAT (09) con reglas (total, repone stock). |
| Courier, zona de envío, rol | **Catálogo** | Datos que el negocio agrega o desactiva. |
| Estados de pago, comprobante, cotización, reembolso, envío; tipos (`boleta/factura`, `recojo/domicilio`, documento) | **ENUM** | Valores técnicos fijos que de todas formas exigen cambiar código si cambian; ENUM ocupa 1 byte y valida solo. Las transiciones de pago y cotización igual están en tablas. |

### 6.2 BLOB vs. ruta para PDF/XML/CDR

Se guardan **las dos cosas**: las URLs del OSE en `comprobante` y una copia binaria opcional en `comprobante_archivo` (`LONGBLOB`, con SHA-256 y tamaño). Motivo: el administrador debe poder ver “la copia de lo emitido” aunque el enlace del OSE caduque o se cambie de proveedor; el volumen es bajo (XML/CDR de pocos KB, PDF de decenas de KB, unos miles al año). La tabla está separada para que la cabecera siga liviana y para poder excluirla de copias rápidas si crece (`mysqldump --ignore-table`). Límite: `max_allowed_packet` (64 MB en el Docker incluido).

### 6.3 Búsqueda sin `pg_trgm`

`FULLTEXT` con colación `ai_ci` resuelve mayúsculas y tildes, pero **no** errores de tipeo ni palabras de menos de 3 letras, y la lista de palabras vacías por defecto es en inglés. Alternativas propuestas: (a) el catálogo es pequeño (decenas o cientos de productos): búsqueda difusa en Django (por ejemplo `rapidfuzz`) sobre `v_catalogo_productos`; (b) `LIKE 'prefijo%'` para autocompletar; (c) parser `ngram` si se quiere coincidencia por fragmentos (índice más grande, peor ranking); (d) tabla de palabras vacías en español con `innodb_ft_server_stopword_table`.

### 6.4 Procedimientos como camino principal, triggers como red

Los triggers de MySQL no controlan transacciones ni pueden modificar su propia tabla. Por eso cada flujo crítico es un `sp_*` con `START TRANSACTION ... COMMIT` y `ROLLBACK + RESIGNAL` ante error, y los triggers validan, normalizan, bloquean y auditan. Las columnas derivadas (stock, montos pagados, estado de pago, valoración) solo cambian con la marca de contexto interno que fijan los procedimientos; si Django intenta escribirlas directo (por ejemplo, un `save()` del ORM con un stock viejo), el trigger lo impide con un mensaje claro.

### 6.5 Otras decisiones

- **Identificadores**: `BIGINT UNSIGNED` autoincremental en lugar de UUID (más simple para Django e índices compactos). Los números visibles (pedido, ticket, reclamo, cotización, devolución, ARCO) salen de `secuencia_documento`, que es transaccional: sin saltos ni duplicados aun con concurrencia.
- **Secreto TOTP**: lo cifra la aplicación (Fernet/AES-GCM, clave en variables de entorno) y la BD guarda `VARBINARY`. No se usa `AES_ENCRYPT` porque la clave viajaría en las sentencias (podría verse en el log general o en `SHOW PROCESSLIST`) y su modo por defecto es ECB.
- **Pepper de los códigos**: lo envía Django como parámetro; nunca se guarda en la BD. Sin sal por fila a propósito: así el índice único puede impedir dos códigos vigentes iguales.
- **Auditoría y bitácora de APIs sin FK**: deben sobrevivir a cualquier cambio y quedan listas para particionar por fecha (InnoDB no admite FK en tablas particionadas).
- **Reservas explícitas** (`reserva_stock`): la suma de reservas activas debe ser igual a `variante.stock_reservado`; `v_inconsistencias` lo comprueba.
- **Cliente de mostrador** (`mostrador@bordadoswanka.invalid`): permite ventas presenciales sin cuenta web; no puede iniciar sesión y no recibe correos. El nombre y documento del comprobante salen de los datos de facturación del pedido.
- **Carrito y favoritos**: son estado de interfaz sin valor histórico; se quitan físicamente, pero solo con `sp_quitar_item_carrito` / `sp_alternar_favorito` (las cuentas de la app no tienen DELETE).
- **Emisión al pagar el total** (`emitir_comprobante_al = pago_total`): ver decisión abierta sobre anticipos.
- **Comunicación de baja**: no implementada; por regla del equipo un comprobante aceptado solo se corrige con nota de crédito.

## 7. Rendimiento, paginación y crecimiento

- Índices en todas las FK y compuestos para las consultas críticas: pedidos por cliente (`id_usuario, creado_en`), por estado (`estado, creado_en`), expiración (`estado, expira_en`), pagos por pedido/estado, colas (`estado, proximo_intento_en`), kardex (`id_variante, creado_en`), auditoría (`entidad, id_entidad, creado_en`), límites por IP (`ip, creado_en`). Verificado con `EXPLAIN`: `v_pedidos_estado WHERE id_usuario = ?` usa `idx_pedido_usuario`; la expiración usa `idx_pedido_expira`; el límite de contacto usa `idx_mensaje_ip`.
- Reportes sin subconsultas correlacionadas (agregados en tablas derivadas unidas por JOIN).
- **Paginación**: por llave (`WHERE id_pedido < :ultimo ORDER BY id_pedido DESC LIMIT 20`) en listados grandes; `LIMIT/OFFSET` solo en pantallas pequeñas.
- **Plan de particionado/archivado** (cuando superen ~1–5 millones de filas):
  - `auditoria` y `log_api_externa` (ya sin FK): cambiar la PK a `(id, creado_en)` y particionar por rango anual:
    ```sql
    ALTER TABLE auditoria DROP PRIMARY KEY, ADD PRIMARY KEY (id_auditoria, creado_en);
    ALTER TABLE auditoria PARTITION BY RANGE (YEAR(creado_en)) (
      PARTITION p2026 VALUES LESS THAN (2027), PARTITION p2027 VALUES LESS THAN (2028), PARTITION pmax VALUES LESS THAN MAXVALUE);
    -- Retención: el DBA exporta y elimina particiones de más de 12 meses (ALTER TABLE ... DROP PARTITION p2026).
    ```
  - `movimiento_stock` (tiene FK): archivar por año en `movimiento_stock_AAAA` (misma estructura, sin FK) con un procedimiento del DBA, dejando un movimiento de “saldo inicial” por variante.
  - `log_api_externa`, `intento_acceso`, `cola_correo`, `sesion`, `evento_pasarela`: ya se purgan por retención en `ev_mantenimiento_diario` (nunca antes de 12 meses en las bitácoras de seguridad).

## 8. Envío de correos (códigos y avisos)

La BD solo tiene la cola (`cola_correo`) con reintentos y backoff; el envío lo hace la aplicación (`sp_tomar_correos_pendientes` → enviar → `sp_marcar_correo`). El **código de verificación nunca entra en la cola** (un trigger rechaza `contexto.codigo`): Django lo recibe de `sp_generar_codigo_verificacion` y lo envía al momento.

- **Opción A — cuenta de correo propia por SMTP** (p. ej. `notificaciones@<dominio de la empresa>` en el proveedor de correo de la empresa). Gratis o incluida, remitente fijo, configuración en `EMAIL_HOST` de Django. Límites de envío diarios y más riesgo de caer en spam si no se configuran SPF/DKIM/DMARC.
- **Opción B — servicio transaccional** (API o SMTP de un proveedor especializado). Mejor entrega, métricas y rebotes; requiere cuenta, verificación del dominio y, según el volumen, costo.
- **Recomendación para el proyecto local**: empezar con **A** (o con el backend de consola/archivo de Django mientras se desarrolla) porque no agrega dependencias ni costos; pasar a **B** al publicar si la entrega de códigos falla o crece el volumen. El esquema no cambia en ningún caso.

## 9. Verificación realizada

- Instalación completa 00→08 en **MySQL 8.4.11** (Docker), dos veces seguidas (re-ejecutable) y desde cero.
- **Importación por phpMyAdmin 5.2** (su propio analizador de SQL, archivo por archivo): sin errores y con los mismos objetos que por consola.
- `99_pruebas.sql`: **299 casos ✔, 0 ✘** (flujo feliz, adelanto, mayorista, cancelaciones, pago huérfano, devoluciones, NC, rechazos esperados, matriz de permisos y las regresiones de la revisión de la sección 10). Se revisó que cada error esperado salga por el motivo correcto, no solo con el código.
- Permisos probados con **cuentas reales** de cada rol (tienda, admin y la cuenta `wanka_dba`): lo permitido funciona y lo prohibido falla con 1142/1143/1370 o el error de negocio.
- **Concurrencia real** (`scripts/prueba_concurrencia.sh`): 6 compras simultáneas de la última unidad → 1 pedido y 5 rechazos 45001 (sin sobreventa); 5 clics simultáneos en pagar → 1 pago; 2 administradores validando el mismo voucher → 1 confirmación y 1 error 45004; 7 solicitudes simultáneas de código → 5 códigos y 2 rechazos 45010; 2 clientes agregando y quitando la misma variante 150 veces → 0 deadlocks; 2 pagos confirmados a la vez mientras otra sesión retiene el pedido → pedido pagado completo.
- Eventos ejecutándose en el servidor (`LAST_EXECUTED` actualizado) y sin errores en el log.
- **No probado en MariaDB** (el objetivo acordado es MySQL 8): las diferencias están marcadas con `COMPAT-MARIADB` y resumidas en `LEEME_INSTALACION.md`.

## 10. Revisión de errores posterior a la primera entrega

Después de la primera entrega se hizo una revisión en dos pasadas. Cada hallazgo se reprodujo con SQL antes de corregirlo y quedó con su prueba en `99_pruebas.sql` (secciones 7c y 7d) o en `scripts/prueba_concurrencia.sh`.

### 10.1 Primera pasada (revisión propia, pruebas Q01–Q31)

| Área | Problema | Corrección |
|---|---|---|
| Devoluciones | Tras una devolución el pedido quedaba con "saldo pendiente" y el reembolso salía de un solo pago. | `pedido.monto_devuelto`; el saldo descuenta lo devuelto (negativo = a favor del cliente); `spi_repartir_reembolso` reparte entre los pagos aplicados. Una sola NC por devolución (06 solo si anula todo el comprobante; si no, 07). |
| Webhooks | Un webhook aprobado sin monto, de otro proveedor o sobre un Yape por validar podía confirmar pagos; un evento falso con el id del verdadero lo bloqueaba. | Monto obligatorio, proveedor = método, `metodo_distinto`; la copia con firma válida reemplaza a la inválida aún no procesada. Los pagos de pasarela no se rechazan a mano. |
| Usuarios (IDOR) | Un cliente podía editar la fila de otro, activarse, marcar su correo como verificado o tocar su bloqueo; ARCO, contacto y reclamos aceptaban otro `id_usuario`. | Triggers que comparan el actor con el dueño y exigen procedimiento para estado, verificación y bloqueo; validación de dueño en esos procedimientos. |
| Pedidos y cotizaciones | Variante repetida con error 1062; personalización en productos que no la admiten; cotización mayorista sin fecha; pago en un pedido vencido; pedidos con cobro de pasarela en curso expiraban. | Mensajes 45006/45009/45007; plazo de gracia `minutos_gracia_pago_pasarela`. |
| Acceso | Sin límite por IP (prueba de contraseñas contra muchas cuentas). | `login_max_fallos_ip_15min` → resultado `ip_bloqueada`. |
| Catálogo | Ciclos en la jerarquía de categorías; productos en categorías inhabilitadas. | `spi_validar_categoria_padre`; error 45032. |
| Operación | Faltaban reintento de emisión, anonimización ARCO y lista de NC pendientes. | `sp_reintentar_emision`, `sp_anonimizar_usuario`, `v_notas_credito_pendientes`; aviso al cancelar un pedido con comprobante. |

### 10.2 Segunda pasada (tres revisores independientes con SQL, pruebas T01–T82)

**Seguridad y permisos**

| Hallazgo | Corrección |
|---|---|
| La marca de "contexto interno" era `@wanka_ctx_interno = 1`, que cualquier sesión podía fijar; además el admin podía ejecutar los `spi_*` internos (p. ej. confirmar un pedido sin pago o escribir auditoría falsa). | Token `fn_token_interno()` = SHA-256(secreto de la instalación, id de conexión); tabla `secreto_interno` sin acceso para la app; `fn_token_interno` es INVOKER. El admin recibe EXECUTE explícito solo sobre `sp_*`/`fn_*` públicos y SELECT por tabla. |
| Columnas del ciclo de vida del pedido (plazo de reserva, fechas, entrega, facturación, zona) y el estado del envío se cambiaban por UPDATE directo. | Triggers que exigen el token; el admin solo edita por columnas (`fecha_entrega_estimada`, datos del courier). Nuevo `sp_corregir_facturacion_pedido`. |
| El Libro de Reclamaciones y los mensajes de contacto se podían editar desde el panel. | Sin UPDATE directo; `sp_marcar_en_atencion` y los `sp_responder_*`. |
| La contraseña y el documento del usuario se podían cambiar por UPDATE directo (sin historial ni cierre de sesiones). | Exigen el procedimiento; la tienda solo actualiza nombres, apellidos y celular. |
| El DNI completo (`usuario.numero_documento`) y la caché de RENIEC se podían listar con SELECT. | SELECT por columnas sin el documento (tienda y admin); `sp_ver_documento_completo` (auditado) y `sp_obtener_consulta_documento` (un documento exacto). |
| El 2FA no contaba fallos ni respetaba el bloqueo; con la contraseña correcta se reiniciaba el contador; un paso TOTP NULL saltaba el anti-replay; los códigos de respaldo servían sin 2FA activo y su uso no se auditaba. | `spi_registrar_fallo_acceso` común a contraseña, TOTP y códigos de respaldo; bloqueo respetado también en `sp_abrir_sesion`; paso TOTP obligatorio; auditoría del uso de respaldo. |
| Un administrador podía pasar su 2FA a "correo" o dejarlo inactivo al reconfigurarlo. | Solo TOTP para administradores; reconfiguración pendiente hasta confirmar; invalida los códigos de respaldo; cerrar sesiones al cambiar rol o desactivar el 2FA. |
| El código de verificación se ligaba al `id_usuario` y podía enviarse a cualquier correo (robo de cuenta por recuperación). | El código va al correo de la cuenta (salvo `cambiar_correo`); el flujo anónimo deduce el dueño del correo; la recuperación exige que el código haya ido a ese correo. |
| La cuota de códigos era compartida entre propósitos (un tercero bloqueaba el 2FA del titular) y el tope era configurable hasta 20. | Cupos por correo **y propósito** (5/hora, 15/día) y por IP (20/hora); tope máximo 5. |
| `@app_ip` inválida rompía el login (error 1411) y `NULL` desactivaba los límites por IP. | IP validada (`IS_IPV4/IS_IPV6`, primera de `X-Forwarded-For`); sin IP, cupo compartido. |
| La bitácora de APIs aceptaba tokens y contraseñas (y luego no se podían borrar en 12 meses). | `fn_contiene_secretos` en JSON y URL; `sp_redactar_log_api` solo para el DBA autorizado. |
| `fn_contiene_datos_tarjeta` se evadía con `card_cvv`, `cvv_code`, `cvn`, un PAN con puntos o escondido tras 50 números. | Claves por subcadena, `.` como separador y rechazo al pasar 500 candidatos. |
| `TRUNCATE` del DBA vaciaba la auditoría sin disparar triggers. | El rol DBA ya no tiene `DROP`. |
| Login con contraseña "NULL" contaba como acierto. | `COALESCE(..., 0)`. |
| El DNI era único global: se podía averiguar si otro era cliente u "ocupar" su documento. | Índice no único. |
| **Encontrado al verificar con la cuenta DBA real**: `fn_borrado_dba_autorizado()` devolvía NULL sin la variable de autorización y `NOT NULL` dejaba pasar la redacción. | `COALESCE(..., FALSE)`. |

**Pedidos, stock y cotizaciones**

| Hallazgo | Corrección |
|---|---|
| Con un cobro de pasarela en vuelo se podía editar el pedido; el cobro quedaba entero como huérfano y el pedido nunca expiraba (contaba pagos no aplicados). | Edición bloqueada con pagos `pendiente`; la expiración solo cuenta pagos aplicados y anula los cobros abandonados. |
| Deadlock seguro (1213) al agregar/quitar a la vez la misma variante. | Variante bloqueada antes de insertar; además, los `IF EXISTS (SELECT ...)` de los procedimientos tomaban bloqueos con huecos en `item_pedido` (comprobado con `performance_schema.data_locks`) y se cambiaron por `SELECT ... INTO`. Probado: 300 ciclos en paralelo, 0 deadlocks. |
| Una cotización con la misma variante en dos líneas (distinta personalización) no se podía convertir y dejaba reservas colgadas. | Sin índice único por variante; las reservas se cierran por (variante, reserva). |
| El cliente cancelaba con `sp_cambiar_estado_pedido` saltándose las validaciones de `sp_cancelar_pedido`. | Ese procedimiento es solo del administrador y nunca cancela. |
| El envío no cotizado salía gratis aunque la zona cobrara. | `cotizacion.costo_envio` NULL = tarifa de la zona al aceptar. |
| `tipo_venta` se calculaba distinto al crear y al recalcular. | Mismo criterio: precio por volumen efectivamente aplicado. |
| Si el courier informaba "entregado" y el pedido no podía cerrarse, se perdía el evento; un `p_origen` NULL saltaba el permiso. | Punto de guardado: el evento queda y se avisa al administrador; `COALESCE(p_origen, '')`. |
| Insumos descontables en cualquier estado; pedidos a pedido podían saltar la producción. | Solo confirmado/en producción; los pedidos con productos a pedido pasan por `en_produccion`. |
| El pedido complementario heredaba siempre la fecha del original. | Parámetro `p_fecha_entrega`. |
| `sp_registrar_envio` creaba otro envío ante un doble clic; errores genéricos 1062/1265. | Idempotente (devuelve el envío existente) y errores 45028. |
| Cantidades 1,5 se redondeaban; JSON mal formado daba errores genéricos. | Cantidades enteras validadas con `JSON_TYPE`; mensajes propios. |

**Pagos, notas de crédito y comprobantes**

| Hallazgo | Corrección |
|---|---|
| En REPEATABLE READ (eventos, phpMyAdmin) los montos y topes se calculaban con una instantánea vieja: dos pagos confirmados a la vez dejaban el pedido "parcial"; reembolsos y NC podían superar lo cobrado. | Agregados con `FOR SHARE` y búsquedas previas fuera de la transacción (la instantánea nace después del bloqueo del pedido). Probado con 3 sesiones: el pedido queda pagado completo. |
| Un Yape válido que llegaba con el pedido ya pagado solo se podía rechazar; los cobros de pasarela pendientes no contaban al registrar otro pago. | Se confirma como huérfano por reembolsar; los cobros en proceso cuentan dentro del plazo de gracia; `sp_anular_pago_pendiente`. |
| NC y reembolsos no idempotentes; una NC rechazada dejaba vivo su reembolso. | Rechazo de la misma NC repetida en 2 minutos; al rechazarse la NC se anulan sus reembolsos solicitados y se revierte la rebaja. |
| Se aceptaban NC de devolución sin devolución o de anulación con el pedido vigente; después la devolución era imposible. | Reglas por motivo; la NC de la devolución se acota a lo que queda del comprobante. |
| Se reembolsaba un pago aplicado de un pedido vigente (quedaba "saldo pendiente" y el IGV sin corregir); una compensación bloqueaba la entrega. | En pedidos vigentes solo excedente o `ajuste_precio`; `pedido.monto_ajustes` registra rebajas (NC 04/05/08/09/10 o compensación sin comprobante). |
| **Encontrado al corregir**: una devolución reembolsaba el valor devuelto aunque el cliente solo hubiera pagado un adelanto. | Se reembolsa solo lo pagado de más tras la devolución (`-saldo` menos reembolsos en curso). |
| Un estado externo NULL consumía el webhook; sin forma de registrar un contracargo. | Validación de NULL; estado `revertido` → evento con error y aviso. |
| **Encontrado al preparar la entrega**: si la pasarela informaba una operación ya registrada en otro pago, el webhook fallaba con 1062 y se reintentaba sin fin. | Resultado `referencia_duplicada`: evento con error y aviso para revisarlo. |
| Un trabajo de emisión podía quedar "procesando" para siempre. | Si el worker murió en el último intento, se descarta y se avisa. |
| Saltos de correlativo con UPDATE directo a la serie; dirección del cliente guardada como cadena vacía; varios errores genéricos (1048, 1265, 1452, 3819). | Token exigido para el correlativo; `NULLIF`; validaciones con errores 450xx. |
