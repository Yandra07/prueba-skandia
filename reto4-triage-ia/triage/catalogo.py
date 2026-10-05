"""Catálogo CERRADO de runbooks. El modelo solo puede elegir uno de estos IDs.

Cada runbook declara qué señales del contexto lo justifican. El validador exige que la evidencia citada por el
modelo contenga al menos una de esas señales: así se detecta una acción sugerida "sin sustento".
"""
RUNBOOKS = {
    "RB-00": {"nombre": "Escalar a la persona de guardia (sin acción automática)",
              "cuando": "La evidencia no alcanza para elegir otra acción, o el riesgo de actuar es mayor que el de esperar.",
              "senales": []},
    "RB-01": {"nombre": "Reiniciar el application pool PortalPagosPool (runbook Restaurar-PoolIIS, con salvaguardas)",
              "cuando": "El pool está detenido o deshabilitado (WAS 5002, 503 AppOffline, estado del pool distinto de Running).",
              "senales": ["pool_caido"]},
    "RB-02": {"nombre": "Liberar espacio en C: y bajar el nivel de log de la aplicación",
              "cuando": "Espacio libre en C: bajo o cayendo rápido (srv 2013, % Free Space).",
              "senales": ["disco_bajo"]},
    "RB-03": {"nombre": "Escalar a desarrollo por fuga de memoria / evaluar rollback de la última versión",
              "cuando": "OutOfMemoryException o crecimiento sostenido de la memoria del pool, en especial tras un despliegue.",
              "senales": ["oom", "memoria_alta"]},
    "RB-04": {"nombre": "Verificar dependencia externa (el pool está sano pero el servicio falla)",
              "cuando": "El health check falla con el pool en ejecución, o hay errores de una dependencia.",
              "senales": ["dependencia"]},
    "RB-05": {"nombre": "Mitigar tráfico malicioso (bloqueo en WAF / proxy)",
              "cuando": "Escaneos o picos de 4xx desde pocas IP.",
              "senales": ["escaneo"]},
    "RB-06": {"nombre": "Escalar a infraestructura: el servidor no envía señales",
              "cuando": "Sin heartbeat del agente o la VM no responde.",
              "senales": ["sin_heartbeat"]},
}
IDS = sorted(RUNBOOKS)


def texto_catalogo() -> str:
    return "\n".join(f"- {k}: {v['nombre']}. Cuándo: {v['cuando']}" for k, v in sorted(RUNBOOKS.items()))
