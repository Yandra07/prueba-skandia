# Prueba técnica · Especialista en Observabilidad y Automatización

Caso PortalPagos (Andina Financiera, datos ficticios). Solución completa de los 5 retos, organizada para leerse como caso de estudio: qué se pidió, cómo se resolvió paso a paso y dónde está la evidencia.

| Reto | Carpeta | Resultado |
|---|---|---|
| 1 · Diagnóstico basado en datos | [`reto1-diagnostico/`](reto1-diagnostico/README.md) | Análisis reproducible (byte a byte) y post-mortem de 3 páginas para la directora |
| 2 · Modernizar el mantenimiento | [`reto2-powershell/`](reto2-powershell/README.md) | Reemplazo del .BAT en PowerShell: 38/38 Pester en Windows PowerShell 5.1 y mantenimiento real con código 0 |
| 3 · Observabilidad y auto-remediación en Azure | [`reto3-azure/`](reto3-azure/README.md) | Laboratorio en Bicep, probado con fallas provocadas: MTTD 1,0–1,7 min y MTTR 2,3–3,3 min, sin intervención humana; capturas y limpieza documentadas |
| 4 · IA para el triage de incidentes | [`reto4-triage-ia/`](reto4-triage-ia/README.md) | Triage con esquema propio y validación de lo que dice el modelo, conectado a la alerta real del Reto 3 |
| 5 · Propuesta de 90 días | [`reto5-propuesta/`](reto5-propuesta/README.md) | 5 iniciativas priorizadas, métricas y qué no se haría (2 páginas) |

Bitácora de uso de IA: [`IA_BITACORA.md`](IA_BITACORA.md)

## Por dónde empezar

1. **La directora:** `reto1-diagnostico/POSTMORTEM.pdf` (qué pasó) y `reto5-propuesta/PROPUESTA_90_DIAS.pdf` (qué se propone).
2. **La evidencia técnica:** `reto1-diagnostico/HALLAZGOS_TECNICOS.md` (hechos frente a hipótesis, con archivo y línea) y `reto3-azure/evidencias/LEEME.md` (mediciones, capturas y limpieza).
3. **El código:** cada carpeta tiene su README con los pasos para reproducirla, las pruebas y los supuestos.

## Cómo se resolvió, paso a paso

### Reto 1 · Diagnóstico
1. **Desconfiar de los datos antes de analizarlos:** log duplicado (SHA-256), logs de IIS y HTTP.sys en UTC (validado de tres formas), cambio de formato a mitad de archivo y un proxy que oculta la IP del cliente.
2. **Reconstruir el 18-sep en hora de Colombia:** degradación 11:45, primer error 13:23, caída total 14:38–15:04, con lo que vio el cliente en cada momento.
3. **Causa raíz con evidencia:** la memoria crece ≈0,5 MB por pago confirmado desde la v2.3.1 (R² 0,999) y el pico del fin de plazo agotó el límite. Hechos, hipótesis y cómo confirmarlas, separados.
4. **Disponibilidad real frente al NOC:** 98,57 % contra el "100 %" reportado, y por qué no coinciden.
5. **Señales tempranas y riesgos:** la memoria avisaba desde el miércoles 16; pronóstico de disco lleno con método y escenarios.
6. **Post-mortem sin culpables** para la directora, con acciones, responsables y fechas.

### Reto 2 · Mantenimiento
1. **11 problemas del .BAT ordenados por riesgo**, cruzados con lo que ya pasó en el Reto 1.
2. **Decisión por paso:** qué desaparece, qué se transforma y con qué se reemplaza (el `iisreset` pasa a reciclaje por memoria; no se quita sin reemplazo mientras exista la fuga).
3. **Script nuevo** con parámetros validados, `-WhatIf`, códigos de salida confiables, log JSON, gMSA sin credenciales e idempotencia.
4. **Pruebas** en PowerShell 7 y en Windows PowerShell 5.1 dentro de la VM del Reto 3, con ejecución real.

### Reto 3 · Azure
1. **Infraestructura como código** (Bicep) con presupuesto y alerta, sin RDP y con identidades administradas.
2. **Recolección** con Azure Monitor Agent y DCR: logs de IIS, eventos y contadores.
3. **KQL** de disponibilidad real, 5xx, p95 y eventos del pool, validado contra el esquema de las tablas.
4. **6 alertas** con umbral y severidad justificados y **auto-remediación** con límite de intentos, anti-bucle, cuándo no actuar y escalamiento.
5. **Tablero** con una vista para la directora y otra para el NOC.
6. **Falla provocada y medida**, capturas del portal y eliminación del grupo de recursos.

### Reto 4 · Triage con IA
1. **Esquema de salida propio** y catálogo cerrado de runbooks.
2. **Contexto con evidencias numeradas** desde el kit o desde Log Analytics.
3. **Validación de lo que dice el modelo:** esquema, citas literales, sustento y vigencia de la acción; respaldo por reglas si falla.
4. **Casos de prueba**, incluidos uno en que el modelo se equivoca, uno en que inventa y uno de inyección; conexión con la alerta real del Reto 3.

### Reto 5 · Propuesta de 90 días
1. **Punto de partida medido** con las cifras de los retos 1 a 4.
2. **5 iniciativas** priorizadas por impacto, esfuerzo y riesgo, con métricas de éxito, lo que hay que destrabar y lo que no se haría.

## Estructura esperada en disco

```
Prueba_Tecnica/
├── kit_prueba_portalpagos/      ← kit original (fuera del repo, ver .gitignore)
└── caso-estudio-observabilidad/ ← este repositorio
```

## Supuestos generales

1. **Los datos son los del kit, tal como vinieron.** El análisis está fechado con la información disponible al cierre del kit (domingo 20-sep-2026, 23:55). Por eso los pronósticos hablan del 21 y 22-sep.
2. **Hora:** todo se presenta en hora de Colombia (UTC-5). Los logs de IIS y de HTTP.sys vienen en UTC y se convierten.
3. **Azure:** el laboratorio del Reto 3 se desplegó en una suscripción propia con presupuesto y alerta, y se eliminó al terminar. La evidencia queda en los archivos y en las capturas.
4. **Ningún secreto en el repositorio:** sin contraseñas, claves, cadenas de conexión ni tokens; el despliegue usa identidades administradas y código de dispositivo.
5. **Uso de IA:** se usó en todos los retos para ganar tiempo en lo de mayor complejidad; qué se le pidió, qué se corrigió y qué no se le delegó está en la bitácora.
