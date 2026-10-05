"""Reto 1 · Diagnóstico basado en datos — PortalPagos (WEB-PAGOS-01).

Uso:
    python src/analisis.py --kit ../kit_prueba_portalpagos --out salidas

Genera en --out:
    calidad_datos.json        problemas encontrados en el kit y cómo se trataron
    linea_tiempo_18sep.csv    hitos del incidente (hora Colombia) con fuente y línea
    disponibilidad_diaria.csv disponibilidad por día bajo 4 definiciones
    senales_tempranas.csv     indicadores diarios (memoria, latencia, disco, errores)
    modelo_memoria.json       regresión memoria w3wp vs pagos confirmados
    pronostico_disco.csv/json pronóstico de agotamiento de C:
    resumen.json              todas las cifras que usa el post-mortem
    fig_*.png                 gráficas

Todas las cifras del post-mortem salen de resumen.json; nada se escribe a mano.
"""
from __future__ import annotations
import argparse, json
from pathlib import Path

import numpy as np
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

from parsers import load_iis, load_httperr, load_events, load_perfmon, load_tickets

# ----------------------------------------------------------------------------- constantes
TRANSACCIONALES = ["/", "/login", "/api/saldos", "/api/movimientos",
                   "/api/pagos/iniciar", "/api/pagos/confirmar"]
SCANNER_RE = r"(?:wp-login|\.env|phpmyadmin|admin/config|\.git)"
DEPLOY_TS = pd.Timestamp("2026-09-15 22:03:00")  # AndinaDeploy 1000 v2.3.1
DIA = pd.Timestamp("2026-09-18")
SEMANA = (pd.Timestamp("2026-09-14"), pd.Timestamp("2026-09-21"))
ERR_PCT_UMBRAL = 5.0      # mismo umbral que la alerta de ejemplo (Reto 4)
P95_UMBRAL_MS = 3000      # SLO de latencia asumido para endpoints transaccionales


def p95(s):
    return float(np.nanpercentile(s, 95)) if len(s) else np.nan


def jsonable(o):
    if isinstance(o, (pd.Timestamp,)):
        return o.strftime("%Y-%m-%d %H:%M:%S")
    if isinstance(o, (np.integer,)):
        return int(o)
    if isinstance(o, (np.floating, float)):
        return None if np.isnan(o) else round(float(o), 3)
    if isinstance(o, dict):
        return {(str(k) if not isinstance(k, (str, int, float, bool)) else k): jsonable(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [jsonable(v) for v in o]
    return o


def dump(obj, path: Path):
    path.write_text(json.dumps(jsonable(obj), indent=2, ensure_ascii=False), encoding="utf-8")


# ----------------------------------------------------------------------------- carga
def cargar(kit: Path):
    iis, dropped = load_iis(kit)
    he = load_httperr(kit)
    ev = load_events(kit)
    pm = load_perfmon(kit)
    tk = load_tickets(kit)
    iis["is_scanner"] = iis["cs-uri-stem"].str.contains(SCANNER_RE, regex=True)
    iis["is_user"] = ~iis["is_probe"] & ~iis["is_scanner"]
    iis["is_tx"] = iis["is_user"] & iis["cs-uri-stem"].isin(TRANSACCIONALES)
    he["is_user"] = ~he["is_probe"] & he["sc-status"].eq(503)
    return iis, dropped, he, ev, pm, tk


def calidad_datos(kit, iis, dropped, he, ev, pm):
    q = {}
    q["iis_archivos_descartados"] = dropped
    # cobertura de cada archivo W3C: IIS rota el log a las 00:00 UTC, es decir a las 19:00 de Bogotá.
    # Por eso u_ex260921.log no está fuera del periodo: contiene el domingo 20 de 19:00 a 23:59 (hora Colombia).
    cob = iis.groupby("source_file").agg(desde_local=("ts", "min"), hasta_local=("ts", "max"), lineas=("ts", "size"))
    q["iis_cobertura_archivos"] = {
        f: {"desde_local": r.desde_local, "hasta_local": r.hasta_local, "lineas": int(r.lineas)} for f, r in cob.iterrows()}
    q["iis_rotacion_19h_local"] = bool((cob.hasta_local.dt.hour.iloc[:-1] == 18).all())
    # cambio de formato W3C dentro de un archivo
    fmt = iis.assign(tiene_xff=iis.get("X-Forwarded-For").notna())
    cambio = fmt[fmt.tiene_xff].sort_values("ts").iloc[0]
    with (kit / "logs" / "iis" / "W3SVC2" / cambio.source_file).open(encoding="utf-8", errors="replace") as f:
        linea_fields = max(n for n, l in enumerate(f, start=1) if l.startswith("#Fields:") and n < cambio.line)
    q["iis_cambio_formato"] = {
        "archivo": cambio.source_file, "linea_fields": linea_fields, "primera_linea_datos": int(cambio.line),
        "ts_utc": cambio.ts_utc.strftime("%Y-%m-%d %H:%M:%S"), "ts_local": cambio.ts,
        "detalle": "Se agregan cs-host y X-Forwarded-For; desde aquí c-ip de los usuarios es 10.20.4.4 (proxy).",
        "pct_usuarios_via_proxy_despues": round(100 * (iis[(iis.ts >= cambio.ts) & iis.is_user]["c-ip"] == "10.20.4.4").mean(), 1),
        "evento_de_cambio_registrado": False,
    }
    # validación de zona horaria: el 503 en HTTP.sys debe coincidir con WAS 5002 (hora local)
    was = ev[(ev.Id == 5002)].ts.min()
    # segunda validación, independiente: cada iisreset (evento 3201, hora local) debe dejar un hueco en el log IIS
    # a la misma hora si el log se convierte de UTC, y no dejarlo si se leyera el log como si ya fuera hora local.
    ts_crudo = iis.ts_utc.dt.tz_localize(None)
    def hueco(serie, t):
        w = serie[(serie >= t - pd.Timedelta("2min")) & (serie < t + pd.Timedelta("3min"))].sort_values()
        return float(w.diff().dt.total_seconds().max())
    resets = ev[ev.Id == 3201].ts
    con_conv = [hueco(iis.ts, t) for t in resets]
    sin_conv = [hueco(ts_crudo, t) for t in resets]
    q["zona_horaria"] = {
        "supuesto": "IIS/HTTP.sys en UTC; eventos y Perfmon en hora local (UTC-5)",
        "evidencia": {
            "WAS_5002_pool_deshabilitado_local": was,
            "httperr_primer_503_utc": he.ts_utc.min().strftime("%Y-%m-%d %H:%M:%S"),
            "httperr_primer_503_local": he.ts.min(),
            "desfase_segundos_tras_convertir": (he.ts.min() - was).total_seconds(),
            "iisreset_hueco_max_s_convirtiendo_utc": con_conv,
            "iisreset_hueco_max_s_sin_convertir": sin_conv,
            # sin convertir hay huecos naturales de madrugada (poco tráfico); convertido, el hueco del reset los supera todos
            "iisreset_coincide_solo_si_se_convierte": bool(min(con_conv) > np.nanmax(sin_conv)),
        },
    }
    q["perfmon"] = {
        "muestras": len(pm), "intervalo_s": 300,
        "w3wp_vacios": int(pm.w3wp_private_bytes.isna().sum()),
        "w3wp_vacios_ts": pm.loc[pm.w3wp_private_bytes.isna(), "ts"].dt.strftime("%m-%d %H:%M").tolist(),
        "nota": "Vacíos = proceso w3wp inexistente en ese instante (caída o reciclaje).",
    }
    q["httperr_cobertura"] = {"desde_local": he.ts.min(), "hasta_local": he.ts.max(),
                              "nota": "Solo cubre desde el 18/09; no permite medir 503 de HTTP.sys en días previos."}
    lineas = (kit / "scripts" / "mantenimiento.log").read_text(encoding="utf-8", errors="replace").splitlines()
    lineas = [l.strip() for l in lineas if l.strip()]
    q["mantenimiento_log"] = {
        "lineas": len(lineas), "lineas_proceso_ok": sum(l == "Proceso OK" for l in lineas),
        "nota": "Sin fecha; el .bat escribe 'Proceso OK' siempre (no refleja éxito real).",
    }
    return q


# ----------------------------------------------------------------------------- línea de tiempo
def linea_tiempo(iis, he, ev, pm, tk):
    d = iis[(iis.ts >= DIA) & (iis.ts < DIA + pd.Timedelta(days=1))]
    tx = d[d.is_tx]
    base = iis[iis.is_tx & (iis.ts < DEPLOY_TS) & iis.ts.dt.hour.between(8, 18)]
    base_p95 = p95(base["time-taken"])

    # degradación: primera ventana de 15 min con p95 > 2x línea base sostenida 2 ventanas
    w = tx.set_index("ts")["time-taken"].resample("15min").apply(p95)
    sobre = w > 2 * base_p95
    sost = sobre & sobre.shift(-1, fill_value=False)
    inicio_degr = sost[sost & (sost.index.hour >= 6)].index.min()

    e5_all = d[(d["sc-status"] >= 500) & d.is_user]
    # errores de fondo: /api/movimientos falla ~18 veces/día toda la semana (otro defecto, ver riesgos).
    # El incidente empieza en la primera ventana de 5 min con >= 5 % de errores.
    uw = d[d.is_user].set_index("ts")["sc-status"].resample("5min").agg(lambda s: 100 * (s >= 500).mean())
    win = uw[(uw >= ERR_PCT_UMBRAL) & (uw.index >= DIA + pd.Timedelta("6h"))].index.min()
    oom = ev[ev.Message.str.contains("OutOfMemory", na=False) & (ev.ts >= DIA)]
    crash = ev[(ev.Id == 1026) & (ev.ts >= DIA)]
    was5002 = ev[ev.Id == 5002].iloc[0]
    he503 = he[he["sc-status"] == 503]
    rec = d[(d.ts > he503.ts.max()) & (d["sc-status"] < 500)].iloc[0]
    # errores 500 del incidente: desde la primera ventana con >= 5 % de errores hasta la recuperación
    # (los 500 de fondo posteriores a las 15:04 no son del incidente)
    e5 = e5_all[(e5_all.ts >= win) & (e5_all.ts < rec.ts)]
    # fin de la normalización: después de la recuperación, primera ventana 15 min sin 5xx y p95 < 2x base
    post = tx[tx.ts >= rec.ts]
    g = post.set_index("ts").resample("15min").agg({"time-taken": p95, "sc-status": lambda s: (s >= 500).sum()})
    normal = g[(g["time-taken"] < 2 * base_p95) & (g["sc-status"] == 0)].index.min()
    pmd = pm[(pm.ts >= DIA)]
    def ev_row(r): return f"eventos_WEB-PAGOS-01.csv:{int(r.line)}"
    def iis_row(r): return f"{r.source_file}:{int(r.line)}"

    hitos = [
        (pd.Timestamp("2026-09-18 02:00:01"), "Mantenimiento nocturno: iisreset (el pool arranca con ~300 MB)", "Normal", ev_row(ev[(ev.Id == 3201) & (ev.ts.dt.date == DIA.date())].iloc[0])),
        (pmd[(pmd.ts > DIA + pd.Timedelta("2h1min")) & (pmd.w3wp_private_mb > 1000)].ts.min(), "Memoria del pool supera 1.000 MB (3,3x lo normal antes del despliegue)", "Normal, aún sin síntomas", "perfmon_WEB-PAGOS-01.csv (Process(w3wp)\\Private Bytes)"),
        (inicio_degr, f"Inicio de la degradación: p95 transaccional > 2x la línea base ({base_p95:.0f} ms)", "Lentitud al consultar y pagar", "u_ex260918.log (p95 por ventana 15 min)"),
        (e5.ts.min(), "Primer error 500 a un usuario", "'Ha ocurrido un error inesperado'", iis_row(e5.sort_values("ts").iloc[0])),
        (oom.ts.min(), "Primera OutOfMemoryException en SesionPagoCache.Agregar (/api/pagos/confirmar)", "Pagos fallan de forma intermitente", ev_row(oom.iloc[0])),
        (tk.loc[tk.Id == "T-10252", "ts"].iloc[0], "Primer ticket: error al confirmar pago (T-10252)", "Usuarios reportan", "tickets_mesa_servicio.csv"),
        (crash.ts.min(), "Primer cierre del proceso w3wp por memoria (crash + dump)", "Errores y sesiones perdidas", ev_row(crash.iloc[0])),
        (pd.Timestamp(was5002.ts), "IIS deshabilita el pool tras 5 caídas seguidas (Rapid-Fail Protection)", "Caída total", ev_row(was5002)),
        (he503.ts.min(), "Primer 503 'Service Unavailable' (HTTP.sys, AppOffline)", "'Service Unavailable' en todo el portal", "httperr1.log:5"),
        (tk.loc[tk.Id == "T-10255", "ts"].iloc[0], "Ticket crítico T-10255: portal caído", "Usuarios reportan", "tickets_mesa_servicio.csv"),
        (rec.ts, "Primera respuesta exitosa tras el reinicio manual del pool (15:04 según T-10255)", "Portal vuelve a responder", iis_row(rec)),
        (normal, "Latencia y errores vuelven a valores normales", "Servicio normal", "u_ex260918.log"),
    ]
    tl = pd.DataFrame(hitos, columns=["hora_colombia", "hito", "que_vio_el_usuario", "evidencia"]).sort_values("hora_colombia")
    # pagos confirmados durante el incidente, en las 2 h previas y en las 2 h posteriores a la recuperación
    t_err = e5.ts.min()
    conf = iis[iis.is_user & (iis["cs-uri-stem"] == "/api/pagos/confirmar")]
    def confirmados(t0, t1):
        c = conf[(conf.ts >= t0) & (conf.ts < t1)]
        return int((c["sc-status"] == 200).sum()), int(len(c))
    ok_inc, tot_inc = confirmados(t_err, rec.ts)
    ok_pre, tot_pre = confirmados(t_err - pd.Timedelta("2h"), t_err)
    ok_post, _ = confirmados(rec.ts, rec.ts + pd.Timedelta("2h"))
    # misma franja horaria (recuperación + 2 h) de lunes a jueves, como referencia de un día normal
    ref = [confirmados(dd + (rec.ts - DIA), dd + (rec.ts - DIA) + pd.Timedelta("2h"))[0]
           for dd in pd.date_range(SEMANA[0], DIA, inclusive="left")]
    he_u = he[he.is_user]
    extra = {
        "linea_base_p95_ms": base_p95, "inicio_degradacion": inicio_degr, "primer_error": t_err,
        "minutos_degradacion_a_primer_error": (e5.ts.min() - inicio_degr).total_seconds() / 60,
        "caida_total_inicio": he503.ts.min(), "caida_total_fin": he503.ts.max(),
        "caida_total_min": (rec.ts - he503.ts.min()).total_seconds() / 60,
        "impacto_desde_primer_error_min": (rec.ts - e5.ts.min()).total_seconds() / 60,
        "crashes_w3wp": int(len(crash)), "oom_eventos_aspnet": int((ev.Id == 1309).sum()),
        "errores_500_usuario": int(len(e5)),
        "errores_500_fondo_semana_movimientos": int(((iis["sc-status"] >= 500) & iis.is_user & (iis["cs-uri-stem"] == "/api/movimientos") & ~((iis.ts >= win) & (iis.ts < normal))).sum()),
        "errores_500_confirmar_iniciar": int(e5["cs-uri-stem"].isin(["/api/pagos/confirmar", "/api/pagos/iniciar"]).sum()),
        "rechazos_503_usuario": int(he["is_user"].sum()),
        "rechazos_503_pagos": int(he[he.is_user & he["cs-uri"].str.startswith("/api/pagos")].shape[0]),
        "health_503_en_httperr": int((he.is_probe & (he["sc-status"] == 503)).sum()),
        "health_status_durante_errores_500": d[d.is_probe & (d.ts >= e5.ts.min()) & (d.ts < he503.ts.min())]["sc-status"].value_counts().to_dict(),
        "minutos_primer_error_a_primer_ticket": (tk.loc[tk.Id == "T-10252", "ts"].iloc[0] - e5.ts.min()).total_seconds() / 60,
        "win32_64_cliente_abandona": int((e5["sc-win32-status"] == 64).sum()),
        "solicitudes_fallidas_incidente": int(len(e5) + he_u.shape[0]),
        "intentos_pago_fallidos_incidente": int(e5["cs-uri-stem"].isin(["/api/pagos/confirmar", "/api/pagos/iniciar"]).sum()
                                                + he_u["cs-uri"].str.startswith("/api/pagos").sum()),
        # intentos de pago (iniciar/confirmar) y qué fracción falló: antes de la caída total (13:23-14:38) y en todo el incidente
        **_pagos_fallidos(d, he_u, t_err, he503.ts.min(), rec.ts),
        "errores_500_movimientos_semana_total": int(((iis["sc-status"] >= 500) & iis.is_user & (iis["cs-uri-stem"] == "/api/movimientos")).sum()),
        # durante la caída total todo llega desde el proxy: solo se pueden contar clientes con los 500 previos
        # IP distintas (X-Forwarded-For): aproximación al número de clientes, no un conteo exacto (NAT, móviles, varias IP)
        "ips_distintas_con_500": int(e5.client_ip.nunique()),
        "pagos_confirmados_ok_durante_incidente": ok_inc, "pagos_confirmar_intentos_durante_incidente": tot_inc,
        "pagos_confirmados_ok_2h_previas": ok_pre, "pagos_confirmar_intentos_2h_previas": tot_pre,
        "pagos_confirmados_2h_tras_recuperacion": ok_post,
        "pagos_confirmados_misma_franja_promedio_lun_jue": float(np.mean(ref)),
    }
    return tl, extra


def _pagos_fallidos(d, he_u, t0, t_caida, t_rec):
    """Intentos de pago (POST iniciar/confirmar) y % fallido. En IIS, fallido = status >= 500; los 503 de HTTP.sys son
    intentos que IIS nunca registró, así que se suman a los dos lados."""
    pagos = d[d.is_user & d["cs-uri-stem"].isin(["/api/pagos/iniciar", "/api/pagos/confirmar"])]
    def tramo(a, b):
        x = pagos[(pagos.ts >= a) & (pagos.ts < b)]
        h = int(he_u[(he_u.ts >= a) & (he_u.ts < b) & he_u["cs-uri"].str.startswith("/api/pagos")].shape[0])
        fall = int((x["sc-status"] >= 500).sum()) + h
        tot = int(len(x)) + h
        return tot, fall, (100.0 * fall / tot if tot else float("nan"))
    t1, f1, p1 = tramo(t0, t_caida)
    t2, f2, p2 = tramo(t0, t_rec)
    return {"pagos_intentos_antes_caida_total": t1, "pagos_fallidos_antes_caida_total": f1, "pct_pagos_fallidos_antes_caida_total": p1,
            "pagos_intentos_incidente": t2, "pagos_fallidos_incidente": f2, "pct_pagos_fallidos_incidente": p2}


# ----------------------------------------------------------------------------- disponibilidad
def disponibilidad(iis, he):
    u = iis[iis.is_user]
    rows = []
    for day in pd.date_range(*SEMANA, inclusive="left"):
        m = (u.ts >= day) & (u.ts < day + pd.Timedelta(days=1))
        dd = u[m]
        h = he[(he.ts >= day) & (he.ts < day + pd.Timedelta(days=1))]
        pr = iis[iis.is_probe & (iis.ts >= day) & (iis.ts < day + pd.Timedelta(days=1))]
        ok = int((dd["sc-status"] < 500).sum())
        fail = int((dd["sc-status"] >= 500).sum()) + int(h.is_user.sum())
        # por minutos: minuto malo si %5xx >= umbral o hay 503 de HTTP.sys o p95 tx > umbral
        mins = pd.date_range(day, day + pd.Timedelta(days=1), freq="1min", inclusive="left")
        g = dd.set_index("ts").resample("1min")["sc-status"].agg(["size", lambda s: (s >= 500).sum()]).reindex(mins, fill_value=0)
        g.columns = ["n", "e5"]
        g["e503"] = h[h.is_user].set_index("ts").resample("1min").size().reindex(mins, fill_value=0)
        tx = dd[dd.is_tx].set_index("ts")["time-taken"].resample("1min").apply(p95).reindex(mins)
        tot = g.n + g.e503
        err_pct = 100 * (g.e5 + g.e503) / tot.where(tot > 0)
        malo_err = err_pct >= ERR_PCT_UMBRAL
        malo_lento = tx > P95_UMBRAL_MS
        # sondeo NOC: lo que ve en los logs IIS vs incluyendo HTTP.sys
        pr_ok = int((pr["sc-status"] == 200).sum())
        pr_fail_he = int((h.is_probe & (h["sc-status"] == 503)).sum())
        rows.append({
            "dia": day.date(), "solicitudes_usuario": ok + fail, "fallidas": fail,
            "disp_solicitudes_pct": 100 * ok / (ok + fail),
            "disp_minutos_errores_pct": 100 * (1 - malo_err.sum() / len(mins)),
            "disp_minutos_errores_y_latencia_pct": 100 * (1 - (malo_err | malo_lento).sum() / len(mins)),
            "minutos_malos": int((malo_err | malo_lento).sum()),
            "noc_health_solo_iis_pct": 100.0 if pr_ok else np.nan,
            "noc_health_con_httperr_pct": 100 * pr_ok / (pr_ok + pr_fail_he),
        })
    df = pd.DataFrame(rows)
    tot = {
        "disp_solicitudes_pct": 100 * (1 - df.fallidas.sum() / df.solicitudes_usuario.sum()),
        "disp_minutos_errores_pct": df.disp_minutos_errores_pct.mean(),
        "disp_minutos_errores_y_latencia_pct": df.disp_minutos_errores_y_latencia_pct.mean(),
        "minutos_malos_semana": int(df.minutos_malos.sum()),
        "noc_health_con_httperr_pct": df.noc_health_con_httperr_pct.mean(),
    }
    # reinicio nocturno: hueco máximo sin respuestas alrededor de las 02:00
    huecos = []
    for day in pd.date_range(*SEMANA, inclusive="left"):
        w = iis[(iis.ts >= day + pd.Timedelta("1h58min")) & (iis.ts < day + pd.Timedelta("2h05min"))].sort_values("ts")
        huecos.append(float(w.ts.diff().dt.total_seconds().max()))
    tot["hueco_nocturno_iisreset_s_promedio"] = float(np.mean(huecos))
    tot["hueco_nocturno_iisreset_s"] = huecos
    return df, tot


# ----------------------------------------------------------------------------- señales tempranas
def senales(iis, pm, ev, primer_error):
    u = iis[iis.is_user]
    tx = u[u.is_tx]
    pm = pm.copy()
    pm["dia"] = pm.ts.dt.date
    s = pm.groupby("dia").agg(w3wp_max_mb=("w3wp_private_mb", "max"),
                              disco_libre_min_mb=("disk_c_free_mb", "min"),
                              disco_libre_min_pct=("disk_c_free_pct", "min"),
                              cpu_max_pct=("cpu_pct", "max"))
    s["p95_tx_ms"] = tx.groupby(tx.ts.dt.date)["time-taken"].apply(p95)
    noche = tx[tx.ts.dt.hour.between(18, 23)]
    s["p95_tx_noche_ms"] = noche.groupby(noche.ts.dt.date)["time-taken"].apply(p95)
    s["errores_5xx"] = u[u["sc-status"] >= 500].groupby(u.ts.dt.date).size()
    s["pagos_confirmados"] = u[(u["cs-uri-stem"] == "/api/pagos/confirmar") & (u["sc-status"] == 200)].groupby(u.ts.dt.date).size()
    s["dcom_10016"] = ev[ev.Id == 10016].groupby(ev.ts.dt.date).size()
    s = s.fillna(0)
    pre = pm[pm.ts < DEPLOY_TS]
    base_mem = float(pre.w3wp_private_mb.max())
    # latencia: primera ventana de 15 min después del despliegue con p95 transaccional > 2x la línea base
    base_p95 = p95(iis[iis.is_tx & (iis.ts < DEPLOY_TS) & iis.ts.dt.hour.between(8, 18)]["time-taken"])
    w15 = tx[tx.ts > DEPLOY_TS].set_index("ts")["time-taken"].resample("15min").apply(p95)
    cruce_p95 = w15[w15 > 2 * base_p95].index.min()
    factor_noche = (s["p95_tx_noche_ms"] / base_p95).round(2).to_dict()
    cruce = pm[(pm.ts > DEPLOY_TS) & (pm.w3wp_private_mb > 2 * base_mem)].ts.min()
    # aumento de C: libre entre 01:55 y 02:10 de cada día (la ventana del mantenimiento). OJO: el .BAT purga D:, no C:;
    # la única ruta de C: que toca es C:\Dumps\*.*. El origen del aumento del 15-sep no está demostrado (hipótesis).
    purga = {}
    for day in pd.date_range(*SEMANA, inclusive="left"):
        v = pm[(pm.ts >= day + pd.Timedelta("1h55min")) & (pm.ts <= day + pd.Timedelta("2h10min"))].disk_c_free_mb
        purga[str(day.date())] = float(v.max() - v.iloc[0]) if len(v) else np.nan
    pre_reset = pm[(pm.ts >= "2026-09-18 01:00") & (pm.ts < "2026-09-18 02:00")]
    pre_crash = pm[(pm.ts >= DIA + pd.Timedelta("12h")) & (pm.ts <= ev[(ev.Id == 1026)].ts.min())]
    notif = ev[ev.Message.str.contains("Servicio Notificaciones service entered the running", na=False)]
    return s, {"w3wp_max_previo_mb": base_mem, "primer_cruce_2x_memoria": cruce,
               "horas_de_anticipacion": (primer_error - cruce).total_seconds() / 3600,
               "primer_p95_15min_sobre_2x_base": cruce_p95,
               "factor_p95_noche_vs_base_por_dia": {str(k): v for k, v in factor_noche.items()},
               "w3wp_max_antes_reset_18sep_mb": float(pre_reset.w3wp_private_mb.max()),
               "ram_libre_min_mb_antes_primer_crash": float(pre_crash.mem_avail_mb.min()),
               "dcom_10016_semana": int((ev.Id == 10016).sum()),
               "notificaciones_arranques_semana": int(len(notif)),
               "notificaciones_arranques_a_las_02h": int(((notif.ts.dt.hour == 2) & (notif.ts.dt.minute < 5)).sum()),
               "c_libre_aumento_0155_0210_mb": purga}


# ----------------------------------------------------------------------------- modelo de memoria
def modelo_memoria(iis, pm, ev, primer_error):
    """Crecimiento de w3wp por pago confirmado, dentro de cada 'vida' del proceso."""
    conf = iis[(iis["cs-uri-stem"] == "/api/pagos/confirmar") & (iis["sc-status"] == 200)]
    ini = iis[(iis["cs-uri-stem"] == "/api/pagos/iniciar") & (iis["sc-status"] == 200)]
    allu = iis[iis.is_user]
    s = pm.set_index("ts")[["w3wp_private_mb"]].copy()
    s["conf"] = conf.set_index("ts").resample("5min").size().reindex(s.index, fill_value=0)
    s["ini"] = ini.set_index("ts").resample("5min").size().reindex(s.index, fill_value=0)
    s["req"] = allu.set_index("ts").resample("5min").size().reindex(s.index, fill_value=0)
    s["dmem"] = s.w3wp_private_mb.diff()
    reinicio = s.w3wp_private_mb.diff() < -300           # iisreset / crash
    s["vida"] = (reinicio | s.w3wp_private_mb.isna()).cumsum()
    s = s.dropna(subset=["w3wp_private_mb"])
    res = {}
    for nombre, mask in {"antes_v2.3.1": s.index < DEPLOY_TS, "despues_v2.3.1": s.index >= DEPLOY_TS + pd.Timedelta("4h")}.items():
        x = s[mask].copy()
        out = {}
        for var in ["conf", "ini", "req"]:
            # dentro de cada vida del proceso: memoria ~ a_vida + b * acumulado(var); se centra por vida
            x["cum"] = x.groupby("vida")[var].cumsum()
            xc = x.groupby("vida")[["cum", "w3wp_private_mb"]].transform(lambda c: c - c.mean())
            X, Y = xc["cum"].values, xc["w3wp_private_mb"].values
            b = float((X * Y).sum() / (X * X).sum())
            r2 = 1 - ((Y - b * X) ** 2).sum() / (Y ** 2).sum()
            out[var] = {"mb_por_unidad": b, "r2": r2}
        res[nombre] = out
    mb_pago = res["despues_v2.3.1"]["conf"]["mb_por_unidad"]
    # umbral observado de OOM: memoria máxima justo antes del primer crash
    crash1 = ev[(ev.Id == 1026)].ts.min()
    umbral = float(pm[(pm.ts <= crash1)].w3wp_private_mb.tail(12).max())
    base = float(pm[(pm.ts >= "2026-09-18 02:00") & (pm.ts <= "2026-09-18 02:30")].w3wp_private_mb.mean())
    cap = (umbral - base) / mb_pago
    # pagos confirmados desde el reset hasta el primer error del 18
    real = int(conf[(conf.ts >= "2026-09-18 02:00") & (conf.ts < primer_error)].shape[0])
    wk = conf[conf.ts < "2026-09-19"].groupby(conf.ts.dt.date).size()
    viernes = int(wk.loc[DIA.date()])
    return {
        "regresiones": res, "mb_por_pago_confirmado": mb_pago, "umbral_oom_observado_mb": umbral,
        "memoria_tras_reset_mb": base, "capacidad_pagos_entre_reinicios": cap,
        "pagos_confirmados_18sep_hasta_primer_error": real,
        "pagos_confirmados_por_dia_lun_jue": wk.iloc[:4].to_dict(),
        "pagos_confirmados_18sep": viernes,
        "factor_pagos_18sep_vs_promedio_lun_jue": viernes / wk.iloc[:4].mean(),
        "factor_pagos_18sep_vs_max_lun_jue": viernes / wk.iloc[:4].max(),
        "uso_capacidad_dia_normal_pct": 100 * wk.iloc[:4].mean() / cap,
        "dias_hasta_oom_sin_reinicio_nocturno": cap / wk.iloc[:4].mean(),
        "nota": "Dentro de cada vida del proceso w3wp (entre reinicios), memoria ~ base + b * pagos acumulados. "
                "Antes de v2.3.1 la pendiente es ~0 (memoria plana); después, cada pago deja memoria retenida.",
    }


# ----------------------------------------------------------------------------- pronóstico de disco
def pronostico_disco(iis, pm, ev):
    s = pm.set_index("ts")[["disk_c_free_mb"]].resample("1h").last()
    req = iis[iis.is_user].set_index("ts").resample("1h").size().reindex(s.index, fill_value=0)
    s["req"] = req
    s["consumo_mb"] = -s.disk_c_free_mb.diff()
    total_mb = float((pm.disk_c_free_mb / (pm.disk_c_free_pct / 100)).median())
    dumps = (s.index >= "2026-09-18 14:00") & (s.index <= "2026-09-18 15:00")
    out = {}
    for nombre, mask in {"antes": s.index < DEPLOY_TS, "despues": (s.index > DEPLOY_TS + pd.Timedelta("2h")) & ~dumps}.items():
        x = s[mask].dropna()
        b = np.polyfit(x.req, x.consumo_mb, 1)
        r2 = 1 - ((x.consumo_mb - np.polyval(b, x.req)) ** 2).sum() / ((x.consumo_mb - x.consumo_mb.mean()) ** 2).sum()
        out[nombre] = {"mb_por_1000_solicitudes": 1000 * b[0], "mb_por_hora_base": b[1], "r2": r2,
                       "consumo_mb_dia_promedio": float(x.consumo_mb.mean() * 24)}
    out["salto_dumps_18sep_mb"] = float(s.loc["2026-09-18 14:00":"2026-09-18 15:00", "consumo_mb"].sum())
    # perfil de tráfico horario por tipo de día
    u = iis[iis.is_user]
    hh = u.groupby([u.ts.dt.dayofweek < 5, u.ts.dt.date, u.ts.dt.hour]).size()
    perfil = {lab: hh.loc[flag].groupby(level=1).mean() for flag, lab in [(True, "habil"), (False, "finde")]}
    perfil["habil"] = u[u.ts < "2026-09-18"].groupby([u.ts.dt.date, u.ts.dt.hour]).size().groupby(level=1).mean()  # sin el pico del 18
    b1, b0 = out["despues"]["mb_por_1000_solicitudes"] / 1000, out["despues"]["mb_por_hora_base"]
    # escenarios: tráfico del día hábil más bajo / promedio / más alto observado (14-17 sep)
    diario = u[u.ts < "2026-09-18"].groupby(u.ts.dt.date).size()
    escenarios = {"bajo": diario.min() / diario.mean(), "medio": 1.0, "alto": diario.max() / diario.mean()}

    def simular(factor):
        libre = float(pm.disk_c_free_mb.iloc[-1]); t = pm.ts.iloc[-1].ceil("h")
        rows, hit = [], {}
        while libre > 0 and len(rows) < 24 * 30:
            tipo = "habil" if t.dayofweek < 5 else "finde"
            consumo = b0 + b1 * float(perfil[tipo].get(t.hour, 0)) * (factor if tipo == "habil" else 1)
            libre -= consumo
            rows.append({"ts": t, "libre_mb_pronostico": libre, "libre_pct": 100 * libre / total_mb})
            for etiqueta, lim in [("10pct", 0.10 * total_mb), ("5pct", 0.05 * total_mb), ("0", 0)]:
                if libre <= lim and etiqueta not in hit:
                    hit[etiqueta] = t
            t += pd.Timedelta("1h")
        return rows, hit
    rows, hit = simular(1.0)
    out["escenarios_lleno"] = {k: simular(f)[1].get("0") for k, f in escenarios.items()}
    # escenario de cierre de mes: un día con el tráfico del 18/09
    pico = u[(u.ts >= DIA) & (u.ts < DIA + pd.Timedelta(days=1))].shape[0]
    out.update({
        "disco_total_mb": total_mb, "libre_al_cierre_kit_mb": float(pm.disk_c_free_mb.iloc[-1]),
        "libre_al_cierre_kit_pct": float(pm.disk_c_free_pct.iloc[-1]),
        "agota_10pct": "ya por debajo al cierre del kit" if pm.disk_c_free_pct.iloc[-1] < 10 else hit.get("10pct"), "agota_5pct": hit.get("5pct"), "agota_0": hit.get("0"),
        "consumo_dia_habil_mb": float(sum(b0 + b1 * perfil["habil"].get(h, 0) for h in range(24))),
        "consumo_dia_pico_mb": float(24 * b0 + b1 * pico),
        "evento_srv_2013": ev[ev.Id == 2013].ts.min(),
        "metodo": "Regresión lineal consumo_horario_MB ~ solicitudes_hora (después del despliegue, sin el salto por dumps), "
                  "proyectada con el perfil horario promedio de días hábiles (14-17 sep) y de fin de semana (19-20 sep).",
    })
    return pd.DataFrame(rows), out, s


# ----------------------------------------------------------------------------- figuras
COL = {"lat": "#2F6DB5", "err": "#C8423B", "mem": "#6A4C93", "disk": "#2E8B57", "mut": "#888888"}


def fig_incidente(iis, he, pm, tl, path):
    d0, d1 = pd.Timestamp("2026-09-18 08:00"), pd.Timestamp("2026-09-18 17:00")
    tx = iis[iis.is_tx & (iis.ts >= d0) & (iis.ts < d1)].set_index("ts")
    lat = tx["time-taken"].resample("5min").apply(p95) / 1000
    u = iis[iis.is_user & (iis.ts >= d0) & (iis.ts < d1)].set_index("ts")
    tot = u["sc-status"].resample("5min").size()
    e = u["sc-status"].resample("5min").apply(lambda s: (s >= 500).sum())
    h = he[he.is_user].set_index("ts").resample("5min").size().reindex(tot.index, fill_value=0)
    err = 100 * (e + h) / (tot + h).where((tot + h) > 0)
    m = pm[(pm.ts >= d0) & (pm.ts < d1)].set_index("ts").w3wp_private_mb
    fig, ax = plt.subplots(3, 1, figsize=(11, 7.5), sharex=True)
    ax[0].plot(m.index, m, color=COL["mem"]); ax[0].set_ylabel("Memoria pool (MB)")
    ax[0].axhline(1400, ls="--", color=COL["mut"], lw=1); ax[0].text(d0, 1420, "zona de OutOfMemory (~1,4 GB)", fontsize=8, color=COL["mut"])
    ax[1].plot(lat.index, lat, color=COL["lat"]); ax[1].set_ylabel("Latencia p95 (s)")
    ax[2].fill_between(err.index, err.fillna(0), color=COL["err"], alpha=.8, step="post"); ax[2].set_ylabel("% solicitudes con error")
    ax[2].set_ylim(0, 105)
    for _, r in tl.iterrows():
        if d0 <= r.hora_colombia < d1 and any(k in r.hito for k in ["Inicio de la degr", "Primer error 500", "deshabilita", "Primera respuesta"]):
            for a in ax: a.axvline(r.hora_colombia, color=COL["mut"], lw=.8, ls=":")
            ax[0].text(r.hora_colombia, ax[0].get_ylim()[1] * .97, " " + r.hora_colombia.strftime("%H:%M"), fontsize=8, va="top")
    for a in ax:
        a.spines[["top", "right"]].set_visible(False); a.grid(alpha=.25)
    ax[2].xaxis.set_major_formatter(mdates.DateFormatter("%H:%M"))
    fig.suptitle("Viernes 18-sep (hora Colombia): memoria → lentitud → errores → caída", x=0.01, ha="left")
    fig.tight_layout(); fig.savefig(path, dpi=130); plt.close(fig)


def fig_semana(pm, ev, path):
    s = pm.set_index("ts")
    fig, ax = plt.subplots(2, 1, figsize=(11, 6), sharex=True)
    ax[0].plot(s.index, s.w3wp_private_mb, color=COL["mem"], lw=1); ax[0].set_ylabel("Memoria pool (MB)")
    ax[1].plot(s.index, s.disk_c_free_mb / 1024, color=COL["disk"], lw=1.2); ax[1].set_ylabel("Libre en C: (GB)")
    marks = [(DEPLOY_TS, "Despliegue v2.3.1"), (pd.Timestamp("2026-09-16 11:30"), "Se retira D:"), (pd.Timestamp("2026-09-18 14:22"), "Caída")]
    for i, (t, lab) in enumerate(marks):
        for a in ax: a.axvline(t, color=COL["mut"], lw=.8, ls=":")
        ax[0].text(t, ax[0].get_ylim()[1] * (.97 - .08 * (i % 2)), " " + lab, fontsize=8, va="top")
    for a in ax:
        a.spines[["top", "right"]].set_visible(False); a.grid(alpha=.25)
    ax[1].xaxis.set_major_formatter(mdates.DateFormatter("%a %d"))
    fig.suptitle("Semana 14–20 sep: la fuga de memoria y el consumo de disco empiezan con el despliegue", x=0.01, ha="left")
    fig.tight_layout(); fig.savefig(path, dpi=130); plt.close(fig)


def fig_disco(pm, fc, out, path):
    fig, ax = plt.subplots(figsize=(11, 3.8))
    ax.plot(pm.ts, pm.disk_c_free_mb / 1024, color=COL["disk"], label="Observado")
    ax.plot(fc.ts, fc.libre_mb_pronostico.clip(lower=0) / 1024, color=COL["disk"], ls="--", label="Pronóstico")
    ax.axhline(0.10 * out["disco_total_mb"] / 1024, color=COL["mut"], lw=.8, ls=":"); ax.text(pm.ts.iloc[0], 0.10 * out["disco_total_mb"] / 1024 + .5, "10 % libre", fontsize=8)
    if out["agota_0"] is not None:
        ax.axvline(out["agota_0"], color=COL["err"], lw=1); ax.text(out["agota_0"], 30, " C: lleno\n " + out["agota_0"].strftime("%a %d %H:%M"), color=COL["err"], fontsize=9)
    ax.set_ylabel("Libre en C: (GB)"); ax.legend(frameon=False)
    ax.spines[["top", "right"]].set_visible(False); ax.grid(alpha=.25)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%a %d"))
    ax.set_title("Pronóstico: el disco C: se llena si no se corrige el nivel de log y la limpieza", loc="left")
    fig.tight_layout(); fig.savefig(path, dpi=130); plt.close(fig)


# ----------------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--kit", type=Path, required=True, help="carpeta kit_prueba_portalpagos")
    ap.add_argument("--out", type=Path, default=Path("salidas"))
    a = ap.parse_args(argv)
    if not (a.kit / "logs" / "iis").is_dir():
        raise SystemExit(f"No encuentro logs/iis dentro de {a.kit}")
    a.out.mkdir(parents=True, exist_ok=True)

    iis, dropped, he, ev, pm, tk = cargar(a.kit)
    q = calidad_datos(a.kit, iis, dropped, he, ev, pm); dump(q, a.out / "calidad_datos.json")
    tl, inc = linea_tiempo(iis, he, ev, pm, tk); tl.to_csv(a.out / "linea_tiempo_18sep.csv", index=False)
    disp, disp_tot = disponibilidad(iis, he); disp.round(3).to_csv(a.out / "disponibilidad_diaria.csv", index=False)
    sen, sen_x = senales(iis, pm, ev, inc["primer_error"]); sen.round(1).to_csv(a.out / "senales_tempranas.csv")
    mem = modelo_memoria(iis, pm, ev, inc["primer_error"]); dump(mem, a.out / "modelo_memoria.json")
    fc, dsk, _ = pronostico_disco(iis, pm, ev); fc.to_csv(a.out / "pronostico_disco.csv", index=False); dump(dsk, a.out / "pronostico_disco.json")
    fig_incidente(iis, he, pm, tl, a.out / "fig_incidente_18sep.png")
    fig_semana(pm, ev, a.out / "fig_semana.png")
    fig_disco(pm, fc, dsk, a.out / "fig_pronostico_disco.png")

    resumen = {"incidente": inc, "disponibilidad": disp_tot, "senales": sen_x, "memoria": mem, "disco": dsk,
               "calidad": {"descartados": dropped, "cambio_formato": q["iis_cambio_formato"]},
               "volumen": {"solicitudes_usuario_semana": int(iis.is_user.sum()), "sondeos_health": int(iis.is_probe.sum()),
                           "escaneos_404": int(iis.is_scanner.sum())}}
    dump(resumen, a.out / "resumen.json")
    print(tl.to_string(index=False))
    print(disp.round(2).to_string(index=False))
    print(json.dumps(jsonable({"incidente": inc, "disp": disp_tot, "senales": sen_x}), indent=1, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
