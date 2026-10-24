#!/usr/bin/env bash
# Prepara el entorno local: entorno virtual, dependencias, cuentas MySQL de la app y .env
# Uso: ./scripts/preparar.sh   (con el contenedor wanka-mysql corriendo y la BD instalada)
set -euo pipefail
cd "$(dirname "$0")/.."
BD_DIR="${WANKA_BD_DIR:-../bordados_wanka_db}"
[ -f "$BD_DIR/.env" ] || { echo "No encuentro $BD_DIR/.env (clave de root de MySQL)"; exit 1; }
set -a; . "$BD_DIR/.env"; set +a

[ -d .venv ] || python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements.txt

gen() { .venv/bin/python -c "import secrets;print(secrets.token_urlsafe($1))"; }
if [ ! -f .env ]; then
  FERNET=$(.venv/bin/python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())")
  cat > .env <<EOV
DJANGO_SECRET_KEY=$(gen 48)
DJANGO_DEBUG=1
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=bordados_wanka
DB_TIENDA_USUARIO=wanka_tienda
DB_TIENDA_CLAVE=$(gen 24)
DB_ADMIN_USUARIO=wanka_admin
DB_ADMIN_CLAVE=$(gen 24)
CODIGO_PEPPER=$(gen 32)
TOTP_FERNET_KEY=$FERNET
EOV
  chmod 600 .env
  echo "» .env creado con claves aleatorias"
fi
set -a; . ./.env; set +a

# Cuentas de la app para conexiones desde fuera del contenedor ('%': solo desarrollo local)
docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" wanka-mysql mysql -uroot <<EOSQL
CREATE USER IF NOT EXISTS '$DB_TIENDA_USUARIO'@'%' IDENTIFIED BY '$DB_TIENDA_CLAVE';
ALTER USER '$DB_TIENDA_USUARIO'@'%' IDENTIFIED BY '$DB_TIENDA_CLAVE' ACCOUNT UNLOCK;
GRANT rol_app_tienda TO '$DB_TIENDA_USUARIO'@'%';
SET DEFAULT ROLE rol_app_tienda TO '$DB_TIENDA_USUARIO'@'%';
CREATE USER IF NOT EXISTS '$DB_ADMIN_USUARIO'@'%' IDENTIFIED BY '$DB_ADMIN_CLAVE';
ALTER USER '$DB_ADMIN_USUARIO'@'%' IDENTIFIED BY '$DB_ADMIN_CLAVE' ACCOUNT UNLOCK;
GRANT rol_app_admin TO '$DB_ADMIN_USUARIO'@'%';
SET DEFAULT ROLE rol_app_admin TO '$DB_ADMIN_USUARIO'@'%';
EOSQL
echo "» Cuentas $DB_TIENDA_USUARIO y $DB_ADMIN_USUARIO listas"
.venv/bin/python manage.py check
echo "» Listo. Siguiente: .venv/bin/python manage.py sembrar_demo  y luego  .venv/bin/python manage.py runserver"
