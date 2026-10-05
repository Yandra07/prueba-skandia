#!/usr/bin/env bash
# Provoca una falla en la VM y mide la detección y la recuperación desde Log Analytics (consulta Q8).
#   ./scripts/provocar-falla.sh crash | detener-pool | dependencia | fuga | limpiar
source "$(dirname "$0")/comun.sh"
ESC="${1:?escenario: crash | detener-pool | dependencia | fuga | limpiar | medir (solo mide la última prueba)}"
ESPERA_MIN="${ESPERA_MIN:-15}"
requiere_login
WS=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
DESDE="1970-01-01T00:00:00Z"
if [ "$ESC" != "medir" ]; then
  DESDE=$(utc_hace_min 2)
  log "Provocando '$ESC' en $VM (queda T0 en el evento AndinaPrueba 4000)"
  run_en_vm "$RAIZ/vm/provocar-falla.ps1" "Escenario=$ESC" >&2
fi
[ "$ESC" = "limpiar" ] && exit 0
# Q8 (MTTD/MTTR) del archivo de consultas: el último bloque del .kql
Q=$(python3 - "$RAIZ/kql/consultas.kql" <<'PY'
import re,sys
t=open(sys.argv[1]).read(); b=t[t.index("let pruebas = Event"):]
print("\n".join(l for l in b.splitlines() if not l.strip().startswith("//")).rstrip().rstrip(";"))
PY
)
SAL="$RAIZ/evidencias/medicion-$ESC-$(date +%Y%m%d-%H%M%S).json"
for i in $(seq 1 $((ESPERA_MIN * 2))); do
  sleep 30
  R=$(az monitor log-analytics query -w "$WS" --analytics-query "$Q" --timespan PT3H -o json 2>/dev/null || echo '[]')
  FILA=$(echo "$R" | DESDE="$DESDE" python3 -c "import sys,json,os;d=[x for x in json.load(sys.stdin) if x.get('T0','')>=os.environ['DESDE']];print(json.dumps(d[0]) if d else '')")
  if [ -n "$FILA" ]; then
    log "  $(echo "$FILA" | python3 -c "import sys,json;d=json.load(sys.stdin);print('primer_fallo',d.get('primer_fallo'),'| detectado',d.get('detectado'),'| recuperado',d.get('recuperado'))")"
    if echo "$FILA" | python3 -c "import sys,json;d=json.load(sys.stdin);v=d.get('recuperado'); sys.exit(0 if v not in (None,'','None') else 1)"; then
      echo "$FILA" | python3 -m json.tool | tee "$SAL"; log "Medición guardada en $SAL"; exit 0
    fi
  fi
done
log "Sin recuperación en $ESPERA_MIN min (esperado en 'dependencia': la remediación escala y no reinicia). Último estado:"
# ojo: "${FILA:-{}}" agregaba una "}" de más (bash cierra la expansión en la primera "}"): JSON inválido
if [ -n "$FILA" ]; then echo "$FILA"; else echo '{}'; fi | python3 -m json.tool | tee "$SAL"
