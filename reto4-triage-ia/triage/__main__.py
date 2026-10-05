"""CLI.
  python -m triage --alerta alerta.json --kit ../kit_prueba_portalpagos            # contexto desde el kit
  python -m triage --alerta alerta.json --workspace <customerId>                   # contexto desde Log Analytics
  python -m triage --contexto casos/x/contexto.json                                 # contexto guardado (reproducible)
Variables: AZURE_OPENAI_ENDPOINT, AZURE_OPENAI_DEPLOYMENT (por defecto 'triage'). Sin claves: Entra ID.
"""
import argparse, json, sys
from pathlib import Path
from .contexto import Contexto, desde_kit, desde_log_analytics
from .llm import crear_cliente
from .motor import ejecutar


def main(argv=None):
    ap = argparse.ArgumentParser(prog="triage")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--contexto", type=Path, help="contexto.json ya construido")
    g.add_argument("--alerta", type=Path, help="alerta en el esquema común de Azure Monitor")
    ap.add_argument("--kit", type=Path); ap.add_argument("--workspace")
    ap.add_argument("--guardar-contexto", type=Path); ap.add_argument("--salida", type=Path)
    ap.add_argument("--timeout", type=float, default=25)
    a = ap.parse_args(argv)
    if a.contexto:
        ctx = Contexto.from_dict(json.loads(a.contexto.read_text(encoding="utf-8")))
    else:
        al = json.loads(a.alerta.read_text(encoding="utf-8"))
        if a.kit:
            ctx = desde_kit(al, a.kit)
        elif a.workspace:
            ctx = desde_log_analytics(al, a.workspace)
        else:
            ap.error("--alerta requiere --kit o --workspace")
    if a.guardar_contexto:
        a.guardar_contexto.parent.mkdir(parents=True, exist_ok=True)
        a.guardar_contexto.write_text(json.dumps(ctx.to_dict(), ensure_ascii=False, indent=1), encoding="utf-8")
    r = ejecutar(ctx, crear_cliente(timeout_s=a.timeout))
    out = json.dumps(r, ensure_ascii=False, indent=2)
    if a.salida:
        a.salida.parent.mkdir(parents=True, exist_ok=True); a.salida.write_text(out, encoding="utf-8")
    print(out)
    return 0 if r["validacion"]["valido"] else 2


if __name__ == "__main__":
    sys.exit(main())
