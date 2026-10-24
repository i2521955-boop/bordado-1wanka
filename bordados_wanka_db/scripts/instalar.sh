#!/usr/bin/env bash
# =====================================================================
# Instalador de la base de datos de Bordados Wanka (MySQL 8.4)
#
# Uso:
#   ./scripts/instalar.sh                 # instala/actualiza bordados_wanka (00..08)
#   ./scripts/instalar.sh --reiniciar     # BORRA bordados_wanka y la instala desde cero
#   ./scripts/instalar.sh --pruebas       # crea bordados_wanka_test desde cero y corre 99_pruebas.sql
#   ./scripts/instalar.sh --base otra_base --reiniciar   # instala con otro nombre de base (copias de trabajo)
#   (con --pruebas y --base, el nombre debe terminar en _test)
#
# Conexión:
#   - Si el contenedor Docker "wanka-mysql" está corriendo, usa docker exec.
#   - Si no, usa el cliente "mysql" local con MYSQL_HOST / MYSQL_PORT / MYSQL_USER
#     y la clave en MYSQL_PWD (variable de entorno; nunca en el script).
#   - La clave de root de Docker se lee de .env (MYSQL_ROOT_PASSWORD).
# Se detiene en el primer error (los scripts son re-ejecutables).
# =====================================================================
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
SQL="${WANKA_SQL_DIR:-$RAIZ/sql}"   # WANKA_SQL_DIR permite instalar desde otra carpeta
BASE="bordados_wanka"
REINICIAR=0
PRUEBAS=0

BASE_ELEGIDA=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --reiniciar) REINICIAR=1 ;;
    --pruebas)   PRUEBAS=1; REINICIAR=1 ;;
    --base)      BASE_ELEGIDA="${2:-}"; shift ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -n "$BASE_ELEGIDA" ]]; then
  [[ "$BASE_ELEGIDA" =~ ^[a-z0-9_]{1,60}$ ]] || { echo "Nombre de base inválido: $BASE_ELEGIDA" >&2; exit 2; }
  BASE="$BASE_ELEGIDA"
elif [[ $PRUEBAS -eq 1 ]]; then
  BASE="bordados_wanka_test"
fi
if [[ $PRUEBAS -eq 1 && "$BASE" != *_test ]]; then
  echo "Las pruebas solo corren sobre una base cuyo nombre termina en _test" >&2; exit 2
fi

if [[ -f "$RAIZ/.env" && -z "${MYSQL_PWD:-}" ]]; then
  # shellcheck disable=SC1091
  set -a; . "$RAIZ/.env"; set +a
  export MYSQL_PWD="${MYSQL_ROOT_PASSWORD:-}"
fi

if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx wanka-mysql; then
  mysql_cmd() { docker exec -i -e MYSQL_PWD="$MYSQL_PWD" wanka-mysql mysql -uroot --default-character-set=utf8mb4 "$@"; }
  echo "» Conectando al contenedor Docker wanka-mysql"
else
  mysql_cmd() { mysql -h "${MYSQL_HOST:-127.0.0.1}" -P "${MYSQL_PORT:-3306}" -u "${MYSQL_USER:-root}" --default-character-set=utf8mb4 "$@"; }
  echo "» Conectando a ${MYSQL_HOST:-127.0.0.1}:${MYSQL_PORT:-3306} como ${MYSQL_USER:-root}"
fi

# Adapta el nombre de la base (solo para la base de pruebas)
preparar() {
  if [[ "$BASE" == "bordados_wanka" ]]; then cat "$1"
  else perl -pe "s/\\bbordados_wanka\\b/$BASE/g" "$1"; fi
}

if [[ $REINICIAR -eq 1 ]]; then
  echo "» Borrando la base $BASE (si existe)"
  mysql_cmd -e "DROP DATABASE IF EXISTS \`$BASE\`;"
fi

for f in 00_requisitos_y_entorno 01_esquema_acceso 02_esquema_tienda 03_funciones_procedimientos \
         04_triggers 05_vistas 06_eventos 07_roles_permisos 08_datos_iniciales; do
  printf '» %-32s ' "$f.sql"
  preparar "$SQL/$f.sql" | mysql_cmd --batch --silent > /dev/null
  echo "ok"
done

if [[ $PRUEBAS -eq 1 ]]; then
  echo "» Ejecutando 99_pruebas.sql sobre $BASE"
  perl -pe "s/\\bbordados_wanka_test\\b/$BASE/g" "$SQL/99_pruebas.sql" | mysql_cmd --table
fi

echo "» Listo: base $BASE instalada."
