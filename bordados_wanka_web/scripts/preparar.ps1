# Prepara la web en Windows: entorno virtual, dependencias, .env con claves aleatorias y cuentas MySQL de la app.
# Uso (desde la carpeta bordados_wanka_web, con la base ya instalada):
#   powershell -ExecutionPolicy Bypass -File .\scripts\preparar.ps1
$ErrorActionPreference = "Stop"
$Raiz = Split-Path -Parent $PSScriptRoot
Set-Location $Raiz
$bdEnv = Join-Path (Split-Path -Parent $Raiz) "bordados_wanka_db\.env"
if (-not (Test-Path $bdEnv)) { throw "No encuentro $bdEnv (clave de root de MySQL)." }
$root = ((Get-Content $bdEnv | Where-Object { $_ -match '^MYSQL_ROOT_PASSWORD=' }) -replace '^MYSQL_ROOT_PASSWORD=', '').Trim()

$py = if (Get-Command py -ErrorAction SilentlyContinue) { "py" } else { "python" }
if (-not (Test-Path ".venv")) { & $py -m venv .venv }
$vpy = ".\.venv\Scripts\python.exe"
& $vpy -m pip install -q --upgrade pip
& $vpy -m pip install -q -r requirements.txt

if (-not (Test-Path ".env")) {
  function Gen($n) { & $vpy -c "import secrets;print(secrets.token_urlsafe($n))" }
  $fernet = & $vpy -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"
  $contenido = @"
DJANGO_SECRET_KEY=$(Gen 48)
DJANGO_DEBUG=1
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=bordados_wanka
DB_TIENDA_USUARIO=wanka_tienda
DB_TIENDA_CLAVE=$(Gen 24)
DB_ADMIN_USUARIO=wanka_admin
DB_ADMIN_CLAVE=$(Gen 24)
CODIGO_PEPPER=$(Gen 32)
TOTP_FERNET_KEY=$fernet
"@
  [IO.File]::WriteAllText((Join-Path $Raiz ".env"), $contenido, (New-Object System.Text.UTF8Encoding $false))
  Write-Host "» .env creado con claves aleatorias"
}
$cfg = @{}
Get-Content ".env" | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $cfg[$k] = $v.Trim() }
$t = $cfg.DB_TIENDA_USUARIO; $tc = $cfg.DB_TIENDA_CLAVE; $a = $cfg.DB_ADMIN_USUARIO; $ac = $cfg.DB_ADMIN_CLAVE
$sql = "CREATE USER IF NOT EXISTS '$t'@'%' IDENTIFIED BY '$tc'; ALTER USER '$t'@'%' IDENTIFIED BY '$tc' ACCOUNT UNLOCK; GRANT rol_app_tienda TO '$t'@'%'; SET DEFAULT ROLE rol_app_tienda TO '$t'@'%';" +
       "CREATE USER IF NOT EXISTS '$a'@'%' IDENTIFIED BY '$ac'; ALTER USER '$a'@'%' IDENTIFIED BY '$ac' ACCOUNT UNLOCK; GRANT rol_app_admin TO '$a'@'%'; SET DEFAULT ROLE rol_app_admin TO '$a'@'%';"
docker exec -e MYSQL_PWD=$root wanka-mysql mysql -uroot -e $sql
if ($LASTEXITCODE -ne 0) { throw "No se pudieron crear las cuentas MySQL de la app" }
Write-Host "» Cuentas $t y $a listas"
& $vpy manage.py check
Write-Host "» Listo. Siguiente: .\.venv\Scripts\python.exe manage.py sembrar_demo   y luego   .\.venv\Scripts\python.exe manage.py runserver"
