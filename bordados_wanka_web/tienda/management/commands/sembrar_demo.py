"""Carga datos de demostración: administrador, cliente de prueba y catálogo inicial.

Uso:  python manage.py sembrar_demo [--clave-admin X] [--clave-cliente Y]
Si no se indican claves, se generan al azar y se muestran UNA vez en pantalla (no se guardan en ningún archivo).
"""
import secrets

from django.conf import settings
from django.contrib.auth.hashers import make_password
from django.core.management.base import BaseCommand

from wanka.bd import ErrorNegocio, ejecutar, fila, sp

ADMIN = "admin@bordadoswanka.pe"
CLIENTE = "cliente@bordadoswanka.pe"

PRODUCTOS = [
    # categoría, nombre, descripción, precio, tipo, tallas, color, stock, imagen, destacado, tramo (cantidad, precio)
    ("polleras", "Pollera Andina Roja", "Pollera de bayeta bordada a mano con flores del valle del Mantaro.", 250, "stock", "S,M,L", "Rojo", 12, "pollera", 1, (6, 220)),
    ("polleras", "Pollera de Gala Verde", "Pollera de fiesta con bordado de hilo dorado y blondas.", 320, "stock", "M,L", "Verde", 6, "pollera", 1, (6, 290)),
    ("polleras", "Pollera Huanca Clásica", "Modelo tradicional para danzas y festividades.", 210, "stock", "S,M,L,XL", "Azul", 15, "pollera", 0, None),
    ("fajas", "Faja Tradicional Wanka", "Faja tejida a telar con rombos andinos.", 45, "stock", "U", "Multicolor", 40, "faja", 1, (12, 38)),
    ("fajas", "Faja Ceremonial", "Faja ancha con motivos de la cosmovisión andina.", 65, "stock", "U", "Rojo", 20, "faja", 0, None),
    ("fajas", "Chumpi Fino", "Faja delgada para uso diario, tejido fino.", 30, "stock", "U", "Negro", 30, "faja", 0, None),
    ("chalecos", "Chaleco Folklórico Bordado", "Chaleco de paño bordado para danzas folklóricas.", 180, "stock", "S,M,L", "Negro", 10, "chaleco", 1, (6, 160)),
    ("chalecos", "Chaleco Personalizado", "Chaleco a pedido con el nombre de tu comparsa bordado.", 190, "a_pedido", "U", "Negro", 0, "chaleco", 1, None),
    ("chalecos", "Chaleco de Gala", "Chaleco con aplicaciones de lentejuelas y bordado dorado.", 240, "stock", "M,L", "Granate", 5, "chaleco", 0, None),
]


class Command(BaseCommand):
    help = "Carga administrador, cliente de prueba y productos de demostración"

    def add_arguments(self, parser):
        parser.add_argument("--clave-admin")
        parser.add_argument("--clave-cliente")

    def handle(self, *args, **o):
        claves = {}
        admin = fila("SELECT id_usuario FROM usuario WHERE correo = %s", [ADMIN], bd="panel")
        if admin:
            id_admin = admin["id_usuario"]
            self.stdout.write(f"· Administrador ya existe ({ADMIN})")
        else:
            clave = o.get("clave_admin") or secrets.token_urlsafe(9)
            (id_admin,) = sp("sp_crear_administrador_inicial", [ADMIN, make_password(clave), "Ana", "Administradora"], 1, bd="panel")
            claves[ADMIN] = clave
            self.stdout.write(self.style.WARNING(f"   Administrador: {ADMIN}  /  {clave}   (anótela: no se guarda)"))

        if not fila("SELECT id_usuario FROM usuario WHERE correo = %s", [CLIENTE]):
            clave = o.get("clave_cliente") or secrets.token_urlsafe(9)
            (uid,) = sp("sp_registrar_usuario", [CLIENTE, make_password(clave), "María", "Huamán", "964111222", settings.VERSION_POLITICA, 0], 1)
            codigo, _, _ = sp("sp_generar_codigo_verificacion", [uid, CLIENTE, "verificar_correo", settings.CODIGO_PEPPER], 3)
            sp("sp_verificar_codigo", [CLIENTE, "verificar_correo", codigo, settings.CODIGO_PEPPER], 3)
            claves[CLIENTE] = clave
            self.stdout.write(self.style.WARNING(f"   Cliente:       {CLIENTE}  /  {clave}   (anótela: no se guarda)"))
        else:
            self.stdout.write(f"· Cliente de prueba ya existe ({CLIENTE})")

        cats = {r["slug"]: r["id_categoria"] for r in __import__("wanka.bd", fromlist=["filas"]).filas("SELECT slug, id_categoria FROM categoria", bd="panel")}
        creados = 0
        for cat, nombre, desc, precio, tipo, tallas, color, stock, img, dest, tramo in PRODUCTOS:
            slug = nombre.lower().translate(str.maketrans("áéíóúñ ", "aeioun-"))
            if fila("SELECT 1 x FROM producto WHERE slug = %s", [slug], bd="panel"):
                continue
            try:
                idp = ejecutar("""INSERT INTO producto (id_categoria, nombre, slug, descripcion, precio_base, tipo_fabricacion, dias_produccion,
                                                        permite_personalizacion, destacado, estado)
                                  VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, 'activo')""",
                               [cats[cat], nombre, slug, desc, precio, tipo, 7 if tipo != "stock" else 0, 1 if tipo != "stock" else 0, dest],
                               bd="panel", actor=id_admin)
                ejecutar("INSERT INTO imagen_producto (id_producto, url, texto_alt, principal) VALUES (%s, %s, %s, 1)",
                         [idp, f"/static/img/{img}.svg", nombre], bd="panel", actor=id_admin)
                if tramo:
                    ejecutar("INSERT INTO precio_volumen (id_producto, cantidad_minima, precio_unitario) VALUES (%s, %s, %s)",
                             [idp, tramo[0], tramo[1]], bd="panel", actor=id_admin)
                for talla in tallas.split(","):
                    idv = ejecutar("INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES (%s, %s, %s, %s)",
                                   [idp, f"{slug[:20]}-{talla}".upper(), talla, color], bd="panel", actor=id_admin)
                    if stock:
                        sp("sp_ajustar_stock", [idv, "ingreso", stock, "Stock inicial de demostración"], 1, bd="panel", actor=id_admin)
                creados += 1
            except ErrorNegocio as e:
                self.stderr.write(f"✘ {nombre}: {e.mensaje}")
        self.stdout.write(self.style.SUCCESS(f"✔ {creados} productos nuevos"))
        if claves:
            self.stdout.write(self.style.WARNING("\nCuentas creadas (anote las claves: no se guardan en ningún archivo):"))
            for correo, clave in claves.items():
                self.stdout.write(f"   {correo}  /  {clave}")
            self.stdout.write("El administrador configura su app autenticadora (2FA) en el primer ingreso.")
