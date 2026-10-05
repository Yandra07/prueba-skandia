"""Construye el contexto del incidente: evidencias numeradas (E1, E2…) con texto literal y señales.

Dos fuentes, con el mismo formato de salida:
  - desde_kit():           archivos del kit (logs IIS, HTTP.sys, eventos, Perfmon) alrededor de la alerta.
  - desde_log_analytics(): consultas KQL al workspace del Reto 3 (alerta real del laboratorio).

Solo entra información ANTERIOR al disparo de la alerta (con 2 min de margen): el triage debe razonar con lo que
se sabía en ese momento, no con el desenlace.

El texto de las evidencias es DATO, no instrucción: el prompt lo marca así y el validador exige citas literales.
"""
from __future__ import annotations
import json, re, subprocess, sys
from dataclasses import dataclass, field, asdict
from datetime import datetime, timedelta, timezone
from pathlib import Path

BOGOTA = timezone(timedelta(hours=-5))
MAX_TEXTO = 320


@dataclass
class Evidencia:
    id: str
    fuente: str
    ts: str
    texto: str
    senales: list[str] = field(default_factory=list)
    ts_fin: str = ""          # último instante que cubre la evidencia (grupos y ventanas); vacío = ts


@dataclass
class Contexto:
    alerta: dict
    ventana: dict
    evidencias: list[Evidencia]

    def to_dict(self) -> dict:
        return {"alerta": self.alerta, "ventana": self.ventana, "evidencias": [asdict(e) for e in self.evidencias]}

    @staticmethod
    def from_dict(d: dict) -> "Contexto":
        return Contexto(d["alerta"], d["ventana"], [Evidencia(**e) for e in d["evidencias"]])

    def por_id(self) -> dict[str, Evidencia]:
        return {e.id: e for e in self.evidencias}

    def senales(self) -> set[str]:
        return {s for e in self.evidencias for s in e.senales}


# ------------------------------------------------------------------ alerta (esquema común de Azure Monitor)
def leer_alerta(d: dict) -> dict:
    if d.get("schemaId") != "azureMonitorCommonAlertSchema":
        raise ValueError(f"Esquema de alerta no soportado: {d.get('schemaId')}")
    e = d["data"]["essentials"]
    ctx = d["data"].get("alertContext") or {}
    cond = (ctx.get("condition") or {}).get("allOf") or [{}]
    return {
        "id": e.get("alertId", "").split("/")[-1], "regla": e.get("alertRule"), "severidad": e.get("severity"),
        "condicion": e.get("monitorCondition"), "disparo_utc": e.get("firedDateTime"),
        "descripcion": e.get("description", ""), "objetivo": (e.get("alertTargetIDs") or [""])[0].split("/")[-1],
        "consulta": cond[0].get("searchQuery", ""), "valor": cond[0].get("metricValue"), "umbral": cond[0].get("threshold"),
    }


def _ts_utc(s: str) -> datetime:
    """ISO 8601 tolerante. fromisoformat en Python 3.10 solo acepta fracciones de 3 o 6 dígitos y no acepta 'Z';
    Azure devuelve de 1 a 7 dígitos (p. ej. '01:35:01.67945' falló en Automation el 04-oct): se normaliza a 6."""
    s = s.strip().replace("Z", "+00:00")
    s = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], s)
    t = datetime.fromisoformat(s)
    return (t if t.tzinfo else t.replace(tzinfo=timezone.utc)).astimezone(timezone.utc)


def _senales(texto: str) -> list[str]:
    t = texto.lower()
    reglas = {
        "pool_caido": [r"\b5002\b", "appoffline", "automatically disabled", "service unavailable", r"estado del pool: (?!3)", "pool .*stopped"],
        "oom": ["outofmemory"],
        "memoria_alta": ["private bytes memory limit"],
        "disco_bajo": ["at or near capacity"],
        "dependencia": ["dependencia", "health.*503.*pool.*started", "pool started pero"],
        "escaneo": ["wp-login", r"\.env", "phpmyadmin"],
        "sin_heartbeat": ["sin heartbeat"],
        "despliegue_reciente": ["despliegue completado", "cambio de infraestructura"],
        "crash_w3wp": [r"\b5011\b", r"\b1026\b", "fatal communication error", "terminated due to an unhandled exception"],
    }
    return sorted(k for k, pats in reglas.items() if any(re.search(p, t) for p in pats))


class _Acum:
    def __init__(self):
        self.items: list[Evidencia] = []

    def add(self, fuente: str, ts: datetime | str, texto: str, senales: list[str] | None = None, auto: bool = True,
            ts_fin: datetime | str | None = None):
        """auto=False: solo las señales explícitas (hechos calculados por código, donde el texto puede nombrar
        un evento para decir que NO ocurrió, como "0 eventos WAS 5002")."""
        def fmt(x):   # sin zona = ya está en hora de Bogotá (kit); con zona = se convierte
            return x if isinstance(x, str) else (x if x.tzinfo is None else x.astimezone(BOGOTA)).strftime("%Y-%m-%d %H:%M:%S")
        tss = fmt(ts)
        texto = " ".join(str(texto).split())[:MAX_TEXTO]
        sen = sorted(set((senales or []) + (_senales(texto) if auto else [])))
        self.items.append(Evidencia(f"E{len(self.items) + 1}", fuente, tss, texto, sen, fmt(ts_fin) if ts_fin is not None else tss))


# ------------------------------------------------------------------ fuente 1: kit del caso
def desde_kit(alerta_json: dict, kit: Path, minutos_antes: int = 60) -> Contexto:
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "reto1-diagnostico" / "src"))
    import pandas as pd
    from parsers import load_iis, load_httperr, load_events, load_perfmon  # noqa: E402

    al = leer_alerta(alerta_json)
    fin = _ts_utc(al["disparo_utc"]).astimezone(BOGOTA).replace(tzinfo=None) + timedelta(minutes=2)
    ini = fin - timedelta(minutes=minutos_antes + 2)
    A = _Acum()

    iis, _ = load_iis(kit)
    u = iis[~iis["is_probe"] & (iis.ts >= ini) & (iis.ts <= fin)]
    if len(u):
        g = u.set_index("ts").resample("10min")["sc-status"].agg(["size", lambda s: (s >= 500).sum()])
        g.columns = ["n", "e5"]
        lat = u.set_index("ts")["time-taken"].resample("10min").quantile(0.95)
        for t, r in g.iterrows():
            A.add("iis-agregado", t, f"IIS {t:%H:%M}-{t + pd.Timedelta('10min'):%H:%M}: {int(r.n)} solicitudes de usuario, "
                  f"{int(r.e5)} con 5xx ({100 * r.e5 / max(r.n, 1):.1f} %), latencia p95 {lat.get(t, float('nan')):.0f} ms",
                  ts_fin=t + pd.Timedelta("10min"))
        e5 = u[u["sc-status"] >= 500]
        for uri, n in e5.groupby("cs-uri-stem").size().sort_values(ascending=False).head(4).items():
            A.add("iis-agregado", fin, f"IIS en la ventana: {n} errores 5xx en {uri}")
        for _, r in e5.sort_values("ts").head(3).iterrows():
            A.add("iis-linea", r.ts, f"{r.source_file}:{r.line} {r['cs-method']} {r['cs-uri-stem']} {int(r['sc-status'])} "
                  f"time-taken={int(r['time-taken'])} ms")
        h = iis[iis["is_probe"] & (iis.ts >= ini) & (iis.ts <= fin)]
        if len(h):
            A.add("iis-agregado", fin, f"Sonda NOC /health en la ventana: {len(h)} respuestas, "
                  f"{int((h['sc-status'] == 200).sum())} con 200")

    he = load_httperr(kit)
    he = he[(he.ts >= ini) & (he.ts <= fin)]
    if len(he):
        A.add("httperr", he.ts.min(), f"HTTP.sys: {len(he)} rechazos {int(he['sc-status'].mode()[0])} "
              f"{he['s-reason'].mode()[0]} entre {he.ts.min():%H:%M:%S} y {he.ts.max():%H:%M:%S}")

    ev = load_events(kit)
    cambios = ev[(ev.ProviderName == "AndinaDeploy") & (ev.ts <= fin) & (ev.ts >= fin - timedelta(days=7))]
    for _, r in cambios.iterrows():
        A.add("evento", r.ts, f"[{r.ProviderName} {r.Id}] {r.Message}")
    w = ev[(ev.ts >= ini) & (ev.ts <= fin) & ~ev.ProviderName.isin(["Microsoft-Windows-DistributedCOM", "Service Control Manager"])]
    for (prov, eid), grp in w.groupby(["ProviderName", "Id"]):
        r = grp.iloc[0]
        A.add("evento", r.ts, f"[{prov} {eid} {r.LevelDisplayName}] x{len(grp)} desde {grp.ts.min():%H:%M:%S} hasta "
              f"{grp.ts.max():%H:%M:%S}. Ejemplo: {r.Message}", ts_fin=grp.ts.max())
    dcom = ev[(ev.ts >= ini) & (ev.ts <= fin) & (ev.ProviderName == "Microsoft-Windows-DistributedCOM")]
    if len(dcom):
        A.add("evento", dcom.ts.min(), f"[DistributedCOM 10016 Warning] x{len(dcom)} en la ventana (aviso de permisos COM)")

    pm = load_perfmon(kit)
    p = pm[(pm.ts >= ini - timedelta(hours=3)) & (pm.ts <= fin)].iloc[::6]
    for _, r in p.iterrows():
        A.add("perfmon", r.ts, f"Perfmon {r.ts:%H:%M}: memoria privada de w3wp {r.w3wp_private_mb:.0f} MB, "
              f"memoria disponible {r.mem_avail_mb:.0f} MB, CPU {r.cpu_pct:.0f} %, {r.disk_c_free_pct:.1f} % libre en C:",
              (["memoria_alta"] if r.w3wp_private_mb > 800 else []) + (["disco_bajo"] if r.disk_c_free_pct < 15 else []), auto=False)
    return Contexto(al, {"desde": f"{ini:%Y-%m-%d %H:%M}", "hasta": f"{fin:%Y-%m-%d %H:%M}", "zona": "America/Bogota", "fuente": "kit"},
                    A.items)


# ------------------------------------------------------------------ fuente 2: Log Analytics (alerta real del Reto 3)
def _kql(workspace: str, q: str, desde: datetime, hasta: datetime) -> list[dict]:
    """Consulta KQL. Con identidad administrada (runbook) usa la API REST de Log Analytics; si no, Azure CLI."""
    span = f"{desde:%Y-%m-%dT%H:%M:%SZ}/{hasta:%Y-%m-%dT%H:%M:%SZ}"
    from .llm import token_identidad_administrada
    tok = token_identidad_administrada("https://api.loganalytics.io")
    if tok:
        import urllib.request
        req = urllib.request.Request(f"https://api.loganalytics.io/v1/workspaces/{workspace}/query",
                                     data=json.dumps({"query": q, "timespan": span}).encode(), method="POST",
                                     headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=60) as r:
            t = json.loads(r.read())["tables"][0]
        cols = [c["name"] for c in t["columns"]]
        return [{c: ("" if v is None else str(v)) for c, v in zip(cols, fila)} for fila in t["rows"]]
    r = subprocess.run(["az", "monitor", "log-analytics", "query", "-w", workspace, "--analytics-query", q,
                        "--timespan", span, "-o", "json"], capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        raise RuntimeError(f"KQL falló: {r.stderr[-300:]}")
    return json.loads(r.stdout or "[]")


def desde_log_analytics(alerta_json: dict, workspace: str, minutos_antes: int = 30) -> Contexto:
    al = leer_alerta(alerta_json)
    fin = _ts_utc(al["disparo_utc"])          # nada posterior al disparo (ni la propia remediación)
    ini = fin - timedelta(minutes=minutos_antes)
    A = _Acum()
    for r in _kql(workspace, """W3CIISLog | where csUriStem !in~ ("/health.aspx","/fallar.aspx")
        | summarize n=count(), e5=countif(toint(scStatus)>=500), p95=percentile(TimeTaken,95) by bin(TimeGenerated,5m) | order by TimeGenerated asc""", ini, fin):
        A.add("iis-agregado", _ts_utc(r["TimeGenerated"]), f"IIS {_ts_utc(r['TimeGenerated']).astimezone(BOGOTA):%H:%M} (5 min): {r['n']} solicitudes, "
              f"{r['e5']} con 5xx, latencia p95 {float(r['p95']):.0f} ms", ts_fin=_ts_utc(r["TimeGenerated"]) + timedelta(minutes=5))
    for r in _kql(workspace, """Event | where Source == "AndinaSonda"
        | summarize ok=countif(EventID==2000), fallas=countif(EventID==2001), ejemplo=take_anyif(RenderedDescription, EventID==2001) by bin(TimeGenerated,5m) | order by TimeGenerated asc""", ini, fin):
        txt = f"Sonda sintética (5 min): {r['ok']} OK, {r['fallas']} fallas"
        if int(r["fallas"]):
            txt += f". Ejemplo de falla: {r['ejemplo']}"
        A.add("sonda", _ts_utc(r["TimeGenerated"]), txt, ts_fin=_ts_utc(r["TimeGenerated"]) + timedelta(minutes=5))
    for r in _kql(workspace, """Event | where Source !in ("AndinaSonda","AndinaPrueba") and Source !startswith "Microsoft-Windows-DistributedCOM"
        | summarize n=count(), desde=min(TimeGenerated), hasta=max(TimeGenerated), ejemplo=take_any(RenderedDescription) by Source, EventID, EventLevelName
        | order by desde asc | take 20""", ini, fin):
        A.add("evento", _ts_utc(r["desde"]), f"[{r['Source']} {r['EventID']} {r['EventLevelName']}] x{r['n']} desde "
              f"{_ts_utc(r['desde']).astimezone(BOGOTA):%H:%M:%S} hasta {_ts_utc(r['hasta']).astimezone(BOGOTA):%H:%M:%S}. Ejemplo: {r['ejemplo']}",
              ts_fin=_ts_utc(r["hasta"]))
    for r in _kql(workspace, """Perf | where (ObjectName=="APP_POOL_WAS" and CounterName=="Current Application Pool State")
        or (ObjectName=="Process" and CounterName=="Private Bytes" and InstanceName startswith "w3wp")
        or (ObjectName=="LogicalDisk" and CounterName=="% Free Space" and InstanceName=="C:")
        | summarize v=max(CounterValue) by bin(TimeGenerated,5m), CounterName | order by TimeGenerated asc""", ini, fin):
        t = _ts_utc(r["TimeGenerated"]).astimezone(BOGOTA)
        v = float(r["v"])
        if r["CounterName"] == "Private Bytes":
            A.add("perf", t, f"Memoria privada de w3wp a las {t:%H:%M}: {v / 1048576:.0f} MB", ["memoria_alta"] if v > 800 * 1048576 else [], auto=False)
        elif r["CounterName"] == "% Free Space":
            A.add("perf", t, f"Disco C: a las {t:%H:%M}: {v:.1f} % libre", ["disco_bajo"] if v < 15 else [], auto=False)
        else:
            A.add("perf", t, f"Estado del pool PortalPagosPool a las {t:%H:%M}: {v:.0f} (3 = Running)",
                  ["pool_caido"] if v != 3 else [], auto=False)
    # hechos derivados por código (no por el modelo) sobre los ÚLTIMOS 10 min antes del disparo
    u = _kql(workspace, """let f = Event | where Source == "AndinaSonda" | summarize fallas = countif(EventID == 2001), ok = countif(EventID == 2000);
        let p = Perf | where ObjectName == "APP_POOL_WAS" and CounterName == "Current Application Pool State" | summarize no_running = countif(CounterValue != 3), muestras = count();
        let w = Event | where Source == "Microsoft-Windows-WAS" and EventID == 5002 | summarize was5002 = count();
        f | extend k = 1 | join (p | extend k = 1) on k | join (w | extend k = 1) on k | project fallas, ok, no_running, muestras, was5002""",
             fin - timedelta(minutes=10), fin)
    if u:
        r = {k: int(float(v)) for k, v in u[0].items() if k != "TableName"}
        txt = (f"Derivado (últimos 10 min antes de la alerta): sonda {r['fallas']} fallas y {r['ok']} OK; pool fuera de Running en "
               f"{r['no_running']} de {r['muestras']} muestras; {r['was5002']} eventos WAS 5002")
        sen = []
        if r["fallas"] and not r["no_running"] and not r["was5002"]:
            txt += ". La sonda falla con el pool en Running: la falla no está en el pool (posible dependencia)"
            sen = ["dependencia"]
        elif r["no_running"] or r["was5002"]:
            txt += ". El pool está detenido o deshabilitado"
            sen = ["pool_caido"]
        A.add("derivado", fin, txt, sen, auto=False)
    hb = _kql(workspace, "Heartbeat | summarize ultimo=max(TimeGenerated)", ini, fin)
    if hb and hb[0].get("ultimo"):
        A.add("heartbeat", _ts_utc(hb[0]["ultimo"]), f"Último heartbeat del agente: {_ts_utc(hb[0]['ultimo']).astimezone(BOGOTA):%H:%M:%S}")
    else:
        A.add("heartbeat", fin, "Sin heartbeat del agente en la ventana", ["sin_heartbeat"])
    return Contexto(al, {"desde": f"{ini:%Y-%m-%dT%H:%MZ}", "hasta": f"{fin:%Y-%m-%dT%H:%MZ}", "zona": "UTC", "fuente": "log-analytics"},
                    A.items)
