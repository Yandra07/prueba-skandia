# Reto 2 · Problemas del .BAT y decisiones

Archivo revisado: `scripts/mantenimiento_diario.bat` (36 líneas, "Autor: soporte 2019 - no tocar, funciona"). Las líneas citadas son del archivo original. La evidencia operativa viene del Reto 1 (`reto1-diagnostico/HALLAZGOS_TECNICOS.md`).

## Problemas, ordenados por riesgo

El riesgo combina el impacto (seguridad, pérdida de datos, disponibilidad) con la probabilidad. Varios de estos problemas **ya se materializaron** en la semana del incidente.

| # | Problema | Línea | Qué puede pasar · qué pasó | Riesgo |
|---|---|---|---|---|
| 1 | **Contraseña en texto plano** de `ANDINA\svc_mantenimiento` en `net use … /user:ANDINA\svc_mantenimiento <contraseña>` (se omite aquí a propósito; es ficticia, pero no se replica una credencial) | 31 | Cualquiera que lea `C:\scripts`, un respaldo o un repositorio obtiene la credencial. Además viaja en la línea de comandos, así que queda en el evento 4688 y en las listas de procesos. Es una cuenta de dominio con acceso al share de auditoría | **Crítico** |
| 2 | **`del /q /s %LOGDIR%\*.tmp` sin validar `%1`** | 8, 18 | Si la tarea se invoca sin argumento, `LOGDIR` queda vacío y el comando se convierte en `del /q /s \*.tmp`: **borra todos los .tmp de toda la unidad** de forma recursiva. Una ruta con espacios también rompe `forfiles` y `del` (sin comillas) | **Crítico** |
| 3 | **Falla en silencio y miente**: no revisa ningún `%ERRORLEVEL%`, escribe `Proceso OK` siempre, sin fecha, y termina con `exit /b 0` | 35-36 | **Ya pasó.** Desde el 16-sep, día en que se retiró `D:`, la purga y la copia de auditoría no hacen nada, y el Programador de tareas registra "return code 0" cada noche (TaskScheduler 201) | **Alto** |
| 4 | **`iisreset /restart` todas las noches** "para liberar memoria" | 24 | Detiene **todo** IIS, no solo el pool: ~50 s sin servicio cada noche y transacciones en curso cortadas. **Escondió la fuga de memoria de v2.3.1** durante 3 días (Reto 1). El comentario muestra que el síntoma se conoce desde 2019 y nunca se diagnosticó | **Alto** |
| 5 | **Ruta de logs fija a `D:\logs\iis`**, una unidad que ya no existe | 5, 8 | **Ya pasó.** Desde el 16-sep la purga y la copia no tienen sobre qué actuar. Mientras tanto C:, que el .BAT no limpia, pasó de 48 GB a 11 GB libres y se llena hacia el 22-sep (Reto 1, R1). Los logs de IIS ahora están en `C:\inetpub\logs\LogFiles` | **Alto** |
| 6 | **Purga antes de archivar**, y archiva sin verificar | 15, 32 | Si una noche el share no responde, `forfiles` ya borró los logs con más de 7 días y **esos logs de auditoría se pierden para siempre**. `xcopy /s /y` recopia todo cada noche, sin hash ni reintento | **Alto** (cumplimiento) |
| 7 | **`del /q %CRASHDIR%\*.*` borra todos los volcados**, apuntando a la carpeta equivocada | 10, 21 | Borrar todos los dumps destruye la evidencia forense. Por suerte la ruta está mal (`C:\Dumps`, cuando WER escribe en `C:\CrashDumps`), así que no toca los volcados de WER y los 5 dumps del 18-sep (~8,7 GB) siguen ahí. El resultado es el peor de los dos mundos: ni conserva con criterio ni libera el espacio que ocupan los volcados reales | **Medio** |
| 8 | **Reinicio a ciegas de "Servicio Notificaciones"** | 27-28 | Corta el servicio aunque funcione bien, no revisa servicios dependientes ni el resultado. No hay eventos 7036 del servicio en la ventana 02:00–02:01 en ninguna noche de la semana, así que **probablemente ni siquiera funciona** (hipótesis) | **Medio** |
| 9 | **`net use Z:` con letra fija** | 31, 33 | Si `Z:` ya está mapeada, falla la copia. Si `xcopy` falla, la conexión con la credencial queda abierta hasta el `delete` | **Bajo** |
| 10 | **Sin modo simulación, sin candado de ejecución única, sin tiempo máximo**, y `forfiles /s` recursivo sobre todo `LOGDIR` | — | No se puede probar sin riesgo, dos ejecuciones simultáneas se pisan y borra `*.log` de cualquier subcarpeta | **Bajo** |
| 11 | **"No tocar, funciona"**: sin control de versiones, sin dueño y sin pruebas | 6 | Es la causa de fondo de 3, 4 y 5: nadie se enteró cuando dejó de funcionar | Organizacional |

## Qué pasos desaparecen y con qué se reemplazan

| Paso del .BAT | Decisión | Reemplazo | Por qué |
|---|---|---|---|
| 1. `forfiles … /d -7 del` (purga de logs) | **Se transforma** | Purga de logs IIS **solo si están archivados y verificados por hash**, retención local de 14 días. Purga aparte de los logs de la app (7 días), que muy probablemente son los que llenan el disco (hipótesis del Reto 1), más un **modo "presión de disco"**: si C: sigue bajo el umbral de aviso, borra logs de la app del más viejo al más nuevo, con un piso de 1 día | Primero se archiva y después se borra. Un log que no se pudo archivar no se borra nunca. Con los datos del Reto 1, 7 días de logs en *Debug* son ~39 GB: la retención fija sola no evita que C: se llene |
| 2. `del /s *.tmp` | **Desaparece** | — | No hay evidencia de que algo genere `.tmp` en la carpeta de logs, y es el comando más peligroso del script (problema 2) |
| 3. `del %CRASHDIR%\*.*` | **Se transforma** | Retención de volcados: nunca borra los de menos de 14 días y conserva siempre los 5 más recientes. La ruta sale de un parámetro (por defecto `C:\CrashDumps`) | Los dumps son evidencia. Los del 18-sep son la prueba de la fuga y se copian fuera antes de cualquier limpieza manual |
| 4. `iisreset /restart` | **Desaparece del script** | **Reciclaje nativo del pool en IIS** (`Instalar-*.ps1`): por memoria privada > ~1 GB (por debajo del techo de OOM, ~1,4 GB), programado a las 02:00 y con *overlapped recycle* (sin 503). El script solo **verifica** el estado del pool y avisa. La remediación automática es del Reto 3 | Quitar el reinicio sin más **tumbaría el portal en ~1,5 días** mientras la fuga siga (Reto 1, R2). El reciclaje por memoria también protege un día de fin de plazo, como el 18-sep, a las 11 de la mañana, antes de la OOM. Con 0,496 MB por pago, el límite llega a los ~1.356 pagos: **un reciclaje por día hábil** (1.539–1.805 pagos) y unos dos el 18-sep. Costo aceptado: se pierden las sesiones de pago en memoria del proceso viejo, lo mismo que con un crash, pero sin caída |
| 5. `net stop/start` del servicio | **Se transforma** | Asegurar el estado: si está detenido lo inicia y avisa; si está *Disabled* no lo toca; si está corriendo no hace nada | Reiniciar algo que funciona solo agrega riesgo. Si se cae, el aviso queda en el log y en el evento |
| 6. `net use` + `xcopy` con contraseña | **Se transforma** | Copia incremental por UNC con la identidad de la tarea (**gMSA**, sin contraseña almacenada): a `.partial`, verificación SHA-256 y renombre. Los archivos que ya están por purgarse se re-verifican por hash y, si la copia está corrupta, se recopia | No hay credenciales en el código. La copia es atómica, verificada e idempotente |
| `echo Proceso OK` / `exit /b 0` | **Desaparece** | Log JSON Lines por paso (`C:\ProgramData\Andina\Mantenimiento\logs`), evento en *Application* (fuente `AndinaMantenimiento`, Id 1000 + código) y **código de salida real** | Lo que hoy es invisible queda disponible para Azure Monitor (Reto 3) |
| *(nuevo)* | **Se agrega** | Verificación de espacio en disco al inicio y al final: < 20 % = Aviso, < 10 % = Error | Habría avisado desde el 16-sep que C: se estaba llenando |
| *(nuevo)* | **Se agrega** | Candado de ejecución única (código 4) y `-WhatIf` en cada acción | Se puede probar sin riesgo y no se pisa con otra ejecución |

**Lo que el script NO hace, a propósito:** no reinicia el pool ni IIS (lo hace el reciclaje nativo o el runbook del Reto 3, con límite de intentos), no corrige la fuga (le corresponde a desarrollo) y no cambia el nivel de log de la aplicación (es un cambio de la app). Lo que sí hace es aplicar retención sobre esos logs.

## Códigos de salida

| Código | Significado | Ejemplo |
|---|---|---|
| 0 | OK | Todo archivado y purgado, disco sano |
| 1 | Parámetros inválidos o no pudo iniciar | `-DiasRetencionIis 0`. PowerShell ya devuelve 1 cuando falla la validación de parámetros, por eso 1 **no** se usa para avisos |
| 2 | Aviso | Disco < 20 %, purga por presión de disco, servicio que se tuvo que iniciar, pool detenido, copia de auditoría corrupta que se reemplazó |
| 3 | Error | Share de auditoría no accesible (no se purga nada), un borrado o copia que falla (incluido un volcado bloqueado: los pasos siguientes se ejecutan igual), disco < 10 % |
| 4 | Otra ejecución en curso | El candado está tomado |
