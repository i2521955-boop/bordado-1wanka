#!/usr/bin/env python3
"""
Genera docs/DICCIONARIO_DE_DATOS.md y docs/DIAGRAMA_ER.md leyendo information_schema
de la base instalada, para que la documentación coincida siempre con el SQL.

Uso:  python3 -I scripts/generar_documentacion.py            (base bordados_wanka)
Conexión: contenedor Docker "wanka-mysql" (clave de root en .env) o, si no existe,
el cliente "mysql" local con MYSQL_HOST/MYSQL_PORT/MYSQL_USER y MYSQL_PWD.
"""
import os
import re
import subprocess
import sys
from collections import OrderedDict, defaultdict

RAIZ = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASE = sys.argv[1] if len(sys.argv) > 1 else "bordados_wanka"

# ---------------------------------------------------------------------------
# Módulos y referencias a requisitos. Las referencias "§" apuntan al prompt
# (docs/PROMPT_ORIGINAL.md). Los códigos HU/RF/RNF son los citados en el prompt
# o en el script original; el resto debe completarse con el Excel (no recibido).
# ---------------------------------------------------------------------------
MODULOS = OrderedDict([
    ("Acceso y seguridad", OrderedDict([
        ("rol", "§1 roles administrador/cliente; §6"),
        ("usuario", "§4 acceso; §2.4 validación de documentos; §2.6 inhabilitar; Ley 29733"),
        ("sesion", "§4 acceso (sesiones y cierre remoto)"),
        ("intento_acceso", "§6 bloqueo tras 5 intentos (15 min)"),
        ("codigo_verificacion", "§2.7 códigos por correo; HU-02 (Excel dice 10 min, se aplica 5)"),
        ("historial_contrasena", "§4 no reutilizar las últimas 3"),
        ("autenticacion_2fa", "§4 TOTP obligatorio para administradores"),
        ("codigo_respaldo_2fa", "§4 2FA"),
        ("consentimiento_datos", "§4 consentimiento (Ley 29733)"),
        ("solicitud_arco", "§4 derechos ARCO (Ley 29733)"),
        ("auditoria", "§4 auditoría inmutable, retención >= 12 meses; §2.5"),
        ("secreto_interno", "Seguridad: marca de contexto interno no falsificable (solo la leen los procedimientos)"),
    ])),
    ("Sistema e integraciones", OrderedDict([
        ("configuracion", "§4 sistema; §2.2 adelanto; §2.7 minutos del código; §2.8 umbral de boleta"),
        ("secuencia_documento", "§5.10-11 correlativos sin saltos"),
        ("catalogo_error", "§3.1 SIGNAL con códigos propios; RNF 20"),
        ("control_frecuencia", "§5.10 límites de frecuencia; §7.12 concurrencia"),
        ("cola_correo", "§2.7 envío de correos; RNF 18"),
        ("notificacion", "§5.7 avisos al cliente"),
        ("log_api_externa", "§2.10 bitácora de APIs externas"),
        ("consulta_documento", "§2.10 caché RENIEC/SUNAT"),
    ])),
    ("Catálogo", OrderedDict([
        ("categoria", "§4 catálogo"),
        ("producto", "§4 catálogo; búsqueda FULLTEXT; §2.6 archivar"),
        ("variante_producto", "§4 catálogo e inventario"),
        ("imagen_producto", "§4 catálogo"),
        ("precio_volumen", "§4 catálogo; §5.2 precio por volumen (venta al por mayor)"),
        ("favorito", "§4 catálogo (lista de deseos)"),
        ("resena", "§5.8 reseñas"),
        ("banner", "§4 catálogo (portada)"),
    ])),
    ("Inventario e insumos", OrderedDict([
        ("reserva_stock", "§5.3 reservas de stock"),
        ("movimiento_stock", "§4 kardex; §2.9 devoluciones reponen stock"),
        ("insumo", "HU-13 insumos"),
        ("movimiento_insumo", "HU-13 kardex de insumos"),
        ("receta_producto", "§4 (opcional recomendado) receta para descontar insumos"),
    ])),
    ("Compra y pedidos", OrderedDict([
        ("carrito", "§4 compra (el precio nunca se guarda en el carrito)"),
        ("item_carrito", "§4 compra"),
        ("zona_envio", "§5.1 costo de envío desde la zona"),
        ("direccion", "§4 compra; §3.1 predeterminada única"),
        ("estado_pedido", "§2.5 estados consultables por grupo"),
        ("transicion_estado_pedido", "§5.7 transiciones permitidas"),
        ("pedido", "§2.2 modalidad total/adelanto; §5.1; §5.4-7; HU-29 complementario"),
        ("item_pedido", "§5.2 copia de datos y precio desde la BD"),
        ("historial_estado_pedido", "§2.5 historial inmutable"),
        ("devolucion", "§2.9 devoluciones"),
        ("devolucion_item", "§2.9 no devolver dos veces"),
    ])),
    ("Cotizaciones", OrderedDict([
        ("cotizacion", "HU-28 / HU-17 / HU-18; §5.9"),
        ("item_cotizacion", "HU-28 / HU-17 / HU-18"),
        ("transicion_estado_cotizacion", "§5.9 flujo de cotización"),
    ])),
    ("Envíos", OrderedDict([
        ("courier", "§4 envío; API del courier (decisión abierta)"),
        ("envio", "HU-12 seguimiento de envío"),
        ("seguimiento_envio", "HU-12 eventos de seguimiento"),
    ])),
    ("Pagos y reembolsos", OrderedDict([
        ("metodo_pago", "§1 Mercado Pago, PayPal, Yape, Plin, transferencia, efectivo"),
        ("pago", "§2.2; §2.3 pago huérfano; §5.5-6"),
        ("transicion_estado_pago", "§4 máquina de estados del pago"),
        ("reembolso", "§4 reembolsos; §7.6"),
        ("evento_pasarela", "§2.10 webhooks idempotentes"),
    ])),
    ("Comprobantes electrónicos", OrderedDict([
        ("serie_comprobante", "§2.8 series (reemplazar por las reales del OSE)"),
        ("motivo_nota_credito", "§2.8 catálogo SUNAT 09"),
        ("comprobante", "§2.8 copia completa de lo emitido"),
        ("comprobante_item", "§2.8 líneas del comprobante"),
        ("comprobante_archivo", "§2.8 PDF/XML/CDR en BLOB"),
        ("cola_emision_comprobante", "§2.8 emisión asíncrona y reintentable"),
    ])),
    ("Atención al cliente", OrderedDict([
        ("mensaje_contacto", "§4 contacto (máx. 3 por hora por IP)"),
        ("reclamo", "§4 Libro de Reclamaciones (plazo: verificar INDECOPI)"),
        ("respuesta_atencion", "§4 respuestas con historial"),
    ])),
])

AUDITORIA_COLS = {"creado_en", "actualizado_en", "creado_por", "actualizado_por",
                  "inhabilitado_en", "inhabilitado_por"}


def consulta(sql):
    """Devuelve filas (listas) de una consulta usando docker o el cliente local."""
    con_docker = subprocess.run(["docker", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
    if "wanka-mysql" in con_docker.stdout.split():
        clave = os.environ.get("MYSQL_PWD")
        if not clave:
            with open(os.path.join(RAIZ, ".env"), encoding="utf-8") as f:
                for linea in f:
                    if linea.startswith("MYSQL_ROOT_PASSWORD="):
                        clave = linea.strip().split("=", 1)[1]
        cmd = ["docker", "exec", "-i", "-e", f"MYSQL_PWD={clave}", "wanka-mysql", "mysql", "-uroot"]
    else:
        cmd = ["mysql", "-h", os.environ.get("MYSQL_HOST", "127.0.0.1"), "-P", os.environ.get("MYSQL_PORT", "3306"),
               "-u", os.environ.get("MYSQL_USER", "root")]
    cmd += ["--default-character-set=utf8mb4", "-B", "-N", "--raw", "-e", sql]
    salida = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return [linea.split("\t") for linea in salida.splitlines() if linea]


def limpiar_check(texto):
    texto = re.sub(r"_utf8mb4\\?'", "'", texto)
    texto = texto.replace("`", "").replace("\\'", "'")
    return re.sub(r"\s+", " ", texto).strip()


def md(texto):
    return (texto or "").replace("|", "\\|").replace("\n", " ")


def main():
    b = BASE
    tablas = {r[0]: r[1] for r in consulta(
        f"SELECT TABLE_NAME, TABLE_COMMENT FROM information_schema.TABLES WHERE TABLE_SCHEMA='{b}' AND TABLE_TYPE='BASE TABLE'")}
    columnas = defaultdict(list)
    for r in consulta(f"""SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, IFNULL(COLUMN_DEFAULT,'∅'), COLUMN_KEY, EXTRA,
                                IFNULL(GENERATION_EXPRESSION,''), COLUMN_COMMENT, DATA_TYPE
                           FROM information_schema.COLUMNS WHERE TABLE_SCHEMA='{b}' ORDER BY TABLE_NAME, ORDINAL_POSITION"""):
        columnas[r[0]].append(r)
    fks = defaultdict(list)
    for r in consulta(f"""SELECT TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, CONSTRAINT_NAME
                           FROM information_schema.KEY_COLUMN_USAGE
                          WHERE TABLE_SCHEMA='{b}' AND REFERENCED_TABLE_NAME IS NOT NULL ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION"""):
        fks[r[0]].append(r)
    checks = defaultdict(list)
    for r in consulta(f"""SELECT tc.TABLE_NAME, cc.CONSTRAINT_NAME, REPLACE(REPLACE(cc.CHECK_CLAUSE, '\\n', ' '), '\\t', ' ')
                           FROM information_schema.TABLE_CONSTRAINTS tc
                           JOIN information_schema.CHECK_CONSTRAINTS cc ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
                          WHERE tc.TABLE_SCHEMA='{b}' AND tc.CONSTRAINT_TYPE='CHECK' ORDER BY tc.TABLE_NAME, cc.CONSTRAINT_NAME"""):
        checks[r[0]].append(r)
    indices = defaultdict(list)
    for r in consulta(f"""SELECT TABLE_NAME, INDEX_NAME, MIN(NON_UNIQUE), GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', '), MIN(INDEX_TYPE)
                           FROM information_schema.STATISTICS WHERE TABLE_SCHEMA='{b}' GROUP BY TABLE_NAME, INDEX_NAME ORDER BY TABLE_NAME, INDEX_NAME"""):
        indices[r[0]].append(r)
    triggers = defaultdict(list)
    for r in consulta(f"""SELECT EVENT_OBJECT_TABLE, TRIGGER_NAME, ACTION_TIMING, EVENT_MANIPULATION
                           FROM information_schema.TRIGGERS WHERE TRIGGER_SCHEMA='{b}' ORDER BY EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION"""):
        triggers[r[0]].append(r)
    vistas = [r[0] for r in consulta(f"SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA='{b}' ORDER BY TABLE_NAME")]
    rutinas = consulta(f"""SELECT ROUTINE_NAME, ROUTINE_TYPE, ROUTINE_COMMENT FROM information_schema.ROUTINES
                            WHERE ROUTINE_SCHEMA='{b}' ORDER BY ROUTINE_TYPE, ROUTINE_NAME""")
    parametros = defaultdict(list)
    for r in consulta(f"""SELECT SPECIFIC_NAME, IFNULL(PARAMETER_MODE,'RETURNS'), IFNULL(PARAMETER_NAME,''), DTD_IDENTIFIER
                           FROM information_schema.PARAMETERS WHERE SPECIFIC_SCHEMA='{b}' ORDER BY SPECIFIC_NAME, ORDINAL_POSITION"""):
        parametros[r[0]].append(r)
    eventos = consulta(f"""SELECT EVENT_NAME, CONCAT('cada ', INTERVAL_VALUE, ' ', INTERVAL_FIELD), EVENT_COMMENT
                            FROM information_schema.EVENTS WHERE EVENT_SCHEMA='{b}' ORDER BY EVENT_NAME""")

    asignadas = {t for m in MODULOS.values() for t in m}
    faltantes = sorted(set(tablas) - asignadas)
    if faltantes:
        MODULOS["Otras"] = OrderedDict((t, "") for t in faltantes)

    # ------------------------------------------------------------------ diccionario
    o = []
    o.append("# Diccionario de datos — Bordados Wanka S.A.C. (MySQL 8)\n")
    o.append("> Generado automáticamente desde `information_schema` con `scripts/generar_documentacion.py`. "
             "No editar a mano: cambie el `COMMENT` en el SQL y regenere.\n")
    o.append(f"Base: `{b}` · {len(tablas)} tablas · {len(vistas)} vistas · "
             f"{sum(1 for r in rutinas if r[1] == 'PROCEDURE')} procedimientos · {sum(1 for r in rutinas if r[1] == 'FUNCTION')} funciones · "
             f"{sum(len(v) for v in triggers.values())} triggers · {len(eventos)} eventos\n")
    o.append("Convenciones: fechas en UTC (`DATETIME(3)`), las vistas convierten a Lima; `∅` = sin valor por defecto; "
             "**Clave** PRI = llave primaria, UNI = única, MUL = índice/llave foránea. La columna **Referencia** usa las secciones "
             "del prompt (§) y los códigos HU/RF/RNF citados; el resto de la trazabilidad está en `TRAZABILIDAD_HU_RF_RNF.md`.\n")
    o.append("## Índice\n")
    for modulo, ts in MODULOS.items():
        o.append(f"- **{modulo}**: " + ", ".join(f"[{t}](#{t})" for t in ts if t in tablas))
    o.append("- [Vistas](#vistas) · [Procedimientos y funciones](#procedimientos-y-funciones) · [Eventos](#eventos)\n")

    for modulo, ts in MODULOS.items():
        o.append(f"\n## {modulo}\n")
        for t, ref in ts.items():
            if t not in tablas:
                continue
            o.append(f"### {t}\n")
            o.append(f"{tablas[t]}\n")
            if ref:
                o.append(f"**Referencia:** {ref}\n")
            o.append("| Columna | Tipo | Nulo | Defecto / cálculo | Clave | Descripción |")
            o.append("|---|---|---|---|---|---|")
            for c in columnas[t]:
                _, col, tipo, nulo, defecto, clave, extra, gen, coment, _dt = c
                calc = f"GENERADA: `{md(limpiar_check(gen))}`" if gen else ("AUTO_INCREMENT" if "auto_increment" in extra else md(defecto))
                o.append(f"| `{col}` | {md(tipo)} | {'sí' if nulo == 'YES' else 'no'} | {calc} | {clave} | {md(coment)} |")
            if checks[t]:
                o.append("\n**Restricciones CHECK**\n")
                for _, nombre, clausula in checks[t]:
                    o.append(f"- `{nombre}`: `{md(limpiar_check(clausula))}`")
            if fks[t]:
                o.append("\n**Llaves foráneas**\n")
                agrupadas = OrderedDict()
                for _, col, rt, rc, nombre in fks[t]:
                    agrupadas.setdefault(nombre, ([], rt, []))
                    agrupadas[nombre][0].append(col)
                    agrupadas[nombre][2].append(rc)
                for nombre, (cols, rt, rcs) in agrupadas.items():
                    o.append(f"- `{nombre}`: ({', '.join(cols)}) → `{rt}`({', '.join(rcs)})")
            if indices[t]:
                o.append("\n**Índices**: " + "; ".join(
                    f"`{n}` ({'único' if nu == '0' else ('FULLTEXT' if it == 'FULLTEXT' else 'normal')}: {cols})"
                    for _, n, nu, cols, it in indices[t]))
            if triggers[t]:
                o.append("\n**Triggers**: " + ", ".join(f"`{n}` ({tim} {ev})" for _, n, tim, ev in triggers[t]))
            o.append("")

    o.append("\n## Vistas\n")
    o.append("| Vista | Columnas |")
    o.append("|---|---|")
    for v in vistas:
        o.append(f"| `{v}` | " + ", ".join(c[1] for c in columnas[v]) + " |")

    o.append("\n## Procedimientos y funciones\n")
    o.append("Prefijos: `fn_` función · `sp_` procedimiento público (una transacción) · `spi_` interno (sin transacción, lo usan otros procedimientos y los triggers).\n")
    o.append("| Nombre | Tipo | Parámetros | Descripción |")
    o.append("|---|---|---|---|")
    for nombre, tipo, coment in rutinas:
        ps = ", ".join(
            (f"{modo} {pn} {dt}".strip() if modo != "RETURNS" else f"→ {dt}") for _, modo, pn, dt in parametros[nombre])
        o.append(f"| `{nombre}` | {'función' if tipo == 'FUNCTION' else 'procedimiento'} | {md(ps)} | {md(coment)} |")

    o.append("\n## Eventos\n")
    o.append("| Evento | Frecuencia | Descripción |")
    o.append("|---|---|---|")
    for nombre, freq, coment in eventos:
        o.append(f"| `{nombre}` | {freq.lower()} | {md(coment)} |")

    with open(os.path.join(RAIZ, "docs", "DICCIONARIO_DE_DATOS.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(o) + "\n")

    # ------------------------------------------------------------------ diagrama ER
    unicos = set()
    for t, idx in indices.items():
        for _, n, nu, cols, _it in idx:
            if nu == "0" and "," not in cols:
                unicos.add((t, cols))
    e = ["# Diagrama entidad-relación — Bordados Wanka S.A.C.\n",
         "> Generado desde `information_schema` (`scripts/generar_documentacion.py`). Un diagrama por módulo para que sea legible; "
         "las tablas de otros módulos aparecen solo con su llave primaria. Se muestran llaves y columnas principales "
         "(las de auditoría `creado_*`, `actualizado_*`, `inhabilitado_*` se omiten). Notación Mermaid `erDiagram` "
         "(GitHub, VS Code y GitLab lo dibujan).\n"]
    for modulo, ts in MODULOS.items():
        propias = [t for t in ts if t in tablas]
        externas = set()
        rel = []
        for t in propias:
            vistos = set()
            for _, col, rt, rc, nombre in fks[t]:
                if nombre in vistos:
                    continue
                vistos.add(nombre)
                if rt not in propias:
                    externas.add(rt)
                nulo = next((c[3] for c in columnas[t] if c[1] == col), "YES") == "YES"
                lado_padre = "|o" if nulo else "||"
                lado_hijo = "o|" if (t, col) in unicos else "o{"
                rel.append(f"    {rt} {lado_padre}--{lado_hijo} {t} : \"{col}\"")
        e.append(f"\n## {modulo}\n")
        e.append("```mermaid")
        e.append("erDiagram")
        for t in propias:
            claves_fk = {r[1] for r in fks[t]}
            e.append(f"    {t} {{")
            otras = 0
            for c in columnas[t]:
                col, clave, dt = c[1], c[5], c[9]
                marcas = []
                if clave == "PRI":
                    marcas.append("PK")
                if col in claves_fk:
                    marcas.append("FK")
                if (t, col) in unicos and clave != "PRI":
                    marcas.append("UK")
                if not marcas:
                    if col in AUDITORIA_COLS or otras >= 8:
                        continue
                    otras += 1
                e.append(f"        {dt} {col}" + (f" {', '.join(marcas)}" if marcas else ""))
            e.append("    }")
        for t in sorted(externas):
            pk = [c for c in columnas[t] if c[5] == "PRI"]
            e.append(f"    {t} {{")
            for c in pk:
                e.append(f"        {c[9]} {c[1]} PK")
            e.append("    }")
        e.extend(sorted(set(rel)))
        e.append("```")
    with open(os.path.join(RAIZ, "docs", "DIAGRAMA_ER.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(e) + "\n")
    print(f"OK: {len(tablas)} tablas documentadas en docs/DICCIONARIO_DE_DATOS.md y docs/DIAGRAMA_ER.md")


if __name__ == "__main__":
    main()
