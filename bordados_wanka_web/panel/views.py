"""Panel de administración: usa la conexión 'panel' (cuenta wanka_admin) y los procedimientos de la BD."""
from django.contrib import messages
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from tienda.seguridad import requiere_admin
from wanka.bd import ErrorNegocio, ejecutar, fila, filas, sp

P = "panel"


def _hx(request, url):
    from django.http import HttpResponse
    if request.headers.get("HX-Request"):
        r = HttpResponse()
        r["HX-Redirect"] = url
        return r
    return redirect(url)


@requiere_admin
def tablero(request):
    resumen = filas("SELECT estado, estado_nombre, estado_grupo, pedidos, monto_total FROM v_resumen_estados_pedido ORDER BY orden", bd=P)
    return render(request, "panel/tablero.html", {
        "resumen": resumen,
        "por_validar": fila("SELECT COUNT(*) n FROM v_pagos_por_validar", bd=P)["n"],
        "stock_bajo": filas("SELECT producto, sku, talla, color, stock_disponible, stock_minimo FROM v_stock_bajo LIMIT 8", bd=P),
        "ventas": fila("SELECT COALESCE(SUM(total_neto),0) total, COALESCE(SUM(pedidos),0) pedidos FROM v_ventas_diarias", bd=P),
        "ultimos": filas("SELECT id_pedido, numero, cliente, estado_nombre, estado_grupo, total, creado_lima FROM v_pedidos_estado ORDER BY id_pedido DESC LIMIT 8", bd=P),
    })


@requiere_admin
def pagos(request):
    return render(request, "panel/pagos.html", {"pagos": filas("SELECT * FROM v_pagos_por_validar ORDER BY registrado_lima", bd=P)})


@require_POST
@requiere_admin
def pago_accion(request, id_pago):
    try:
        if request.POST.get("accion") == "confirmar":
            (estado,) = sp("sp_confirmar_pago_manual", [id_pago], 1, bd=P)
            messages.success(request, f"Pago confirmado. Pedido: {estado}.")
        else:
            sp("sp_rechazar_pago", [id_pago, request.POST.get("motivo") or "Voucher no válido"], bd=P)
            messages.warning(request, "Pago rechazado: se avisó al cliente.")
    except ErrorNegocio as e:
        messages.error(request, e.mensaje)
    return _hx(request, "/panel/pagos/")


@requiere_admin
def pedidos(request):
    estado = request.GET.get("estado") or ""
    where, params = ("WHERE estado = %s", [estado]) if estado else ("", [])
    lista = filas(f"""SELECT id_pedido, numero, cliente, estado, estado_nombre, estado_grupo, estado_pago, tipo_entrega, total, saldo, creado_lima
                        FROM v_pedidos_estado {where} ORDER BY id_pedido DESC LIMIT 200""", params, bd=P)
    estados = filas("SELECT codigo, nombre FROM estado_pedido ORDER BY orden", bd=P)
    return render(request, "panel/pedidos.html", {"pedidos": lista, "estados": estados, "estado": estado})


@requiere_admin
def pedido(request, id_pedido):
    p = fila("SELECT * FROM v_pedidos_estado WHERE id_pedido = %s", [id_pedido], bd=P)
    if not p:
        return redirect("/panel/pedidos/")
    if request.method == "POST":
        destino = request.POST.get("destino")
        try:
            if destino == "cancelado":
                sp("sp_cancelar_pedido", [id_pedido, request.POST.get("comentario") or "Cancelado por la tienda"], bd=P)
            elif destino == "enviado":
                sp("sp_registrar_envio", [id_pedido, 1, request.POST.get("guia") or None, None, None, None], 1, bd=P)
            else:
                sp("sp_cambiar_estado_pedido", [id_pedido, destino, request.POST.get("comentario") or None], bd=P)
            messages.success(request, "Estado actualizado.")
        except ErrorNegocio as e:
            messages.error(request, e.mensaje)
        return _hx(request, f"/panel/pedidos/{id_pedido}/")
    transiciones = filas("""SELECT t.estado_destino, e.nombre FROM transicion_estado_pedido t JOIN estado_pedido e ON e.codigo = t.estado_destino
                             WHERE t.estado_origen = %s AND t.automatica = 0 AND t.tipo_entrega_aplicable IN ('ambos', %s) ORDER BY e.orden""",
                         [p["estado"], p["tipo_entrega"]], bd=P)
    envio = fila("SELECT id_envio, estado, numero_guia FROM envio WHERE id_pedido = %s ORDER BY id_envio DESC LIMIT 1", [id_pedido], bd=P)
    return render(request, "panel/pedido.html", {
        "p": p, "transiciones": transiciones, "envio": envio,
        "items": filas("SELECT nombre_producto, sku, talla, color, cantidad, precio_unitario, subtotal, personalizacion FROM item_pedido WHERE id_pedido = %s AND estado = 'vigente'", [id_pedido], bd=P),
        "pagos": filas("SELECT id_pago, metodo, monto, estado, referencia_externa, aplicado_al_pedido FROM pago WHERE id_pedido = %s ORDER BY id_pago", [id_pedido], bd=P),
        "historial": filas("SELECT estado_nuevo, estado_nombre, realizado_por, comentario, fecha_lima FROM v_historial_pedido WHERE id_pedido = %s ORDER BY fecha_lima", [id_pedido], bd=P),
    })


@require_POST
@requiere_admin
def entregar_envio(request, id_pedido):
    envio = fila("SELECT id_envio FROM envio WHERE id_pedido = %s ORDER BY id_envio DESC LIMIT 1", [id_pedido], bd=P)
    try:
        sp("sp_registrar_seguimiento_envio", [envio["id_envio"], "entregado", "Entregado al cliente", None, None, "admin", None], 1, bd=P)
        messages.success(request, "Entrega registrada.")
    except (ErrorNegocio, TypeError) as e:
        messages.error(request, getattr(e, "mensaje", "El pedido no tiene envío."))
    return _hx(request, f"/panel/pedidos/{id_pedido}/")


@requiere_admin
def productos(request):
    lista = filas("""SELECT v.id_variante, p.id_producto, p.nombre, p.slug, c.nombre AS categoria, v.sku, v.talla, v.color,
                            COALESCE(v.precio, p.precio_base) AS precio, v.stock_actual, v.stock_reservado, v.stock_disponible, p.estado
                       FROM variante_producto v JOIN producto p ON p.id_producto = v.id_producto JOIN categoria c ON c.id_categoria = p.id_categoria
                      ORDER BY p.nombre, v.talla""", bd=P)
    return render(request, "panel/productos.html", {"variantes": lista,
                                                    "categorias": filas("SELECT id_categoria, nombre FROM categoria WHERE activo = 1", bd=P)})


@require_POST
@requiere_admin
def producto_nuevo(request):
    f = request.POST
    try:
        import re
        slug = re.sub(r"[^a-z0-9]+", "-", f["nombre"].lower().translate(str.maketrans("áéíóúñü", "aeiounu"))).strip("-")
        idp = ejecutar("""INSERT INTO producto (id_categoria, nombre, slug, descripcion, precio_base, tipo_fabricacion, estado)
                          VALUES (%s, %s, %s, %s, %s, %s, 'activo')""",
                       [f["id_categoria"], f["nombre"], slug, f.get("descripcion") or None, f["precio"], f.get("tipo") or "stock"], bd=P)
        img = {"1": "pollera", "2": "faja", "3": "chaleco"}.get(f["id_categoria"], "pollera")
        ejecutar("INSERT INTO imagen_producto (id_producto, url, texto_alt, principal) VALUES (%s, %s, %s, 1)",
                 [idp, f"/static/img/{img}.svg", f["nombre"]], bd=P)
        for talla in [t.strip() for t in (f.get("tallas") or "U").split(",") if t.strip()]:
            idv = ejecutar("INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES (%s, %s, %s, %s)",
                           [idp, f"{slug[:24]}-{talla}".upper(), talla, f.get("color") or None], bd=P)
            if int(f.get("stock") or 0) > 0:
                sp("sp_ajustar_stock", [idv, "ingreso", int(f["stock"]), "Stock inicial"], 1, bd=P)
        messages.success(request, f"Producto «{f['nombre']}» creado.")
    except (ErrorNegocio, KeyError, ValueError) as e:
        messages.error(request, getattr(e, "mensaje", str(e)))
    except Exception as e:   # p. ej. slug repetido o dato inválido (CHECK)
        messages.error(request, f"No se pudo crear: {e.args[-1] if e.args else e}")
    return redirect("/panel/productos/")


@require_POST
@requiere_admin
def stock(request, id_variante):
    try:
        cant = int(request.POST.get("cantidad", 0))
        sp("sp_ajustar_stock", [id_variante, "ingreso" if cant > 0 else "ajuste", cant, request.POST.get("motivo") or "Ajuste desde el panel"], 1, bd=P)
        messages.success(request, "Stock actualizado.")
    except (ErrorNegocio, ValueError) as e:
        messages.error(request, getattr(e, "mensaje", "Cantidad inválida."))
    return _hx(request, "/panel/productos/")
