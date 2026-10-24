from django.urls import include, path

urlpatterns = [
    path("panel/", include("panel.urls")),
    path("", include("tienda.urls")),
]
