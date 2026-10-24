# Diagrama entidad-relación — Bordados Wanka S.A.C.

> Generado desde `information_schema` (`scripts/generar_documentacion.py`). Un diagrama por módulo para que sea legible; las tablas de otros módulos aparecen solo con su llave primaria. Se muestran llaves y columnas principales (las de auditoría `creado_*`, `actualizado_*`, `inhabilitado_*` se omiten). Notación Mermaid `erDiagram` (GitHub, VS Code y GitLab lo dibujan).


## Acceso y seguridad

```mermaid
erDiagram
    rol {
        tinyint id_rol PK
        varchar codigo UK
        varchar nombre
        varchar descripcion
        tinyint requiere_2fa
        tinyint activo
    }
    usuario {
        bigint id_usuario PK
        tinyint id_rol FK
        varchar correo UK
        varchar hash_contrasena
        varchar nombres
        varchar apellidos
        varchar nombre_completo
        varchar celular
        enum tipo_documento
        varchar numero_documento
        enum estado
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    sesion {
        bigint id_sesion PK
        bigint id_usuario FK
        char token_hash UK
        varbinary ip
        varchar user_agent
        datetime ultima_actividad_en
        datetime expira_en
        datetime cerrada_en
        enum motivo_cierre
    }
    intento_acceso {
        bigint id_intento PK
        varchar correo_intentado
        bigint id_usuario FK
        varbinary ip
        varchar user_agent
        tinyint exitoso
        enum resultado
    }
    codigo_verificacion {
        bigint id_codigo PK
        bigint id_usuario FK
        varchar correo_destino
        enum proposito
        char codigo_hash
        enum estado
        tinyint intentos
        tinyint max_intentos
        char hash_vigente UK
        varbinary ip
        datetime expira_en
    }
    historial_contrasena {
        bigint id_historial PK
        bigint id_usuario FK
        varchar hash_contrasena
        enum origen
    }
    autenticacion_2fa {
        bigint id_usuario PK, FK
        enum metodo
        varbinary secreto_cifrado
        tinyint activo
        datetime verificado_en
        bigint ultimo_paso_totp
        datetime ultimo_uso_en
        datetime desactivado_en
        enum metodo_pendiente
    }
    codigo_respaldo_2fa {
        bigint id_codigo_respaldo PK
        bigint id_usuario FK
        smallint lote
        char codigo_hash
        datetime usado_en
        datetime invalidado_en
    }
    consentimiento_datos {
        bigint id_consentimiento PK
        bigint id_usuario FK
        varchar correo
        enum finalidad
        varchar version_documento
        tinyint otorgado
        varbinary ip
        varchar user_agent
    }
    solicitud_arco {
        bigint id_solicitud PK
        varchar numero UK
        bigint id_usuario FK
        varchar nombres
        enum tipo_documento
        varchar numero_documento
        varchar correo
        enum tipo
        text detalle
        enum estado
        date fecha_limite
        bigint atendido_por FK
        bigint actualizado_por FK
    }
    auditoria {
        bigint id_auditoria PK
        bigint id_usuario_actor
        bigint id_usuario_afectado
        varchar evento
        varchar entidad
        bigint id_entidad
        json detalle
        varbinary ip
        enum origen
    }
    secreto_interno {
        tinyint id_secreto PK
        char secreto
    }
    rol ||--o{ usuario : "id_rol"
    usuario |o--o{ codigo_verificacion : "id_usuario"
    usuario |o--o{ consentimiento_datos : "id_usuario"
    usuario |o--o{ intento_acceso : "id_usuario"
    usuario |o--o{ solicitud_arco : "actualizado_por"
    usuario |o--o{ solicitud_arco : "atendido_por"
    usuario |o--o{ solicitud_arco : "id_usuario"
    usuario |o--o{ usuario : "actualizado_por"
    usuario |o--o{ usuario : "creado_por"
    usuario |o--o{ usuario : "inhabilitado_por"
    usuario ||--o{ codigo_respaldo_2fa : "id_usuario"
    usuario ||--o{ historial_contrasena : "id_usuario"
    usuario ||--o{ sesion : "id_usuario"
    usuario ||--o| autenticacion_2fa : "id_usuario"
```

## Sistema e integraciones

```mermaid
erDiagram
    configuracion {
        varchar clave PK
        varchar valor
        enum tipo
        decimal valor_minimo
        decimal valor_maximo
        varchar opciones
        varchar descripcion
        tinyint editable
        tinyint por_verificar
        bigint actualizado_por FK
    }
    secuencia_documento {
        varchar prefijo PK
        smallint anio PK
        int ultimo
    }
    catalogo_error {
        smallint codigo PK
        varchar nombre UK
        varchar mensaje_usuario
        smallint http_sugerido
    }
    control_frecuencia {
        varchar ambito PK
        varchar clave PK
    }
    cola_correo {
        bigint id_correo PK
        bigint id_usuario FK
        varchar destinatario
        varchar plantilla
        json contexto
        tinyint prioridad
        enum estado
        smallint intentos
        smallint max_intentos
        datetime proximo_intento_en
    }
    notificacion {
        bigint id_notificacion PK
        bigint id_usuario FK
        varchar tipo
        varchar titulo
        varchar mensaje
        varchar enlace
        bigint id_pedido FK
        tinyint leida
        datetime leida_en
    }
    log_api_externa {
        bigint id_log PK
        enum proveedor
        varchar endpoint
        enum metodo_http
        smallint codigo_http
        int duracion_ms
        tinyint exitoso
        json request_enmascarado
        json response_enmascarado
    }
    consulta_documento {
        bigint id_consulta PK
        enum tipo_documento
        varchar numero
        varchar nombre_razon_social
        varchar estado_contribuyente
        varchar condicion_domicilio
        varchar domicilio_fiscal
        varchar fuente
        tinyint exitosa
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    pedido |o--o{ notificacion : "id_pedido"
    usuario |o--o{ cola_correo : "id_usuario"
    usuario |o--o{ configuracion : "actualizado_por"
    usuario ||--o{ notificacion : "id_usuario"
```

## Catálogo

```mermaid
erDiagram
    categoria {
        smallint id_categoria PK
        smallint id_categoria_padre FK
        varchar nombre UK
        varchar slug UK
        varchar descripcion
        varchar icono
        smallint orden
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    producto {
        bigint id_producto PK
        smallint id_categoria FK
        varchar nombre
        varchar slug UK
        text descripcion
        decimal precio_base
        enum tipo_fabricacion
        smallint dias_produccion
        tinyint permite_personalizacion
        char unidad_medida_sunat
        char codigo_afectacion_igv
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    variante_producto {
        bigint id_variante PK
        bigint id_producto FK
        varchar sku UK
        varchar talla
        varchar color
        varchar talla_clave
        varchar color_clave
        decimal precio
        int stock_actual
        int stock_reservado
        int stock_disponible
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    imagen_producto {
        bigint id_imagen PK
        bigint id_producto FK
        bigint id_variante FK
        varchar url
        varchar texto_alt
        smallint orden
        tinyint principal
        bigint principal_clave UK
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    precio_volumen {
        bigint id_precio_volumen PK
        bigint id_producto FK
        int cantidad_minima
        decimal precio_unitario
        int cantidad_activa
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    favorito {
        bigint id_usuario PK, FK
        bigint id_producto PK, FK
    }
    resena {
        bigint id_resena PK
        bigint id_producto FK
        bigint id_usuario FK
        bigint id_pedido FK
        tinyint calificacion
        varchar titulo
        varchar comentario
        enum estado
        bigint moderado_por FK
        datetime moderado_en
        varchar motivo_moderacion
    }
    banner {
        bigint id_banner PK
        varchar titulo
        varchar subtitulo
        varchar imagen_url
        varchar enlace
        varchar texto_boton
        smallint orden
        datetime vigente_desde
        datetime vigente_hasta
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    categoria |o--o{ categoria : "id_categoria_padre"
    categoria ||--o{ producto : "id_categoria"
    pedido ||--o{ resena : "id_pedido"
    producto ||--o{ favorito : "id_producto"
    producto ||--o{ imagen_producto : "id_producto"
    producto ||--o{ precio_volumen : "id_producto"
    producto ||--o{ resena : "id_producto"
    producto ||--o{ variante_producto : "id_producto"
    usuario |o--o{ banner : "actualizado_por"
    usuario |o--o{ banner : "creado_por"
    usuario |o--o{ banner : "inhabilitado_por"
    usuario |o--o{ categoria : "actualizado_por"
    usuario |o--o{ categoria : "creado_por"
    usuario |o--o{ categoria : "inhabilitado_por"
    usuario |o--o{ imagen_producto : "actualizado_por"
    usuario |o--o{ imagen_producto : "creado_por"
    usuario |o--o{ imagen_producto : "inhabilitado_por"
    usuario |o--o{ precio_volumen : "actualizado_por"
    usuario |o--o{ precio_volumen : "creado_por"
    usuario |o--o{ precio_volumen : "inhabilitado_por"
    usuario |o--o{ producto : "actualizado_por"
    usuario |o--o{ producto : "creado_por"
    usuario |o--o{ producto : "inhabilitado_por"
    usuario |o--o{ resena : "moderado_por"
    usuario |o--o{ variante_producto : "actualizado_por"
    usuario |o--o{ variante_producto : "creado_por"
    usuario |o--o{ variante_producto : "inhabilitado_por"
    usuario ||--o{ favorito : "id_usuario"
    usuario ||--o{ resena : "id_usuario"
    variante_producto |o--o{ imagen_producto : "id_variante"
```

## Inventario e insumos

```mermaid
erDiagram
    reserva_stock {
        bigint id_reserva PK
        bigint id_pedido FK
        bigint id_item_pedido FK, UK
        bigint id_variante FK
        int cantidad
        enum estado
        datetime cerrada_en
    }
    movimiento_stock {
        bigint id_movimiento PK
        bigint id_variante FK
        enum tipo
        int cantidad
        int stock_actual_resultante
        int stock_reservado_resultante
        bigint id_pedido FK
        bigint id_item_pedido FK
        bigint id_devolucion FK
        bigint id_usuario FK
        varchar motivo
    }
    insumo {
        bigint id_insumo PK
        varchar nombre UK
        enum tipo
        enum unidad
        decimal stock_actual
        decimal stock_minimo
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    movimiento_insumo {
        bigint id_movimiento PK
        bigint id_insumo FK
        enum tipo
        decimal cantidad
        decimal stock_resultante
        bigint id_pedido FK
        bigint id_usuario FK
        varchar motivo
    }
    receta_producto {
        bigint id_producto PK, FK
        bigint id_insumo PK, FK
        decimal cantidad_por_unidad
        tinyint activo
        bigint creado_por FK
        bigint actualizado_por FK
    }
    devolucion {
        bigint id_devolucion PK
    }
    item_pedido {
        bigint id_item_pedido PK
    }
    pedido {
        bigint id_pedido PK
    }
    producto {
        bigint id_producto PK
    }
    usuario {
        bigint id_usuario PK
    }
    variante_producto {
        bigint id_variante PK
    }
    devolucion |o--o{ movimiento_stock : "id_devolucion"
    insumo ||--o{ movimiento_insumo : "id_insumo"
    insumo ||--o{ receta_producto : "id_insumo"
    item_pedido |o--o{ movimiento_stock : "id_item_pedido"
    item_pedido ||--o| reserva_stock : "id_item_pedido"
    pedido |o--o{ movimiento_insumo : "id_pedido"
    pedido |o--o{ movimiento_stock : "id_pedido"
    pedido ||--o{ reserva_stock : "id_pedido"
    producto ||--o{ receta_producto : "id_producto"
    usuario |o--o{ insumo : "actualizado_por"
    usuario |o--o{ insumo : "creado_por"
    usuario |o--o{ insumo : "inhabilitado_por"
    usuario |o--o{ movimiento_insumo : "id_usuario"
    usuario |o--o{ movimiento_stock : "id_usuario"
    usuario |o--o{ receta_producto : "actualizado_por"
    usuario |o--o{ receta_producto : "creado_por"
    variante_producto ||--o{ movimiento_stock : "id_variante"
    variante_producto ||--o{ reserva_stock : "id_variante"
```

## Compra y pedidos

```mermaid
erDiagram
    carrito {
        bigint id_carrito PK
        bigint id_usuario FK
        enum estado
        bigint activo_clave UK
        bigint id_pedido FK
    }
    item_carrito {
        bigint id_item_carrito PK
        bigint id_carrito FK
        bigint id_variante FK
        int cantidad
        varchar personalizacion
        datetime agregado_en
    }
    zona_envio {
        smallint id_zona PK
        varchar nombre UK
        decimal costo
        smallint dias_estimados
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    direccion {
        bigint id_direccion PK
        bigint id_usuario FK
        varchar alias
        varchar nombre_receptor
        varchar telefono
        varchar direccion
        varchar referencia
        varchar distrito
        varchar provincia
        varchar departamento
        smallint id_zona FK
        bigint predeterminada_clave UK
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    estado_pedido {
        varchar codigo PK
        varchar nombre
        enum grupo
        tinyint orden UK
        tinyint es_final
        tinyint notifica_cliente
        varchar descripcion
    }
    transicion_estado_pedido {
        varchar estado_origen PK, FK
        varchar estado_destino PK, FK
        enum tipo_entrega_aplicable
        tinyint automatica
        tinyint permitido_cliente
        tinyint requiere_saldo_cero
        varchar descripcion
    }
    pedido {
        bigint id_pedido PK
        varchar numero UK
        bigint id_usuario FK
        bigint id_pedido_origen FK
        bigint id_cotizacion FK, UK
        enum tipo_venta
        enum canal
        varchar estado FK
        enum estado_pago
        enum modalidad_pago
        decimal adelanto_porcentaje
        enum tipo_entrega
        bigint id_direccion FK
        smallint id_zona FK
        varchar entrega_nombre
        varchar entrega_telefono
        bigint cancelado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    item_pedido {
        bigint id_item_pedido PK
        bigint id_pedido FK
        bigint id_variante FK
        bigint id_producto FK
        varchar nombre_producto
        varchar sku
        varchar talla
        varchar color
        enum tipo_fabricacion
        int cantidad
        decimal precio_lista
        decimal precio_unitario
    }
    historial_estado_pedido {
        bigint id_historial PK
        bigint id_pedido FK
        varchar estado_anterior FK
        varchar estado_nuevo FK
        bigint id_usuario FK
        varchar comentario
    }
    devolucion {
        bigint id_devolucion PK
        varchar numero UK
        bigint id_pedido FK
        enum tipo
        varchar motivo
        decimal monto_total
        bigint registrado_por FK
    }
    devolucion_item {
        bigint id_devolucion_item PK
        bigint id_devolucion FK
        bigint id_item_pedido FK
        int cantidad
        decimal monto
        tinyint repuso_stock
    }
    cotizacion {
        bigint id_cotizacion PK
    }
    producto {
        bigint id_producto PK
    }
    usuario {
        bigint id_usuario PK
    }
    variante_producto {
        bigint id_variante PK
    }
    carrito ||--o{ item_carrito : "id_carrito"
    cotizacion |o--o| pedido : "id_cotizacion"
    devolucion ||--o{ devolucion_item : "id_devolucion"
    direccion |o--o{ pedido : "id_direccion"
    estado_pedido |o--o{ historial_estado_pedido : "estado_anterior"
    estado_pedido ||--o{ historial_estado_pedido : "estado_nuevo"
    estado_pedido ||--o{ pedido : "estado"
    estado_pedido ||--o{ transicion_estado_pedido : "estado_destino"
    estado_pedido ||--o{ transicion_estado_pedido : "estado_origen"
    item_pedido ||--o{ devolucion_item : "id_item_pedido"
    pedido |o--o{ carrito : "id_pedido"
    pedido |o--o{ pedido : "id_pedido_origen"
    pedido ||--o{ devolucion : "id_pedido"
    pedido ||--o{ historial_estado_pedido : "id_pedido"
    pedido ||--o{ item_pedido : "id_pedido"
    producto |o--o{ item_pedido : "id_producto"
    usuario |o--o{ devolucion : "registrado_por"
    usuario |o--o{ direccion : "actualizado_por"
    usuario |o--o{ direccion : "creado_por"
    usuario |o--o{ direccion : "inhabilitado_por"
    usuario |o--o{ historial_estado_pedido : "id_usuario"
    usuario |o--o{ pedido : "actualizado_por"
    usuario |o--o{ pedido : "cancelado_por"
    usuario |o--o{ pedido : "creado_por"
    usuario |o--o{ zona_envio : "actualizado_por"
    usuario |o--o{ zona_envio : "creado_por"
    usuario |o--o{ zona_envio : "inhabilitado_por"
    usuario ||--o{ carrito : "id_usuario"
    usuario ||--o{ direccion : "id_usuario"
    usuario ||--o{ pedido : "id_usuario"
    variante_producto |o--o{ item_pedido : "id_variante"
    variante_producto ||--o{ item_carrito : "id_variante"
    zona_envio |o--o{ pedido : "id_zona"
    zona_envio ||--o{ direccion : "id_zona"
```

## Cotizaciones

```mermaid
erDiagram
    cotizacion {
        bigint id_cotizacion PK
        varchar numero UK
        bigint id_usuario FK
        enum origen
        enum estado
        text descripcion
        varchar imagen_referencia_url
        date fecha_entrega_solicitada
        decimal subtotal
        decimal costo_envio
        decimal total
        bigint id_admin FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    item_cotizacion {
        bigint id_item_cotizacion PK
        bigint id_cotizacion FK
        bigint id_variante FK
        varchar descripcion
        int cantidad
        decimal precio_unitario
        decimal subtotal
        varchar personalizacion
    }
    transicion_estado_cotizacion {
        enum estado_origen PK
        enum estado_destino PK
        varchar descripcion
    }
    usuario {
        bigint id_usuario PK
    }
    variante_producto {
        bigint id_variante PK
    }
    cotizacion ||--o{ item_cotizacion : "id_cotizacion"
    usuario |o--o{ cotizacion : "actualizado_por"
    usuario |o--o{ cotizacion : "creado_por"
    usuario |o--o{ cotizacion : "id_admin"
    usuario ||--o{ cotizacion : "id_usuario"
    variante_producto |o--o{ item_cotizacion : "id_variante"
```

## Envíos

```mermaid
erDiagram
    courier {
        smallint id_courier PK
        varchar nombre UK
        varchar url_seguimiento
        tinyint tiene_api
        tinyint activo
        bigint inhabilitado_por FK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    envio {
        bigint id_envio PK
        bigint id_pedido FK
        smallint id_courier FK
        varchar numero_guia
        enum estado
        decimal costo_real
        date fecha_entrega_estimada
        datetime despachado_en
        datetime entregado_en
        varchar observaciones
        bigint creado_por FK
        bigint actualizado_por FK
    }
    seguimiento_envio {
        bigint id_seguimiento PK
        bigint id_envio FK
        enum estado
        varchar descripcion
        varchar ubicacion
        datetime ocurrido_en
        enum origen
        varchar id_evento_externo
        bigint registrado_por FK
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    courier |o--o{ envio : "id_courier"
    envio ||--o{ seguimiento_envio : "id_envio"
    pedido ||--o{ envio : "id_pedido"
    usuario |o--o{ courier : "actualizado_por"
    usuario |o--o{ courier : "creado_por"
    usuario |o--o{ courier : "inhabilitado_por"
    usuario |o--o{ envio : "actualizado_por"
    usuario |o--o{ envio : "creado_por"
    usuario |o--o{ seguimiento_envio : "registrado_por"
```

## Pagos y reembolsos

```mermaid
erDiagram
    metodo_pago {
        varchar codigo PK
        varchar nombre
        enum tipo
        tinyint requiere_comprobante
        enum canal
        tinyint orden
        tinyint activo
        bigint inhabilitado_por FK
        bigint actualizado_por FK
    }
    pago {
        bigint id_pago PK
        bigint id_pedido FK
        varchar metodo FK
        enum tipo
        decimal monto
        char moneda
        char moneda_cobro
        decimal monto_cobro
        decimal tipo_cambio
        enum estado
        tinyint aplicado_al_pedido
        varchar idempotency_key UK
        bigint validado_por FK
        varchar operacion_clave UK
        bigint creado_por FK
        bigint actualizado_por FK
    }
    transicion_estado_pago {
        enum estado_origen PK
        enum estado_destino PK
        varchar descripcion
    }
    reembolso {
        bigint id_reembolso PK
        bigint id_pago FK
        bigint id_pedido FK
        decimal monto
        enum motivo
        varchar detalle
        enum estado
        enum medio
        varchar referencia_externa
        bigint id_nota_credito FK
        bigint id_devolucion FK
        bigint solicitado_por FK
        bigint procesado_por FK
        datetime completado_en
        varchar error
    }
    evento_pasarela {
        bigint id_evento PK
        enum proveedor
        varchar id_externo
        varchar tipo
        json payload
        tinyint firma_valida
        enum estado
        smallint intentos
        text error
        bigint id_pago FK
        bigint id_comprobante FK
    }
    comprobante {
        bigint id_comprobante PK
    }
    devolucion {
        bigint id_devolucion PK
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    comprobante |o--o{ evento_pasarela : "id_comprobante"
    comprobante |o--o{ reembolso : "id_nota_credito"
    devolucion |o--o{ reembolso : "id_devolucion"
    metodo_pago ||--o{ pago : "metodo"
    pago |o--o{ evento_pasarela : "id_pago"
    pago ||--o{ reembolso : "id_pago"
    pedido ||--o{ pago : "id_pedido"
    pedido ||--o{ reembolso : "id_pedido"
    usuario |o--o{ metodo_pago : "actualizado_por"
    usuario |o--o{ metodo_pago : "inhabilitado_por"
    usuario |o--o{ pago : "actualizado_por"
    usuario |o--o{ pago : "creado_por"
    usuario |o--o{ pago : "validado_por"
    usuario |o--o{ reembolso : "procesado_por"
    usuario |o--o{ reembolso : "solicitado_por"
```

## Comprobantes electrónicos

```mermaid
erDiagram
    serie_comprobante {
        smallint id_serie PK
        enum tipo
        char serie
        int ultimo_correlativo
        tinyint por_verificar
        tinyint activo
        bigint inhabilitado_por FK
    }
    motivo_nota_credito {
        char codigo PK
        varchar descripcion
        tinyint es_total
        tinyint repone_stock
        tinyint activo
    }
    comprobante {
        bigint id_comprobante PK
        bigint id_pedido FK
        enum tipo
        char codigo_tipo_sunat
        smallint id_serie FK
        char serie
        int correlativo
        varchar numero_completo
        bigint id_comprobante_ref FK
        char codigo_motivo_nc FK
        varchar motivo_detalle
        bigint id_devolucion FK
        date fecha_emision
        char emisor_ruc
        bigint pedido_activo_clave UK
        bigint creado_por FK
    }
    comprobante_item {
        bigint id_comprobante_item PK
        bigint id_comprobante FK
        smallint orden
        bigint id_item_pedido FK
        varchar codigo_producto
        varchar descripcion
        char unidad_medida
        decimal cantidad
        decimal precio_unitario
        decimal valor_unitario
        decimal valor_venta
    }
    comprobante_archivo {
        bigint id_archivo PK
        bigint id_comprobante FK
        enum tipo
        varchar mime
        longblob contenido
        int tamano_bytes
        char sha256
    }
    cola_emision_comprobante {
        bigint id_trabajo PK
        bigint id_comprobante FK, UK
        enum estado
        smallint intentos
        smallint max_intentos
        datetime proximo_intento_en
        text ultimo_error
        varchar tomado_por
        datetime tomado_en
    }
    devolucion {
        bigint id_devolucion PK
    }
    item_pedido {
        bigint id_item_pedido PK
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    comprobante |o--o{ comprobante : "id_comprobante_ref"
    comprobante ||--o{ comprobante_archivo : "id_comprobante"
    comprobante ||--o{ comprobante_item : "id_comprobante"
    comprobante ||--o| cola_emision_comprobante : "id_comprobante"
    devolucion |o--o{ comprobante : "id_devolucion"
    item_pedido |o--o{ comprobante_item : "id_item_pedido"
    motivo_nota_credito |o--o{ comprobante : "codigo_motivo_nc"
    pedido ||--o{ comprobante : "id_pedido"
    serie_comprobante ||--o{ comprobante : "id_serie"
    usuario |o--o{ comprobante : "creado_por"
    usuario |o--o{ serie_comprobante : "inhabilitado_por"
```

## Atención al cliente

```mermaid
erDiagram
    mensaje_contacto {
        bigint id_mensaje PK
        varchar ticket UK
        bigint id_usuario FK
        varchar nombre
        varchar correo
        varchar celular
        enum asunto
        bigint id_pedido FK
        varchar mensaje
        tinyint acepto_datos
        varbinary ip
        enum estado
        bigint atendido_por FK
    }
    reclamo {
        bigint id_reclamo PK
        varchar numero UK
        bigint id_usuario FK
        varchar nombres
        varchar apellidos
        enum tipo_doc
        varchar num_doc
        varchar domicilio
        varchar correo
        varchar celular
        tinyint es_menor_edad
        bigint id_pedido FK
        bigint respondido_por FK
    }
    respuesta_atencion {
        bigint id_respuesta PK
        bigint id_mensaje FK
        bigint id_reclamo FK
        enum autor
        bigint id_usuario FK
        text mensaje
    }
    pedido {
        bigint id_pedido PK
    }
    usuario {
        bigint id_usuario PK
    }
    mensaje_contacto |o--o{ respuesta_atencion : "id_mensaje"
    pedido |o--o{ mensaje_contacto : "id_pedido"
    pedido |o--o{ reclamo : "id_pedido"
    reclamo |o--o{ respuesta_atencion : "id_reclamo"
    usuario |o--o{ mensaje_contacto : "atendido_por"
    usuario |o--o{ mensaje_contacto : "id_usuario"
    usuario |o--o{ reclamo : "id_usuario"
    usuario |o--o{ reclamo : "respondido_por"
    usuario |o--o{ respuesta_atencion : "id_usuario"
```
