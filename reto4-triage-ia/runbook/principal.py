# ---- Runbook Triage-Alerta (Azure Automation, Python 3.10) -----------------------------------------------
# Lo dispara el mismo grupo de acciones que la auto-remediación (alerta PortalPagos-Sitio-NoDisponible).
# Construye el contexto desde Log Analytics, pide el triage al modelo y deja el resultado en la salida del job
# (JobStreams → Log Analytics → tablero NOC). NO ejecuta acciones: solo sugiere.
import json, os, sys


def _variable(nombre, defecto=None):
    try:
        import automationassets  # disponible en el sandbox de Azure Automation
        return automationassets.get_automation_variable(nombre)
    except Exception:
        return os.environ.get(nombre, defecto)


def _json_balanceado(txt, desde):
    """Devuelve el objeto JSON que empieza en la primera '{' a partir de `desde` (respeta strings y escapes)."""
    i = txt.index("{", desde); nivel = 0; en_str = False; esc = False
    for j in range(i, len(txt)):
        c = txt[j]
        if en_str:
            esc = (c == "\\") and not esc
            if c == '"' and not esc:
                en_str = False
            if c != "\\":
                esc = False
        elif c == '"':
            en_str = True
        elif c == "{":
            nivel += 1
        elif c == "}":
            nivel -= 1
            if nivel == 0:
                return json.loads(txt[i:j + 1])
    raise ValueError("JSON sin cerrar")


def _alerta_desde_argv(argv):
    """Azure Automation entrega el webhook a un runbook Python partido en espacios y sin comillas en el envoltorio:
    {WebhookName:x,RequestBody:{...json original...},RequestHeader:{...}}. Se reconstruye y se extrae RequestBody."""
    txt = " ".join(argv[1:])
    for intento in (lambda: json.loads(txt), lambda: _json_balanceado(txt, txt.index("RequestBody:"))):
        try:
            d = intento()
        except Exception:
            continue
        if isinstance(d, dict) and "RequestBody" in d:
            d = json.loads(d["RequestBody"]) if isinstance(d["RequestBody"], str) else d["RequestBody"]
        if isinstance(d, dict) and d.get("schemaId") == "azureMonitorCommonAlertSchema":
            return d
    raise SystemExit("Sin alerta en el esquema común: este runbook se ejecuta desde un grupo de acciones. Inicio de argv: "
                     + txt[:200])


def principal(argv):
    from triage.contexto import desde_log_analytics
    from triage.llm import crear_cliente
    from triage.motor import ejecutar
    alerta = _alerta_desde_argv(argv)
    if alerta["data"]["essentials"].get("monitorCondition") == "Resolved":
        print(json.dumps({"tipo": "triage-ia", "decision": "omitido", "motivo": "alerta resuelta"}))
        return
    os.environ["AZURE_OPENAI_ENDPOINT"] = _variable("AoaiEndpoint")
    ctx = desde_log_analytics(alerta, _variable("WorkspaceId"))
    r = ejecutar(ctx, crear_cliente(timeout_s=25))
    t = r["triage"]
    print(json.dumps({
        "tipo": "triage-ia", "alerta": r["alerta"], "origen": r["origen"], "modelo": r["modelo"],
        "resumen": t["resumen"], "impacto": t["impacto"],
        "hipotesis": [{"descripcion": h["descripcion"], "probabilidad": h["probabilidad"], "evidencia": [e["id"] for e in h["evidencia"]]} for h in t["hipotesis"]],
        "accion": {k: r["accion"][k] for k in ("runbook", "nombre", "justificacion", "requiere_aprobacion_humana", "ejecutada")},
        "confianza": t["confianza"], "valido": r["validacion"]["valido"],
        "problemas": sorted({p["tipo"] for i in r["validacion"]["intentos"] for p in i.get("problemas", [])}),
        "evidencias_en_contexto": len(ctx.evidencias), "duracion_ms": r["duracion_ms"],
    }, ensure_ascii=True))   # ASCII: la salida del job pasa por varias capas con codificaciones distintas


principal(sys.argv)
