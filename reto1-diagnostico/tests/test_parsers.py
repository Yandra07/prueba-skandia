"""Pruebas de los parsers y de los supuestos de limpieza de datos.

    pytest -q                       # solo pruebas sintéticas
    KIT=../kit_prueba_portalpagos pytest -q   # además, invariantes sobre el kit real
"""
import os, sys
from pathlib import Path
import pandas as pd
import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from parsers import read_w3c, select_iis_files, load_iis  # noqa: E402

OLD = "#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) cs(Referer) sc-status sc-substatus sc-win32-status time-taken"
NEW = "#Fields: date time s-ip cs-method cs-uri-stem cs-uri-query s-port cs-username c-ip cs(User-Agent) cs(Referer) cs-host sc-status sc-substatus sc-win32-status time-taken X-Forwarded-For"


def _write(p: Path, lines):
    p.write_text("\n".join(lines) + "\n", encoding="utf-8")


@pytest.fixture
def kit(tmp_path):
    d = tmp_path / "logs" / "iis" / "W3SVC2"; d.mkdir(parents=True)
    _write(d / "u_ex260918.log", [
        "#Software: Microsoft Internet Information Services 10.0", OLD,
        "2026-09-18 18:23:08 10.0.0.1 POST /api/pagos/confirmar - 443 - 1.2.3.4 UA - 500 0 0 25000",
        "linea corrupta",
        NEW,
        "2026-09-18 20:04:00 10.0.0.1 GET /health - 443 - 10.20.1.50 NOC-HealthProbe/1.4 - h 200 0 0 2 -",
        "2026-09-18 20:04:01 10.0.0.1 GET /login - 443 - 10.20.4.4 UA - h 200 0 0 80 191.1.1.1",
    ])
    (d / "u_ex260918 - copia.log").write_bytes((d / "u_ex260918.log").read_bytes())
    return tmp_path


def test_cambio_de_fields_a_mitad_de_archivo(kit):
    df = read_w3c(kit / "logs/iis/W3SVC2/u_ex260918.log", "iis")
    assert len(df) == 3                      # la línea corrupta se ignora
    assert df["line"].tolist() == [3, 6, 7]  # números de línea del archivo original
    assert df["X-Forwarded-For"].isna().tolist() == [True, False, False]


def test_duplicado_exacto_se_descarta_y_gana_el_canonico(kit):
    keep, dropped = select_iis_files(kit / "logs/iis/W3SVC2")
    assert [p.name for p in keep] == ["u_ex260918.log"]
    assert dropped[0]["archivo"] == "u_ex260918 - copia.log"


def test_conversion_utc_a_bogota_y_ip_real(kit):
    df, _ = load_iis(kit)
    r = df.iloc[0]
    assert r.ts == pd.Timestamp("2026-09-18 13:23:08")       # 18:23 UTC -> 13:23 Bogotá
    login = df[df["cs-uri-stem"] == "/login"].iloc[0]
    assert login.client_ip == "191.1.1.1"                    # IP del proxy reemplazada por X-Forwarded-For
    assert df["is_probe"].sum() == 1


KIT = os.environ.get("KIT")


@pytest.mark.skipif(not KIT, reason="defina KIT=<ruta al kit> para validar sobre los datos reales")
def test_invariantes_kit_real():
    from parsers import load_httperr, load_events
    k = Path(KIT)
    iis, dropped = load_iis(k)
    assert any("copia" in d["archivo"] for d in dropped)
    he, ev = load_httperr(k), load_events(k)
    # la conversión de zona horaria alinea fuentes independientes (HTTP.sys vs WAS 5002)
    was = ev[ev.Id == 5002].ts.min()
    assert abs((he.ts.min() - was).total_seconds()) < 10
    # el hueco del iisreset de las 02:00 locales aparece en los logs IIS a las 02:00 locales
    w = iis[(iis.ts >= "2026-09-16 01:58") & (iis.ts < "2026-09-16 02:05")].sort_values("ts")
    assert w.ts.diff().dt.total_seconds().max() > 30
    # IIS rota el log a las 00:00 UTC = 19:00 Bogotá: u_ex260921.log es el domingo 20 de 19:00 a 23:59 local
    cob = iis.groupby("source_file").ts.agg(["min", "max"])
    assert (cob["max"].iloc[:-1].dt.hour == 18).all()
    assert cob.loc["u_ex260921.log", "min"] >= pd.Timestamp("2026-09-20 19:00")
    assert cob.loc["u_ex260921.log", "max"] < pd.Timestamp("2026-09-21")
