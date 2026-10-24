"""Sesión, permisos y segundo factor (TOTP) de la web."""
import functools
import time

import pyotp
from cryptography.fernet import Fernet
from django.conf import settings
from django.contrib import messages
from django.shortcuts import redirect


def iniciar_sesion(request, usuario):
    request.session.cycle_key()
    request.session.update({"uid": usuario["id_usuario"], "nombre": usuario["nombres"], "rol": usuario["rol"],
                            "autenticado": True})
    request.session.pop("pendiente_2fa", None)


def requiere_cliente(vista):
    @functools.wraps(vista)
    def envoltura(request, *a, **k):
        if not request.session.get("autenticado"):
            messages.info(request, "Inicia sesión para continuar.")
            return redirect(f"/ingresar/?siguiente={request.path}")
        return vista(request, *a, **k)
    return envoltura


def requiere_admin(vista):
    @functools.wraps(vista)
    def envoltura(request, *a, **k):
        if not (request.session.get("autenticado") and request.session.get("rol") == "administrador"):
            return redirect("/ingresar/?siguiente=/panel/")
        return vista(request, *a, **k)
    return envoltura


def _fernet():
    return Fernet(settings.TOTP_FERNET_KEY.encode())


def cifrar(secreto):
    return _fernet().encrypt(secreto.encode())


def descifrar(dato):
    return _fernet().decrypt(bytes(dato)).decode()


def paso_totp(secreto, codigo):
    """Devuelve el paso TOTP que coincide con el código (±30 s) o None."""
    totp = pyotp.TOTP(secreto)
    ahora = time.time()
    codigo = (codigo or "").strip().replace(" ", "")
    for desfase in (0, -1, 1):
        t = ahora + desfase * 30
        if totp.at(t) == codigo:
            return int(t // totp.interval)
    return None
