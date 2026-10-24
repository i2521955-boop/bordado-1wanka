-- =====================================================================
-- BORDADOS WANKA S.A.C. — Base de datos MySQL
-- 00_requisitos_y_entorno.sql
-- ---------------------------------------------------------------------
-- Propósito : comprobar el motor, fijar el modo estricto, crear la base
--             y la cuenta técnica dueña de procedimientos, triggers,
--             vistas y eventos (sin inicio de sesión).
-- Ejecutar  : PRIMERO, como root (o una cuenta con CREATE USER, GRANT,
--             SET_ANY_DEFINER / SET_USER_ID y SYSTEM_VARIABLES_ADMIN).
-- Re-ejecutable: sí (IF NOT EXISTS en todo).
-- Orden completo: 00 → 01 → 02 → 03 → 04 → 05 → 06 → 07 → 08 (→ 99 solo en pruebas)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Verificación del motor
-- ---------------------------------------------------------------------
-- Objetivo: MySQL 8.0.16+ (recomendado 8.4 LTS). Si VERSION() contiene
-- "MariaDB" (XAMPP / WAMP suelen traer MariaDB), revisa la sección
-- COMPAT-MARIADB de LEEME_INSTALACION.md antes de seguir. En resumen,
-- en MariaDB dejan de funcionar o cambian:
--   * REGEXP_LIKE(..., 'c') de los CHECK              -- COMPAT-MARIADB: usar  col REGEXP BINARY '...'
--   * Valores por defecto con expresión (UTC_TIMESTAMP(3)) -- soportado desde 10.2
--   * RANDOM_BYTES()                                  -- existe desde MariaDB 10.10
--   * CREATE ROLE / SET DEFAULT ROLE / IDENTIFIED BY RANDOM PASSWORD -- sintaxis distinta
--   * JSON es alias de LONGTEXT (sin validación binaria; se agrega CHECK JSON_VALID)
--   * SKIP LOCKED                                     -- desde 10.6
--   * Colación utf8mb4_0900_ai_ci                     -- no existe: usar utf8mb4_unicode_520_ci / uca1400_ai_ci (11.x)
SELECT VERSION() AS version_servidor,
       CASE
         WHEN VERSION() LIKE '%MariaDB%' THEN 'ATENCIÓN: es MariaDB. El script está hecho para MySQL 8. Ver COMPAT-MARIADB en LEEME_INSTALACION.md'
         WHEN CAST(SUBSTRING_INDEX(VERSION(), '.', 1) AS UNSIGNED) < 8 THEN 'ERROR: se requiere MySQL 8.0.16 o superior'
         ELSE 'OK: MySQL 8 detectado'
       END AS diagnostico;

-- ---------------------------------------------------------------------
-- 2. Modo estricto y zona horaria de ESTA sesión de instalación
-- ---------------------------------------------------------------------
-- Todas las fechas se guardan en UTC. La sesión de instalación usa UTC
-- para que los horarios de los eventos (06) queden en UTC.
SET SESSION sql_mode = 'STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,ONLY_FULL_GROUP_BY,NO_ENGINE_SUBSTITUTION';
SET SESSION time_zone = '+00:00';
SET NAMES utf8mb4 COLLATE utf8mb4_0900_ai_ci;

-- Recomendado también a nivel servidor (my.cnf / my.ini, sección [mysqld]):
--   sql_mode = STRICT_TRANS_TABLES,NO_ZERO_DATE,NO_ZERO_IN_DATE,ERROR_FOR_DIVISION_BY_ZERO,ONLY_FULL_GROUP_BY,NO_ENGINE_SUBSTITUTION
--   character-set-server = utf8mb4
--   collation-server     = utf8mb4_0900_ai_ci
--   default-time-zone    = '+00:00'
--   event_scheduler      = ON

-- ---------------------------------------------------------------------
-- 3. Programador de eventos (expiración de pedidos, códigos, limpieza)
-- ---------------------------------------------------------------------
-- En MySQL 8 viene encendido por defecto. Esta línea lo enciende hasta el
-- próximo reinicio; para que sea permanente usa my.cnf o SET PERSIST.
-- Requiere SYSTEM_VARIABLES_ADMIN (root lo tiene).
SET GLOBAL event_scheduler = ON;

-- ---------------------------------------------------------------------
-- 4. Base de datos
-- ---------------------------------------------------------------------
-- Para empezar desde cero en desarrollo (BORRA TODO), descomenta:
-- DROP DATABASE IF EXISTS bordados_wanka;
CREATE DATABASE IF NOT EXISTS bordados_wanka
  CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;

-- ---------------------------------------------------------------------
-- 5. Cuenta técnica dueña de la lógica (DEFINER)
-- ---------------------------------------------------------------------
-- 'wanka_definer' es el DEFINER de procedimientos, funciones, triggers,
-- vistas y eventos. Está BLOQUEADA (ACCOUNT LOCK): nadie puede iniciar
-- sesión con ella; solo sirve como contexto de seguridad de los objetos
-- con SQL SECURITY DEFINER. Así la aplicación no necesita permisos
-- directos sobre las tablas críticas: solo EXECUTE sobre los sp_*.
-- No lleva contraseña en el script (ver LEEME_INSTALACION.md).
CREATE USER IF NOT EXISTS 'wanka_definer'@'localhost' ACCOUNT LOCK;
ALTER USER 'wanka_definer'@'localhost' ACCOUNT LOCK;

-- Privilegios de ejecución de la lógica. DELETE es necesario solo para
-- tablas temporales (sesiones, códigos, colas, carrito); en las tablas de
-- negocio un trigger bloquea el DELETE físico para todos (ver 04).
-- CREATE TEMPORARY TABLES: tablas de trabajo de sp_devolver_pedido y de los códigos de respaldo 2FA.
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE, TRIGGER, EVENT, SHOW VIEW, CREATE TEMPORARY TABLES
   ON bordados_wanka.* TO 'wanka_definer'@'localhost';

USE bordados_wanka;

SELECT 'Entorno listo: continúa con 01_esquema_acceso.sql' AS siguiente_paso;
