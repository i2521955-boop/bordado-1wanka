# Trazabilidad HU / RF / RNF → objetos de la base de datos

> **Aviso importante:** el Excel `BORDADOS_WANKA_Requerimientos_y_Backlog.xlsx` (58 RF, 52 RNF, 40 HU) **no se recibió**. Por eso:
> - La **Parte A** traza cada funcionalidad que pide el prompt (y lo que un comercio electrónico serio necesita) a tablas, procedimientos, triggers, vistas y eventos. Está completa.
> - La **Parte B** lista HU-01…HU-40, RF-01…RF-58 y RNF-01…RNF-52. Solo se llenaron los códigos que el prompt o el script original citan expresamente (HU-02, HU-12, HU-13, HU-17, HU-18, HU-28, HU-29, HU-40, RNF 13, RNF 18, RNF 20). El resto queda **“pendiente: verificar contra el Excel”**: basta ubicar cada requisito en la fila correspondiente de la Parte A.
> - Cuando tengan el Excel, compártanlo y se completa la Parte B en minutos.

Leyenda de estado: **Cubierto** · **Parcial** (la BD lo soporta, falta una decisión) · **No aplica a la BD** (lo resuelve la app o la infraestructura) · **Fuera de alcance** · **Pendiente** (falta el Excel).

## Parte A — Matriz por funcionalidad

| # | Funcionalidad (fuente) | Tablas | Procedimientos / funciones | Triggers | Vistas / eventos | Estado |
|---|---|---|---|---|---|---|
| A01 | Registro de cliente y verificación de correo con código (HU-02, §2.7) | `usuario`, `codigo_verificacion`, `consentimiento_datos`, `historial_contrasena` | `sp_registrar_usuario`, `sp_generar_codigo_verificacion`, `sp_verificar_codigo`, `fn_generar_digitos`, `fn_hash_codigo` | `trg_usuario_bi/bu/au`, `trg_codigo_verificacion_bi/bu/bd` | `ev_expirar_codigos` | Cubierto (5 min; el Excel dice 10) |
| A02 | Inicio de sesión, bloqueo tras 5 intentos (15 min), sesiones (§6) | `intento_acceso`, `sesion`, `usuario` | `sp_registrar_intento_acceso` (límite por IP, contraseña NULL = fallo), `spi_registrar_fallo_acceso` (común a contraseña y 2FA), `sp_abrir_sesion` (respeta el bloqueo), `sp_cerrar_sesion`, `sp_cerrar_sesiones_usuario`, `sp_desbloquear_usuario` | `trg_intento_acceso_bu/bd`, `trg_sesion_bu` | `ev_mantenimiento_diario` | Cubierto |
| A03 | Recuperar / cambiar contraseña; no reutilizar las 3 últimas (§4) | `codigo_verificacion`, `historial_contrasena` | `sp_cambiar_contrasena`, `sp_cambiar_correo` | `trg_usuario_au` (historial) | `v_historial_contrasena_reciente` | Cubierto (la comparación de contraseñas la hace Django con `check_password`) |
| A04 | Segundo factor TOTP obligatorio para administradores (§4) | `autenticacion_2fa`, `codigo_respaldo_2fa`, `rol.requiere_2fa` | `sp_configurar_2fa`, `sp_confirmar_2fa`, `sp_registrar_segundo_factor`, `sp_desactivar_2fa`, `sp_generar_codigos_respaldo_2fa`, `sp_usar_codigo_respaldo_2fa` | `trg_autenticacion_2fa_bu`, `trg_codigo_respaldo_2fa_bu` | `v_administradores_sin_2fa` (solo TOTP cuenta) | Cubierto (fallos cuentan para el bloqueo; reconfiguración pendiente hasta confirmar; la app obliga a configurarlo) |
| A05 | Roles administrador y cliente (§1) | `rol`, `usuario` | `sp_crear_administrador_inicial`, `sp_cambiar_rol_usuario`, `fn_es_admin` | `trg_rol_bu/bd` | — | Cubierto |
| A06 | Gestión de usuarios por el administrador; eliminar = inhabilitar (§2.6) | `usuario` | `sp_inhabilitar_usuario`, `sp_reactivar_usuario` | `trg_usuario_bd` (bloquea DELETE) | `v_usuarios` | Cubierto |
| A07 | Protección de datos personales: consentimiento, ARCO, enmascarado, minimización (Ley 29733, §4, §6) | `consentimiento_datos`, `solicitud_arco`, `consulta_documento` | `sp_registrar_consentimiento`, `sp_registrar_solicitud_arco`, `sp_atender_solicitud_arco`, `sp_anonimizar_usuario`, `sp_ver_documento_completo`, `sp_obtener_consulta_documento`, `fn_enmascarar_*`; SELECT por columnas sin `numero_documento` | `trg_consentimiento_datos_*`, `trg_solicitud_arco_*` | `v_solicitudes_arco_pendientes`, `v_clientes_resumen` (enmascarado), `ev_alertar_vencimientos` | Cubierto (plazos por verificar) |
| A08 | Catálogo: CRUD de categorías, productos, variantes, imágenes, banners (§4) | `categoria`, `producto`, `variante_producto`, `imagen_producto`, `banner` | `sp_inhabilitar_*`, `sp_reactivar_*`, `sp_definir_imagen_principal` | `trg_categoria_*`, `trg_producto_*`, `trg_variante_producto_*`, `trg_imagen_producto_*`, `trg_banner_*` | `v_catalogo_productos`, `v_variantes_disponibles`, `v_banners_vigentes` | Cubierto |
| A09 | Búsqueda de productos sin tildes (§4) | `producto` (`FULLTEXT ft_producto_busqueda`) | — | — | — | Parcial (sin tolerancia a errores de tipeo: ver comparativa §6.3) |
| A10 | Precios por volumen (venta al por mayor) (§5.2) | `precio_volumen` | `fn_precio_volumen`, `fn_precio_unitario`, `sp_inhabilitar_precio_volumen` | `trg_precio_volumen_*` | `v_precios_volumen` | Cubierto |
| A11 | Favoritos / lista de deseos (§4) | `favorito` | `sp_alternar_favorito` | — | — | Cubierto |
| A12 | Carrito sin precios (§4) | `carrito`, `item_carrito` | `sp_agregar_item_carrito`, `sp_quitar_item_carrito` | `trg_carrito_bu`, `trg_item_carrito_bi/bu` | `ev_mantenimiento_diario` (abandono) | Cubierto |
| A13 | Direcciones y zonas de envío; costo desde la zona (§5.1) | `direccion`, `zona_envio` | `sp_definir_direccion_predeterminada`, `sp_inhabilitar_direccion`, `sp_inhabilitar_zona_envio` | `trg_direccion_*`, `trg_zona_envio_*`, `trg_pedido_bi` | — | Cubierto |
| A14 | Crear pedido; ítems con copia y precio desde la BD; reserva de stock (§5.1–5.3) | `pedido`, `item_pedido`, `reserva_stock` | `sp_crear_pedido`, `sp_agregar_item`, `sp_quitar_item`, `spi_insertar_pedido`, `spi_agregar_item_interno` | `trg_pedido_bi/bu/ai/au`, `trg_item_pedido_bi/bu/bd`, `trg_reserva_stock_*` | `v_pedido_detalle`, `v_reservas_activas` | Cubierto |
| A15 | Modalidad de pago total o adelanto 50 % (§2.2) | `pedido` (`modalidad_pago`, `adelanto_porcentaje`, `monto_requerido`), `configuracion` | `sp_definir_modalidad_pago`, `spi_recalcular_pagos_pedido`, `spi_validar_pedido_completo` | `trg_pago_au` | — | Cubierto (regla de saldo por confirmar) |
| A16 | Venta al por mayor con anticipación mínima (§5.1) | `pedido.tipo_venta`, `configuracion.dias_minimos_mayor` | `spi_insertar_pedido`, `spi_recalcular_tipo_venta` | `trg_pedido_bi` | — | Cubierto |
| A17 | Pagos Mercado Pago y PayPal por webhook verificado e idempotente (§1, §5.5) | `pago`, `metodo_pago`, `evento_pasarela`, `transicion_estado_pago` | `sp_registrar_pago`, `sp_anular_pago_pendiente`, `sp_registrar_evento_pasarela`, `sp_procesar_pago_pasarela` (incluye `revertido`) | `trg_pago_bi/bu/ai/au`, `trg_evento_pasarela_*` | `v_eventos_pasarela_con_error` | Cubierto (moneda de PayPal y contracargos: decisiones abiertas) |
| A18 | Yape / Plin / transferencia / efectivo validados por el administrador (§1, §5.5) | `pago` | `sp_registrar_pago`, `sp_confirmar_pago_manual`, `sp_rechazar_pago` | `trg_pago_bu` | `v_pagos_por_validar` | Cubierto |
| A19 | Pago huérfano / por reembolsar (§2.3) | `pago` (`aplicado_al_pedido`, `motivo_no_aplicado`) | `sp_procesar_pago_pasarela`, `sp_confirmar_pago_manual` | `trg_pago_au` | `v_pagos_por_reembolsar` | Cubierto |
| A20 | Reembolsos (§4, §7.6) | `reembolso`, `pedido.monto_ajustes` | `sp_reembolsar_pago` (en pedidos vigentes solo excedente o `ajuste_precio`), `sp_completar_reembolso`, `spi_crear_reembolso`, `spi_repartir_reembolso`, `spi_recalcular_ajustes_pedido` | `trg_reembolso_bi/bu/au` | `v_reembolsos`, `v_pagos_por_reembolsar`, `v_ingresos_diarios` | Cubierto |
| A21 | Estados del pedido siempre consultables + historial inmutable + avisos (§2.5, §5.7) | `estado_pedido`, `transicion_estado_pedido`, `historial_estado_pedido`, `cola_correo`, `notificacion` | `sp_cambiar_estado_pedido`, `spi_cambiar_estado_pedido` | `trg_pedido_au`, `trg_historial_estado_pedido_*` | `v_pedidos_estado`, `v_resumen_estados_pedido`, `v_historial_pedido`, `v_transiciones_pedido` | Cubierto |
| A22 | Cancelación y expiración de pedidos sin pago (§5.3–5.4) | `pedido`, `reserva_stock`, `movimiento_stock` | `sp_cancelar_pedido`, `sp_expirar_pedidos_pendientes`, `spi_reponer_stock_pedido` | — | `ev_expirar_pedidos` | Cubierto |
| A23 | Devoluciones que reponen stock, sin devolver dos veces (§2.9) | `devolucion`, `devolucion_item`, `item_pedido.cantidad_devuelta` | `sp_devolver_pedido` | `trg_devolucion_*`, `trg_item_pedido_bu` | — | Cubierto |
| A24 | Inventario: kardex, stock mínimo y alertas (§4) | `variante_producto`, `movimiento_stock` | `sp_ajustar_stock`, `spi_mover_stock` | `trg_variante_producto_au` (alerta), `trg_movimiento_stock_*` | `v_kardex`, `v_stock_bajo`, `v_inconsistencias` | Cubierto |
| A25 | Insumos y su kardex; receta opcional (HU-13) | `insumo`, `movimiento_insumo`, `receta_producto` | `sp_ajustar_insumo`, `sp_consumir_insumos_pedido`, `spi_mover_insumo` | `trg_insumo_*`, `trg_movimiento_insumo_*` | `v_insumos_stock_bajo`, `v_kardex_insumos` | Cubierto |
| A26 | Cotizaciones al por mayor y bordado personalizado; conversión a pedido; vencimiento (HU-28, HU-17, HU-18, §5.9) | `cotizacion`, `item_cotizacion`, `transicion_estado_cotizacion` | `sp_solicitar_cotizacion`, `sp_cotizar`, `sp_cambiar_estado_cotizacion`, `sp_aceptar_cotizacion`, `sp_vencer_cotizaciones` | `trg_cotizacion_*`, `trg_item_cotizacion_*` | `v_cotizaciones`, `ev_vencer_cotizaciones` | Cubierto |
| A27 | Pedido complementario (HU-29) | `pedido.id_pedido_origen` | `sp_crear_pedido_complementario` (con fecha de entrega propia opcional) | `trg_pedido_bu` | — | Cubierto (envío gratis por confirmar) |
| A28 | Envío y seguimiento; preparado para la API del courier (HU-12) | `courier`, `envio`, `seguimiento_envio` | `sp_registrar_envio`, `sp_registrar_seguimiento_envio` | `trg_envio_*`, `trg_seguimiento_envio_*` | `v_envios_seguimiento` | Cubierto (courier y su API: decisión abierta) |
| A29 | Comprobantes electrónicos con copia completa; cola de emisión al OSE/PSE (§2.8) | `serie_comprobante`, `comprobante`, `comprobante_item`, `comprobante_archivo`, `cola_emision_comprobante` | `sp_emitir_comprobante`, `sp_tomar_comprobante_para_emitir`, `sp_registrar_respuesta_ose`, `sp_guardar_archivo_comprobante`, `sp_marcar_comprobante_enviado_correo`, `fn_igv_incluido` | `trg_comprobante_*`, `trg_comprobante_item_*`, `trg_serie_comprobante_bu` | `v_comprobantes`, `v_comprobante_copia_completa`, `v_comprobante_items`, `v_cola_emision` | Cubierto (proveedor OSE, series y umbral: por verificar) |
| A30 | Factura con RUC y razón social; boleta > S/ 700 con documento (§2.8) | `pedido.facturacion_*`, `comprobante.cliente_*` | `fn_ruc_valido`, `spi_validar_pedido_completo`, `sp_emitir_comprobante` | `trg_comprobante_bi` | — | Cubierto (umbral por verificar con SUNAT/OSE) |
| A31 | Notas de crédito validadas (§2.8) | `motivo_nota_credito`, `comprobante` | `sp_emitir_nota_credito` (reglas por motivo, sin doble emisión), `spi_emitir_nota_credito`, `sp_registrar_respuesta_ose` (NC rechazada anula sus reembolsos) | `trg_comprobante_bi/bu` | `v_notas_credito_saldo`, `v_notas_credito_pendientes` | Cubierto |
| A32 | Reseñas de quien compró y recibió; moderación; valoración (§5.8) | `resena`, `producto.valoracion_promedio` | `sp_registrar_resena`, `sp_moderar_resena`, `spi_recalcular_valoracion` | `trg_resena_bi/bu/ai/au/bd` | `v_resenas_publicadas` | Cubierto |
| A33 | Contacto como ticket, máx. 3 por hora por IP (§4, §5.10) | `mensaje_contacto`, `respuesta_atencion`, `control_frecuencia` | `sp_registrar_mensaje_contacto`, `sp_responder_mensaje_contacto` | `trg_mensaje_contacto_*` | `v_mensajes_contacto_pendientes` | Cubierto |
| A34 | Libro de Reclamaciones con plazo configurable (§4) | `reclamo`, `respuesta_atencion` | `sp_registrar_reclamo`, `sp_marcar_en_atencion`, `sp_responder_reclamo` (sin edición directa) | `trg_reclamo_*` | `v_reclamos_pendientes`, `ev_alertar_vencimientos` | Cubierto (plazo: verificar INDECOPI) |
| A35 | Notificaciones y cola de correos con reintentos (RNF 18, §2.7) | `notificacion`, `cola_correo` | `spi_encolar_correo`, `spi_notificar`, `sp_tomar_correos_pendientes`, `sp_marcar_correo`, `sp_marcar_notificacion_leida` | `trg_cola_correo_bi/bu`, `trg_notificacion_bu` | `v_correos_pendientes` | Cubierto |
| A36 | Reportes y panel: ventas por día (Lima), categoría, productos, clientes, ingresos (§4) | — | `fn_utc_a_lima`, `fn_hoy_lima` | — | `v_ventas_diarias`, `v_ingresos_diarios`, `v_ventas_por_categoria`, `v_productos_mas_vendidos`, `v_clientes_resumen` | Cubierto |
| A37 | Configuración validada por tipo y rango (§4) | `configuracion` | `sp_actualizar_configuracion`, `fn_config*`, `spi_validar_valor_config` | `trg_configuracion_bi/bu/au` | `v_configuracion_por_verificar` | Cubierto |
| A38 | Auditoría inmutable con retención ≥ 12 meses (§4) | `auditoria` | `spi_auditar` | `trg_auditoria_bu/bd` y auditoría en triggers de negocio | `v_auditoria` | Cubierto |
| A39 | APIs externas: webhooks, bitácora, caché DNI/RUC (§2.10) | `evento_pasarela`, `log_api_externa`, `consulta_documento` | `sp_registrar_evento_pasarela`, `sp_registrar_log_api` (rechaza tarjetas y credenciales), `sp_redactar_log_api` (DBA), `sp_guardar_consulta_documento`, `sp_obtener_consulta_documento` | `trg_log_api_externa_*`, `trg_evento_pasarela_*` | — | Cubierto |
| A40 | Mensajes de error claros (RNF 20, §3.1) | `catalogo_error` | `spi_error` (SIGNAL 45001–45035) | todos | — | Cubierto |
| A41 | Numeración correlativa sin saltos (§5.10–11) | `secuencia_documento`, `serie_comprobante` | `spi_siguiente_numero`, `spi_siguiente_correlativo` | `trg_secuencia_documento_bu`, triggers `_bi` que numeran | — | Cubierto |
| A42 | Borrado lógico y bloqueo de DELETE físico (§2.6) | columnas `activo`/`estado` + `inhabilitado_en/por` | `sp_inhabilitar_*`, `sp_reactivar_*`, `spi_control_borrado`, `fn_borrado_dba_autorizado` | `trg_*_bd` | — | Cubierto |
| A43 | Seguridad: mínimo privilegio, hashes, sin secretos, sin datos de tarjeta (§6) | `secreto_interno` | `fn_token_interno`, `fn_contexto_interno` (marca no falsificable), `fn_contiene_datos_tarjeta`, `fn_contiene_secretos`, `fn_luhn_valido`, `fn_ip_sesion` | `trg_pago_bi/bu`, `trg_evento_pasarela_bi`, `trg_cola_correo_bi` | roles en `07_roles_permisos.sql` | Cubierto |
| A44 | Concurrencia sin sobreventa ni doble cobro (§3.2, §7.12) | `control_frecuencia`, índices únicos | `sp_crear_pedido` (reintento 1213), bloqueo pedido → pago → variantes (la variante antes de insertar el ítem), agregados con `FOR SHARE` | — | `scripts/prueba_concurrencia.sh` (7 escenarios) | Cubierto (probado) |
| A45 | Fechas en UTC y reportes por día de Lima (§3, §7.13) | todas (`DATETIME(3)` UTC) | `fn_utc_a_lima`, `fn_hoy_lima` | `actualizado_en` por trigger | vistas `*_lima` | Cubierto |
| A46 | Copias de seguridad y prueba de restauración (RNF 13) | — | — | — | `LEEME_INSTALACION.md` §8 | No aplica a la BD (procedimiento documentado) |
| A47 | Rendimiento (índices, paginación, crecimiento) | índices compuestos | — | — | plan en `COMPARATIVA_Y_CAMBIOS.md` §7 | Cubierto |
| A48 | Cupones de descuento (HU-40) | `pedido.descuento` (reservado) | `sp_emitir_comprobante` rechaza descuentos hasta implementarlo | — | — | Fuera de alcance |
| A49 | Interfaz: diseño, responsive, accesibilidad, SEO, idioma de pantallas | — | — | — | — | No aplica a la BD (Django) |

## Parte B — Lista numerada

### Historias de usuario (HU-01 … HU-40)

| Código | Cubierto por (Parte A) | Estado |
|---|---|---|
| HU-01 | — | Pendiente: verificar contra el Excel |
| HU-02 | A01 (código por correo: 5 min, el Excel dice 10) | Cubierto — corregir el Excel |
| HU-03 | — | Pendiente: verificar contra el Excel |
| HU-04 | — | Pendiente: verificar contra el Excel |
| HU-05 | — | Pendiente: verificar contra el Excel |
| HU-06 | — | Pendiente: verificar contra el Excel |
| HU-07 | — | Pendiente: verificar contra el Excel |
| HU-08 | — | Pendiente: verificar contra el Excel |
| HU-09 | — | Pendiente: verificar contra el Excel |
| HU-10 | — | Pendiente: verificar contra el Excel |
| HU-11 | — | Pendiente: verificar contra el Excel |
| HU-12 | A28 (envío y seguimiento) | Cubierto |
| HU-13 | A25 (insumos) | Cubierto |
| HU-14 | — | Pendiente: verificar contra el Excel |
| HU-15 | — | Pendiente: verificar contra el Excel |
| HU-16 | — | Pendiente: verificar contra el Excel |
| HU-17 | A26 (cotización / bordado personalizado, según el script original) | Cubierto |
| HU-18 | A26 (cotización / bordado personalizado, según el script original) | Cubierto |
| HU-19 | — | Pendiente: verificar contra el Excel |
| HU-20 | — | Pendiente: verificar contra el Excel |
| HU-21 | — | Pendiente: verificar contra el Excel |
| HU-22 | — | Pendiente: verificar contra el Excel |
| HU-23 | — | Pendiente: verificar contra el Excel |
| HU-24 | — | Pendiente: verificar contra el Excel |
| HU-25 | — | Pendiente: verificar contra el Excel |
| HU-26 | — | Pendiente: verificar contra el Excel |
| HU-27 | — | Pendiente: verificar contra el Excel |
| HU-28 | A26 + A10 + A16 (venta al por mayor por cotización) | Cubierto |
| HU-29 | A27 (pedido complementario) | Cubierto |
| HU-30 | — | Pendiente: verificar contra el Excel |
| HU-31 | — | Pendiente: verificar contra el Excel |
| HU-32 | — | Pendiente: verificar contra el Excel |
| HU-33 | — | Pendiente: verificar contra el Excel |
| HU-34 | — | Pendiente: verificar contra el Excel |
| HU-35 | — | Pendiente: verificar contra el Excel |
| HU-36 | — | Pendiente: verificar contra el Excel |
| HU-37 | — | Pendiente: verificar contra el Excel |
| HU-38 | — | Pendiente: verificar contra el Excel |
| HU-39 | — | Pendiente: verificar contra el Excel |
| HU-40 | A48 (cupones) | Fuera de alcance (diseño preparado) |

### Requerimientos funcionales (RF-01 … RF-58)

Ningún RF se cita por número en el prompt ni en el script original. Cada uno debe ubicarse en la fila A01–A49 que corresponda.

| Código | Cubierto por (Parte A) | Estado |
|---|---|---|
| RF-01 … RF-58 | Ubicar en A01–A49 | Pendiente: verificar contra el Excel |

### Requerimientos no funcionales (RNF-01 … RNF-52)

| Código | Cubierto por (Parte A) | Estado |
|---|---|---|
| RNF-13 | A46 (copias de seguridad y restauración) | No aplica a la BD — procedimiento en `LEEME_INSTALACION.md` |
| RNF-18 | A35 (cola de correos y envío desacoplado) | Cubierto |
| RNF-20 | A40 (mensajes de error claros) | Cubierto |
| Resto (RNF-01 … RNF-52) | Probablemente A42–A47 (seguridad, rendimiento, fechas, concurrencia) o A49 (interfaz) | Pendiente: verificar contra el Excel |

## Discrepancias detectadas entre el Excel (según el prompt) y las decisiones del equipo

| Tema | Excel | Decisión aplicada | Dónde se configura |
|---|---|---|---|
| Vigencia del código por correo (HU-02) | 10 minutos | **5 minutos** (tope 5) | `configuracion.codigo_verificacion_minutos` |
| Adelanto | solo pedidos al por mayor | **todos** los pedidos eligen total o mitad | `configuracion.adelanto_permitido_en` (`todos` / `solo_mayor`) |
