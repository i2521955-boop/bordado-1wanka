"""Tienda pública de Bordados Wanka."""
import io
import uuid

import pyotp
import qrcode
import qrcode.image.svg
from django.conf import settings
from django.contrib import messages
from django.contrib.auth.hashers import check_password, make_password
from django.core.mail import send_mail
from django.http import HttpResponse
from django.shortcuts import redirect, render
from django.views.decorators.http import require_POST

from wanka.bd import ErrorNegocio, ejecutar, fila, filas, sp
from wanka.middleware import fijar_actor

from .seguridad import cifrar, descifrar, iniciar_sesion, paso_totp, requiere_cliente

CATEGORIAS = [("polleras", "Polleras"), ("fajas", "Fajas"), ("chalecos", "Chalecos")]
METODOS_MANUALES = [("yape", "Yape"), ("plin", "Plin"), ("transferencia", "Transferencia bancaria")]


def _productos(where="", params=None, limite=60):
    return filas(f"""SELECT id_producto, slug, nombre, descripcion, categoria, categoria_slug, precio_desde, stock_disponible,
                            disponible, imagen_principal, tipo_fabricacion, tiene_precio_volumen, destacado
                       FROM v_catalogo_productos WHERE 1 = 1 {where} ORDER BY destacado DESC, nombre LIMIT {int(limite)}""", params)


# ---------------------------------------------------------------- catálogo
def inicio(request):
    return render(request, "tienda/inicio.html", {"destacados": _productos(limite=8), "categorias": CATEGORIAS})


def catalogo(request, categoria=None):
    q = (request.GET.get("q") or "").strip()
    where, params = "", []
    if categoria:
        where += " AND categoria_slug = %s"
        params.append(categoria)
    if q:
        where += " AND (nombre LIKE %s OR descripcion LIKE %s)"
        params += [f"%{q}%", f"%{q}%"]
    titulo = dict(CATEGORIAS).get(categoria, "Todos los productos")
    return render(request, "tienda/catalogo.html", {"productos": _productos(where, params), "titulo": titulo,
                                                    "categoria": categoria, "categorias": CATEGORIAS, "q": q})


def producto(request, slug):
    p = fila("SELECT * FROM v_catalogo_productos WHERE slug = %s", [slug])
    if not p:
        return render(request, "tienda/404.html", status=404)
    variantes = filas("""SELECT id_variante, sku, talla, color, precio, stock_disponible, disponible
                           FROM v_variantes_disponibles WHERE id_producto = %s ORDER BY talla, color""", [p["id_producto"]])
    volumen = filas("SELECT cantidad_minima, precio_unitario FROM precio_volumen WHERE id_producto = %s AND activo = 1 ORDER BY cantidad_minima",
                    [p["id_producto"]])
    return render(request, "tienda/producto.html", {"p": p, "variantes": variantes, "volumen": volumen})


# ---------------------------------------------------------------- cuentas
def registro(request):
    if request.method == "POST":
        f = request.POST
        if f.get("clave") != f.get("clave2") or len(f.get("clave", "")) < 8:
            messages.error(request, "Las contraseñas no coinciden o tienen menos de 8 caracteres.")
            return render(request, "tienda/registro.html", {"f": f})
        if not f.get("acepto"):
            messages.error(request, "Debes aceptar la política de privacidad.")
            return render(request, "tienda/registro.html", {"f": f})
        try:
            correo = f["correo"].strip().lower()
            (uid,) = sp("sp_registrar_usuario", [correo, make_password(f["clave"]), f["nombres"], f["apellidos"],
                                                 f.get("celular") or None, settings.VERSION_POLITICA, 1 if f.get("publicidad") else 0], 1)
            _enviar_codigo(request, uid, correo)
            return redirect(f"/verificar/?correo={correo}")
        except ErrorNegocio as e:
            messages.error(request, e.mensaje)
            return render(request, "tienda/registro.html", {"f": f})
    return render(request, "tienda/registro.html", {"f": {}})


def _enviar_codigo(request, uid, correo):
    codigo, expira, _ = sp("sp_generar_codigo_verificacion", [uid, correo, "verificar_correo", settings.CODIGO_PEPPER], 3)
    send_mail("Tu código de verificación - Bordados Wanka", f"Tu código es {codigo}. Vence en 5 minutos.", None, [correo])
    if settings.DEBUG:
        messages.info(request, f"Modo desarrollo: tu código es {codigo} (también salió en la terminal del servidor).")


def verificar(request):
    correo = (request.POST.get("correo") or request.GET.get("correo") or "").strip().lower()
    if request.method == "POST":
        if request.POST.get("accion") == "reenviar":
            u = fila("SELECT id_usuario FROM usuario WHERE correo = %s AND estado = 'pendiente_verificacion'", [correo])
            try:
                if u:
                    _enviar_codigo(request, u["id_usuario"], correo)
                messages.success(request, "Si la cuenta existe y no está verificada, enviamos un código nuevo.")
            except ErrorNegocio as e:
                messages.error(request, e.mensaje)
        else:
            res, restantes, _ = sp("sp_verificar_codigo", [correo, "verificar_correo", request.POST.get("codigo", ""), settings.CODIGO_PEPPER], 3)
            textos = {"ok": None, "invalido": f"Código incorrecto. Te quedan {restantes} intentos.", "vencido": "El código venció: pide uno nuevo.",
                      "bloqueado": "Demasiados intentos: pide un código nuevo.", "usado": "Ese código ya se usó.", "no_existe": "No hay un código para ese correo."}
            if res == "ok":
                messages.success(request, "¡Cuenta verificada! Ya puedes ingresar.")
                return redirect(f"/ingresar/?correo={correo}")
            messages.error(request, textos.get(res, res))
    return render(request, "tienda/verificar.html", {"correo": correo})


def ingresar(request):
    siguiente = request.POST.get("siguiente") or request.GET.get("siguiente") or ""
    if request.method == "POST":
        correo = request.POST.get("correo", "").strip().lower()
        u = fila("""SELECT u.id_usuario, u.nombres, u.hash_contrasena, r.codigo AS rol FROM usuario u JOIN rol r ON r.id_rol = u.id_rol
                     WHERE u.correo = %s""", [correo])
        correcta = check_password(request.POST.get("clave", ""), u["hash_contrasena"]) if u else (make_password("x") and False)
        res, uid, bloqueado, req2fa = sp("sp_registrar_intento_acceso", [correo, 1 if correcta else 0,
                                                                         request.META.get("HTTP_USER_AGENT", "")[:255]], 4)
        if res == "ok":
            iniciar_sesion(request, u)
            messages.success(request, f"¡Hola, {u['nombres']}!")
            return redirect(siguiente or ("/panel/" if u["rol"] == "administrador" else "/"))
        if res == "requiere_2fa":
            request.session["pendiente_2fa"] = {"uid": u["id_usuario"], "nombres": u["nombres"], "rol": u["rol"], "siguiente": siguiente}
            return redirect("/segundo-factor/")
        textos = {"credenciales_invalidas": "Correo o contraseña incorrectos.", "usuario_inexistente": "Correo o contraseña incorrectos.",
                  "bloqueada_ahora": "Demasiados intentos: tu cuenta quedó bloqueada 15 minutos.",
                  "cuenta_bloqueada": "Tu cuenta está bloqueada temporalmente. Intenta más tarde.",
                  "cuenta_inhabilitada": "Esta cuenta está inhabilitada.", "ip_bloqueada": "Demasiados intentos desde tu conexión. Espera unos minutos."}
        if res == "correo_no_verificado":
            messages.warning(request, "Primero verifica tu correo con el código que te enviamos.")
            return redirect(f"/verificar/?correo={correo}")
        messages.error(request, textos.get(res, res))
    return render(request, "tienda/ingresar.html", {"siguiente": siguiente, "correo": request.GET.get("correo", "")})


def segundo_factor(request):
    p = request.session.get("pendiente_2fa")
    if not p:
        return redirect("/ingresar/")
    f2 = fila("SELECT metodo, secreto_cifrado, activo FROM autenticacion_2fa WHERE id_usuario = %s", [p["uid"]])
    configurado = bool(f2 and f2["activo"])
    ctx = {"nombres": p["nombres"], "configurado": configurado}
    if not configurado:
        # Primera vez: se genera el secreto y se muestra el QR para la app autenticadora
        secreto = request.session.get("secreto_2fa") or pyotp.random_base32()
        request.session["secreto_2fa"] = secreto
        uri = pyotp.TOTP(secreto).provisioning_uri(name=f"usuario-{p['uid']}", issuer_name="Bordados Wanka")
        buf = io.BytesIO()
        qrcode.make(uri, image_factory=qrcode.image.svg.SvgPathImage, box_size=8).save(buf)
        ctx.update({"qr": buf.getvalue().decode(), "secreto": secreto})
    if settings.DEBUG:
        # Solo en desarrollo local: muestra el código vigente para probar sin celular
        sec_dev = descifrar(f2["secreto_cifrado"]) if configurado else ctx["secreto"]
        ctx["codigo_dev"] = pyotp.TOTP(sec_dev).now()
    if request.method == "POST":
        codigo = request.POST.get("codigo", "")
        ua = request.META.get("HTTP_USER_AGENT", "")[:255]
        try:
            if configurado:
                paso = paso_totp(descifrar(f2["secreto_cifrado"]), codigo)
                (res,) = sp("sp_registrar_segundo_factor", [p["uid"], paso or 0, 1 if paso else 0, ua], 1)
                ok = res == "ok"
                if not ok and res in ("bloqueada_ahora", "cuenta_bloqueada"):
                    request.session.pop("pendiente_2fa", None)
                    messages.error(request, "Cuenta bloqueada por intentos fallidos. Intenta en 15 minutos.")
                    return redirect("/ingresar/")
            else:
                secreto = request.session["secreto_2fa"]
                paso = paso_totp(secreto, codigo)
                ok = bool(paso)
                if ok:
                    sp("sp_configurar_2fa", [p["uid"], "totp", cifrar(secreto)], actor=p["uid"])
                    sp("sp_confirmar_2fa", [p["uid"], paso], actor=p["uid"])
                    request.session.pop("secreto_2fa", None)
            if ok:
                iniciar_sesion(request, {"id_usuario": p["uid"], "nombres": p["nombres"], "rol": p["rol"]})
                messages.success(request, f"¡Hola, {p['nombres']}!")
                return redirect(p.get("siguiente") or ("/panel/" if p["rol"] == "administrador" else "/"))
            messages.error(request, "Código incorrecto.")
        except ErrorNegocio as e:
            messages.error(request, e.mensaje)
    return render(request, "tienda/segundo_factor.html", ctx)


@require_POST
def salir(request):
    request.session.flush()
    messages.info(request, "Sesión cerrada.")
    return redirect("/")


# ---------------------------------------------------------------- carrito
def _items_carrito(uid):
    return filas("""SELECT i.id_variante, i.cantidad, p.nombre, p.slug, v.talla, v.color, v.stock_disponible,
                           fn_precio_unitario(i.id_variante, i.cantidad) AS precio,
                           fn_precio_unitario(i.id_variante, i.cantidad) * i.cantidad AS subtotal,
                           (SELECT imagen_principal FROM v_catalogo_productos c WHERE c.id_producto = p.id_producto) AS imagen
                      FROM carrito c JOIN item_carrito i ON i.id_carrito = c.id_carrito
                      JOIN variante_producto v ON v.id_variante = i.id_variante JOIN producto p ON p.id_producto = v.id_producto
                     WHERE c.id_usuario = %s AND c.estado = 'activo' ORDER BY i.id_item_carrito""", [uid])


@requiere_cliente
def carrito(request):
    items = _items_carrito(request.session["uid"])
    return render(request, "tienda/carrito.html", {"items": items, "total": sum(i["subtotal"] for i in items)})


@require_POST
def agregar_carrito(request):
    if not request.session.get("autenticado"):
        if request.headers.get("HX-Request"):
            r = HttpResponse()
            r["HX-Redirect"] = "/ingresar/"
            return r
        return redirect("/ingresar/")
    try:
        sp("sp_agregar_item_carrito", [request.session["uid"], int(request.POST["id_variante"]), int(request.POST.get("cantidad", 1)), None], 1)
        n = fila("""SELECT COALESCE(SUM(i.cantidad),0) n FROM carrito c JOIN item_carrito i ON i.id_carrito = c.id_carrito
                    WHERE c.id_usuario = %s AND c.estado = 'activo'""", [request.session["uid"]])["n"]
        if request.headers.get("HX-Request"):
            return render(request, "parciales/aviso_carrito.html", {"ok": True, "n": int(n)})
        messages.success(request, "Agregado al carrito.")
    except (ErrorNegocio, ValueError, KeyError) as e:
        msg = getattr(e, "mensaje", "Elige talla y cantidad.")
        if request.headers.get("HX-Request"):
            return render(request, "parciales/aviso_carrito.html", {"ok": False, "msg": msg})
        messages.error(request, msg)
    return redirect("/carrito/")


@require_POST
@requiere_cliente
def quitar_carrito(request, id_variante):
    sp("sp_quitar_item_carrito", [request.session["uid"], id_variante])
    return redirect("/carrito/")


# ---------------------------------------------------------------- compra y pedidos
@requiere_cliente
def checkout(request):
    uid = request.session["uid"]
    items = _items_carrito(uid)
    if not items:
        messages.info(request, "Tu carrito está vacío.")
        return redirect("/catalogo/")
    direcciones = filas("""SELECT d.id_direccion, d.alias, d.direccion, d.distrito, z.nombre AS zona, z.costo
                             FROM direccion d JOIN zona_envio z ON z.id_zona = d.id_zona
                            WHERE d.id_usuario = %s AND d.activo = 1 ORDER BY d.predeterminada DESC, d.id_direccion""", [uid])
    zonas = filas("SELECT id_zona, nombre, costo FROM zona_envio WHERE activo = 1 ORDER BY costo")
    if request.method == "POST":
        f = request.POST
        try:
            id_dir = None
            if f.get("tipo_entrega") == "domicilio":
                id_dir = f.get("id_direccion")
                if id_dir == "nueva":
                    id_dir = ejecutar("""INSERT INTO direccion (id_usuario, alias, nombre_receptor, telefono, direccion, referencia, distrito,
                                                                provincia, departamento, id_zona) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                                      [uid, f.get("alias") or "Casa", f["receptor"], f["telefono"], f["direccion"], f.get("referencia") or None,
                                       f["distrito"], f.get("provincia") or "Huancayo", f.get("departamento") or "Junín", f["id_zona"]])
            doc = (f.get("dni") or "").strip() or None
            pid, numero, total = sp("sp_crear_pedido", [uid, None, f.get("tipo_entrega", "recojo"), id_dir, "total", "boleta",
                                                         "DNI" if doc else None, doc, f.get("nombre_doc") or None, None, None,
                                                         f.get("notas") or None, "web"], 3)
            messages.success(request, f"Pedido {numero} creado. Ahora registra tu pago.")
            return redirect(f"/mis-pedidos/{pid}/")
        except (ErrorNegocio, KeyError) as e:
            messages.error(request, getattr(e, "mensaje", "Completa los datos de entrega."))
    return render(request, "tienda/checkout.html", {"items": items, "total": sum(i["subtotal"] for i in items),
                                                    "direcciones": direcciones, "zonas": zonas})


@requiere_cliente
def mis_pedidos(request):
    pedidos = filas("""SELECT id_pedido, numero, estado, estado_nombre, estado_grupo, estado_pago, total, saldo, creado_lima, tipo_entrega
                         FROM v_pedidos_estado WHERE id_usuario = %s ORDER BY id_pedido DESC""", [request.session["uid"]])
    return render(request, "tienda/mis_pedidos.html", {"pedidos": pedidos})


@requiere_cliente
def pedido(request, id_pedido):
    uid = request.session["uid"]
    p = fila("SELECT * FROM v_pedidos_estado WHERE id_pedido = %s AND id_usuario = %s", [id_pedido, uid])
    if not p:
        return render(request, "tienda/404.html", status=404)
    if request.method == "POST":
        try:
            if request.POST.get("accion") == "cancelar":
                sp("sp_cancelar_pedido", [id_pedido, request.POST.get("motivo") or "Cancelado por el cliente"])
                messages.success(request, "Pedido cancelado.")
            else:
                monto = p["saldo"] if p["monto_pagado"] else p["monto_requerido"]
                _, estado, dup = sp("sp_registrar_pago", [id_pedido, request.POST["metodo"], monto, f"web-{uuid.uuid4()}",
                                                          request.POST.get("operacion", "").strip() or None, None, None, None, None, None], 3)
                messages.success(request, "Pago registrado: lo validaremos en breve." if estado == "en_revision" else "Pago registrado.")
        except (ErrorNegocio, KeyError) as e:
            messages.error(request, getattr(e, "mensaje", "Elige el método de pago."))
        return redirect(f"/mis-pedidos/{id_pedido}/")
    items = filas("SELECT nombre_producto, talla, color, cantidad, precio_unitario, subtotal FROM item_pedido WHERE id_pedido = %s AND estado = 'vigente'",
                  [id_pedido])
    pagos = filas("SELECT metodo, monto, estado, referencia_externa, motivo_rechazo, creado_en FROM pago WHERE id_pedido = %s ORDER BY id_pago",
                  [id_pedido])
    historial = filas("SELECT estado_nuevo, fecha_lima, comentario FROM v_historial_pedido WHERE id_pedido = %s ORDER BY fecha_lima", [id_pedido])
    hay_en_revision = any(x["estado"] in ("en_revision", "pendiente") for x in pagos)
    return render(request, "tienda/pedido.html", {"p": p, "items": items, "pagos": pagos, "historial": historial,
                                                  "metodos": METODOS_MANUALES, "puede_pagar": p["estado"] not in ("cancelado", "devuelto")
                                                  and p["saldo"] > 0 and not hay_en_revision})
