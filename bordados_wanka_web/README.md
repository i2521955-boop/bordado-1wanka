# Bordados Wanka — Web (tienda + panel)

Django 5.2 + plantillas HTML + HTMX + Tailwind, sobre la base de datos MySQL de `../bordados_wanka_db`.
Diseño basado en el Figma "Sistema moderno dinámico" (terracota, Playfair Display + Nunito, logo de rombo).

## Levantar en local
Requisitos: Docker Desktop, Python 3.12+ y la base instalada (`../bordados_wanka_db`, ver su README).

```bash
./scripts/preparar.sh
```
Crea el entorno virtual, instala dependencias, genera `.env` con claves aleatorias y las cuentas MySQL de la app.

```bash
.venv/bin/python manage.py sembrar_demo
```
Crea el administrador, un cliente de prueba y 9 productos. Muestra las claves **una sola vez**.

```bash
.venv/bin/python manage.py runserver
```
Abra <http://127.0.0.1:8000>. El panel está en <http://127.0.0.1:8000/panel/> (el administrador configura su app autenticadora en el primer ingreso).

## Qué incluye
- **Tienda:** inicio con carrusel, catálogo por categoría y búsqueda, ficha de producto con tallas y precio por mayor, carrito (HTMX), compra con recojo o envío a domicilio, pago con Yape/Plin/transferencia, mis pedidos con seguimiento.
- **Cuentas:** registro, verificación por código (en desarrollo el código sale en la terminal y en pantalla), ingreso con bloqueo por intentos, 2FA TOTP obligatorio para el administrador.
- **Panel:** resumen, pagos por validar (confirmar/rechazar), pedidos con cambio de estado según las transiciones de la BD, despacho y entrega, productos y ajuste de stock.

Toda la lógica de negocio corre en los procedimientos de la BD: la web los llama con la cuenta `wanka_tienda` (tienda) o `wanka_admin` (panel).

## Estructura
```
wanka/      settings, middleware del actor (@app_actor_id), acceso a la BD (wanka/bd.py)
tienda/     vistas de la tienda y cuentas; comando sembrar_demo
panel/      vistas del panel de administración
templates/  HTML (Tailwind) · static/img: ilustraciones de producto (reemplazar por fotos reales)
```

## Pendiente (siguientes etapas)
Cotizaciones, devoluciones y notas de crédito, comprobantes electrónicos (OSE), Libro de Reclamaciones, Mercado Pago/PayPal, fotos reales de productos y despliegue.
