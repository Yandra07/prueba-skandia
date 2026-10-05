# Evidencias del Reto 3

## Ya generadas (sin Azure)

| Archivo | Qué prueba |
|---|---|
| `kql-validacion.txt` | Las 28 consultas (archivo, alertas y workbook) compilan contra el esquema real de las tablas |
| `pester-runbook.txt` / `.xml` | Salvaguardas del runbook y decisiones en la VM (16/16 el 03-oct; 18/18 tras la corrección del 04-oct, con `KIT`) |
| `scriptanalyzer.txt` | Scripts de la VM y del runbook: 0 hallazgos, compatibles con 5.1 y 7 |
| `bicep-lint.txt` | Plantillas Bicep sin advertencias |

## Del laboratorio ejecutado (1-oct-2026)

| Archivo | Qué prueba |
|---|---|
| `configuracion-vm.json` | Estado de la VM al terminar la configuración: IIS, pool, tareas y `/health` 200 |
| `medicion-crash-1.json`, `medicion-crash-2.json` | MTTD 1,2 / 1,6 min y MTTR 3,0 / 3,3 min, con recuperación automática |
| `medicion-crash-3-reincidencia.json` + `runbook-salida-reincidencia.txt` | El runbook no reinicia por segunda vez en 15 min: escala. Los valores `None` y la falta de MTTD se explican abajo |
| `medicion-dependencia.json` + `runbook-salida-dependencia.txt` | Pool sano con `/health` 503: no reinicia, escala |
| `runbook-salida-crash-1.txt` | Traza JSON del job: recibida → recuperado (pool Stopped→Started, health 503→200) |
| `resultados-kql.json` | Q1–Q8 sobre los datos reales, incluida la disponibilidad real (61 %) frente a la que dan los logs de IIS (100 %) |
| `reto2-en-vm.txt` | Reto 2 en Windows PowerShell 5.1 (versión del 01-oct): 27/27 Pester y mantenimiento real con código 0. Ver las limitaciones abajo |
| `medicion-crash-4-con-triage.json` | Crash con la remediación y el triage IA disparados por la misma alerta: MTTD 1,0 min, MTTR 2,3 min |

### Limitaciones de `medicion-crash-3-reincidencia.json`

- **Se corrigió solo su sintaxis** (03-oct): terminaba con una `}` de más por un error de `provocar-falla.sh` (`"${FILA:-{}}"`), ya corregido. Los valores quedaron tal como salieron.
- **Valores en `None`:** el script dejó de esperar antes de que una persona recuperara el pool. Los valores definitivos están en Q8 (`resultados-kql.json`): primer fallo 03:28:46, recuperado 03:34:07, **MTTR 5,3 min**.
- **MTTD no medible:** la alerta de las 03:29:03 todavía respondía a las fallas del crash #2 (ventana de 5 min sin resolución automática). Ver la nota del README.
- Los acentos dañados de `runbook-salida-*.txt` (`volviÃ³`) vienen de la salida del job de Automation; se dejan sin editar.

### Limitaciones conocidas de `reto2-en-vm.txt`

Se deja tal como salió de la VM, sin editar, porque es evidencia. Hay que leerlo con tres salvedades:

1. **Está truncado al inicio.** Azure Run Command devuelve solo los últimos 4 KB, y las líneas `What if:` de las pruebas de `-WhatIf` consumieron casi todo ese espacio. Las líneas del resumen (PESTER, MANTENIMIENTO, TAREA, POOL y EVENTOS) sí están completas, al final del archivo.
2. **Tiene caracteres dañados** (`A·` en lugar de `·`, `cA3digo` en lugar de `código`), porque Run Command no respeta la codificación.
3. **El `1003/Error` de la línea EVENTOS lo generó una prueba**, no el mantenimiento real: la prueba "share caído => 3" ejecutaba el script completo y, como la fuente de eventos existía, escribía en *Application*.

Corregido para próximas corridas (03-oct): `vm/evidencia-reto2.ps1` ahora ejecuta Pester en un proceso aparte, lee el resultado del XML NUnit y devuelve solo ASCII. Las pruebas del Reto 2 corren con `-OmitirEvento`, así que ya no escriben en el registro real. No se volvió a ejecutar porque el laboratorio ya no está desplegado.

## Prueba en vivo con capturas (4-oct-2026)

| Archivo | Qué prueba |
|---|---|
| `medicion-crash-5-capturas.json` | Crash #5: MTTD 1,7 min, MTTR 3,0 min, recuperación automática (alerta → runbook en 75 s) |
| `medicion-crash-6-antibucle.json` | Crash #6, 13 min después: el anti-bucle no reinicia y escala; ver la nota del README sobre el MTTD |
| `runbook-salida-alerta-residual-corregida.txt` | Runbook corregido ante una alerta residual: *Recibida → Verificar → SinAccion*, sin escalada falsa |
| `runbook-decisiones-20261004.txt` | Traza de decisiones del runbook del 04-oct desde Log Analytics: la **escalada falsa** de las 01:42:41Z (antes de corregir), la escalada correcta del crash #6 y la verificación sin escalada después de corregir |
| `limpieza-20261004.txt` | Salida de Azure CLI de la eliminación: `az group exists` = false, sin recursos con la etiqueta del proyecto, sin nada en soft-delete y Azure OpenAI purgado |
| `reto2-en-vm-20261004-antes-correccion.txt` | Reto 2 en 5.1: 35/35 Pester, pero el mantenimiento real daba **3** (y llevaba 3 noches así): copiaba el log del día abierto por IIS |
| `reto2-en-vm-20261004.txt` | Tras la corrección: **38/38 Pester en Windows PowerShell 5.1** (incluida la prueba de bloqueo real) y mantenimiento real con **código 0** |

**Capturas (`capturas/`)**

| # | Archivo | Qué muestra |
|---|---|---|
| 01 | `01-grupo-recursos.jpg` | Todos los recursos del laboratorio |
| 02 | `02-presupuesto-alertas.jpg` | Presupuesto de US$ 15 con alertas al 50 %, 80 % y 100 % (pronóstico) al correo |
| 03 | `03-alerta-disparada.jpg` | *PortalPagos-Sitio-NoDisponible* (Sev1) disparada a las 20:37 |
| 04 | `04-runbook-trabajos.jpg` | Jobs: `Restaurar-PoolIIS` *Completada* a las 20:37 (y el `Triage-Alerta` que falló, ya corregido). Más abajo, del 02-oct: *Completada* a las 11:50 (crash #4) y *Error* a las 11:55, la misma escalada falsa por alerta residual, que entonces pasó inadvertida |
| 05 | `05-runbook-salida-recuperado.jpg` | Salida del job: Recibida → Recuperado (pool Stopped→Started, `/health` 503→200). ID de suscripción tapado |
| 06 | `06-tablero-direccion-indicadores.jpg` | Pestaña Dirección: disponibilidad real 99,72 %, 4 min con falla, 1 recuperación automática |
| 07 | `07-tablero-direccion-incidentes.jpg` | Tabla de incidentes: 8:35 p. m., 3 min, MTTD 1,7, automático (y el defecto de la leyenda "suma") |
| 08 | `08-tablero-noc-sonda-falla.jpg` | Pestaña NOC, última hora: fallas de la sonda de 8:35 a 8:38 p. m. |
| 09 | `09-tablero-noc-remediacion.jpg` | Traza de la auto-remediación: alerta recibida → 3000 → 3001 pool Stopped→Started → Recuperado. La tabla "Triage con IA" aparece vacía porque en ese momento el runbook de triage falló por el formato de fecha (ver Reto 4, caso 7); ya corregido, su salida está en `../../reto4-triage-ia/evidencias/runbook-triage-alerta-20261004.json` |
| 11 | `11-tablero-corregido-prueba-indicadores.jpg` | **Verificación de la corrección del tablero** (04-oct, workspace temporal ya eliminado, datos de ejemplo): los 4 indicadores con los títulos nuevos, sin cortes |
| 12 | `12-tablero-corregido-prueba-leyenda.jpg` | Igual: la leyenda del disco ahora muestra el **último** valor (56,1 %), no la suma |
| 10 | `10-dcr-origenes-datos.jpg` | DCR con sus 3 orígenes (contadores, eventos, IIS) hacia Log Analytics. La 4.ª fila, "Origen de datos desconocido", la agrega el asistente del portal cuando una DCR creada por código tiene configuración que no sabe editar (aquí, consultas XPath con filtros por proveedor y dos flujos de datos); no es un cuarto origen. Las tres tablas recibían datos (W3CIISLog, Event y Perf con filas hasta las 01:02Z del 05-oct) |

**Notificación:** las alertas envían correo por el grupo de acciones (`emailReceivers` en `infra/recursos.bicep`, con el esquema común). Durante la prueba del 04-oct se dispararon *Sitio-NoDisponible* y *Remediacion-Escalada* (ver `runbook-decisiones-20261004.txt`). No se fotografió el correo porque está en un buzón personal al que no se accedió.

**Limpieza (4-oct-2026, 21:13–21:16, hora Colombia):** se eliminó el workspace con `--force` (sin soft-delete) y luego el grupo `rg-portalpagos-lab` completo. Verificado: el grupo no existe y no queda ningún recurso con la etiqueta `proyecto=prueba-tecnica-observabilidad`. La cuenta de Azure OpenAI quedó primero en soft-delete y **luego se purgó** el mismo día, para poder volver a desplegar con el mismo nombre. Salida completa en `limpieza-20261004.txt`.

## Para regenerar

Se generan solos:

- `salidas-despliegue.json` y `configuracion-vm.json`, con el estado de la VM al terminar la configuración;
- `medicion-<escenario>-<fecha>.json`, con el MTTD y el MTTR de cada falla provocada;
- `reto2-en-vm-<fecha>.txt`, con las pruebas Pester del Reto 2 en Windows PowerShell 5.1 y la ejecución real del mantenimiento.

Capturas para tomar **antes** de `destruir.sh`. Se guardan en `capturas/`.

1. Grupo de recursos con todos los recursos, y el presupuesto con su alerta.
2. DCR con sus 3 orígenes (contadores, eventos, IIS) y la VM asociada.
3. Log Analytics con la consulta Q1 (disponibilidad real frente al NOC) y la Q8 (MTTD/MTTR) con resultados.
4. Las 6 reglas de alerta, y la alerta *Sitio-NoDisponible* disparada y luego resuelta.
5. El job del runbook: salida JSON con la decisión y estado *Completed*. Un segundo job con *Failed* para el escenario `dependencia` o de reincidencia.
6. El correo recibido de la alerta *Remediacion-Escalada*.
7. Workbook, pestaña Dirección y pestaña NOC, durante o después de la falla.
8. Opcional: un video de máximo 5 minutos de `provocar-falla.sh crash` con el tablero NOC abierto.
