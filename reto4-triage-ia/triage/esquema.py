"""Esquema de salida del triage (JSON Schema draft 2020-12), compatible con Structured Outputs (strict)."""
from .catalogo import IDS

NIVELES = ["alta", "media", "baja"]


def esquema() -> dict:
    s = lambda d: {"type": "string", "description": d}
    return {
        "type": "object", "additionalProperties": False,
        "required": ["resumen", "que_esta_pasando", "impacto", "hipotesis", "accion_sugerida", "confianza", "datos_faltantes"],
        "properties": {
            "resumen": s("Una o dos frases para la persona de guardia, en español."),
            "que_esta_pasando": s("Qué muestran los datos, en orden cronológico y con horas."),
            "impacto": {
                "type": "object", "additionalProperties": False,
                "required": ["nivel", "descripcion"],
                "properties": {"nivel": {"type": "string", "enum": ["ninguno", "bajo", "medio", "alto", "critico"]},
                               "descripcion": s("Quién está afectado y cómo (clientes, pagos, porcentaje de errores).")},
            },
            "hipotesis": {
                "type": "array", "minItems": 1, "maxItems": 4,
                "items": {
                    "type": "object", "additionalProperties": False,
                    "required": ["descripcion", "probabilidad", "evidencia"],
                    "properties": {
                        "descripcion": s("Causa posible."),
                        "probabilidad": {"type": "string", "enum": NIVELES},
                        "evidencia": {
                            "type": "array", "minItems": 1, "maxItems": 6,
                            "items": {"type": "object", "additionalProperties": False, "required": ["id", "cita"],
                                      "properties": {"id": {"type": "string", "pattern": "^E[0-9]+$"},
                                                     "cita": s("Fragmento LITERAL del texto de esa evidencia.")}},
                        },
                    },
                },
            },
            "accion_sugerida": {
                "type": "object", "additionalProperties": False,
                "required": ["runbook", "justificacion", "evidencia"],
                "properties": {"runbook": {"type": "string", "enum": IDS},
                               "justificacion": s("Por qué este runbook y no otro."),
                               "evidencia": {"type": "array", "minItems": 1, "maxItems": 6,
                                             "items": {"type": "string", "pattern": "^E[0-9]+$"}}},
            },
            "confianza": {
                "type": "object", "additionalProperties": False, "required": ["nivel", "razon"],
                "properties": {"nivel": {"type": "string", "enum": NIVELES}, "razon": s("Qué la sube o la baja.")},
            },
            "datos_faltantes": {"type": "array", "maxItems": 6, "items": {"type": "string"}},
        },
    }
