"""Parsers de las fuentes del kit PortalPagos.

Decisiones (ver README / supuestos):
- Logs W3C de IIS y HTTP.sys están en UTC (comportamiento por defecto de IIS);
  se convierten a America/Bogota (UTC-5, sin horario de verano).
- Eventos de Windows (Get-WinEvent | Export-Csv) y Perfmon ("SA Pacific Standard Time")
  ya están en hora local.
- Archivos IIS duplicados (mismo hash) se descartan; se conserva el de nombre canónico.
- Un archivo W3C puede cambiar de #Fields a mitad (reinicio de log); se respeta cada bloque.
"""
from __future__ import annotations
import hashlib, re
from pathlib import Path
import pandas as pd

LOCAL_TZ = "America/Bogota"
CANON = re.compile(r"^u_ex\d{6}\.log$")


def _sha256(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def select_iis_files(folder: Path) -> tuple[list[Path], list[dict]]:
    """Devuelve archivos a usar y un reporte de los descartados (duplicados / no canónicos)."""
    files = sorted(folder.glob("*.log"), key=lambda p: (not CANON.match(p.name), p.name))
    seen: dict[str, Path] = {}
    keep, dropped = [], []
    for p in files:
        h = _sha256(p)
        if h in seen:
            dropped.append({"archivo": p.name, "motivo": f"duplicado exacto de {seen[h].name}", "sha256": h[:12]})
            continue
        seen[h] = p
        keep.append(p)
    return sorted(keep), dropped


def read_w3c(path: Path, source: str) -> pd.DataFrame:
    blocks, fields, rows = [], None, []
    with path.open(encoding="utf-8", errors="replace") as f:
        for lineno, line in enumerate(f, start=1):
            line = line.rstrip("\r\n")
            if not line:
                continue
            if line.startswith("#"):
                if line.startswith("#Fields:"):
                    if fields and rows:
                        blocks.append(pd.DataFrame(rows, columns=fields + ["line"]))
                    fields, rows = line[len("#Fields:"):].split(), []
                continue
            parts = line.split(" ")
            if fields and len(parts) == len(fields):
                rows.append(parts + [lineno])
    if fields and rows:
        blocks.append(pd.DataFrame(rows, columns=fields + ["line"]))
    df = pd.concat(blocks, ignore_index=True) if blocks else pd.DataFrame()
    df["source_file"] = path.name
    df["source"] = source
    return df


def load_iis(kit: Path) -> tuple[pd.DataFrame, list[dict]]:
    files, dropped = select_iis_files(kit / "logs" / "iis" / "W3SVC2")
    df = pd.concat([read_w3c(p, "iis") for p in files], ignore_index=True)
    df["ts_utc"] = pd.to_datetime(df["date"] + " " + df["time"], utc=True)
    df["ts"] = df["ts_utc"].dt.tz_convert(LOCAL_TZ).dt.tz_localize(None)
    for c in ["sc-status", "sc-substatus", "sc-win32-status", "time-taken"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    # IP real del cliente: desde el 17/09 03:12 UTC hay un proxy (10.20.4.4) y la IP viene en X-Forwarded-For
    xff = df.get("X-Forwarded-For")
    df["client_ip"] = df["c-ip"]
    if xff is not None:
        m = xff.notna() & (xff != "-")
        df.loc[m, "client_ip"] = xff[m]
    df["is_probe"] = df["cs-uri-stem"].str.lower().eq("/health") | df["cs(User-Agent)"].str.startswith("NOC-HealthProbe", na=False)
    return df, dropped


def load_httperr(kit: Path) -> pd.DataFrame:
    frames = [read_w3c(p, "httperr") for p in sorted((kit / "logs" / "httperr").glob("*.log"))]
    df = pd.concat(frames, ignore_index=True)
    df["ts_utc"] = pd.to_datetime(df["date"] + " " + df["time"], utc=True)
    df["ts"] = df["ts_utc"].dt.tz_convert(LOCAL_TZ).dt.tz_localize(None)
    df["sc-status"] = pd.to_numeric(df["sc-status"], errors="coerce")
    df["is_probe"] = df["cs-uri"].str.lower().str.startswith("/health")
    return df


def load_events(kit: Path) -> pd.DataFrame:
    df = pd.read_csv(next((kit / "eventos").glob("*.csv")))
    df["line"] = df.index + 2  # +1 encabezado, +1 base 1
    df["ts"] = pd.to_datetime(df["TimeCreated"])  # ya en hora local del servidor
    return df


def load_perfmon(kit: Path) -> pd.DataFrame:
    p = next((kit / "metricas").glob("*.csv"))
    df = pd.read_csv(p)
    first = df.columns[0]
    ren = {first: "ts"}
    for c in df.columns[1:]:
        short = c.split("\\")[-2] + "\\" + c.split("\\")[-1]
        ren[c] = {
            "Processor(_Total)\\% Processor Time": "cpu_pct",
            "Memory\\Available MBytes": "mem_avail_mb",
            "LogicalDisk(C:)\\% Free Space": "disk_c_free_pct",
            "LogicalDisk(C:)\\Free Megabytes": "disk_c_free_mb",
            "Process(w3wp)\\Private Bytes": "w3wp_private_bytes",
            "Web Service(PortalPagos)\\Current Connections": "connections",
        }.get(short, short)
    df = df.rename(columns=ren)
    df["ts"] = pd.to_datetime(df["ts"], format="%m/%d/%Y %H:%M:%S.%f")
    for c in df.columns[1:]:
        df[c] = pd.to_numeric(df[c].replace({" ": None, "": None}), errors="coerce")
    df["w3wp_private_mb"] = df["w3wp_private_bytes"] / 1024**2
    return df


def load_tickets(kit: Path) -> pd.DataFrame:
    df = pd.read_csv(next((kit / "tickets").glob("*.csv")))
    df["ts"] = pd.to_datetime(df["FechaHoraReporte"])
    return df
