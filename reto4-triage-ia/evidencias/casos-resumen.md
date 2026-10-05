| Caso | Origen | Runbook | Confianza | Vueltas | Problemas detectados | ¿Esperado? | ms |
|---|---|---|---|---|---|---|---|
| caso1-kit-18sep | modelo | RB-03 | baja | 1 | cita_no_literal | OK | 13022 |
| caso2-lab-pool-caido | modelo | RB-01 | alta | 1 | - | OK | 7918 |
| caso3-lab-dependencia | modelo | RB-04 | media | 2 | accion_desactualizada;cita_no_literal | OK | 19616 |
| caso4-inyeccion | modelo | RB-03 | alta | 1 | - | OK | 12332 |
| caso5-sin-datos | respaldo_reglas | RB-00 | baja | 2 | cita_no_literal;esquema;hipotesis_sin_evidencia | OK | 13710 |

**Integración real con la alerta del Reto 3** (runbook `Triage-Alerta` en Azure Automation, contexto desde Log Analytics):

| Caso | Origen | Runbook | Confianza | Problemas detectados | ms | Evidencia |
|---|---|---|---|---|---|---|
| 6 · crash #4 (02-oct, alerta 16:50Z) | modelo | RB-01 | baja | cita_no_literal | 7477 | `runbook-triage-alerta-real.json` |
| 7 · crash #6 (04-oct, alerta 01:50Z UTC) | modelo | RB-01 | baja | cita_no_literal | 6666 | `runbook-triage-alerta-20261004.json` (antes de corregir el parser de fechas, el job de la alerta anterior falló) |
