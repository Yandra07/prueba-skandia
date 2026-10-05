# Bitácora de uso de IA

## Herramientas y stack de modelos

| Herramienta | Modelo | Ámbito de aplicación |
|---|---|---|
| **Claude (Anthropic)** | `claude-opus-5-5` | **Asistente de desarrollo y análisis:** Procesamiento masivo del kit, desarrollo de parsers/scripts en Python, automatización en PowerShell (Reto 2), Bicep/KQL/runbooks (Reto 3), motor del Reto 4 y maquetación de documentación. Se usó como acelerador en tareas repetitivas, análisis de volumen de datos y pruebas. |
| **Azure OpenAI** | `gpt-4.1-mini` (2025-04-14) | **Motor del Reto 4:** Modelo integrado dentro de la arquitectura para el triage automatizado (no utilizado para desarrollo). |
| **Linters y Testing** | Parser oficial KQL, PSScriptAnalyzer, Pester, pytest, Bicep lint | **Control de calidad determinista (sin IA):** Ninguna salida generada por la IA se integró sin pasar por validación estática y suite de pruebas. |

---

## Prompts clave y dirección técnica

Muestra de las instrucciones ejecutadas para dirigir a la IA en cada etapa de la prueba.

| # | Reto | Prompt ejecutado | Resultado entregado y acción realizada |
|---|---|---|---|
| 1 | Global | *"Analiza el enunciado y el LEEME del kit sin procesar datos todavía. Mapea la matriz de requisitos exactos con su línea de origen. Identifica ambigüedades, propón supuestos técnicos para resolverlas y déjalos listos para mi aprobación."* | Identificó inconsistencias críticas en el kit: logs duplicados, desfase UTC en IIS y falsos positivos en el monitoreo del NOC (check limitado a `/health`). Los supuestos aprobados se documentaron en el README. |
| 2 | 1 | *"Escribe un parser W3C en Python que tolere cambios de `#Fields` a mitad de stream, descarte duplicados por hash SHA-256 y normalice UTC a hora Bogotá (`UTC-5`). Demuestra la validez de la zona horaria cruzando eventos de la aplicación contra el sistema."* | Entregó el parser junto con su suite de pruebas. La conversión horaria se validó contra tres puntos: correlación HTTP.sys vs. WAS 5002 (desfase de 5s), vacíos en eventos de `iisreset` y la rotación diaria de logs a las 19:00 local. |
| 3 | 1 | *"Genera un script que extraiga todas las métricas del post-mortem directamente desde los logs; prohíbo valores hardcodeados en el reporte. Todo lo que no tenga respaldo directo en datos divídelo en Hecho o Hipótesis, con su respectivo método de verificación."* | Generó `resumen.json` como única fuente de verdad y estructuró el anexo de Hecho/Hipótesis/Decisión. La rigidez de la prueba expuso inconsistencias en el primer borrador generado (errores 1 y 3 del Reto 1). |
| 4 | 1 | *"Modela la degradación de memoria de `w3wp` contra el volumen de tráfico. Aísla las métricas por ciclo de vida del proceso (entre reciclamientos) y compara el comportamiento pre y post-despliegue para descartar simple correlación temporal."* | Identificó una fuga de 0,496 MB por pago confirmado ($R^2 = 0{,}999$) tras la v2.3.1 (frente a una pendiente neutra previa). Demostró que la presión provenía del flujo de pagos confirmados y no del volumen general de peticiones. |
| 5 | 2 | *"Reescribe el script .BAT a PowerShell centrándote en tolerancia a fallos: verificación SHA-256 previa a purgar, soporte funcional de `-WhatIf`, códigos de salida legibles por el Programador de Tareas y cero credenciales explícitas. Diseña pruebas para los flujos de excepción."* | Generó el módulo de mantenimiento con retorno explícito (códigos 0 a 4), validación de integridad, control de concurrencia mediante candado, soporte gMSA y pruebas Pester para escenarios de falla (red caída, corrupción de archivos y rutas no encontradas). |
| 6 | 2 | *"Utilizando la volumetría calculada en el Reto 1, simula si la política de retención propuesta evita la saturación del volumen C:."* | La simulación demostró que con el nivel *Debug* activo (≈39 GB/semana) el volumen colapsaba. Se diseñó e implementó un algoritmo dinámico por presión de disco (error 2 del Reto 2). |
| 7 | 3 | *"Diseña la infraestructura como código en Bicep bajo un enfoque 100% automatizado: sin acceso RDP, MSi con privilegio mínimo sobre la VM y presupuestos con alertas. Valida la sintaxis KQL de los cómputos contra el esquema oficial antes de escribir el deployment."* | Entregó el deployment en Bicep y un validador de KQL basado en el parser de Microsoft. La validación detectó un error de tipo en la alerta base del kit (`scStatus` venía como string y no evaluaba numéricamente). |
| 8 | 3 | *"Implementa la automatización de remediación (Runbook) imponiendo límites de reintento, lógica anti-bucle, ventanas de mantenimiento y escalamiento sin reinicio si el origen de falla no es el Application Pool. Mide el MTTD y MTTR directamente desde la telemetría."* | Entregó el runbook con controles de estado. Durante las pruebas de inyección de fallas en Azure, la telemetría en Log Analytics arrojó un MTTD de 1,0–1,7 min y un MTTR de 2,3–3,3 min, detectando un caso de falso escalamiento en vivo (error 4 del Reto 3). |
| 9 | 4 | *"Diseña el motor de triage bajo un esquema 'Human-in-the-loop' (solo recomendación, sin ejecución). Obliga al modelo a citar fragmentos literales del contexto y seleccionar acciones de un catálogo cerrado. Crea una batería de pruebas con prompts adversarios para evaluar el comportamiento."* | Generó el pipeline de validación (esquema, citas literales, vigencia y catálogo). La suite incluyó pruebas para manejo de alucinaciones (caso 5), decisiones fuera de contexto (caso 3) e inyección de código (caso 4). |
| 10 | 5 | *"Escribe un executive summary de máximo 2 páginas dirigido a la dirección técnica. Prioriza iniciativas por impacto/esfuerzo/riesgo basándote únicamente en la telemetría recolectada. Incluye explícitamente qué acciones se descartan y la justificación técnica."* | Generó la propuesta estratégica con 5 iniciativas vinculadas a líneas base reales, definiendo bloqueos a resolver y descartando optimizaciones no probadas en laboratorio. |

---

## Control de alucinaciones y correcciones en ejecución

### Reto 1: Análisis e Incidentes

| # | Comportamiento anómalo de la IA | Método de detección | Corrección aplicada |
|---|---|---|---|
| 1 | Clasificó como "inicio del incidente" un error HTTP 500 aislado a las **00:02** del 18-sep, el cual correspondía a un fallo de fondo preexistente en `/api/movimientos`. | La métrica calculada de "tiempo de degradación a primer fallo" arrojó un valor inconsistente ($-703$ min). | Se redefinieron las reglas de detección: el incidente inicia formalmente en la primera ventana de 5 minutos con una tasa de error $\ge 5\%$. Los errores esporádicos se aislaron como ruido de fondo. |
| 2 | Ejecutó una regresión lineal directa de memoria vs. pagos recibidos arrojando un $R^2 = 0{,}25$, concluyendo erróneamente una baja correlación. | La representación gráfica mostraba una curva de crecimiento sostenido que no correspondía con el coeficiente devuelto. | Se ajustó el modelo para calcular el incremento acumulado de memoria por cada ciclo de vida del proceso `w3wp`, obteniendo un $R^2 = 0{,}999$. |
| 3 | Redactó métricas con valores inconsistentes: reportó **2.086 errores** durante el evento (sumando erróneamente $479 + 1.489$), inventó un encolamiento de 675 pagos y afirmó un incremento de latencia del $200\%$ para el día miércoles (siendo del $30\%$). | Auditoría cruzada mediante un script de validación estricta sobre el dataset procesado. | Se delegó el cálculo de métricas al script `analisis.py` ($1.952$ fallos reales: $463 + 1.489$). Se corrigió la ventana del incremento de latencia al jueves a las 19:30 y se removió la afirmación del encolamiento por falta de evidencia en los datos. |
| 4 | Validó la zona horaria asignando una bandera estática (`true`) e ignoró el archivo `u_ex260921.log` asumiendo que estaba fuera de rango por su nomenclatura. | Revisión manual del código e inspección directa de los encabezados del log, los cuales contenían registros del domingo 20 en hora local. | Se implementó una función de validación dinámica en `pytest` y se reintegró el archivo al análisis del periodo. |

### Reto 2: Automatización y Mantenimiento

| # | Comportamiento anómalo de la IA | Método de detección | Corrección aplicada |
|---|---|---|---|
| 1 | Asignó el código de salida **1 para estado de Aviso**. Dado que PowerShell retorna 1 ante fallos en la sintaxis de parámetros, una ejecución errónea se interpretaba como una advertencia válida. | Prueba de caja negra: `pwsh -File … -DiasRetencionIis 0` retornó código 1. | Reestructuración de la convención de retornos (1: error de parámetros, 2: aviso, 3: error de ejecución, 4: bloqueo por candado) respaldada por pruebas de integración. |
| 2 | Propuso una retención estática de **7 días** para mitigar el llenado de disco. Al cruzar la tasa de generación de logs en modo *Debug*, el almacenamiento colapsaba igualmente. | Evaluación matemática de tasa de transferencia vs. capacidad disponible (déficit de $\approx 0{,}6$ GB en régimen permanente). | Se desarrolló una lógica de purga dinámica por presión de disco que libera espacio ordenadamente según el umbral crítico, respetando un piso mínimo de seguridad y protegiendo logs de sistema y dumps. |
| 3 | Asumió que un archivo sin modificaciones en 120 minutos estaba cerrado. En sistemas de archivos NTFS, la fecha de modificación de un archivo abierto por un proceso no siempre se actualiza en tiempo real, provocando fallos de acceso en la VM. | La ejecución en entorno Windows retornó código 3 con la excepción `file being used by another process` en los logs estructurados. | Se implementó la función `Test-ArchivoEnUso` para verificar el bloqueo del handle antes de operar. Se validó la solución obteniendo **38/38 pruebas Pester exitosas en Windows PowerShell 5.1**. |
| 4 | Asignó una regla de validación de rutas que exigía una profundidad mínima de dos subcarpetas, rechazando la ruta por defecto de Windows Error Reporting (`C:\CrashDumps`). | La prueba inicial en la VM abortó con la excepción `retencion-dumps=Error` sin dejar trazabilidad en los logs. | Se ajustó el validador para permitir profundidad 1 de forma exclusiva en la ruta de volcados de memoria, filtrando estrictamente por extensión `.dmp`. |

### Reto 3: Monitoreo y Remediación (Azure)

| # | Comportamiento anómalo de la IA | Método de detección | Corrección aplicada |
|---|---|---|---|
| 1 | Generó las consultas KQL utilizando comparaciones numéricas directas sobre el campo `scStatus` (`scStatus >= 500`). En el esquema de `W3CIISLog`, dicho campo es de tipo `string`. | El analizador estático de KQL rechazó las sintaxis con el error: `operator '>=' is not defined for string and long`. | Se aplicó la conversión explícita `toint(scStatus)` en las 28 consultas del proyecto, automatizando su validación dentro del pipeline de CI. |
| 2 | En el script de inspección en la VM, concatenó las variables como `"…/health=$h0: …"`. PowerShell parseó `$h0:` como un nombre de variable con alcance/unidad inválido. | Excepción de sintaxis (`ParseException`) durante la ejecución de las pruebas unitarias en Pester. | Se delimitó explícitamente el nombre de la variable utilizando la sintaxis `${h0}`. |
| 3 | Configuro filtros XPath superpuestos en la regla de recopilación de datos (DCR), duplicando la ingesta de eventos de falla y disparando falsos positivos en las alertas. | Detección de registros duplicados al auditar la tabla de eventos en Log Analytics. | Se reestructuraron los filtros XPath para garantizar disyunción estricta, validándolos directamente en la VM con `Get-WinEvent -FilterXPath`. |
| 4 | La lógica anti-bucle del runbook escalaba los incidentes basándose únicamente en el historial de alertas (ventana de 5 min) sin verificar el estado actual del servicio. Esto causaba alertas falsas tras una recuperación exitosa. | Durante la prueba de inyección de fallas del 04-oct (20:42:41), el runbook notified la caída del pool estando el servicio ya operativo. | Se modificó el flujo para incluir un paso de verificación en vivo (*Read-Only*) sobre la VM. El escalamiento solo se ejecuta si la falla persiste. Validación final en Azure: *Verificar $\rightarrow$ SinAccion*. |
| 5 | En la maquetación de los Azure Dashboards, configuró la agregación de métricas como suma global en lugar de promedio/máximo, generando gráficas anómalas (e.g., latencia p95 de "2,56 minutos" y uso de disco de "280%"). | Inspección visual de los tableros desplegados en la consola de Azure. | Se extrajo el esquema de agregación correcto directamente desde el editor de métricas de Azure y se aplicó al archivo `workbook.json`. |

### Reto 4: Motor de Triage e Inferencia

| # | Origen | Comportamiento anómalo de la IA | Método de detección | Corrección aplicada |
|---|---|---|---|---|
| 1 | Modelo | **Caso 3:** Sugirió ejecutar el Runbook RB-03 (fuga de memoria) con confianza alta citando un evento de crash ocurrido 27 minutos antes (ya resuelto), omitiendo que la causa raíz activa era una falla en una dependencia externa. | Auditoría del output de inferencia contra la cronología real de eventos de la VM. | Se implementó la regla de validación `accion_desactualizada`, descartando evidencias con antigüedad mayor a 15 minutos. Con el ajuste, el modelo reclasificó a RB-04. |
| 2 | Modelo | **Caso 5 (escenario degradado/sin datos):** Inventó una cita de telemetría y asoció la degradación a un despliegue realizado 5 días atrás sin respaldo en los registros. | Fallo en la validación de esquema (ID de cita inexistente) y fallo en la verificación de coincidencia literal de texto. | Se configuró un mecanismo de fallback estricto que fuerza la respuesta a la regla por defecto RB-00 con nivel de confianza bajo ante la ausencia de evidencias válidas. |
| 3 | Asistente | Generó el parser de fechas con `datetime.fromisoformat()`. Los timestamps de Azure en Python 3.10 fallan cuando la precisión de microsegundos varía de 5 a 7 decimales. | Fallo en tiempo de ejecución (*Job Failed*) en Azure Automation al procesar un evento de la API. | Se implementó una función de normalización de cadenas de tiempo a 6 decimales con cobertura de pruebas unitarias parametrizadas en `pytest`. |

---

## Metodología de validación y aseguramiento de calidad

- **Ejecución de pruebas automatizadas:** Ningún entregable se integró sin pasar por su respectiva suite de pruebas: `pytest` (Retos 1 y 4), `Pester` (Retos 2 y 3, incluyendo compatibilidad con Windows PowerShell 5.1), validador KQL, `bicep lint` y `PSScriptAnalyzer`.
- **Reproducibilidad y cálculo determinista:** Todas las métricas presentadas en la documentación final son extraídas automáticamente desde los datasets procesados mediante `resumen.json` y `calidad_datos.json`. Los análisis de datos son 100% reproducibles bit a bit.
- **Verificación cruzada de datos:** Los hallazgos que no podían probarse mediante un único archivo de log se validaron mediante correlación cruzada de fuentes (e.g., sincronización horaria mediante HTTP.sys vs. logs de WAS y marcas de tiempo de reinicio de IIS).

---

## Decisiones y tareas excluidas de la IA

- **Definición de hipótesis vs. hechos:** La separación entre eventos confirmados por telemetría y suposiciones técnicas (tales como la presencia de cachés sin expiración o la arquitectura de 32 bits del Application Pool) fue realizada bajo criterio de ingeniería.
- **Evaluación del riesgo operativo:** La decisión de mantener reciclamientos preventivos de IIS hasta solucionar la causa raíz, la prohibición de reiniciar procesos de forma ciega y las reglas de purga de almacenamiento fueron definidas manualmente.
- **Gestión de credenciales y accesos:** La autenticación en servicios Cloud y la ejecución de comandos con privilegios se realizaron exclusivamente por el ingeniero a cargo mediante flujos seguros (OAuth Device Code / MSi). Cero credenciales fueron expuestas a los modelos.
- **Priorización estratégica:** La definición de la hoja de ruta del Reto 5, los análisis de impacto/esfuerzo y las decisiones de arquitectura descartadas se basaron en el contexto operativo de la organización.
- **Pruebas de integración en entornos reales:** Las pruebas de estrés e inyección de fallas en Azure y en la VM permitieron descubrir errores de concurrencia y permisos que no eran visibles mediante análisis estático o pruebas locales.
