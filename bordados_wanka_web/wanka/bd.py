"""Acceso a la BD: consultas y llamadas a procedimientos sp_* con parámetros OUT y errores de negocio claros."""
from django.db import DatabaseError, connections

from .middleware import actor_actual


class ErrorNegocio(Exception):
    """Error 45001-45099 de la BD (regla de negocio): el mensaje se muestra al usuario."""

    def __init__(self, codigo, mensaje):
        super().__init__(mensaje)
        self.codigo = codigo
        self.mensaje = mensaje


def _preparar(cursor, actor=None):
    act, ip = actor_actual()
    if actor is not None:
        act = actor
    cursor.execute("SET @app_actor_id = %s, @app_ip = %s, @wanka_ctx_interno = NULL", [act, ip])


def _traducir(exc):
    args = getattr(exc, "args", ())
    if args and isinstance(args[0], int) and 45000 <= args[0] <= 45999:
        return ErrorNegocio(args[0], str(args[1]))
    return None


def filas(sql, params=None, bd="default"):
    with connections[bd].cursor() as c:
        c.execute(sql, params or [])
        cols = [d[0] for d in c.description]
        return [dict(zip(cols, r)) for r in c.fetchall()]


def fila(sql, params=None, bd="default"):
    r = filas(sql, params, bd)
    return r[0] if r else None


def ejecutar(sql, params=None, bd="default", actor=None):
    try:
        with connections[bd].cursor() as c:
            _preparar(c, actor)
            c.execute(sql, params or [])
            return c.lastrowid
    except DatabaseError as e:
        raise (_traducir(e.__cause__ or e) or e)


def sp(nombre, args=(), salidas=0, bd="default", actor=None):
    """CALL nombre(args..., @o0..@oN) y devuelve la lista de valores OUT."""
    outs = [f"@wo{i}" for i in range(salidas)]
    marcas = ", ".join(["%s"] * len(args) + outs)
    try:
        with connections[bd].cursor() as c:
            _preparar(c, actor)
            c.execute(f"CALL {nombre}({marcas})", list(args))
            while c.nextset():   # descarta conjuntos de resultados del procedimiento
                pass
            if not salidas:
                return []
            c.execute("SELECT " + ", ".join(outs))
            return list(c.fetchone())
    except DatabaseError as e:
        raise (_traducir(e.__cause__ or e) or e)
