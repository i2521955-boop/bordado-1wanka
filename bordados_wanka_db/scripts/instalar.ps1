# Instalador para Windows (PowerShell) de la base Bordados Wanka en el contenedor Docker wanka-mysql.
# Uso (desde la carpeta bordados_wanka_db):
#   powershell -ExecutionPolicy Bypass -File .\scripts\instalar.ps1             # instala/actualiza
#   powershell -ExecutionPolicy Bypass -File .\scripts\instalar.ps1 -Reiniciar  # BORRA y reinstala desde cero
#   powershell -ExecutionPolicy Bypass -File .\scripts\instalar.ps1 -Pruebas    # base bordados_wanka_test + 99_pruebas.sql
param([switch]$Reiniciar, [switch]$Pruebas)
$ErrorActionPreference = "Stop"
$Raiz = Split-Path -Parent $PSScriptRoot
$envFile = Join-Path $Raiz ".env"
if (-not (Test-Path $envFile)) { throw "Falta $envFile. Copie .env.ejemplo como .env y ponga una clave en MYSQL_ROOT_PASSWORD." }
$clave = ((Get-Content $envFile | Where-Object { $_ -match '^MYSQL_ROOT_PASSWORD=' }) -replace '^MYSQL_ROOT_PASSWORD=', '').Trim()
$base = if ($Pruebas) { "bordados_wanka_test"; $Reiniciar = $true } else { "bordados_wanka" }

# Espera a que MySQL acepte conexiones
for ($i = 0; $i -lt 60; $i++) {
  docker exec -e MYSQL_PWD=$clave wanka-mysql mysqladmin ping -uroot --silent 2>$null | Out-Null
  if ($LASTEXITCODE -eq 0) { break }
  Start-Sleep -Seconds 2
}
if ($LASTEXITCODE -ne 0) { throw "MySQL no responde: ¿ejecutó 'docker compose up -d'?" }

# Copia los scripts al contenedor (evita problemas de codificación de PowerShell con tildes)
$tmp = Join-Path $env:TEMP "wanka_sql"
if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
New-Item -ItemType Directory $tmp | Out-Null
Get-ChildItem (Join-Path $Raiz "sql") -Filter *.sql | ForEach-Object {
  $txt = [IO.File]::ReadAllText($_.FullName)
  if ($base -ne "bordados_wanka" -and $_.Name -ne "99_pruebas.sql") { $txt = $txt -replace '\bbordados_wanka\b', $base }
  [IO.File]::WriteAllText((Join-Path $tmp $_.Name), $txt, (New-Object System.Text.UTF8Encoding $false))
}
docker exec wanka-mysql rm -rf /tmp/wanka_sql | Out-Null
docker cp $tmp wanka-mysql:/tmp/wanka_sql | Out-Null

function Ejecutar($archivo, $extra = "--batch --silent") {
  docker exec -e MYSQL_PWD=$clave wanka-mysql sh -c "mysql -uroot --default-character-set=utf8mb4 $extra < /tmp/wanka_sql/$archivo"
  if ($LASTEXITCODE -ne 0) { throw "Error en $archivo" }
}
if ($Reiniciar) {
  Write-Host "» Borrando la base $base (si existe)"
  docker exec -e MYSQL_PWD=$clave wanka-mysql mysql -uroot -e "DROP DATABASE IF EXISTS ``$base``;"
}
foreach ($f in "00_requisitos_y_entorno","01_esquema_acceso","02_esquema_tienda","03_funciones_procedimientos",
                "04_triggers","05_vistas","06_eventos","07_roles_permisos","08_datos_iniciales") {
  Write-Host ("» {0,-32} " -f "$f.sql") -NoNewline
  Ejecutar "$f.sql" | Out-Null
  Write-Host "ok"
}
if ($Pruebas) { Write-Host "» Ejecutando 99_pruebas.sql"; Ejecutar "99_pruebas.sql" "--table" }
Write-Host "» Listo: base $base instalada."
