from django.urls import path

from . import views

urlpatterns = [
    path("", views.inicio),
    path("catalogo/", views.catalogo),
    path("catalogo/<slug:categoria>/", views.catalogo),
    path("producto/<slug:slug>/", views.producto),
    path("registro/", views.registro),
    path("verificar/", views.verificar),
    path("ingresar/", views.ingresar),
    path("segundo-factor/", views.segundo_factor),
    path("salir/", views.salir),
    path("carrito/", views.carrito),
    path("carrito/agregar/", views.agregar_carrito),
    path("carrito/quitar/<int:id_variante>/", views.quitar_carrito),
    path("comprar/", views.checkout),
    path("mis-pedidos/", views.mis_pedidos),
    path("mis-pedidos/<int:id_pedido>/", views.pedido),
]
