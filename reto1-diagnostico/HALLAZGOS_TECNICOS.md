# Reto 1 · Hallazgos técnicos y evidencia

Este es el anexo técnico del `POSTMORTEM.md`. Todas las cifras salen de `salidas/resumen.json` o `salidas/calidad_datos.json`, que genera `src/analisis.py`; ninguna se escribió a mano. Las referencias usan la forma `archivo:línea`, con la línea del archivo original del kit.

Notación: **H** = hecho verificable en los datos · **Hip** = hipótesis (dice qué la apoya y cómo confirmarla) · **D** = decisión de análisis tomada por falta de información.

---

## 0. Calidad de los datos: qué se corrigió antes de analizar

| # | Problema | Cómo se trató | Evidencia |
|---|---|---|---|
| D1 | `u_ex260916 - copia.log` es **idéntico** (mismo SHA-256) a `u_ex260916.log` | Se descarta. Si se dejara, el tráfico del 16-sep contaría doble (+25.882 líneas) | `calidad_datos.json → iis_archivos_descartados` |
| D2 | Los logs W3C de IIS y HTTP.sys están en **UTC** (comportamiento por defecto de IIS). Los eventos y Perfmon (`SA Pacific Standard Time`) están en hora local | Todo se convierte a `America/Bogota` (UTC-5, sin horario de verano). **Validación cruzada:** el primer 503 de HTTP.sys (19:38:00 UTC → 14:38:00) coincide con WAS 5002 "pool deshabilitado" (14:38:05 local), el hueco de cada `iisreset` (evento 3201, 02:00 local) aparece en IIS solo si se convierte de UTC (huecos de 42–60 s frente a un máximo de 30 s sin convertir), y cada archivo `u_ex` rota a las 19:00 locales (00:00 UTC) | `httperr1.log:5`, `eventos…csv:366`, `calidad_datos.json → zona_horaria`, `tests/test_parsers.py::test_invariantes_kit_real` |
| D3 | `u_ex260917.log` **cambia de `#Fields:` a mitad del archivo** (`#Date` en la línea 2350: 17-sep 03:12 UTC = **16-sep 22:12** local; `#Fields` en la 2351; primer registro con el formato nuevo en la 2352): se agregan `cs-host` y `X-Forwarded-For` | El parser respeta cada bloque `#Fields`. La IP del cliente se toma de `X-Forwarded-For` cuando existe | `u_ex260917.log:2348-2352` |
| D4 | Desde ese cambio, el **100 %** del tráfico de usuarios llega desde `10.20.4.4` (proxy). En HTTP.sys solo se ve el proxy | Durante la caída total no se pueden contar clientes únicos. Antes, los 500 llegaron a 463 IP distintas (`resumen.json → ips_distintas_con_500`): es una **aproximación** al número de clientes (una persona puede usar varias IP y varias personas una sola) | `calidad_datos.json → iis_cambio_formato` |
| D5 | `httperr1.log` solo cubre desde el 18-sep 14:38 | Los 503 de HTTP.sys de días previos no se pueden medir. Supuesto: no hubo, porque ningún ticket los reporta | `httperr1.log:3` |
| D6 | Perfmon tiene 13 muestras sin `w3wp` | Se interpretan como "proceso inexistente" (caída o reciclaje) y no se imputan | `calidad_datos.json → perfmon` |
| D7 | `mantenimiento.log` tiene 30 líneas `Proceso OK` **sin fecha**. El .BAT las escribe siempre | No sirve como evidencia de éxito. Se usa TaskScheduler 201 + IISReset 3201/3202 | `mantenimiento_diario.bat:35` |
| D8 | Separación de tráfico | *Usuario* = todo menos `/health` (NOC, `10.20.1.50`) y escáneres (`/.env`, `wp-login`, `phpmyadmin`, `admin/config`). *Transaccional* = `/`, `/login`, `/api/saldos`, `/api/movimientos`, `/api/pagos/*`. Se excluye `/api/reportes/extracto` porque siempre tarda 15–20 s | `src/analisis.py` (constantes) |
| D9 | `u_ex260921.log` parece estar fuera del periodo (21-sep), pero no lo está: como IIS rota el log a las 00:00 **UTC**, contiene el **domingo 20 de 19:00 a 23:59** hora Colombia (1.247 registros). Del mismo modo, `u_ex260914.log` empieza a las 00:00 locales del lunes 14 | Se conserva: sin él se perderían las últimas 5 horas de la semana | `calidad_datos.json → iis_cobertura_archivos` |

---

## 1. Línea de tiempo (hora Colombia) · `salidas/linea_tiempo_18sep.csv`

| Hora | Hito | Evidencia |
|---|---|---|
| 02:00:01 | `iisreset` del mantenimiento: el pool arranca con ~304 MB | `eventos…csv:271` |
| 11:10 | Private Bytes de w3wp > 1.000 MB (1.017,6 MB); a las 11:15 supera 1 GiB (1.039,9 MB) | `perfmon…csv` |
| **11:45** | **Inicio de degradación:** p95 transaccional > 2× la línea base (450 ms, calculada entre 08:00 y 18:00 antes del despliegue) durante 2 ventanas de 15 min seguidas | `u_ex260918.log` |
| **13:23:08** | **Primer 500 del incidente** (primera ventana de 5 min con ≥ 5 % de errores) | `u_ex260918.log:24018` |
| 13:24:19 | 1.ª de 40 `OutOfMemoryException` (ASP.NET 1309) en `Andina.Pagos.SesionPagoCache.Agregar`, ruta `/api/pagos/confirmar` | `eventos…csv:304` |
| 13:34 | T-10252, primer ticket | `tickets…csv` |
| 14:22:12 | 1.º de 5 crashes de w3wp (.NET 1026 + APPCRASH + dump `C:\CrashDumps\w3wp.exe.4471.dmp`) | `eventos…csv:347-350` |
| 14:38:05 | WAS 5002: **Rapid-Fail Protection deshabilita `PortalPagosPool`** | `eventos…csv:366` |
| 14:38:00–15:03:59 | 1.489 rechazos `503 AppOffline` a usuarios y 52 a `/health` | `httperr1.log:5-1545` |
| **15:04:00** | Primera respuesta 200, tras el reinicio manual (T-10255) | `u_ex260918.log:27229` |
| 15:30 | p95 < 2× la línea base y 0 errores en una ventana de 15 min | `u_ex260918.log` |

**Duraciones:** degradación → primer error, 98 min · primer error → recuperación, **101 min** · caída total, **26 min** · primer error → primer ticket, **11 min**. El NOC no generó ninguna alerta.

**Impacto (13:23:08–15:04):** 463 errores 500 a usuarios + 1.489 rechazos 503, lo que equivale a **1.952 solicitudes fallidas**. De ellas, **504 fueron intentos de pago** (275 con 500 y 229 con 503): falló el **40,8 %** de los intentos de pago antes de la caída total (275 de 674) y el **55,8 %** en todo el incidente (504 de 903) (`resumen.json → pct_pagos_fallidos_*`). 160 de los 500 tienen `sc-win32-status = 64`, es decir, el cliente abandonó la espera (p95 ≈ 25 s). Entre 13:23 y 15:04 se confirmaron **217 de 358** pagos (61 %); en las 2 horas previas se confirmaron 588 de 588. En las 2 horas siguientes a la recuperación se confirmaron 694 pagos, 2,3× la misma franja de lunes a jueves (297): es el mismo factor de todo el viernes (2,32×), así que los datos **no muestran** un represamiento distinguible de la demanda del fin de plazo. (Los 2.086 fallos de la tabla del §3 son de **toda la semana**.)

---

## 2. Causa raíz

| Id | Afirmación | Tipo | Evidencia |
|---|---|---|---|
| C1 | v2.3.1 se desplegó el 15-sep a las 22:03 con "nuevo flujo de confirmación de pagos, **caché de sesiones de pago**, Serilog **MinimumLevel=Debug**" | H | `eventos…csv:109` |
| C2 | Antes de v2.3.1, w3wp se mantiene plano en 277–320 MB. Después, crece sin liberar hasta el siguiente reinicio | H | `fig_semana.png`, `senales_tempranas.csv` |
| C3 | Dentro de cada vida del proceso, **memoria = base + 0,496 MB × pagos confirmados acumulados**, con **R² = 0,999**. Antes del despliegue la pendiente es −0,001 MB (R² = 0,02). Los pagos confirmados explican mejor la memoria que los iniciados (R² 0,990) o que el total de solicitudes (0,956) | H | `modelo_memoria.json` |
| C4 | Las 40 OOM y los 5 crashes tienen la **misma pila**: `SesionPagoCache.Agregar` | H | `eventos…csv:304-368` |
| C5 | El 18-sep, la primera OOM llegó tras **2.126 pagos confirmados** desde el reset de las 02:00. El techo observado de w3wp fue 1.478 MB, con 4,7 GB de RAM libre en el servidor | H | `modelo_memoria.json` |
| C6 | `SesionPagoCache` retiene cada sesión de pago sin vencimiento ni límite | **Hip** | Lo apoyan C3 y C4 y que la memoria no baje en horas valle. **Confirmar:** analizar `C:\CrashDumps\w3wp.exe.*.dmp` (5 dumps del 18-sep) con `dotnet-dump`/WinDbg `!dumpheap -stat` y revisar el código |
| C7 | El pool corre en 32 bits (`enable32BitAppOnWin64=true`), con un techo práctico de ~1,4–1,5 GB | **Hip** | La OOM ocurre con 4,7 GB libres. **Confirmar:** `Get-ItemProperty IIS:\AppPools\PortalPagosPool \| Select enable32BitAppOnWin64` |

**Factores contribuyentes (hechos):** demanda **2,3×** el promedio de lunes a jueves (3.794 pagos confirmados el 18 frente a 1.539–1.805; 2,1× el día más alto). El `iisreset` nocturno enmascaraba la fuga; el propio .BAT dice desde 2019 "reiniciar IIS para liberar memoria (la app se pone lenta si no)" (`mantenimiento_diario.bat:23`), así que reiniciar en lugar de diagnosticar ya era la costumbre. `/health` devolvió **200 en las 149 sondas** entre 13:23 y 14:38, y solo falló cuando HTTP.sys rechazó todo. Rapid-Fail Protection apagó el pool sin avisar a nadie.

**Hipótesis descartada:** DCOM 10016 (T-10261). Hubo 261 avisos en la semana con un patrón estable de 26–53 por día, iguales antes, durante y después del incidente, y ninguno entre 13:00 y 15:00 del 18 se aparta del patrón. Es un aviso conocido de permisos de Windows sin efecto en IIS.

---

## 3. Disponibilidad · `salidas/disponibilidad_diaria.csv`

| Definición | Semana | 18-sep |
|---|---|---|
| NOC: `/health` = 200 en log IIS | 100 % | 100 % |
| `/health` incluyendo 503 de HTTP.sys | 99,74 % | 98,19 % |
| Solicitudes de usuario con status < 500 (IIS + HTTP.sys) | **98,57 %** (2.086 / 145.572 fallidas) | **94,48 %** |
| Minutos con < 5 % de error | 98,66 % | 92,78 % |
| Minutos con < 5 % de error **y** p95 transaccional < 3 s | 98,62 % (139 min malos) | 92,50 % (108 min) |

Lunes a jueves y el fin de semana están entre 99,87 % y 99,95 % por solicitudes. La diferencia se debe a errores 500 de fondo en `/api/movimientos` (riesgo R6). **Reinicio nocturno:** cada madrugada IIS deja de responder entre 42 y 60 s (promedio 50 s, ≈ 6 min/semana), y nadie lo cuenta.

**Por qué el NOC ve 100 %** (H + Hip): ping prueba la red, no la app. `/health` es estático (2–4 ms) y no ejercita la memoria, el caché ni la lógica de pagos. Cuando el pool está deshabilitado, IIS no escribe nada en su log W3C: los 503 quedan en `httperr`. Que el NOC calculó su "100 %" con el log W3C es una hipótesis consistente con T-10270 ("/health OK 100 %").

---

## 4. Señales tempranas · `salidas/senales_tempranas.csv`

| Día | w3wp máx (MB) | p95 tx (ms) | p95 tx 18–23 h (ms) | C: libre mín (GB) | Pagos confirmados |
|---|---|---|---|---|---|
| Lun 14 | 317 | 452 | 449 | 47,0 | 1.601 |
| Mar 15 | 320 | 449 | 459 | 47,0 | 1.539 |
| **Mié 16** | **1.091** | 470 | 584 | 40,5 | 1.597 |
| **Jue 17** | **1.186** (1.216 a la 01:55 del 18) | 575 | **1.030** | 33,0 | 1.805 |
| Vie 18 | 1.478 | 1.560 | 491 | 15,8 | 3.794 |

- **Primera señal inequívoca: mié 16 a las 12:10**, cuando w3wp supera 2× su máximo previo (640 MB). Fueron **49 h de anticipación**. La latencia avisó después (ver abajo): la memoria es el indicador temprano.
- **Latencia (H):** el p95 de 18 a 23 h sube 1,3× la noche del 16 y 2,3× la del 17, con poco tráfico. La primera ventana de 15 min por encima de 2× la línea base es el **jue 17 a las 19:30**, unas 18 h antes del primer error (`resumen.json → senales`). **Hip:** la causa es la presión del recolector de basura por la memoria retenida; se confirma con los contadores *.NET CLR Memory* (% Time in GC). El ticket T-10240 (17-sep, "lento en la tarde") se cerró con "monitoreo en verde".
- La noche del 17 al 18 el pool llegó a 1.216 MB, el **82 % del techo**. Fue una casi-falla.
- Indicadores recomendados para el Reto 3: `Process(w3wp)\Private Bytes` (nivel y pendiente), p95 de los endpoints transaccionales, % de 5xx de usuarios (sin `/health`), `LogicalDisk(C:)\% Free Space` con tendencia y eventos WAS 5002/5011.

---

## 5. Otros riesgos y pronósticos

| # | Riesgo | Urgencia | Evidencia / método |
|---|---|---|---|
| **R1** | **C: se llena el mar 22-sep entre 12:00 y 15:00** (escenario medio: 14:00) | Crítica | Ver 5.1 |
| **R2** | **La fuga sigue activa.** Capacidad estimada de ~2.100–2.370 pagos entre reinicios. Un día normal usa entre 65 % y 85 %. Sin el `iisreset`, el pool se cae en ~1,5 días hábiles | Crítica | `modelo_memoria.json`: (1.478 − 304) / 0,496 = 2.367 (techo del modelo); 2.126 (observado). **El Reto 2 no debe quitar el reciclaje hasta corregir la fuga** |
| R3 | Contraseña en texto plano de `ANDINA\svc_mantenimiento` | Alta, inmediata | `mantenimiento_diario.bat:31`. Rotarla y revisar dónde más se usa |
| R4 | El mantenimiento **falla en silencio**: `LOGDIR=%1`, invocado con `D:\logs\iis` (`bat:5`, `bat:8`), pero D: se retiró el 16-sep 11:30 (`eventos…csv:150`). En C: el espacio libre subió 1.620 MB a las 02:00 del 15-sep, durante el mantenimiento, y ninguna otra noche (`resumen.json → c_libre_aumento_0155_0210_mb`); como el .BAT purga `D:` y en C: solo toca `C:\Dumps\*.*`, el origen de ese aumento es una **Hip** (algo borrado en `C:\Dumps`). La copia al share de auditoría no tiene origen (**Hip**: brecha de cumplimiento). `CRASHDIR=C:\Dumps` (`bat:10`), pero WER guarda en `C:\CrashDumps` | Alta | `exit /b 0` y "Proceso OK" incondicionales (`bat:35-36`). TaskScheduler 201 "return code 0" todos los días |
| R5 | Proxy `10.20.4.4` y nuevo formato de log desde el 16-sep 22:12 **sin evento ni ticket de cambio** | Media | `u_ex260917.log:2350-2352`. Cualquier control por IP del cliente ahora ve una sola IP |
| R6 | `/api/movimientos` devuelve 500 de fondo: **192 en la semana, 129 fuera de la ventana del incidente** (13:20–15:30), 3–30 por día, rápidos (p50 226 ms) | Media | Defecto independiente del incidente |
| R7 | El `iisreset` de las 02:00 corta ~50 s de servicio por noche y las transacciones en curso | Media | Huecos en IIS de 02:00 a 02:01 (`resumen.json → hueco_nocturno_iisreset_s`) |
| R8 | "Servicio Notificaciones" entra en *running* 32 veces a horas aleatorias, pero nunca a las 02:00 cuando el .BAT lo reinicia | Baja | **Hip**: se cae y lo levanta la recuperación del servicio, y/o el `net stop/start` del .BAT no hace nada. Revisar opciones de recuperación y el log del servicio |
| R9 | Escaneos de internet: 1.772 solicitudes a `/.env`, `wp-login.php`, `phpmyadmin`, `admin/config.php`, **todas 404** | Baja | No hay exposición. Schannel 36887 (alerta TLS 46, 44 en la semana) es ruido de clientes |

### 5.1 Método del pronóstico de disco (R1)

1. Se calcula el consumo horario de C: (`−Δ Free Megabytes`) y se cruza con las solicitudes de usuario por hora.
2. Antes de v2.3.1: 0,10 GB por 1.000 solicitudes, R² 0,11, ~0,55 GB/día. **Después: 0,301 GB por 1.000 solicitudes, R² 0,999**, sin el salto de 8,7 GB del 18-sep entre 14:00 y 15:00, que corresponde a los 5 dumps de ~1,7 GB.
3. **Hip:** el consumo proviene de los logs de la aplicación en nivel *Debug* (C1). Los logs de IIS solo suman 2–9 MB/día. **Confirmar:** `Get-ChildItem C:\ -Recurse -File | Sort Length -desc | Select -First 20`.
4. La regresión se proyecta desde el último dato (dom 20, 23:55, **11.172 MB = 9,1 %**), con el perfil horario promedio de lunes a jueves para días hábiles y de sábado y domingo para fin de semana.
5. Escenarios: tráfico del día hábil más bajo (−7 %), medio y más alto (+10 %).
6. **Resultado:** 5 % libre el lun 21 hacia las 15:00, **0 % el mar 22 entre 12:00 y 15:00**. Un día de fin de plazo consume ~10,4 GB, así que se llena en menos de un día.

**Supuestos:** el tráfico es estacionario, nadie limpia el disco y no hay más crashes. Si hubiera crashes, cada dump suma ~1,7 GB y adelanta la fecha. Con C: lleno, IIS deja de escribir logs, la app falla al escribir sus logs y no se pueden generar dumps.

---

## 6. Cómo reproducir

```bash
pip install -r requirements.txt
python src/analisis.py --kit ../../kit_prueba_portalpagos --out salidas
KIT=../../kit_prueba_portalpagos pytest -q     # 4 pruebas: parser + invariantes del kit (zona horaria, rotación, duplicado)
python tools/render_pdf.py                      # opcional: POSTMORTEM.pdf (requiere pandoc + playwright)
```
