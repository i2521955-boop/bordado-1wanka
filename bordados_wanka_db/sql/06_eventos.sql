-- =====================================================================
-- BORDADOS WANKA S.A.C. — 06_eventos.sql
-- ---------------------------------------------------------------------
-- Propósito : tareas programadas (reemplazan pg_cron).
-- Requisito : event_scheduler = ON (ver 00_requisitos_y_entorno.sql y
--             LEEME_INSTALACION.md). Comprobar con:  SHOW VARIABLES LIKE 'event_scheduler';
-- Horarios  : en UTC (la sesión de instalación usa time_zone '+00:00').
--             08:00 UTC = 03:00 Lima; 05:10 UTC = 00:10 Lima.
-- Re-ejecutable: sí (DROP EVENT IF EXISTS).
-- =====================================================================
USE bordados_wanka;
SET SESSION time_zone = '+00:00';

DROP EVENT IF EXISTS ev_expirar_pedidos;
CREATE DEFINER=`wanka_definer`@`localhost` EVENT ev_expirar_pedidos
  ON SCHEDULE EVERY 5 MINUTE STARTS (UTC_TIMESTAMP() + INTERVAL 1 MINUTE)
  ON COMPLETION PRESERVE ENABLE
  COMMENT 'Cancela pedidos sin pago vencidos (horas_reserva_pedido) y libera su stock'
  DO CALL sp_expirar_pedidos_pendientes(@ev_pedidos_cancelados);

DROP EVENT IF EXISTS ev_expirar_codigos;
CREATE DEFINER=`wanka_definer`@`localhost` EVENT ev_expirar_codigos
  ON SCHEDULE EVERY 1 MINUTE STARTS (UTC_TIMESTAMP() + INTERVAL 1 MINUTE)
  ON COMPLETION PRESERVE ENABLE
  COMMENT 'Marca como expirados los códigos de verificación vencidos (la verificación igual valida expira_en)'
  DO CALL sp_expirar_codigos_verificacion(@ev_codigos_expirados);

DROP EVENT IF EXISTS ev_vencer_cotizaciones;
CREATE DEFINER=`wanka_definer`@`localhost` EVENT ev_vencer_cotizaciones
  ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(UTC_DATE()) + INTERVAL 1 DAY + INTERVAL 310 MINUTE)
  ON COMPLETION PRESERVE ENABLE
  COMMENT '00:10 Lima: cotizaciones cuya vigencia terminó pasan a vencida'
  DO CALL sp_vencer_cotizaciones(@ev_cotizaciones_vencidas);

DROP EVENT IF EXISTS ev_mantenimiento_diario;
CREATE DEFINER=`wanka_definer`@`localhost` EVENT ev_mantenimiento_diario
  ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(UTC_DATE()) + INTERVAL 1 DAY + INTERVAL 8 HOUR)
  ON COMPLETION PRESERVE ENABLE
  COMMENT '03:00 Lima: carritos abandonados, sesiones vencidas y purga por retención de datos temporales'
  DO CALL sp_mantenimiento_diario();

DROP EVENT IF EXISTS ev_alertar_vencimientos;
CREATE DEFINER=`wanka_definer`@`localhost` EVENT ev_alertar_vencimientos
  ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(UTC_DATE()) + INTERVAL 1 DAY + INTERVAL 13 HOUR)
  ON COMPLETION PRESERVE ENABLE
  COMMENT '08:00 Lima: avisa reclamos y solicitudes ARCO por vencer'
  DO CALL sp_alertar_vencimientos();

SELECT EVENT_NAME, STATUS, INTERVAL_VALUE, INTERVAL_FIELD, STARTS FROM information_schema.EVENTS WHERE EVENT_SCHEMA = DATABASE();
SELECT @@event_scheduler AS event_scheduler, 'Si dice OFF, actívelo (ver LEEME_INSTALACION.md)' AS nota;
SELECT 'Eventos listos: continúa con 07_roles_permisos.sql' AS siguiente_paso;
