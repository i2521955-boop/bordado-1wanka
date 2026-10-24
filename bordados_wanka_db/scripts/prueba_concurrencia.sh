#!/usr/bin/env bash
# Uso: ./scripts/prueba_concurrencia.sh   (después de ./scripts/instalar.sh --pruebas)
# Prueba de concurrencia real con sesiones paralelas sobre bordados_wanka_test
set -u
cd "$(dirname "$0")/.."   # raíz del proyecto, esté donde esté
set -a; . ./.env; set +a
Q() { docker exec -i -e MYSQL_PWD="$MYSQL_ROOT_PASSWORD" wanka-mysql mysql -uroot --default-character-set=utf8mb4 -N bordados_wanka_test "$@" 2>&1; }
ADMIN=$(Q -e "SELECT u.id_usuario FROM usuario u JOIN rol r ON r.id_rol=u.id_rol WHERE r.codigo='administrador' LIMIT 1")
PROD=$(Q -e "SELECT id_producto FROM producto WHERE slug='pollera-bordada-wanka'")
# Variante nueva con stock 1 y 6 clientes activos
VAR=$(Q -e "SET @app_actor_id=$ADMIN; INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES ($PROD, 'POL-CONC-$$', 'S$$', 'Verde'); SELECT LAST_INSERT_ID();")
Q -e "SET @app_actor_id=$ADMIN; CALL sp_ajustar_stock($VAR, 'ingreso', 1, 'Prueba de concurrencia', @s);"
PEPPER='pepper-solo-para-pruebas-0123456789'
RED="10.$(( ($$ / 250) % 250 )).$(( $$ % 250 ))"   # IP de prueba distinta en cada corrida (los cupos por IP no se acumulan)
CLIS=()
for i in 1 2 3 4 5 6; do
  # Alta normal: registro + verificación del correo con código (la cuenta se activa por procedimiento)
  C=$(Q -e "SET @app_actor_id=NULL; SET @app_ip='$RED.$i'; SET @hash='pbkdf2_sha256\$600000\$s\$QUJDREVGR0hJSktMTU5PUFFSU1RVVldYWVo=';
            CALL sp_registrar_usuario('conc$i.$$@correo.pe', @hash, 'Cliente', 'Concurrente', NULL, '1.0', 0, @id);
            CALL sp_generar_codigo_verificacion(@id, 'conc$i.$$@correo.pe', 'verificar_correo', '$PEPPER', @c, @x, @idc);
            CALL sp_verificar_codigo('conc$i.$$@correo.pe', 'verificar_correo', @c, '$PEPPER', @r, @rest, @u);
            SELECT @id;" | tail -1)
  CLIS+=("$C")
done
echo "C1. Seis clientes compran a la vez la ÚLTIMA unidad (stock 1):"
for C in "${CLIS[@]}"; do
  ( Q -e "SET @app_actor_id=$C; CALL sp_crear_pedido($C, '[{\"id_variante\":$VAR,\"cantidad\":1}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p, @n, @t); SELECT CONCAT('OK ', @n);" | tail -1 ) &
done
wait
echo "   → stock final: $(Q -e "SELECT CONCAT('actual=', stock_actual, ' reservado=', stock_reservado, ' disponible=', stock_disponible) FROM variante_producto WHERE id_variante=$VAR")"
echo "   → pedidos creados con esa variante: $(Q -e "SELECT COUNT(*) FROM item_pedido WHERE id_variante=$VAR")"

C=${CLIS[0]}
PED=$(Q -e "SELECT p.id_pedido FROM pedido p JOIN item_pedido i ON i.id_pedido=p.id_pedido WHERE i.id_variante=$VAR LIMIT 1")
DUENO=$(Q -e "SELECT id_usuario FROM pedido WHERE id_pedido=$PED")
TOTAL=$(Q -e "SELECT total FROM pedido WHERE id_pedido=$PED")
echo "C2. Doble clic: 5 llamadas simultáneas a sp_registrar_pago con la misma clave:"
for i in 1 2 3 4 5; do
  ( Q -e "SET @app_actor_id=$DUENO; CALL sp_registrar_pago($PED, 'yape', $TOTAL, 'idem-concurrencia-$$-0001', 'OP-CONC-$$', NULL, NULL, NULL, NULL, NULL, @pg, @e, @d); SELECT CONCAT('pago=', @pg, ' duplicado=', @d);" | tail -1 ) &
done
wait
echo "   → pagos registrados para el pedido: $(Q -e "SELECT COUNT(*) FROM pago WHERE id_pedido=$PED")"
PG=$(Q -e "SELECT id_pago FROM pago WHERE id_pedido=$PED")
echo "C4. Dos administradores validan el mismo voucher a la vez:"
for i in 1 2; do
  ( Q -e "SET @app_actor_id=$ADMIN; CALL sp_confirmar_pago_manual($PG, @e); SELECT CONCAT('confirmado, pedido=', @e);" | tail -1 ) &
done
wait
echo "   → estado del pago: $(Q -e "SELECT estado FROM pago WHERE id_pago=$PG"); pedido: $(Q -e "SELECT CONCAT(estado,'/',estado_pago) FROM pedido WHERE id_pedido=$PED")"
echo "C5. Siete solicitudes simultáneas de código para el mismo correo (límite 5/hora):"
C2=${CLIS[1]}
for i in 1 2 3 4 5 6 7; do
  ( Q -e "SET @app_actor_id=NULL; SET @app_ip='$RED.20'; CALL sp_generar_codigo_verificacion($C2, 'conc2.$$@correo.pe', 'iniciar_sesion', '$PEPPER', @c, @x, @id); SELECT 'código generado';" | tail -1 ) &
done
wait
echo "   → códigos de inicio de sesión: $(Q -e "SELECT COUNT(*) FROM codigo_verificacion WHERE id_usuario=$C2 AND proposito='iniciar_sesion'") (máx. 5); activos: $(Q -e "SELECT COUNT(*) FROM codigo_verificacion WHERE id_usuario=$C2 AND estado='activo'")"

echo "C6. Dos clientes agregan y quitan a la vez la MISMA variante 150 veces cada uno (antes: deadlock 1213):"
VARB=$(Q -e "SET @app_actor_id=$ADMIN; INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES ($PROD, 'POL-CONCB-$$', 'B$$', 'Azul'); SELECT LAST_INSERT_ID();")
VARA=$(Q -e "SET @app_actor_id=$ADMIN; INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES ($PROD, 'POL-CONCA-$$', 'A$$', 'Azul'); SELECT LAST_INSERT_ID();")
Q -e "SET @app_actor_id=$ADMIN; CALL sp_ajustar_stock($VARA, 'ingreso', 50, 'Prueba', @s); CALL sp_ajustar_stock($VARB, 'ingreso', 50, 'Prueba', @s);" >/dev/null
Q <<'SQL' >/dev/null
DROP PROCEDURE IF EXISTS tst_ciclo_item;
DELIMITER $$
CREATE PROCEDURE tst_ciclo_item(IN p_actor BIGINT UNSIGNED, IN p_pedido BIGINT UNSIGNED, IN p_var BIGINT UNSIGNED, IN p_veces INT,
                                OUT p_ok INT, OUT p_deadlocks INT, OUT p_otros INT)
BEGIN
  DECLARE i INT DEFAULT 0; DECLARE v_item BIGINT UNSIGNED; DECLARE v_err INT;
  SET p_ok = 0, p_deadlocks = 0, p_otros = 0, @app_actor_id = p_actor;
  WHILE i < p_veces DO
    SET v_err = 0;
    BEGIN
      DECLARE CONTINUE HANDLER FOR SQLEXCEPTION GET DIAGNOSTICS CONDITION 1 v_err = MYSQL_ERRNO;
      CALL sp_agregar_item(p_pedido, p_var, 1, NULL, @t);
      IF v_err = 0 THEN
        SELECT MAX(id_item_pedido) INTO v_item FROM item_pedido WHERE id_pedido = p_pedido AND id_variante = p_var AND estado = 'vigente';
        CALL sp_quitar_item(p_pedido, v_item, @t);
      END IF;
    END;
    IF v_err = 0 THEN SET p_ok = p_ok + 1; ELSEIF v_err = 1213 THEN SET p_deadlocks = p_deadlocks + 1; ELSE SET p_otros = p_otros + 1; END IF;
    SET i = i + 1;
  END WHILE;
END $$
DELIMITER ;
SQL
PEDS=()
for C in "${CLIS[2]}" "${CLIS[3]}"; do
  P=$(Q -e "SET @app_actor_id=$C; CALL sp_crear_pedido($C, '[{\"id_variante\":$VARA,\"cantidad\":1}]', 'recojo', NULL, 'total', 'boleta', NULL, NULL, NULL, NULL, NULL, NULL, 'web', @p, @n, @t); SELECT @p;" | tail -1)
  PEDS+=("$C:$P")
done
for CP in "${PEDS[@]}"; do
  ( C=${CP%%:*}; P=${CP##*:}; Q -e "CALL tst_ciclo_item($C, $P, $VARB, 150, @ok, @dl, @otros); SELECT CONCAT('cliente ', $C, ': ok=', @ok, ' deadlocks=', @dl, ' otros=', @otros);" | tail -1 ) &
done
wait
Q -e "DROP PROCEDURE IF EXISTS tst_ciclo_item;" >/dev/null
echo "   → stock de la variante: $(Q -e "SELECT CONCAT('actual=', stock_actual, ' reservado=', stock_reservado) FROM variante_producto WHERE id_variante=$VARB") (debe quedar reservado=0)"
echo "C7. Un adelanto por Yape y otro por pasarela se confirman a la vez mientras otra sesión retiene el pedido (REPEATABLE READ):"
VARC=$(Q -e "SET @app_actor_id=$ADMIN; INSERT INTO variante_producto (id_producto, sku, talla, color) VALUES ($PROD, 'POL-CONCC-$$', 'C$$', 'Rojo'); SELECT LAST_INSERT_ID();")
Q -e "SET @app_actor_id=$ADMIN; CALL sp_ajustar_stock($VARC, 'ingreso', 10, 'Prueba', @s);" >/dev/null
C7=${CLIS[4]}
PM=$(Q -e "SET @app_actor_id=$C7; SET @app_ip='$RED.30';
           CALL sp_crear_pedido($C7, '[{\"id_variante\":$VARC,\"cantidad\":6}]', 'recojo', NULL, 'adelanto', 'boleta', 'DNI', '41234567', 'Cliente Concurrente',
                                NULL, UTC_DATE() + INTERVAL 20 DAY, NULL, 'web', @p, @n, @t); SELECT @p;" | tail -1)
MITAD=$(Q -e "SELECT monto_requerido FROM pedido WHERE id_pedido=$PM")
Q -e "SET @app_actor_id=$C7; SET @app_ip='$RED.30';
      CALL sp_registrar_pago($PM, 'mercadopago', $MITAD, 'idem-c7-mp-$$-000001', NULL, NULL, NULL, NULL, NULL, NULL, @a, @b, @c);
      CALL sp_registrar_pago($PM, 'yape', $MITAD, 'idem-c7-yape-$$-00001', 'OP-C7-$$', NULL, NULL, NULL, NULL, NULL, @a, @b, @c);
      CALL sp_registrar_evento_pasarela('mercadopago', 'mp-c7-$$', 'payment.updated', '{\"id\":\"c7\"}', 1, @ev, @pr);" >/dev/null
PGY=$(Q -e "SELECT id_pago FROM pago WHERE id_pedido=$PM AND metodo='yape'")
EV=$(Q -e "SELECT id_evento FROM evento_pasarela WHERE id_externo='mp-c7-$$'")
( Q -e "START TRANSACTION; SELECT id_pedido FROM pedido WHERE id_pedido=$PM FOR UPDATE; DO SLEEP(2); COMMIT;" >/dev/null ) &
sleep 0.3
( Q -e "SET @app_actor_id=$ADMIN; CALL sp_confirmar_pago_manual($PGY, @e); SELECT CONCAT('Yape confirmado, pedido=', @e);" | tail -1 ) &
( Q -e "SET @app_actor_id=NULL; CALL sp_procesar_pago_pasarela($EV, 'mercadopago', 'idem-c7-mp-$$-000001', 'MP-C7-$$', 'aprobado', $MITAD, NULL, NULL, NULL, NULL, @r); SELECT CONCAT('webhook: ', @r);" | tail -1 ) &
wait
echo "   → pedido: $(Q -e "SELECT CONCAT('total=', total, ' pagado=', monto_pagado, ' estado_pago=', estado_pago, ' saldo=', saldo) FROM pedido WHERE id_pedido=$PM") (debe quedar pagado y saldo 0)"
echo "   → inconsistencias globales: $(Q -e "SELECT COUNT(*) FROM v_inconsistencias")"
