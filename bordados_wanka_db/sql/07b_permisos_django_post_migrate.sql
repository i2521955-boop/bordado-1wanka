-- =====================================================================
-- BORDADOS WANKA S.A.C. — 07b_permisos_django_post_migrate.sql  (OPCIONAL)
-- ---------------------------------------------------------------------
-- Ejecutar SOLO después de "python manage.py migrate" (lo corre una cuenta
-- con permisos DDL, p. ej. wanka_dba). MySQL no permite dar permisos de
-- DML sobre tablas que aún no existen, por eso este archivo va aparte.
-- Las tablas de negocio de este esquema se declaran en Django con
-- managed = False (las define este SQL, no las migraciones).
-- Ajusta la lista a las apps de Django que realmente instales.
-- =====================================================================
USE bordados_wanka;

GRANT SELECT, INSERT, UPDATE, DELETE ON bordados_wanka.django_session      TO rol_app_tienda, rol_app_admin;
GRANT SELECT                         ON bordados_wanka.django_content_type TO rol_app_tienda, rol_app_admin;
GRANT SELECT                         ON bordados_wanka.django_migrations   TO rol_app_tienda, rol_app_admin;
GRANT SELECT                         ON bordados_wanka.auth_permission     TO rol_app_tienda, rol_app_admin;
-- Si usan django.contrib.admin:
-- GRANT SELECT, INSERT ON bordados_wanka.django_admin_log TO rol_app_admin;
