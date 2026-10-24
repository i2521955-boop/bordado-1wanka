"""Configuración de la web de Bordados Wanka (tienda + panel) sobre la BD MySQL bordados_wanka."""
import os
from pathlib import Path

import pymysql
from dotenv import load_dotenv

pymysql.install_as_MySQLdb()   # conector en Python puro (no requiere compilar mysqlclient)

BASE_DIR = Path(__file__).resolve().parent.parent
load_dotenv(BASE_DIR / ".env")

SECRET_KEY = os.environ["DJANGO_SECRET_KEY"]
DEBUG = os.environ.get("DJANGO_DEBUG", "0") == "1"
ALLOWED_HOSTS = ["127.0.0.1", "localhost"]

INSTALLED_APPS = [
    "django.contrib.staticfiles",
    "django.contrib.messages",
    "django.contrib.sessions",
    "tienda",
    "panel",
]

MIDDLEWARE = [
    "django.middleware.security.SecurityMiddleware",
    "django.contrib.sessions.middleware.SessionMiddleware",
    "django.middleware.common.CommonMiddleware",
    "django.middleware.csrf.CsrfViewMiddleware",
    "django.contrib.messages.middleware.MessageMiddleware",
    "django.middleware.clickjacking.XFrameOptionsMiddleware",
    "wanka.middleware.ActorBDMiddleware",
]

ROOT_URLCONF = "wanka.urls"
TEMPLATES = [{
    "BACKEND": "django.template.backends.django.DjangoTemplates",
    "DIRS": [BASE_DIR / "templates"],
    "APP_DIRS": True,
    "OPTIONS": {"context_processors": [
        "django.template.context_processors.request",
        "django.contrib.messages.context_processors.messages",
        "wanka.contexto.globales",
    ]},
}]
WSGI_APPLICATION = "wanka.wsgi.application"


def _bd(usuario, clave):
    return {
        "ENGINE": "django.db.backends.mysql",
        "NAME": os.environ.get("DB_NAME", "bordados_wanka"),
        "USER": os.environ[usuario],
        "PASSWORD": os.environ[clave],
        "HOST": os.environ.get("DB_HOST", "127.0.0.1"),
        "PORT": os.environ.get("DB_PORT", "3306"),
        "CONN_MAX_AGE": 60,
        "OPTIONS": {"charset": "utf8mb4", "init_command": "SET time_zone = '+00:00'"},
    }


# Dos cuentas con permisos distintos: la tienda pública y el panel de administración
DATABASES = {
    "default": _bd("DB_TIENDA_USUARIO", "DB_TIENDA_CLAVE"),
    "panel": _bd("DB_ADMIN_USUARIO", "DB_ADMIN_CLAVE"),
}

# Sesiones firmadas en cookie: no requieren tablas propias de Django en la BD
SESSION_ENGINE = "django.contrib.sessions.backends.signed_cookies"
SESSION_COOKIE_HTTPONLY = True
SESSION_COOKIE_AGE = 60 * 60 * 8
MESSAGE_STORAGE = "django.contrib.messages.storage.cookie.CookieStorage"

LANGUAGE_CODE = "es-pe"
TIME_ZONE = "America/Lima"
USE_I18N = True
USE_TZ = True

STATIC_URL = "static/"
STATICFILES_DIRS = [BASE_DIR / "static"]

EMAIL_BACKEND = "django.core.mail.backends.console.EmailBackend"   # en desarrollo los correos salen en la terminal
DEFAULT_FROM_EMAIL = "Bordados Wanka <notificaciones@bordadoswanka.local>"

CODIGO_PEPPER = os.environ["CODIGO_PEPPER"]
TOTP_FERNET_KEY = os.environ["TOTP_FERNET_KEY"]
VERSION_POLITICA = "1.0"
DEFAULT_AUTO_FIELD = "django.db.models.BigAutoField"
