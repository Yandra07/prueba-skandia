# Reto 1 · Diagnóstico basado en datos

| Entregable | Archivo |
|---|---|
| Post-mortem para la Directora (≤ 3 páginas, sin culpables) | `POSTMORTEM.pdf` (fuente: `POSTMORTEM.md`) |
| Evidencia técnica: hechos vs. hipótesis, con archivo:línea | `HALLAZGOS_TECNICOS.md` |
| Código reproducible | `src/parsers.py`, `src/analisis.py` |
| Pruebas | `tests/test_parsers.py` |
| Salidas generadas (CSV/JSON/PNG) | `salidas/` |

## Reproducir

Requisitos: Python 3.10+. El kit se deja **fuera del repositorio**, como hermano de la carpeta del repo.

```bash
cd reto1-diagnostico
python -m venv .venv && source .venv/bin/activate      # Windows: .venv\Scripts\Activate.ps1
pip install -r requirements.txt
python src/analisis.py --kit ../../kit_prueba_portalpagos --out salidas
KIT=../../kit_prueba_portalpagos pytest -q             # PowerShell: $env:KIT="..\..\kit_prueba_portalpagos"; pytest -q
```

Tarda entre 10 segundos y 1 minuto (la primera vez matplotlib construye su caché de fuentes). Todas las cifras de los documentos salen de `salidas/resumen.json` y `salidas/calidad_datos.json`.
Para regenerar el PDF: `pip install playwright` + pandoc, y luego `python tools/render_pdf.py`.

## Supuestos

1. Los logs W3C de IIS y de HTTP.sys están en **UTC** y se convierten a America/Bogota (UTC-5). Los eventos y Perfmon ya vienen en hora local. Se validó de tres formas: HTTP.sys coincide con WAS 5002 (5 s de diferencia), el hueco de cada `iisreset` de las 02:00 aparece en IIS solo al convertir, y cada archivo `u_ex` rota a las 19:00 locales (00:00 UTC).
2. `u_ex260916 - copia.log` es un duplicado exacto (SHA-256) y se descarta. `u_ex260921.log` se conserva: por la rotación en UTC contiene el domingo 20 de 19:00 a 23:59 hora Colombia.
3. "Usuario" excluye el sondeo del NOC (`/health`, 10.20.1.50) y los escáneres (`/.env`, `wp-login`, `phpmyadmin`, `admin/config`).
4. "Transaccional" = `/`, `/login`, `/api/saldos`, `/api/movimientos`, `/api/pagos/*`. `/api/reportes/extracto` queda fuera porque siempre es lento.
5. Línea base de latencia: p95 transaccional entre 08:00 y 18:00 antes del despliegue de v2.3.1 (450 ms).
6. Degradación = p95 > 2× la línea base durante 2 ventanas de 15 min. Inicio del incidente = primera ventana de 5 min con ≥ 5 % de errores (el mismo umbral de la alerta de ejemplo).
7. Minuto "malo" = ≥ 5 % de errores o p95 transaccional > 3 s (SLO asumido).
8. Sin `httperr` antes del 18-sep, se asume que no hubo 503 de HTTP.sys en días previos (ningún ticket los reporta).
9. El pronóstico de disco supone tráfico estacionario y ninguna limpieza manual (ver `HALLAZGOS_TECNICOS.md §5.1`).
