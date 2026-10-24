from .bd import fila


def globales(request):
    s = request.session
    ctx = {"usuario_nombre": s.get("nombre"), "es_admin": s.get("rol") == "administrador" and s.get("autenticado"),
           "autenticado": bool(s.get("autenticado")), "carrito_n": 0}
    if s.get("autenticado") and s.get("rol") == "cliente":
        r = fila("""SELECT COALESCE(SUM(i.cantidad), 0) AS n FROM carrito c JOIN item_carrito i ON i.id_carrito = c.id_carrito
                    WHERE c.id_usuario = %s AND c.estado = 'activo'""", [s["uid"]])
        ctx["carrito_n"] = int(r["n"]) if r else 0
    return ctx
