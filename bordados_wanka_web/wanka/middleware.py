"""Actor de cada petición: los procedimientos de la BD saben quién actúa (@app_actor_id, @app_ip)."""
import threading

_local = threading.local()


def actor_actual():
    return getattr(_local, "actor", None), getattr(_local, "ip", None)


def fijar_actor(id_usuario):
    _local.actor = id_usuario


class ActorBDMiddleware:
    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        _local.actor = request.session.get("uid") if request.session.get("autenticado") else None
        _local.ip = request.META.get("REMOTE_ADDR")
        try:
            return self.get_response(request)
        finally:
            _local.actor = None
            _local.ip = None
