-- =====================================================================
-- BORDADOS WANKA S.A.C. — 07_roles_permisos.sql
-- ---------------------------------------------------------------------
-- Propósito : mínimo privilegio con roles de MySQL 8.
--   rol_app_tienda        aplicación pública (clientes): lee catálogo y sus
--                         datos, escribe SOLO vía procedimientos. Sin DELETE.
--   rol_app_admin         panel de administración: lee las tablas (menos el
--                         secreto interno y el DNI completo de usuario), CRUD
--                         de catálogos (INSERT/UPDATE), el resto vía sp_*.
--                         EXECUTE solo sobre sp_* y fn_* públicos: los spi_*
--                         internos no se pueden llamar desde la app.
--                         "Eliminar" = inhabilitar (sp_inhabilitar_*). Sin DELETE.
--   rol_reportes          solo SELECT sobre vistas v_* (datos enmascarados).
--   rol_dba_mantenimiento único con borrado físico; NO lo usa la app.
--                         Aun así, los triggers exigen además
--                         SET @wanka_autorizo_borrado = 'SI-AUTORIZO' y lo auditan.
--                         Sin DROP: TRUNCATE (que no dispara triggers) queda
--                         bloqueado en todas las tablas, incluida la auditoría.
-- Usuarios  : se crean BLOQUEADOS y con contraseña aleatoria que nadie
--             conoce (no hay contraseñas en este script). Para habilitarlos:
--   ALTER USER 'wanka_tienda'@'localhost' IDENTIFIED BY '<CAMBIAR_CLAVE_TIENDA>' ACCOUNT UNLOCK;
--   ALTER USER 'wanka_admin'@'localhost'  IDENTIFIED BY '<CAMBIAR_CLAVE_ADMIN>'  ACCOUNT UNLOCK;
--   ALTER USER 'wanka_reportes'@'localhost' IDENTIFIED BY '<CAMBIAR_CLAVE_REPORTES>' ACCOUNT UNLOCK;
--   ALTER USER 'wanka_dba'@'localhost'    IDENTIFIED BY '<CAMBIAR_CLAVE_DBA>'    ACCOUNT UNLOCK;
--   (Con Docker la app se conecta desde otra IP: cree las cuentas con '%' o
--    con la IP de la red de Docker; ver LEEME_INSTALACION.md.)
-- Tablas de Django (sesiones, migraciones...): se crean con "migrate" DESPUÉS;
--   sus permisos van en 07b_permisos_django_post_migrate.sql.
-- Re-ejecutable: sí (IF NOT EXISTS; GRANT es idempotente; REVOKE IF EXISTS quita
--   permisos de versiones anteriores de este script).
-- COMPAT-MARIADB: roles y IDENTIFIED BY RANDOM PASSWORD tienen otra sintaxis.
-- =====================================================================
USE bordados_wanka;

CREATE ROLE IF NOT EXISTS rol_app_tienda, rol_app_admin, rol_reportes, rol_dba_mantenimiento;

-- Permisos de versiones anteriores que ya no corresponden (sin error si no existen)
REVOKE IF EXISTS SELECT, EXECUTE, SHOW VIEW ON bordados_wanka.* FROM rol_app_admin;
REVOKE IF EXISTS UPDATE ON bordados_wanka.pedido           FROM rol_app_admin;
REVOKE IF EXISTS UPDATE ON bordados_wanka.envio            FROM rol_app_admin;
REVOKE IF EXISTS UPDATE ON bordados_wanka.reclamo          FROM rol_app_admin;
REVOKE IF EXISTS UPDATE ON bordados_wanka.mensaje_contacto FROM rol_app_admin;
REVOKE IF EXISTS SELECT, UPDATE ON bordados_wanka.usuario  FROM rol_app_admin;
REVOKE IF EXISTS SELECT, UPDATE ON bordados_wanka.usuario  FROM rol_app_tienda;
REVOKE IF EXISTS SELECT ON bordados_wanka.consulta_documento FROM rol_app_tienda;
REVOKE IF EXISTS EXECUTE ON PROCEDURE bordados_wanka.sp_cambiar_estado_pedido FROM rol_app_tienda;

-- ---------------------------------------------------------------------
-- rol_app_tienda
-- ---------------------------------------------------------------------
-- Lectura (Django filtra por el usuario autenticado; MySQL no tiene seguridad por fila)
GRANT SELECT ON bordados_wanka.categoria             TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.producto              TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.variante_producto     TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.imagen_producto       TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.precio_volumen        TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.zona_envio            TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.banner                TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.metodo_pago           TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.estado_pedido         TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.transicion_estado_pedido TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.courier               TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.configuracion         TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.catalogo_error        TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.rol                   TO rol_app_tienda;
-- usuario: SELECT por columnas (todas menos numero_documento) al final del script
GRANT SELECT ON bordados_wanka.autenticacion_2fa     TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.direccion             TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.carrito               TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.item_carrito          TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.favorito              TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.pedido                TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.item_pedido           TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.historial_estado_pedido TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.pago                  TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.comprobante           TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.comprobante_item      TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.cotizacion            TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.item_cotizacion       TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.envio                 TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.seguimiento_envio     TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.devolucion            TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.notificacion          TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.resena                TO rol_app_tienda;
-- consulta_documento (caché RENIEC/SUNAT): solo un documento exacto con sp_obtener_consulta_documento
GRANT SELECT ON bordados_wanka.v_catalogo_productos  TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_variantes_disponibles TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_precios_volumen     TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_banners_vigentes    TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_resenas_publicadas  TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_pedidos_estado      TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_pedido_detalle      TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_historial_pedido    TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_transiciones_pedido TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_cotizaciones        TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_envios_seguimiento  TO rol_app_tienda;
GRANT SELECT ON bordados_wanka.v_historial_contrasena_reciente TO rol_app_tienda;
-- Escritura directa mínima: nombre y celular del perfil, y direcciones (los triggers protegen el resto)
GRANT UPDATE (nombres, apellidos, celular) ON bordados_wanka.usuario TO rol_app_tienda;
GRANT INSERT, UPDATE ON bordados_wanka.direccion     TO rol_app_tienda;
-- Funciones útiles para mostrar precios y fechas
GRANT EXECUTE ON FUNCTION bordados_wanka.fn_precio_unitario TO rol_app_tienda;
GRANT EXECUTE ON FUNCTION bordados_wanka.fn_hoy_lima        TO rol_app_tienda;
GRANT EXECUTE ON FUNCTION bordados_wanka.fn_utc_a_lima      TO rol_app_tienda;
GRANT EXECUTE ON FUNCTION bordados_wanka.fn_igv_incluido    TO rol_app_tienda;
GRANT EXECUTE ON FUNCTION bordados_wanka.fn_documento_valido TO rol_app_tienda;
-- Procedimientos del cliente
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_usuario            TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_intento_acceso     TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_segundo_factor     TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_abrir_sesion                 TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cerrar_sesion                TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cerrar_sesiones_usuario      TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_generar_codigo_verificacion  TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_verificar_codigo             TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cambiar_contrasena           TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cambiar_correo               TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_configurar_2fa               TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_confirmar_2fa                TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_desactivar_2fa               TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_generar_codigos_respaldo_2fa TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_usar_codigo_respaldo_2fa     TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_consentimiento     TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_solicitud_arco     TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_ver_documento_completo       TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_actualizar_documento_usuario TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_inhabilitar_direccion        TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_reactivar_direccion          TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_definir_direccion_predeterminada TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_agregar_item_carrito         TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_quitar_item_carrito          TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_alternar_favorito            TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_crear_pedido                 TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_agregar_item                 TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_quitar_item                  TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_definir_modalidad_pago       TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cancelar_pedido              TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_crear_pedido_complementario  TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_corregir_facturacion_pedido  TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_anular_pago_pendiente        TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_solicitar_cotizacion         TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_cambiar_estado_cotizacion    TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_aceptar_cotizacion           TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_pago               TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_evento_pasarela    TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_procesar_pago_pasarela       TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_mensaje_contacto   TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_reclamo            TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_resena             TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_marcar_notificacion_leida    TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_registrar_log_api            TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_guardar_consulta_documento   TO rol_app_tienda;
GRANT EXECUTE ON PROCEDURE bordados_wanka.sp_obtener_consulta_documento   TO rol_app_tienda;

-- ---------------------------------------------------------------------
-- rol_app_admin
-- ---------------------------------------------------------------------
-- SELECT por tabla y EXECUTE explícito sobre sp_*/fn_*: ver el procedimiento al final del script
-- CRUD de catálogos (sin DELETE: "eliminar" = sp_inhabilitar_*/sp_reactivar_*)
GRANT INSERT, UPDATE ON bordados_wanka.categoria        TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.producto         TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.variante_producto TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.imagen_producto  TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.precio_volumen   TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.insumo           TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.receta_producto  TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.zona_envio       TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.courier          TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.banner           TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.serie_comprobante TO rol_app_admin;
GRANT UPDATE         ON bordados_wanka.metodo_pago      TO rol_app_admin;
GRANT INSERT, UPDATE ON bordados_wanka.direccion        TO rol_app_admin;
GRANT UPDATE         ON bordados_wanka.notificacion     TO rol_app_admin;
-- Edición directa solo de columnas informativas; estados, montos, fechas del ciclo de vida, reclamos y
-- mensajes de contacto cambian únicamente con sus procedimientos (los triggers lo exigen además)
GRANT UPDATE (nombres, apellidos, celular) ON bordados_wanka.usuario TO rol_app_admin;
GRANT UPDATE (fecha_entrega_estimada)      ON bordados_wanka.pedido  TO rol_app_admin;
GRANT UPDATE (id_courier, numero_guia, costo_real, fecha_entrega_estimada, observaciones) ON bordados_wanka.envio TO rol_app_admin;

-- ---------------------------------------------------------------------
-- rol_reportes: solo vistas (sin la copia completa de comprobantes ni hashes)
-- ---------------------------------------------------------------------
GRANT SELECT ON bordados_wanka.v_catalogo_productos       TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_variantes_disponibles    TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_precios_volumen          TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_pedidos_estado           TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_resumen_estados_pedido   TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_pedido_detalle           TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_historial_pedido         TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_kardex                   TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_kardex_insumos           TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_reservas_activas         TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_stock_bajo               TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_insumos_stock_bajo       TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_pagos_por_validar        TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_pagos_por_reembolsar     TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_reembolsos               TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_ingresos_diarios         TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_ventas_diarias           TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_ventas_por_categoria     TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_productos_mas_vendidos   TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_clientes_resumen         TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_comprobantes             TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_comprobante_items        TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_notas_credito_saldo      TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_cola_emision             TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_cotizaciones             TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_envios_seguimiento       TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_mensajes_contacto_pendientes TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_reclamos_pendientes      TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_solicitudes_arco_pendientes TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_usuarios                 TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_administradores_sin_2fa  TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_auditoria                TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_configuracion_por_verificar TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_correos_pendientes       TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_eventos_pasarela_con_error TO rol_reportes;
GRANT SELECT ON bordados_wanka.v_inconsistencias          TO rol_reportes;

-- ---------------------------------------------------------------------
-- rol_dba_mantenimiento (fuera de la app)
-- ---------------------------------------------------------------------
GRANT ALL PRIVILEGES ON bordados_wanka.* TO rol_dba_mantenimiento;
REVOKE DROP ON bordados_wanka.* FROM rol_dba_mantenimiento;   -- TRUNCATE exige DROP y no dispara los triggers de borrado

-- ---------------------------------------------------------------------
-- Cuentas (bloqueadas hasta que el administrador fije su contraseña)
-- ---------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'wanka_tienda'@'localhost'   IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK;
CREATE USER IF NOT EXISTS 'wanka_admin'@'localhost'    IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK;
CREATE USER IF NOT EXISTS 'wanka_reportes'@'localhost' IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK;
CREATE USER IF NOT EXISTS 'wanka_dba'@'localhost'      IDENTIFIED BY RANDOM PASSWORD ACCOUNT LOCK;
GRANT rol_app_tienda        TO 'wanka_tienda'@'localhost';
GRANT rol_app_admin         TO 'wanka_admin'@'localhost';
GRANT rol_reportes          TO 'wanka_reportes'@'localhost';
GRANT rol_dba_mantenimiento TO 'wanka_dba'@'localhost';
SET DEFAULT ROLE rol_app_tienda        TO 'wanka_tienda'@'localhost';
SET DEFAULT ROLE rol_app_admin         TO 'wanka_admin'@'localhost';
SET DEFAULT ROLE rol_reportes          TO 'wanka_reportes'@'localhost';
SET DEFAULT ROLE rol_dba_mantenimiento TO 'wanka_dba'@'localhost';

-- ---------------------------------------------------------------------
-- Permisos que dependen de la lista real de tablas, columnas y rutinas
-- ---------------------------------------------------------------------
--   rol_app_admin : SELECT en cada tabla/vista salvo secreto_interno; SHOW VIEW en las vistas;
--                   EXECUTE solo en sp_* y fn_* (nunca spi_*, fn_token_interno ni sp_redactar_log_api).
--   usuario       : SELECT por columnas sin numero_documento para tienda y admin (el documento
--                   completo se lee con sp_ver_documento_completo, que deja constancia).
DELIMITER $$
DROP PROCEDURE IF EXISTS tmp_wanka_conceder_permisos $$
CREATE PROCEDURE tmp_wanka_conceder_permisos()
BEGIN
  DECLARE v_fin BOOLEAN DEFAULT 0;
  DECLARE v_sql VARCHAR(2000);
  DECLARE c CURSOR FOR
    SELECT CONCAT('GRANT SELECT', IF(TABLE_TYPE = 'VIEW', ', SHOW VIEW', ''), ' ON `', TABLE_SCHEMA, '`.`', TABLE_NAME, '` TO rol_app_admin')
      FROM information_schema.TABLES
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME NOT IN ('secreto_interno','usuario')
    UNION ALL
    SELECT CONCAT('GRANT SELECT (', GROUP_CONCAT(CONCAT('`', c.COLUMN_NAME, '`') ORDER BY c.ORDINAL_POSITION SEPARATOR ', '),
                  ') ON `', DATABASE(), '`.`usuario` TO ', r.rol)
      FROM information_schema.COLUMNS c
      CROSS JOIN (SELECT 'rol_app_admin' AS rol UNION ALL SELECT 'rol_app_tienda') r
     WHERE c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = 'usuario' AND c.COLUMN_NAME <> 'numero_documento'
     GROUP BY r.rol
    UNION ALL
    SELECT CONCAT('GRANT EXECUTE ON ', ROUTINE_TYPE, ' `', ROUTINE_SCHEMA, '`.`', ROUTINE_NAME, '` TO rol_app_admin')
      FROM information_schema.ROUTINES
     WHERE ROUTINE_SCHEMA = DATABASE()
       AND ((ROUTINE_TYPE = 'PROCEDURE' AND ROUTINE_NAME LIKE 'sp\_%' AND ROUTINE_NAME <> 'sp_redactar_log_api')
         OR (ROUTINE_TYPE = 'FUNCTION' AND ROUTINE_NAME LIKE 'fn\_%' AND ROUTINE_NAME <> 'fn_token_interno'));
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fin = 1;
  SET SESSION group_concat_max_len = 8192;
  OPEN c;
  bucle: LOOP
    FETCH c INTO v_sql;
    IF v_fin THEN LEAVE bucle; END IF;
    SET @wanka_sql_permiso = v_sql;
    PREPARE st FROM @wanka_sql_permiso;
    EXECUTE st;
    DEALLOCATE PREPARE st;
  END LOOP bucle;
  CLOSE c;
  SET @wanka_sql_permiso = NULL;
END $$
DELIMITER ;
CALL tmp_wanka_conceder_permisos();
DROP PROCEDURE IF EXISTS tmp_wanka_conceder_permisos;

SELECT 'Roles y permisos listos: continúa con 08_datos_iniciales.sql' AS siguiente_paso;
