# Bordados Wanka S.A.C. — Base de datos MySQL 8

Base de datos del sistema web de Bordados Wanka (tienda de polleras, fajas y chalecos bordados, Huancayo). Migrada de PostgreSQL a **MySQL 8.4 LTS**, auditada y completada para que la aplicación Django se construya encima, sprint por sprint.

**Estado:** se instala sin errores por consola y por phpMyAdmin; **299/299 pruebas ✔**; 7 escenarios de concurrencia probados con sesiones en paralelo; permisos verificados con cuentas reales de cada rol; copia de seguridad y restauración probadas. Pasó una revisión de errores en dos rondas (ver [COMPARATIVA §10](docs/COMPARATIVA_Y_CAMBIOS.md)).

## Inicio rápido (local con Docker)

Requisito: Docker Desktop. En una máquina nueva, cree primero su `.env` (no viaja con el proyecto porque guarda la clave de root) y ponga una clave propia en `MYSQL_ROOT_PASSWORD`:
```bash
cp .env.ejemplo .env
```
```bash
docker compose up -d
```
```bash
./scripts/instalar.sh
```
phpMyAdmin en <http://localhost:8080> (usuario `root`, clave en `.env`). Sin Docker o con phpMyAdmin propio: ver [docs/LEEME_INSTALACION.md](docs/LEEME_INSTALACION.md).

## Contenido

| Ruta | Qué es |
|---|---|
| `sql/00…08_*.sql` | Scripts numerados, re-ejecutables, en orden |
| `sql/99_pruebas.sql` | Pruebas ✔/✘ (solo sobre `bordados_wanka_test`) |
| `sql/07b_permisos_django_post_migrate.sql` | Permisos de las tablas propias de Django (después de `migrate`) |
| `scripts/instalar.sh` | Instala (`--reiniciar` desde cero, `--pruebas` crea la base de pruebas y corre 99) |
| `scripts/prueba_concurrencia.sh` | Prueba real de concurrencia (último ítem, doble clic, dos administradores, códigos, misma variante sin deadlocks, pagos simultáneos) |
| `scripts/generar_documentacion.py` | Regenera el diccionario y el diagrama ER desde la base |
| [docs/LEEME_INSTALACION.md](docs/LEEME_INSTALACION.md) | Instalación, cuentas, Django, pruebas, copias de seguridad, MariaDB |
| [docs/COMPARATIVA_Y_CAMBIOS.md](docs/COMPARATIVA_Y_CAMBIOS.md) | Original vs. nuevo, hallazgos de la auditoría, decisiones de diseño y la revisión de errores (§10) |
| [docs/DICCIONARIO_DE_DATOS.md](docs/DICCIONARIO_DE_DATOS.md) | Cada tabla y columna con tipo, restricciones y referencia a requisitos |
| [docs/DIAGRAMA_ER.md](docs/DIAGRAMA_ER.md) | Diagrama entidad-relación por módulos (Mermaid) |
| [docs/TRAZABILIDAD_HU_RF_RNF.md](docs/TRAZABILIDAD_HU_RF_RNF.md) | Requisitos → tablas, procedimientos, triggers, vistas y eventos |
| [docs/DECISIONES_ABIERTAS.md](docs/DECISIONES_ABIERTAS.md) | Lo que falta confirmar (SUNAT, INDECOPI, gerente) y discrepancias con el Excel |
| `docs/original_postgresql_tienda.sql`, `docs/PROMPT_ORIGINAL.md` | Insumos recibidos |

## En una línea

64 tablas · 42 vistas · 149 procedimientos (108 públicos) · 30 funciones · 161 triggers · 5 eventos · 4 roles. Flujos críticos en procedimientos con transacción; triggers como red de seguridad; eliminar = inhabilitar; fechas en UTC y reportes en hora de Lima; datos personales enmascarados; sin contraseñas ni secretos en el código.

> El Excel de requerimientos y el script `bordadosdb_login.sql` no se recibieron: el módulo de acceso se reconstruyó según el prompt y la trazabilidad numerada queda marcada para completar con el Excel.
