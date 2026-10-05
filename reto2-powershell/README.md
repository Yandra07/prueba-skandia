# Reto 2 · Modernizar el mantenimiento

| Entregable | Archivo |
|---|---|
| Problemas del .BAT, ordenados por riesgo | [`PROBLEMAS_Y_DECISIONES.md`](PROBLEMAS_Y_DECISIONES.md), primera sección |
| Script PowerShell que lo reemplaza | `src/Invoke-MantenimientoPortalPagos.ps1` + módulo `src/MantenimientoPortal/` |
| Instalación (tarea con gMSA, fuente de eventos, reciclaje del pool) | `src/Instalar-MantenimientoPortalPagos.ps1` |
| Pruebas Pester (39) y evidencia | `tests/`, `evidencias/` |
| Qué pasos desaparecen y con qué se reemplazan | [`PROBLEMAS_Y_DECISIONES.md`](PROBLEMAS_Y_DECISIONES.md), segunda sección |

## Requisitos mínimos del enunciado → dónde se cumplen

| Requisito | Implementación |
|---|---|
| Parámetros validados | `ValidateRange`, `ValidateScript` y `ValidatePattern` en cada parámetro. Además se revalidan los valores por defecto y la coherencia entre umbrales (crítico < aviso). Las rutas a borrar pasan por `Test-RutaSegura`: nunca la raíz de una unidad, nunca menos de 2 niveles de profundidad (1 para la carpeta de volcados, como `C:\CrashDumps`, donde solo se borran `*.dmp` viejos), nunca carpetas del sistema |
| Modo simulación | `-WhatIf` en el script, propagado a cada función con `SupportsShouldProcess`. El log de la simulación sí se escribe, con `"simulacion": true` |
| Errores con código de salida confiable | Cada paso devuelve OK / Aviso / Error y el código final es el peor de todos: 0 / 2 / 3. El 1 queda para parámetros inválidos (el mismo que usa PowerShell) y el 4 para el candado. Ver la tabla en `PROBLEMAS_Y_DECISIONES.md` |
| Log estructurado | JSON Lines, una línea por evento: `ts` (ISO 8601 con zona), `host`, `runId`, `simulacion`, `nivel`, `paso`, `mensaje`, `datos`. Más un evento resumen en *Application* (fuente `AndinaMantenimiento`, Id = 1000 + código), que se puede omitir con `-OmitirEvento` (lo usan las pruebas) |
| Sin credenciales en el código | La tarea corre como **gMSA** y accede al share por UNC con su propia identidad. Una prueba Pester revisa el código en busca de `net use`, `/user:` y contraseñas |
| Se puede ejecutar varias veces sin efectos no deseados | Copia incremental (tamaño + fecha, y hash para lo que se va a purgar), copia atómica `.partial` → renombre, borrado solo de lo vencido y archivado, servicio "asegurar estado" en vez de reiniciar, y candado de ejecución única. Hay una prueba que ejecuta dos veces y compara el estado del disco |

## Uso

```powershell
# simulación (no cambia nada; escribe el log con simulacion=true)
.\src\Invoke-MantenimientoPortalPagos.ps1 -WhatIf -Verbose

# ejecución real con valores por defecto de WEB-PAGOS-01
.\src\Invoke-MantenimientoPortalPagos.ps1 -RutasLogsApp 'C:\inetpub\PortalPagos\logs'

# instalación en el servidor (administrador). Revisar primero con -WhatIf.
# La ruta de los logs de la app se pasa a la tarea: sin ella no hay retención ni modo "presión de disco" sobre esos logs
.\src\Instalar-MantenimientoPortalPagos.ps1 -CuentaGmsa 'ANDINA\gmsa-mant-web$' -ArgumentosTarea '-RutasLogsApp', 'C:\inetpub\PortalPagos\logs' -WhatIf
```

**Modo "presión de disco".** Si después de la retención normal el disco sigue por debajo de `UmbralDiscoAvisoPct`, el script borra logs de la aplicación del más viejo al más nuevo hasta recuperar el umbral, sin bajar nunca de `DiasMinimosApp` días. Nunca toca los logs IIS (auditoría) ni los volcados recientes (evidencia), y siempre termina al menos en Aviso (2), porque necesitarlo significa que algo sigue llenando el disco. Motivo, con los datos del Reto 1: el disco se consume a ~6,8 GB por día hábil y ~39 GB por semana, muy probablemente por los logs en *Debug* (hipótesis del Reto 1, por confirmar). Si el consumo resultara ser otra cosa, el modo presión de disco no hace daño: solo borra logs de la aplicación y nunca baja de 1 día. Con 7 días de retención, más los 8,7 GB de volcados del 18-sep (que se conservan como evidencia), el espacio libre en régimen queda por debajo de cero: **la retención fija sola no evita que C: se llene**. La solución de fondo sigue siendo bajar el nivel de log a *Information* (cambio de la aplicación).

| Parámetro | Por defecto | Validación |
|---|---|---|
| `RutaLogsIis` | `C:\inetpub\logs\LogFiles\W3SVC2` | Debe existir |
| `RutaAuditoria` | `\\fs-auditoria\logs$\WEB-PAGOS-01` | UNC o ruta absoluta. Vacía = no archiva y **no purga** IIS |
| `RutasLogsApp` | *(ninguna)* | Cada una debe existir |
| `RutaDumps` | `C:\CrashDumps` | Ruta absoluta (unidad, UNC o `/ruta`). Si no existe, no hace nada |
| `DiasRetencionIis` / `DiasRetencionApp` | 14 / 7 | 3–365 / 1–90 |
| `DiasMinimosApp` | 1 | 1–90 y ≤ `DiasRetencionApp`. Piso del modo "presión de disco" |
| `DiasMinimosDumps` / `DumpsConservar` | 14 / 5 | 3–365 / 1–50 |
| `UmbralDiscoAvisoPct` / `UmbralDiscoCriticoPct` | 20 / 10 | Crítico < aviso |
| `NombreServicio` / `NombrePool` | `Servicio Notificaciones` / `PortalPagosPool` | Letras, números, espacio, `.`, `-`, `_` (máx. 80 / 64). Vacío = se omite el paso |

## Pruebas

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck
.\tests\Invoke-Pruebas.ps1          # deja pester-resultados.xml (NUnit) y pester-resumen.txt en evidencias\
```

Las pruebas usan carpetas temporales (`TestDrive`), simulan el servicio, el pool y el disco, y corren con `-OmitirEvento`, así que no tocan el sistema (ni la raíz del disco ni el registro *Application*). Cubren:

- salvaguardas de rutas, incluido el caso `%LOGDIR%` vacío;
- `-WhatIf`;
- archivado verificado y purga por retención;
- idempotencia;
- share caído (no purga, código 3) y copia corrupta en auditoría (la detecta y la recopia);
- retención de logs de app y de dumps, incluido un dump bloqueado que da Error sin abortar los pasos siguientes;
- modo "presión de disco": se detiene al recuperar el umbral, respeta el piso de días, no actúa sin presión, en `-WhatIf` no borra y nunca toca logs IIS ni volcados recientes;
- los 5 casos del servicio;
- disco crítico y pool detenido;
- candado;
- formato del log;
- códigos de salida reales del proceso (1, 0, 3), incluidos los umbrales incoherentes;
- ausencia de credenciales.

**Evidencia en `evidencias/`:**

| Archivo | Contenido |
|---|---|
| `pester-resumen.txt` / `pester-resultados.xml` | Historial de corridas. La última: **38 + 1 omitida (solo Windows) en PowerShell 7.4.6 (macOS)**; las anteriores, 27/27 en Linux. El XML no guarda el nombre del equipo, el usuario ni la ruta local |
| `scriptanalyzer.txt` | 0 hallazgos en `src`; compatibilidad de sintaxis con 5.1 y 7.0 = 0 hallazgos |
| `ejecucion-demo.txt` + `ejemplo-log.jsonl` | Corrida de punta a punta (simulación, real, repetición, share caído, parámetro inválido y presión de disco). Se regenera con `generar-demo.sh` (Linux o macOS) |
| `../reto3-azure/evidencias/reto2-en-vm.txt` | **27/27 pruebas en Windows Server 2022 / Windows PowerShell 5.1.20348** con la versión del 01-oct; mantenimiento real con código 0, `-WhatIf` con 0 y parámetro inválido con 1; tarea `\Andina\MantenimientoPortalPagos` registrada; pool con `privateMemory=1000000 KB`, reciclaje a las 02:00 y sin intervalo fijo. Limitaciones del archivo en `../reto3-azure/evidencias/LEEME.md` |

**Verificado en Windows (04-oct):** `../reto3-azure/evidencias/reto2-en-vm-20261004.txt`: **38/38 Pester en Windows PowerShell 5.1** (la prueba 39, de validación de nombres y rutas, se agregó el 04-oct por la noche, después de eliminar el laboratorio, y solo se ejecutó en PowerShell 7) (incluida la prueba de bloqueo real de archivos, que en macOS/Linux se omite) y mantenimiento real con **código 0**. La corrida anterior (`…-antes-correccion.txt`) muestra el defecto del log abierto.

## Supuestos

1. Existe (o la crea el equipo de AD) una gMSA con escritura en el share de auditoría y derecho de "iniciar sesión como proceso por lotes". Mientras no exista, la tarea puede correr como `NT AUTHORITY\SYSTEM`: la cuenta de equipo `WEB-PAGOS-01$` también se puede autorizar en el share. En ningún caso se usa contraseña.
2. La política de auditoría exige conservar en el share **todos** los logs de IIS. Por eso nunca se borra un log local que no esté archivado y verificado, aunque el disco esté lleno: en ese caso el script termina en Error (3) para que alguien actúe.
3. Los logs de la aplicación (Serilog) no son de auditoría: se aplica retención local y, si el disco lo exige, el modo "presión de disco". Su ruta no viene en el kit y se pasa con `-RutasLogsApp`.
4. Retención local de logs IIS: 14 días (el .BAT usaba 7). Ocupan ~5–9 MB/día, así que el costo en disco es despreciable y da margen para diagnosticar.
5. Un log se archiva si no se modificó en los últimos 120 minutos **y no está abierto por otro proceso**. La primera versión solo miraba la fecha, y en NTFS la fecha de un archivo abierto no se actualiza: el log del día "parecía" cerrado, la copia fallaba y el mantenimiento real terminó en Error 3 noches seguidas en la VM (02 al 04-oct). Ahora un log en uso se salta sin error (se archiva en la siguiente ejecución, y mientras tanto no se purga); si sigue bloqueado más de 1 día, Aviso.
6. El límite de reciclaje del pool (1.000.000 KB ≈ 977 MB) se calibró con el techo de OutOfMemory observado (~1,4–1,5 GB) y con la hipótesis de que el pool es de 32 bits. Con el modelo del Reto 1 (≈304 MB tras el reinicio + 0,496 MB por pago confirmado), el límite se alcanza a los **~1.356 pagos** desde el último reciclaje. Un día hábil normal tiene entre 1.539 y 1.805 pagos, así que **el pool se reciclaría una vez por día hábil, por la tarde**, y unas dos veces en un día de fin de plazo como el 18-sep. Cada reciclaje pierde las sesiones de pago en curso del proceso viejo (sin 503 gracias al *overlapped recycle*). Es el costo aceptado mientras desarrollo corrige la fuga; después se revisa el límite.
