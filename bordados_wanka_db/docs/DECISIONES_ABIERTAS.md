# Decisiones abiertas y valores por verificar

Todo lo que figura aquí tiene un valor provisional en la base para que el sistema funcione hoy, y se puede cambiar **sin tocar código** (configuración o catálogo). La consulta `SELECT * FROM v_configuracion_por_verificar;` lista las claves marcadas.

## 1. Decisiones abiertas heredadas del Excel

| # | Decisión | Valor provisional en la BD | Dónde se cambia | Con quién confirmar |
|---|---|---|---|---|
| 1 | **Moneda de PayPal** (PayPal no opera en soles) | El pedido y el pago siempre en PEN; `pago.moneda_cobro`, `monto_cobro` y `tipo_cambio` guardan lo que cobró la pasarela (p. ej. USD) | `configuracion.moneda`; columnas de `pago` | Gerente / contador |
| 2 | **Proveedor OSE/PSE** | Neutro: `comprobante.proveedor_ose`, `payload_envio`, `payload_respuesta`, cola con reintentos | Integración en Django | Gerente |
| 3 | **Umbral de boleta con DNI** | S/ 700 | `configuracion.umbral_boleta_dni` | SUNAT / OSE |
| 4 | **Domicilio fiscal vs. dirección del local** | El comprobante usa `empresa_domicilio_fiscal` (tomado del script original); el local se usa para recojo y contacto | `configuracion.empresa_domicilio_fiscal` / `empresa_direccion_local` | Ficha RUC |
| 5 | **Plazo del Libro de Reclamaciones** | 30 días calendario (lo que indica el prompt) | `reclamo_plazo_dias`, `reclamo_plazo_tipo` (`calendario`/`habiles`) | INDECOPI. Ojo: según nuestra información, una modificación del reglamento (D.S. 101-2022-PCM) habría fijado **15 días hábiles**; confirmarlo antes de publicar |
| 6 | **Adelanto 50 %** | 50 % por defecto; editable por pedido por el administrador y por cotización | `configuracion.adelanto_porcentaje` | Gerente |
| 7 | **Courier y su API** | Solo “Reparto propio”; tablas `envio`/`seguimiento_envio` listas para eventos de una API (idempotentes) | Catálogo `courier` | Gerente |
| 8 | **Registro del banco de datos personales** ante la Autoridad Nacional de Protección de Datos Personales | La BD registra consentimientos (versión, fecha, IP) y solicitudes ARCO | `politica_privacidad_version`; procedimientos ARCO | Asesor legal |

## 2. Discrepancias entre el Excel y las decisiones del equipo (gana el prompt)

| Tema | Excel | Aplicado | Acción pendiente |
|---|---|---|---|
| Vigencia del código de verificación (HU-02) | 10 minutos | **5 minutos** (el máximo permitido en la configuración es 5) | Corregir el Excel |
| Pago con adelanto | Solo pedidos al por mayor | **Todos** los pedidos eligen total o mitad | Corregir el Excel o, si el gerente decide volver al criterio anterior, poner `adelanto_permitido_en = 'solo_mayor'` |

## 3. Decisiones nuevas que surgieron al diseñar (por confirmar)

| # | Tema | Propuesta aplicada | Configuración |
|---|---|---|---|
| 9 | **Saldo pendiente antes del envío** | No pasa a `enviado` ni a `entregado` con saldo pendiente; sí puede llegar a `listo` | `bloquear_envio_con_saldo = 1` |
| 10 | **Comprobante de los adelantos** | Se emite un solo comprobante cuando el pedido está pagado por completo. **Riesgo**: la norma de comprobantes de pago suele exigir emitirlo cuando se recibe el pago si ocurre antes de la entrega, lo que alcanzaría a los anticipos. Confirmar con el contador y el OSE; si corresponde, se agrega la emisión por anticipo (el modelo ya guarda cada pago por separado) | `emitir_comprobante_al = 'pago_total'` |
| 11 | **Series de comprobantes** | B001, F001, BC01, FC01 de **ejemplo** (`por_verificar = 1`) | Tabla `serie_comprobante` (reemplazar por las del OSE) |
| 12 | **Plazos ARCO** | Acceso 20 días hábiles; rectificación/cancelación/oposición 10 días hábiles (sin feriados) | `arco_plazo_*` (verificar con el reglamento de la Ley 29733) |
| 13 | **Envío del pedido complementario** | Gratis si el original aún no salió (viajan juntos) | `complementario_envio_gratis` |
| 14 | **Vigencia por defecto de una cotización** | 15 días | `cotizacion_vigencia_dias` |
| 15 | **Descontar insumos al pasar a producción** | Apagado hasta cargar las recetas | `descontar_insumos_en_produccion` |
| 16 | **Límite de reclamos por IP** | 5 por hora (0 = sin límite); confirmar que no afecta el derecho del consumidor | `reclamo_max_por_hora_ip` |
| 17 | **¿Se reembolsa el costo de envío en una devolución?** | No: se reembolsa el valor de los productos devueltos | Lógica de `sp_devolver_pedido` |
| 18 | **Comunicación de baja ante SUNAT** | No implementada: un comprobante aceptado solo se corrige con nota de crédito | — |
| 19 | **Búsqueda tolerante a errores de tipeo** | `FULLTEXT` sin tildes; difusa en Django si se requiere | Ver comparativa §6.3 |
| 20 | **Cuenta para enviar correos** | Opción A (SMTP propio) para el proyecto local; B (servicio transaccional) al publicar | Ver comparativa §8 |
| 21 | **Política de privacidad** | Versión `1.0` provisional | `politica_privacidad_version` |
| 22 | **Nombre comercial** | “Bordados Wanka” | `empresa_nombre_comercial` |

## 3b. Decisiones que surgieron en la revisión de errores (por confirmar)

| # | Tema | Propuesta aplicada | Configuración / lugar |
|---|---|---|---|
| 23 | **DNI repetido entre cuentas** | Ya no es único: dos cuentas pueden registrar el mismo documento (una familia, o alguien que escribe el DNI de otro). Así no se revela si un DNI ya es cliente ni se puede "ocupar" el de otra persona. Si se requiere unicidad, hay que validar la titularidad (RENIEC) antes | Índice `idx_usuario_documento` |
| 24 | **Datos personales que ve el administrador** | El admin ya no lee el DNI completo de `usuario` por SELECT (usa `sp_ver_documento_completo`, auditado), pero sí ve completos los datos de reclamos, solicitudes ARCO y comprobantes porque los necesita para atenderlos. Si se exige constancia de cada lectura, el panel debe registrarla o usar vistas enmascaradas | `07_roles_permisos.sql` |
| 25 | **Número de pedido y tipo de venta** | El prefijo del número (`BW-MAY-`) refleja el tipo al crear; si al editar el pedido cambia el tipo de venta, el número no cambia (es un correlativo sin saltos). El tipo vigente está en `pedido.tipo_venta` | `spi_recalcular_tipo_venta` |
| 26 | **Comprobante correcto tras una NC 02 (error en el RUC)** | La NC 02 se emite sin reembolso, pero el comprobante original sigue figurando como vigente para el pedido y no se emite otro automáticamente. Definir con el contador/OSE si se emite uno nuevo y cómo se relaciona | `sp_emitir_comprobante` (`pedido_activo_clave`) |
| 27 | **Contracargos y reembolsos iniciados en la pasarela** | Se reciben como `revertido`: el evento queda con error y se avisa al administrador para registrar el reembolso, la NC y revisar el pedido. No se automatiza hasta conocer el flujo real de la pasarela | `sp_procesar_pago_pasarela` |
| 28 | **Cupos de códigos por correo** | 5 por hora y 15 por día por correo **y propósito**; 20 por hora por IP | `codigo_verificacion_max_por_hora`, `_max_por_dia`, `_max_por_ip_hora` |
| 29 | **Plazo de gracia de un cobro de pasarela** | 30 minutos: mientras tanto el pedido no expira, no se edita ni acepta otro pago por el mismo saldo; después el cobro se puede anular | `minutos_gracia_pago_pasarela` |
| 30 | **Rebajas posteriores a la venta** | Las NC que no son anulación ni devolución (03, 04, 05, 08, 09, 10) y las compensaciones reembolsadas sin comprobante bajan lo que el cliente debe (`pedido.monto_ajustes`). Confirmar con el contador el uso de la NC 03 y 10 con monto | `spi_recalcular_ajustes_pedido` |
| 31 | **Qué edita el panel directamente** | Solo columnas informativas (fecha estimada, datos del courier, nombre y celular). Si el panel necesita corregir otros datos de un pedido (p. ej. la dirección antes del despacho), se agrega un procedimiento con sus validaciones | `07_roles_permisos.sql`, `trg_pedido_bu` |
| 32 | **Proxy y `X-Forwarded-For`** | La BD toma la primera IP de la lista; quien despliega debe asegurarse de que esa cabecera la fije su propio proxy (si no, un cliente puede inventar su IP y esquivar los límites por IP) | Middleware de Django (LEEME §8.2) |

## 4. Fuera de alcance por ahora

- **Cupones (HU-40)**: `pedido.descuento` existe (siempre 0) y `sp_emitir_comprobante` rechaza descuentos hasta que se implemente el descuento global en el comprobante.
