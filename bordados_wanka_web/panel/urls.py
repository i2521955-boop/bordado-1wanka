from django.urls import path

from . import views

urlpatterns = [
    path("", views.tablero),
    path("pagos/", views.pagos),
    path("pagos/<int:id_pago>/", views.pago_accion),
    path("pedidos/", views.pedidos),
    path("pedidos/<int:id_pedido>/", views.pedido),
    path("pedidos/<int:id_pedido>/entregar/", views.entregar_envio),
    path("productos/", views.productos),
    path("productos/nuevo/", views.producto_nuevo),
    path("productos/stock/<int:id_variante>/", views.stock),
]
