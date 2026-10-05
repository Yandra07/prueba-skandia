# Reto 3 · Observabilidad y auto-remediación en Azure

Es una versión mínima de WEB-PAGOS-01 en una suscripción propia: Windows Server 2022 + IIS, un sitio de prueba que se puede hacer fallar a voluntad, recolección con Azure Monitor Agent, consultas KQL, alertas, auto-remediación con salvaguardas y un tablero para dos públicos. **Todo es código (Bicep + PowerShell), así que se crea y se destruye con un comando.**

```
                      ┌─────────────── VM web-pagos-01 (Windows Server 2022, IIS 10) ───────────────┐
 sonda cada 20 s ───► │ PortalPagos / PortalPagosPool   ·  /health.aspx profundo  ·  /fallar.aspx (solo local) │
 carga sintética ───► │ eventos AndinaSonda/Remediacion/Mantenimiento · W3C · contadores · WAS/.NET          │
                      └──────────────┬───────────────────────────────────────────────▲──────────────────┘
                     Azure Monitor Agent + DCR                                Run Command (identidad administrada,
                                     ▼                                         rol limitado a la VM)
                         Log Analytics (law-portalpagos) ──► 6 alertas ──► grupo de acciones ──► runbook Restaurar-PoolIIS
                                     │                                         │ (salvaguardas; si no debe actuar → falla → alerta "escalada" → correo)
                                     └──► Workbook "PortalPagos · Dirección y NOC"
```

## Cómo reproducirlo

Requisitos: Azure CLI ≥ 2.60 y Bicep. **No se guardan credenciales**: se inicia sesión en el navegador con un código de dispositivo.

```bash
az login --use-device-code                       # la persona inicia sesión; la herramienta nunca ve la contraseña
CORREO=mi@correo ./scripts/desplegar.sh          # ~15 min. Opcional: LOCATION=eastus2  IP_DEMO=$(curl -s ifconfig.me)/32
./scripts/provocar-falla.sh crash                # provoca la falla y mide MTTD/MTTR (deja el JSON en evidencias/)
./scripts/provocar-falla.sh dependencia          # caso "no actuar": /health 503 con el pool sano → escala sin reiniciar
./scripts/provocar-falla.sh limpiar
./scripts/provocar-falla.sh fuga                 # alerta temprana de memoria + reciclaje del pool (Reto 2)
./scripts/evidencia-reto2.sh                     # Pester del Reto 2 en Windows PowerShell 5.1 dentro de la VM
./scripts/destruir.sh                            # elimina TODO (antes, guardar las capturas)
```

**Validación sin desplegar** (también corre en CI):

| Validación | Comando | Resultado |
|---|---|---|
| Bicep | `bicep build infra/main.bicep` y `bicep lint` | 0 advertencias |
| KQL | `pwsh tests/Test-Kql.ps1 -Dll <Kusto.Language.dll>` (paquete NuGet `Microsoft.Azure.Kusto.Language`) | 28 consultas (archivo, alertas y workbook, incluida la tabla de triage del Reto 4), 0 errores contra el esquema real de las tablas |
| Runbook | `KIT=<ruta al kit> Invoke-Pester tests/Runbook.Tests.ps1` | 18/18 (salvaguardas y decisiones del script en la VM, simuladas). Sin `KIT` se omite la prueba que lee la alerta de ejemplo del kit: 17 + 1 omitida |
| PowerShell | PSScriptAnalyzer | 0 hallazgos; sintaxis compatible con 5.1 y 7 |

## Qué se construyó (puntos 10 a 16)

| # | Pedido | Implementación | Archivo |
|---|---|---|---|
| 10 | VM Windows Server con IIS y sitio de prueba | B2s, Server 2022 Gen2, Trusted Launch, zona horaria de Bogotá, IP privada 10.20.4.15 como en el caso. **Sin RDP**: se administra con Run Command. Sitio `PortalPagos` (ID 2 → `W3SVC2`) y pool `PortalPagosPool` (.NET 4, 32 bits, Rapid-Fail 5/5 min). `/fallar.aspx` provoca 500, lentitud o crash de w3wp **solo desde la propia VM** | `infra/recursos.bicep`, `vm/configurar-vm.ps1`, `vm/sitio/` |
| 11 | Logs IIS, eventos y contadores en Log Analytics | **AMA + DCR**: W3C → `W3CIISLog`; System (WAS y errores) y Application (errores + fuentes Andina*) → `Event`; contadores cada 60 s (CPU, memoria, disco, Private Bytes de w3wp, conexiones, cola ASP.NET, **estado del pool**) → `Perf`. Workspace con 30 días de retención y tope diario de 1 GB | `infra/recursos.bicep` |
| 12 | KQL para las preguntas del Reto 1 | Disponibilidad real (3 definiciones), 5xx, p50/p95/p99, eventos del pool, señales tempranas, trazabilidad de la remediación, MTTD/MTTR | `kql/consultas.kql` |
| 13 | ≥ 2 alertas con sentido operativo | 6 alertas (tabla abajo), definidas como datos | `infra/alertas.json` |
| 14 | Auto-remediación con salvaguardas | Runbook de Automation disparado por la alerta: límite de intentos, cuándo no actuar, escalamiento y trazabilidad | `runbook/Restaurar-PoolIIS.ps1` |
| 15 | Tablero para la directora y el NOC | Azure Workbook con dos pestañas | `infra/workbook.json` |
| 16 | Evidencia + tiempos de detección y recuperación | `provocar-falla.sh` deja la marca T0 y mide desde Log Analytics | `evidencias/` |
| + | IaC y costo | Bicep completo con presupuesto incluido. Costo abajo | `infra/` |

### Una lección del Reto 1 aplicada aquí

- **La sonda mide lo que vive el cliente.** Cuando el pool se cae, IIS no escribe nada en el log W3C (los 503 quedan en HTTP.sys). Por eso la disponibilidad se calcula con una **sonda sintética** que corre cada 20 s y deja un evento por resultado, no con `/health` en el log de IIS. El tablero muestra las dos líneas para que se vea la diferencia.
- **`/health` es profundo:** devuelve 503 si la memoria del proceso o una dependencia están mal, no solo "el servidor responde".
- **La alerta de ejemplo del kit no funciona tal cual.** En `W3CIISLog`, `scStatus` es **texto**, así que `countif(scStatus >= 500)` es un error de tipos ("operator '>=' is not defined for string and long"). Lo detectó el validador KQL. Todas las consultas de este reto usan `toint(scStatus)`.

## Alertas (punto 13)

| Alerta | Sev. | Cada / ventana | Condición | Por qué ese umbral | Acción |
|---|---|---|---|---|---|
| **PortalPagos-Sitio-NoDisponible** | 1 | 1 min / 5 min | Más de 1 señal en 5 min: sondas fallidas o WAS 5002 (pool deshabilitado). Consulta de un solo `where`, porque las alertas de 1 min no admiten `let`/`union` | Con 2 señales se descarta un error aislado de red. **No se auto-resuelve** y se silencia 5 min: en la prueba, una alerta con resolución automática tardó ~16 min en resolverse y mientras tanto no volvía a disparar. Así, una recaída vuelve a llegar al runbook y este la escala | **Runbook** + correo |
| PortalPagos-5xx-Alto | 2 | 5 min / 5 min | > 5 % de 5xx de usuarios **y** ≥ 20 solicitudes | El mismo 5 % del ejemplo, pero con volumen mínimo para no despertar a nadie por 1 de 3 solicitudes de madrugada. El 18-sep la tasa llegó a 15 % desde las 13:23: **habría avisado ~70 min antes de la caída total** | Correo NOC |
| PortalPagos-Memoria-Pool | 3 | 5 min / 15 min | Private Bytes de w3wp **siempre** > 800 MB en 15 min | 2,5 veces el máximo normal (~320 MB) y sostenido, para que no salte por un pico. Con los datos del kit se habría cumplido el 16-sep a las 15:10, **unas 46 h antes** del primer error (la señal del Reto 1, 2× el máximo previo, es anterior: 12:10, 49 h). Ruido esperado: mientras exista la fuga, la memoria pasa de 800 MB antes de cada reciclaje por memoria (~977 MB, ~1 vez por día hábil según el Reto 2), así que esta alerta saltará casi a diario. Es intencional: recuerda que la causa raíz sigue abierta, y por eso **no se cuenta como alerta no accionable** en la meta de ruido del Reto 5 (cada disparo es evidencia para desarrollo). Cuando se corrija la fuga, se sube el umbral por encima del reciclaje (~977 MB) o se desactiva | Correo NOC |
| PortalPagos-Disco-C-Bajo | 2 | 15 min / 30 min | Promedio < 15 % libre | Deja ~1 día de margen al ritmo observado (7 GB/día). El 10 % (crítico del Reto 2) llega tarde | Correo NOC |
| PortalPagos-Remediacion-Escalada | 1 | 5 min / 10 min | El job del runbook terminó en *Failed*, o hubo un evento 3002/3003 de advertencia en la VM | Si la automatización no pudo o no debía actuar, el problema es de una persona **ya** | Correo NOC |
| PortalPagos-VM-SinSenal | 1 | 5 min / 1 h | Sin heartbeat > 5 min | Sin VM no hay sonda ni remediación: hay que saberlo | Correo NOC |

Todas son *stateful* (`autoMitigate`), **salvo *Sitio-NoDisponible***: avisan una vez y se resuelven solas cuando la condición desaparece, así no hay tormentas de correos. *Sitio-NoDisponible* no se resuelve sola a propósito (ver su fila y el supuesto 7). **Las severidades siguen el impacto en el cliente:** Sev1 = no puede pagar · Sev2 = se degrada · Sev3 = todavía no lo nota.

## Triage con IA (Reto 4, suma puntos)

La misma alerta *Sitio-NoDisponible* también dispara el runbook **Triage-Alerta** (Python 3.10). Este arma el contexto desde Log Analytics, le pide a Azure OpenAI un resumen con evidencia verificada y lo deja en la tabla "Triage con IA" de la pestaña NOC. **Solo sugiere.** Ver `../reto4-triage-ia/`.

## Auto-remediación (punto 14)

**Disparo:** la alerta *Sitio-NoDisponible* llama al grupo de acciones, este al webhook y el webhook al runbook `Restaurar-PoolIIS` (esquema común de alertas). Corre con la **identidad administrada** de Automation, con el rol *Virtual Machine Contributor* **solo sobre la VM**. El URI del webhook es un secreto: lo genera `desplegar.sh` en cada despliegue y nunca se escribe en disco ni en el repositorio.

| Salvaguarda | Regla | Configurable en |
|---|---|---|
| Interruptor | `AutoRemediacionHabilitada = false` → no actúa y escala | Variable de Automation |
| Alcance | Solo VM en `VmPermitidas` → otra VM: escala | Variable |
| Cuándo no actuar | Alerta *Resolved* → omite · pool *Started* con `/health` 200 (falso positivo) → no hace nada · ventana 02:00–02:30 (reciclaje programado del Reto 2) → **no reinicia**, pero verifica y escala si el portal sigue caído. *Este último cambio se hizo el 04-oct por la noche, después de eliminar el laboratorio: está cubierto por Pester (18/18), pero no se ejecutó en Azure* | Variables / código |
| No esconder otra causa | Pool *Started* pero `/health` ≠ 200 (por ejemplo, una dependencia caída) → **no reinicia** y escala: reiniciar no lo arregla y borraría evidencia | Código (en la VM) |
| Límite de intentos | Máximo 3 en 60 min → no reinicia; verifica el estado real y escala si sigue caído | `MaxIntentos` |
| Anti-bucle | Si hay otra alerta < 15 min después de la última remediación, **no reinicia**: verifica en la VM (solo lectura). Si el portal sigue caído, escala; si ya responde, es una alerta residual y no hace nada | Código |
| Verificación | Tras `Start-WebAppPool`, hasta 6 × 5 s esperando `/health` 200; si no llega → *Fallido* y escala | Código |
| Escalar a una persona | El job termina en *Failed* con el motivo → alerta *Remediacion-Escalada* (Sev1) → correo. Un error inesperado del propio runbook también termina en *Failed* y también escala, lo que es deseable (si la automatización falla, debe saberlo una persona); se distinguen por el mensaje: las escaladas intencionales empiezan con `ESCALAR:` en la traza | Alerta |

**Trazabilidad:** cada decisión queda en (1) la salida JSON del job (JobStreams → Log Analytics) y (2) eventos en la VM, fuente `AndinaRemediacion`: 3000 inicio · 3001 recuperado · 3002 falló · 3003 sin acción o escalado. Ambas fuentes se ven juntas en la consulta Q7 y en la pestaña NOC.

### Defecto encontrado y corregido en la prueba en vivo del 04-oct

La primera versión escalaba **sin mirar el estado real** cuando aplicaba la regla anti-bucle. **Ya había ocurrido el 02-oct y pasó inadvertido:** en `capturas/04` se ve el job del crash #4 *Completado* a las 11:50 y otro *en Error* a las 11:55, justo al terminar los 5 min de silencio de la alerta; la traza de ese job no se guardó, pero el patrón es el mismo. Como *Sitio-NoDisponible* mira 5 min hacia atrás y no se resuelve sola, se volvía a disparar ~4 min **después** de una recuperación exitosa, y el runbook escalaba con el motivo "el pool volvió a caer" aunque el portal estaba sano: **un correo de emergencia falso tras cada recuperación** (20:42:41 hora UTC-5; traza en `evidencias/runbook-decisiones-20261004.txt`). Ahora el límite y la reincidencia devuelven `Verificar`: el runbook consulta la VM sin tocar nada y solo escala si sigue caído. Verificado en Azure a las 21:00:02: *Recibida → Verificar → SinAccion* y el job terminó *Completed* (`runbook-salida-alerta-residual-corregida.txt`). Dos pruebas Pester nuevas cubren ambos caminos.

## Tablero (punto 15)

**Workbook "PortalPagos · Dirección y NOC"**, con dos pestañas sobre los mismos datos:

| Pestaña | Qué muestra |
|---|---|
| **Dirección** | Cuatro indicadores: disponibilidad real, % de solicitudes exitosas, minutos con falla y recuperaciones automáticas frente a escaladas. La disponibilidad real se compara con la que medía el NOC antes, y hay una tabla de incidentes con duración, MTTD y cómo se resolvió. En lenguaje de negocio, sin KQL a la vista |
| **NOC** | Sonda por minuto, % de 5xx, p50/p95, memoria de w3wp (con el umbral de alerta y de reciclaje), disco, eventos WAS/.NET, decisiones de la auto-remediación y código de salida del mantenimiento del Reto 2 |

**Defecto corregido: la leyenda sumaba los valores.** Debajo de cada gráfico de línea el workbook mostraba la serie **sumada** (agregación por defecto): "p95 2,56 m", "disco libre 280 %" (`capturas/07`, versión anterior). La propiedad correcta se obtuvo del propio editor de Azure (04-oct, en un workspace temporal ya eliminado): `"aggregation"` en cada gráfico, con **2 = máximo, 3 = promedio, 5 = último**, comprobados uno por uno. Quedó así: disponibilidad y latencia, promedio; % de 5xx y memoria, máximo (se comparan con sus umbrales); disco, último. También se acortaron los títulos de los indicadores, que se cortaban (`capturas/06`). Verificado con datos de ejemplo en `capturas/11` y `capturas/12`; no se volvió a desplegar el tablero completo, porque el laboratorio ya no existe.

## Evidencia y tiempos (punto 16) · ejecutado el 1, 2 y 4-oct-2026 en East US 2

`./scripts/provocar-falla.sh <escenario>` deja el evento `AndinaPrueba 4000` (T0), provoca la falla y consulta Log Analytics hasta ver la recuperación (consulta Q8). Definiciones:

- **primer fallo:** primera sonda fallida, es decir, lo que vería el cliente;
- **detectado:** `firedDateTime` de la alerta;
- **MTTD** = detectado − primer fallo;
- **MTTR** = primera sonda OK − primer fallo.

| Escenario | Qué pasó (automático) | MTTD | MTTR | Evidencia |
|---|---|---|---|---|
| **crash #1** (5 crashes de w3wp → IIS deshabilita el pool, como el 18-sep) | Alerta Sev1 → runbook → `Start-WebAppPool` → `/health` 200 | **1,2 min** | **3,0 min** | `medicion-crash-1.json`, `runbook-salida-crash-1.txt` |
| **crash #2** (con la configuración final) | Igual | **1,6 min** | **3,3 min** | `medicion-crash-2.json` |
| **crash #4** (02-oct, con el triage del Reto 4 conectado) | Igual; la misma alerta dispara también el triage con IA | **1,0 min** | **2,3 min** | `medicion-crash-4-con-triage.json` |
| **crash #5** (04-oct, con capturas) | Alerta Sev1 20:37:01 → runbook → `Start-WebAppPool` → `/health` 200 a las 20:38:20, sin intervención | **1,7 min** | **3,0 min** | `medicion-crash-5-capturas.json`, `capturas/03` a `09` |
| **crash #6** (04-oct, 13 min después del #5) | Anti-bucle: el runbook **no reinició** y escaló a una persona (20:50:56). Con el runbook corregido, la alerta de las 20:55 ya estaba a más de 15 min de la remediación anterior y recuperó solo | ~1,7 min\*\* | 7,7 min (espera anti-bucle, intencional) | `medicion-crash-6-antibucle.json` |
| **crash #3, 5 min después del #2** | El runbook **no reinicia**: escala por reincidencia ("el pool volvió a caer 5 min después de la última remediación"). Job *Failed* → alerta *Remediacion-Escalada* → correo. Una persona inicia el pool | **No medible**\* | 5,3 min (manual) | `runbook-salida-reincidencia.txt`, `resultados-kql.json` (Q8). *Es el comportamiento de la versión de entonces; con la actual pasaría por `Verificar` y escalaría igual, porque el pool seguía caído* |
| **dependencia** (`/health` 503 con el pool sano) | El runbook **no reinicia**: "Pool Started pero /health=503: la causa no es el pool". Escala → correo | **0,8 min** | 5,4 min (al quitar la falla) | `runbook-salida-dependencia.txt` |
| **fuga** (2.200 pagos confirmados con la fuga activa) | La memoria de w3wp sube de 48 a 942 MB en ~10 min (muestras cada 5 min). IIS **recicla el pool por memoria** (WAS 5117 "reached its private bytes memory limit", 03:40:50) **sin errores**: 0 de 2.660 solicitudes con 5xx entre 03:35 y 03:45, p95 de 243–245 ms | — (no hubo falla) | — | `resultados-kql.json` (Q3a, Q4, Q5a, Q6) |

\* **Por qué no se puede medir la detección del crash #3:** la prueba se lanzó 5 min después de que se recuperó el crash #2. La alerta *Sitio-NoDisponible* mira 5 min hacia atrás y no se resuelve sola, así que a las 03:29:03 todavía se estaba disparando por las fallas del crash #2: no es una detección del crash #3. Además, el runbook escaló antes de llegar a la VM, así que no hay evento 3000/3003 y Q8 deja `detectado` vacío. El archivo `medicion-crash-3-reincidencia.json` tiene los valores en `None` porque el script dejó de esperar antes de la recuperación manual; los valores definitivos (MTTR 5,3 min) están en Q8. Para medir una reincidencia limpia hay que esperar > 5 min entre pruebas.

\*\* Q8 reporta 6,7 min porque toma la detección de los eventos 3000/3003 de la VM, y la primera alerta (20:50:04) escaló antes de llegar a la VM. El disparo real está en la traza del job y en `../reto4-triage-ia/evidencias/runbook-triage-alerta-20261004.json`.

**Frente al 18-sep:** el MTTD fue ∞ (lo detectaron los clientes) y el MTTR de 101 min. En el laboratorio, con recuperación automática (crashes #1, #2, #4 y #5), el MTTD fue de 1,0–1,7 min y el MTTR de 2,3–3,3 min, sin intervención humana. La caída por memoria, que fue la causa raíz del 18-sep, **no llegó a ocurrir**: el reciclaje del Reto 2 la evitó.

**La lección del Reto 1, reproducida con datos reales del laboratorio (Q1):** en la hora de las pruebas, la disponibilidad medida por la sonda fue **61,3 %**, mientras que "solicitudes de usuario OK según el log de IIS" daba **100 %**. Cuando el pool está deshabilitado, IIS no escribe nada en W3C. Es exactamente el sesgo que hizo que el NOC reportara "sin novedades".

Resultados de todas las consultas (Q1–Q8) sobre los datos reales: `evidencias/resultados-kql.json`. **Capturas del portal** (04-oct, crash #5): `evidencias/capturas/`, 10 imágenes, del grupo de recursos y el presupuesto con alertas hasta la alerta disparada, el job del runbook con su salida, el tablero (Dirección y NOC) y la DCR. El índice está en `evidencias/LEEME.md`. En las imágenes, el ID de la suscripción quedó tapado.

## Costo estimado

Precios de lista en East US, pago por uso, a septiembre de 2026. Se verifican en la calculadora de Azure antes de desplegar.

| Recurso | Precio | 5 días 24/7 | Mes |
|---|---|---|---|
| VM B2s Windows | US$ 0,0496/h ([economize.cloud](https://www.economize.cloud/resources/azure/pricing/virtual-machine/b2s/)) | US$ 5,95 | US$ 36,21 |
| Disco SO StandardSSD E4 (32 GB) | ≈ US$ 2,40/mes | US$ 0,40 | US$ 2,40 |
| IP pública Standard estática | ≈ US$ 0,005/h | US$ 0,60 | US$ 3,65 |
| Log Analytics | US$ 2,30/GB; **5 GB/mes gratis** ([ManageEngine](https://www.manageengine.com/it-operations-management/blog/azure-monitor-alternatives.html)). El laboratorio ingiere ~0,1 GB/día | US$ 0 | US$ 0 |
| 6 alertas de logs | ≈ US$ 0,5–3/regla/mes según frecuencia (1 a 1 min, 4 a 5 min, 1 a 15 min) | ≈ US$ 1,60 | ≈ US$ 9,50 |
| Automation | 500 min de job/mes gratis (cada remediación dura ~1 min) | US$ 0 | US$ 0 |
| Workbook, DCR, grupos de acciones (correo), presupuesto | Sin costo | US$ 0 | US$ 0 |
| **Total** | | **≈ US$ 8,5** | **≈ US$ 52** |

**Control de costo:** presupuesto mensual de US$ 15 con aviso al 50 % y 80 % del gasto real y al 100 % del pronóstico; tope diario de 1 GB en el workspace; etiqueta `eliminarAlTerminar=si`; y `destruir.sh`, que borra el grupo de recursos y el workspace sin soft-delete. Para bajar más el costo se puede usar B1s, que entra en las 750 h gratis, aunque con 1 GB de RAM Windows + IIS + AMA va muy lento.

## Supuestos y decisiones

1. **Sitio de prueba en ASP.NET 4.8 (Web Forms en línea)** en vez de la app real. Reproduce lo que importa: el pool, Rapid-Fail, la fuga por pago confirmado y los crashes de w3wp.
2. **Sonda interna (desde la propia VM).** Mide la app y el pool, no la red ni el DNS públicos. Como mejora con costo queda una prueba de disponibilidad de Application Insights desde varias regiones. El heartbeat cubre el caso "VM caída". **Límite conocido:** si la VM se cuelga sin dejar de enviar heartbeat y la sonda deja de escribir eventos, *Sitio-NoDisponible* no se dispara, porque cuenta fallas y no ausencias. La sonda externa (iniciativa 2 del Reto 5) cierra ese hueco.
3. **La remediación reinicia el pool y nada más.** No reinicia IIS completo ni la VM: eso sería otra decisión, con más impacto, que le corresponde a una persona.
4. **Variables de Automation para el estado y la configuración.** `HistorialRemediacion` se reinicia si se vuelve a desplegar la infraestructura; es aceptable para el laboratorio, y en producción iría en una tabla de Storage. **Límite conocido: no hay control de concurrencia.** Si dos jobs arrancan en el mismo instante, ambos leen el historial antes de que el otro escriba y podrían reiniciar dos veces. Lo atenúan el silencio de 5 min de la alerta y que `Start-WebAppPool` sobre un pool ya iniciado no hace nada; en producción se resolvería con un *lease* (blob con ETag) o una cola de un solo consumidor.
5. **Región East US 2:** disponible en suscripciones de estudiante y barata. Se cambia con `LOCATION`.
6. **Webhook:** el URI vence a los 90 días y se regenera en cada despliegue.
7. **Alertas sin resolución automática:** la regla de remediación crea una instancia nueva por minuto mientras dura la falla (las acciones se silencian 5 min). El listado de alertas se llena más (en la prueba hubo 15 instancias durante una caída), pero una recaída nunca queda sin atender. En producción se agruparían con una regla de procesamiento de alertas.
