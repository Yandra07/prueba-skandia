"""Genera dist/Triage-Alerta.py: un solo archivo con el paquete `triage` embebido (el sandbox de Automation
no permite subir paquetes locales sin una cuenta de almacenamiento). Mismo código que se prueba con pytest."""
from pathlib import Path
R = Path(__file__).resolve().parents[1]
ORDEN = ["__init__", "catalogo", "esquema", "contexto", "llm", "respaldo", "validar", "motor"]
partes = ["# GENERADO por runbook/empaquetar.py — no editar a mano\nimport sys, types\n_FUENTES = {}\n"]
for m in ORDEN:
    partes.append(f"_FUENTES[{('triage' if m == '__init__' else 'triage.' + m)!r}] = {(R / 'triage' / (m + '.py')).read_text(encoding='utf-8')!r}\n")
partes.append('''
for _n, _src in _FUENTES.items():
    _m = types.ModuleType(_n); _m.__package__ = "triage"; _m.__file__ = _n
    if _n == "triage":
        _m.__path__ = []
    sys.modules[_n] = _m
    exec(compile(_src, _n, "exec"), _m.__dict__)
''')
partes.append((R / "runbook" / "principal.py").read_text(encoding="utf-8"))
(R / "dist").mkdir(exist_ok=True)
(R / "dist" / "Triage-Alerta.py").write_text("".join(partes), encoding="utf-8")
print("dist/Triage-Alerta.py", (R / "dist" / "Triage-Alerta.py").stat().st_size, "bytes")
