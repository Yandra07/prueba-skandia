"""Triage de respaldo por reglas: se usa si el modelo falla, se demora o responde algo inválido.

Es deliberadamente conservador: describe las señales que hay, cita evidencia real y recomienda la acción solo cuando
la señal es inequívoca. Si no, RB-00 (escalar a una persona). Confianza siempre "baja".
"""
from __future__ import annotations
from .contexto import Contexto

PRIORIDAD = [  # (señal, runbook, hipótesis)
    ("pool_caido", "RB-01", "El application pool está detenido o deshabilitado"),
    ("oom", "RB-03", "El proceso se queda sin memoria (OutOfMemoryException)"),
    ("dependencia", "RB-04", "La sonda falla con el pool sano: posible dependencia caída"),
    ("disco_bajo", "RB-02", "Espacio en disco bajo"),
    ("sin_heartbeat", "RB-06", "El servidor no envía señales"),
    ("escaneo", "RB-05", "Tráfico de escaneo"),
    ("memoria_alta", "RB-03", "Memoria del pool anormalmente alta"),
]


def triage_por_reglas(ctx: Contexto, motivo: str, solo_escalar: bool = False) -> dict:
    from .validar import _limite_reciente   # import local: validar importa el catálogo y el contexto
    lim = _limite_reciente(ctx)
    hip, accion = [], None
    for senal, rb, desc in PRIORIDAD:
        evs = [e for e in ctx.evidencias if senal in e.senales][:3]
        if evs:
            hip.append({"descripcion": desc, "probabilidad": "media",
                        "evidencia": [{"id": e.id, "cita": e.texto[:120]} for e in evs]})
            # una acción solo se justifica con evidencia ACTUAL (no de un episodio anterior ya resuelto)
            recientes = [e for e in ctx.evidencias if senal in e.senales and (not lim or (e.ts_fin or e.ts) >= lim)][:3]
            if accion is None and recientes:
                accion = {"runbook": rb, "justificacion": f"Regla: señal '{senal}' presente en {', '.join(e.id for e in recientes)}.",
                          "evidencia": [e.id for e in recientes]}
    if not hip:
        e = ctx.evidencias[0] if ctx.evidencias else None
        hip = [{"descripcion": "No hay señales reconocibles en el contexto", "probabilidad": "baja",
                "evidencia": [{"id": e.id, "cita": e.texto[:120]}] if e else []}]
    if solo_escalar or accion is None or accion["runbook"] not in ("RB-01", "RB-04", "RB-06"):
        # sin señal inequívoca de una acción operativa directa, decide una persona
        accion = {"runbook": "RB-00", "justificacion": "Triage automático no disponible y sin señal inequívoca: decide la guardia.",
                  "evidencia": (accion or {}).get("evidencia", [])[:3] or [h["evidencia"][0]["id"] for h in hip if h["evidencia"]][:1]}
    al = ctx.alerta
    return {
        "resumen": f"[Respaldo por reglas] Alerta {al.get('regla')} ({al.get('severidad')}). {hip[0]['descripcion']}.",
        "que_esta_pasando": "Resumen generado por reglas, sin modelo de lenguaje: " + "; ".join(h["descripcion"] for h in hip),
        "impacto": {"nivel": "medio" if al.get("severidad") in ("Sev0", "Sev1") else "bajo",
                    "descripcion": "No estimado: el respaldo no interpreta métricas. Ver evidencias."},
        "hipotesis": hip[:4], "accion_sugerida": accion,
        "confianza": {"nivel": "baja", "razon": f"Generado por reglas porque el modelo no estuvo disponible o fue inválido: {motivo}"},
        "datos_faltantes": ["Análisis del modelo de lenguaje"],
    }
