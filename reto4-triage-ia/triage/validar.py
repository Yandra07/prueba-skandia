"""Validación de la respuesta del modelo. Nada de lo que dice el modelo se acepta sin verificar contra el contexto.

Niveles:
  1. JSON válido y conforme al esquema (jsonschema, con todas las restricciones).
  2. Evidencia real: cada id citado existe en el contexto y cada cita es un fragmento LITERAL de esa evidencia.
  3. Acción con sustento: el runbook sugerido requiere ciertas señales y al menos una evidencia citada para la acción
     debe tenerlas (RB-00 no requiere nada).
  4. Coherencia de confianza: si hay problemas, la confianza se fuerza a "baja" y se marca revisión humana.
"""
from __future__ import annotations
import json, re, unicodedata
from datetime import datetime, timedelta, timezone
try:
    from jsonschema import Draft202012Validator
except ImportError:   # sandbox de Azure Automation: validador mínimo equivalente para este esquema
    Draft202012Validator = None
from .catalogo import RUNBOOKS
from .contexto import Contexto
from .esquema import esquema


def _norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s or "").lower()
    s = s.replace("“", '"').replace("”", '"').replace("’", "'")
    # la puntuación no cambia el sentido de una cita ("11.4 %), latencia" ≈ "11.4 %) latencia"); las palabras y números sí
    s = re.sub(r"[,;:()\[\]{}\"'«»]", " ", s)
    return " ".join(s.split())


VENTANA_RECIENTE_MIN = 15
BOGOTA = timezone(timedelta(hours=-5))


def _limite_reciente(ctx: Contexto) -> str | None:
    d = ctx.alerta.get("disparo_utc")
    if not d:
        return None
    from .contexto import _ts_utc
    t = _ts_utc(d).astimezone(BOGOTA) - timedelta(minutes=VENTANA_RECIENTE_MIN)
    return t.strftime("%Y-%m-%d %H:%M:%S")


def _mini(sch: dict, v, ruta: str = ""):
    """Subconjunto de JSON Schema que usa este esquema: type, required, additionalProperties, properties, items,
    enum, pattern, minItems, maxItems."""
    t = sch.get("type")
    tipos = {"object": dict, "array": list, "string": str}
    if t in tipos and not isinstance(v, tipos[t]):
        yield ruta, f"se esperaba {t}"; return
    if "enum" in sch and v not in sch["enum"]:
        yield ruta, f"{v!r} no está en {sch['enum']}"
    if t == "string" and "pattern" in sch and not re.search(sch["pattern"], v):
        yield ruta, f"{v!r} no cumple {sch['pattern']}"
    if t == "object":
        for k in sch.get("required", []):
            if k not in v:
                yield ruta, f"falta '{k}'"
        if sch.get("additionalProperties") is False:
            for k in v:
                if k not in sch.get("properties", {}):
                    yield ruta, f"propiedad no permitida '{k}'"
        for k, sub in sch.get("properties", {}).items():
            if k in v:
                yield from _mini(sub, v[k], f"{ruta}/{k}".lstrip("/"))
    if t == "array":
        if len(v) < sch.get("minItems", 0):
            yield ruta, f"mínimo {sch['minItems']} elementos"
        if "maxItems" in sch and len(v) > sch["maxItems"]:
            yield ruta, f"máximo {sch['maxItems']} elementos"
        for i, x in enumerate(v):
            yield from _mini(sch.get("items", {}), x, f"{ruta}/{i}".lstrip("/"))


def errores_esquema(d) -> list[tuple[str, str]]:
    if Draft202012Validator is not None:
        return [("/".join(map(str, e.path)), e.message) for e in Draft202012Validator(esquema()).iter_errors(d)]
    return list(_mini(esquema(), d))


def validar(texto: str, ctx: Contexto) -> tuple[dict | None, list[dict]]:
    problemas: list[dict] = []
    try:
        d = json.loads(texto)
    except (ValueError, TypeError, RecursionError) as e:
        # texto que no es JSON, contenido que no es texto (TypeError) o anidamiento extremo (RecursionError)
        return None, [{"tipo": "json_invalido", "detalle": f"{type(e).__name__}: {str(e)[:180]}"}]
    for ruta, msg in errores_esquema(d):
        problemas.append({"tipo": "esquema", "detalle": f"{ruta}: {msg[:160]}"})
    if problemas:
        return d, problemas

    ev = ctx.por_id()
    citados: set[str] = set()
    for i, h in enumerate(d["hipotesis"]):
        validas = 0
        for c in h["evidencia"]:
            e = ev.get(c["id"])
            if not e:
                problemas.append({"tipo": "evidencia_inexistente", "detalle": f"hipótesis {i + 1} cita {c['id']}, que no existe en el contexto"})
                continue
            cita = _norm(c["cita"]).strip(' ."\'…')
            if len(cita) < 6 or cita not in _norm(e.texto):
                # el recorte se marca con "…": sin la marca parecía que el modelo había escrito la cita cortada ("…Exception: Syste")
                mostrada = c["cita"] if len(c["cita"]) <= 80 else c["cita"][:80].rstrip() + "…"
                problemas.append({"tipo": "cita_no_literal", "detalle": f"hipótesis {i + 1}: '{mostrada}' no aparece en {c['id']}"})
                continue
            validas += 1
            citados.add(c["id"])
        if validas == 0:
            problemas.append({"tipo": "hipotesis_sin_evidencia", "detalle": f"hipótesis {i + 1} ('{h['descripcion'][:60]}') no tiene evidencia verificable"})

    a = d["accion_sugerida"]
    rb = RUNBOOKS.get(a["runbook"])
    if rb is None:
        problemas.append({"tipo": "runbook_fuera_de_catalogo", "detalle": a["runbook"]})
    else:
        for x in a["evidencia"]:
            if x not in ev:
                problemas.append({"tipo": "evidencia_inexistente", "detalle": f"la acción cita {x}, que no existe"})
        req = set(rb["senales"])
        if req:
            sen_accion = {s for x in a["evidencia"] if x in ev for s in ev[x].senales}
            if not req & sen_accion:
                problemas.append({"tipo": "accion_sin_sustento",
                                  "detalle": f"{a['runbook']} requiere evidencia con señal {sorted(req)}; la citada tiene {sorted(sen_accion) or 'ninguna'}"})
            else:
                # la señal que justifica la acción debe ser ACTUAL, no de un episodio anterior ya resuelto
                lim = _limite_reciente(ctx)
                recientes = [x for x in a["evidencia"] if x in ev and req & set(ev[x].senales) and (ev[x].ts_fin or ev[x].ts) >= (lim or "")]
                if lim and not recientes:
                    problemas.append({"tipo": "accion_desactualizada",
                                      "detalle": f"la evidencia que justifica {a['runbook']} termina antes de {lim} "
                                                 f"(más de {VENTANA_RECIENTE_MIN} min antes de la alerta): puede ser un episodio anterior"})
    return d, problemas


def es_grave(problemas: list[dict]) -> bool:
    """Problemas que invalidan la respuesta (se reintenta una vez y luego se usa el respaldo)."""
    graves = {"json_invalido", "esquema", "runbook_fuera_de_catalogo", "accion_sin_sustento", "accion_desactualizada",
              "evidencia_inexistente", "hipotesis_sin_evidencia"}
    return any(p["tipo"] in graves for p in problemas)
