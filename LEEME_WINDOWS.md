# Bordados Wanka — Cómo levantarlo en Windows

Contiene dos carpetas:
- `bordados_wanka_db`  → base de datos MySQL 8 (Docker + phpMyAdmin)
- `bordados_wanka_web` → tienda y panel (Django)

## 1. Instalar (una sola vez)
- **Docker Desktop** para Windows (con WSL 2): https://www.docker.com/products/docker-desktop/ — ábralo y espere a que diga "Running".
- **Python 3.12 o superior**: https://www.python.org/downloads/ — en el instalador marque **"Add python.exe to PATH"**.

Abra **PowerShell** en la carpeta donde descomprimió el zip.

## 2. Base de datos
```powershell
cd bordados_wanka_db
copy .env.ejemplo .env
notepad .env
```
En el Bloc de notas cambie `<CAMBIAR_CLAVE_ROOT_LOCAL>` por una clave propia (sin espacios) y guarde.
```powershell
docker compose up -d
powershell -ExecutionPolicy Bypass -File .\scripts\instalar.ps1
cd ..
```
phpMyAdmin queda en http://localhost:8080 (usuario `root`, la clave del `.env`).

## 3. Web
```powershell
cd bordados_wanka_web
powershell -ExecutionPolicy Bypass -File .\scripts\preparar.ps1
.\.venv\Scripts\python.exe manage.py sembrar_demo
```
`sembrar_demo` muestra **una sola vez** las claves del administrador y del cliente de prueba: anótelas.
```powershell
.\.venv\Scripts\python.exe manage.py runserver
```
Abra http://127.0.0.1:8000 (tienda) y http://127.0.0.1:8000/panel/ (panel).
En el primer ingreso del administrador aparece un QR para la app autenticadora; en modo desarrollo también se muestra el código vigente en pantalla.

## Las siguientes veces
Con Docker Desktop abierto:
```powershell
cd bordados_wanka_db ; docker compose up -d ; cd ..\bordados_wanka_web
.\.venv\Scripts\python.exe manage.py runserver
```

## Problemas frecuentes
- **"la ejecución de scripts está deshabilitada"**: use siempre `powershell -ExecutionPolicy Bypass -File ...` como arriba.
- **El puerto 3306 u 8080 está ocupado** (otro MySQL/XAMPP): detenga ese servicio o cambie el puerto en `docker-compose.yml`.
- **`py` o `python` no se reconoce**: reinstale Python marcando "Add python.exe to PATH".
- Detalles completos: `bordados_wanka_db/docs/LEEME_INSTALACION.md` y `bordados_wanka_web/README.md`.
