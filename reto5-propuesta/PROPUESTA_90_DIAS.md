---
title: "Primeros 90 días · Especialista en Observabilidad y Automatización"
subtitle: "Andina Financiera · Dirección de Operaciones de TI · Propuesta basada en el caso PortalPagos"
---

## Punto de partida (medido en los retos 1 a 4)

| Indicador | Hoy (semana del 14-sep) | Probado en el laboratorio (Reto 3) | Meta a 90 días (producción) |
|----------|------------|------------|------------|
| Quién detecta los incidentes | Los clientes (0 % detectado antes del primer ticket) | Una alerta, a ~1–1,7 min | **≥ 80 %** detectados antes del primer ticket |
| MTTD: cuánto tardamos en enterarnos | Nunca: el NOC no alertó; avisaron los clientes | 1,0–1,7 min | **< 5 min** |
| MTTR: cuánto tardamos en recuperar el servicio | 101 min desde el primer error | 2,3–3,3 min (pool caído, automático) | **< 15 min** en fallas conocidas · **< 60 min** en el resto |
| Disponibilidad real | 98,57 % (el NOC reportaba 100 %) | Medida por una sonda sintética | **≥ 99,9 %** mensual en operaciones de pago (SLO acordado con negocio; requiere que desarrollo haya corregido la fuga de memoria) |
| Riesgos abiertos | Disco lleno ~22-sep, fuga de memoria, contraseña en texto plano | Mecanismos probados en el laboratorio (reciclaje por memoria, retención por presión de disco, mantenimiento sin contraseña) | Cerrados en producción en el **día 10** |

Las metas son un punto de partida: el laboratorio prueba que el mecanismo funciona, no el número de producción. Se confirman con las 2 primeras semanas de datos reales (iniciativa 2); el 80 % deja margen a incidentes que ninguna señal anticipa, como un error funcional sin impacto en métricas.

## Iniciativas, priorizadas por impacto, esfuerzo y riesgo

| # | Iniciativa | Impacto | Esfuerzo | Riesgo | Cuándo |
|-|--------------------------------------------|-----------|---------|-----------|-----|
| **1** | **Cerrar los riesgos que ya tienen fecha.** **El día 1** (el disco se llena el día 2): liberar C: y bajar el log a *Information*; copiar fuera los dumps del 18-sep para desarrollo; rotar la contraseña de `svc_mantenimiento`; instalar el mantenimiento del Reto 2 (gMSA, auditoría verificada); y **reemplazar el `iisreset` por reciclaje por memoria**, sin quitar la protección mientras exista la fuga | Muy alto: evita la próxima caída, que ya tiene fecha | Bajo: el mantenimiento nuevo ya está escrito y probado | Medio: va con ventana de cambio y rollback, porque la tarea vieja queda deshabilitada, no borrada | **Días 1–10** |
| **2** | **Detección desde el cliente.** Azure Monitor Agent (Azure Arc si el servidor es on-prem) y sonda sintética **externa** de las operaciones de pago, sin limitarse a `/health`. Las 6 alertas del Reto 3 con umbrales calibrados contra 2 semanas de datos reales, más un tablero para Dirección y otro para el NOC. Se retiran "ping OK" y la revisión semanal manual | Muy alto: cambia quién se entera primero | Bajo-medio | Bajo: solo observa | **Días 5–30** |
| **3** | **Despliegues con red de seguridad.** Una verificación automática 24 h después de cada despliegue: memoria, p95 y 5xx frente a la semana anterior, con el despliegue marcado en el tablero. **Todo** cambio de infraestructura, por ejemplo el proxy del 16-sep, pasa por un ticket. Junto con desarrollo: corregir `SesionPagoCache` y un `/health` profundo | Alto: la causa raíz del 18-sep fue un cambio no vigilado | Medio: hay que coordinar con desarrollo | Bajo | **Días 20–60** |
| **4** | **Auto-remediación con salvaguardas** para las fallas que se repiten: pool caído (Reto 3), disco y servicio detenido. **Dos semanas en modo "sugerir"**, en las que el runbook decide pero no ejecuta y una persona confirma (en la prueba en vivo del laboratorio aparecieron dos defectos que las pruebas automáticas no detectaron: una escalada falsa tras cada recuperación y un mantenimiento que fallaba con el log abierto por IIS); después pasa a modo automático, con límite de intentos, anti-bucle, escalamiento y trazabilidad | Alto: MTTR de horas a minutos | Medio | Medio, controlado por las salvaguardas y por empezar en modo sugerencia | **Días 40–75** |
| **5** | **Triage con IA y post-mortems sin culpables.** El triage del Reto 4 adjunta a cada alerta un resumen con evidencia verificada; solo sugiere y nunca ejecuta. Cada incidente Sev1/Sev2 cierra con un post-mortem y acciones con dueño y fecha: **se acaba "causa: por determinar"** | Medio: acelera la primera respuesta y deja aprendizaje | Bajo | Bajo: el validador rechaza lo que no tenga sustento | **Días 50–90** |

## Cómo se mide el éxito

Se mide todo con datos, no con percepción.

- **Cada mes, en el tablero de Dirección:** MTTD, MTTR y "% detectado antes del primer ticket", calculados al cruzar las alertas con los tickets de la mesa de servicio.
- **Disponibilidad:** según la sonda sintética frente al SLO.
- **Horas de trabajo manual eliminadas:** durante las semanas 1 y 2 se toma una línea base de las tareas repetitivas (revisión semanal del NOC, reinicios manuales, limpieza de disco, cierre de tickets duplicados) y en el día 90 se compara.
- **Calidad del ruido:** < 5 alertas no accionables por semana. Si una alerta no lleva a ninguna acción, se ajusta o se elimina. La alerta de memoria saltará casi a diario mientras exista la fuga y no cuenta como ruido: cada disparo es evidencia para desarrollo; al corregirla, se sube su umbral o se apaga.
- **Cambios:** el 100 % de los despliegues con verificación de 24 h y el 100 % de los cambios de infraestructura con ticket.

**Hitos de control:** día 10, riesgos con fecha cerrados · día 30, detección desde el cliente funcionando y umbrales calibrados · día 60, verificación de despliegues y remediación en modo sugerencia · día 90, metas de la tabla y revisión con la directora.

## Lo que necesito que mi líder destrabe

1. **Acceso de lectura** a los logs y métricas de producción. Si el servidor es on-prem, aprobación para instalar **Azure Arc + AMA**.
2. **Una gMSA** con escritura en el share de auditoría, coordinada con el equipo de directorio activo.
3. **Ventanas de cambio** para la iniciativa 1, con la dueña del servicio informada.
4. **Un acuerdo con desarrollo** sobre la corrección de la fuga, el nivel de log, `/health` profundo y la verificación post-despliegue como requisito para salir a producción.
5. **El SLO de negocio**: qué significa "disponible" para PortalPagos y cuál es el objetivo. Lo decide la directora, no yo.
6. **Presupuesto** de Azure Monitor y Azure OpenAI (decenas de dólares al mes a este volumen) y una **política de datos** con Seguridad: qué se puede enviar a un modelo y con qué enmascaramiento.

## Lo que NO haría en estos 90 días (y por qué)

| No haría | Por qué |
|------------|---------------|
| Quitar el reinicio nocturno sin reemplazo | Con la fuga activa, el portal cae en ~1,5 días (Reto 1). Primero el reciclaje por memoria, después la corrección |
| Auto-remediar reinicios de IIS completo o de la VM, o dejar que la IA ejecute acciones | El impacto de equivocarse es mayor que el de esperar unos minutos a una persona. La IA sugiere y la automatización solo hace lo acotado y probado |
| Comprar otra herramienta de observabilidad | Azure Monitor ya cubre lo necesario. El problema no era de herramienta sino de **qué** se miraba (`/health` y ping) |
| Alertar por todo (DCOM 10016, Schannel, 404 de escáneres) | Es ruido que entrena a la gente a ignorar las alertas. El ticket T-10261 culpó a DCOM sin evidencia |
| Enviar datos reales de clientes a un modelo sin enmascarar | Riesgo regulatorio en una entidad financiera. Primero va la política de datos (punto 6) |
| Corregir yo el código de la aplicación | Le corresponde a desarrollo. Mi parte es que el defecto se vea antes, se contenga y no vuelva a salir sin verificación |
