# Variables y utilidades compartidas por los scripts del Reto 3.
set -euo pipefail
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RG="${RG:-rg-portalpagos-lab}"
VM="${VM:-web-pagos-01}"
AA="${AA:-aa-portalpagos}"
LAW="${LAW:-law-portalpagos}"
RUNBOOK="Restaurar-PoolIIS"
log() { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*" >&2; }
# Portables entre Linux (GNU) y macOS (BSD): base64 en una sola línea y "hace N minutos" en UTC (ISO 8601).
b64_archivo() { base64 < "$1" | tr -d '\n'; }
utc_hace_min() { date -u -d "-$1 min" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-"$1"M +%Y-%m-%dT%H:%M:%SZ; }
requiere_login() {
  az account show -o none 2>/dev/null || { echo "Primero inicia sesión:  az login --use-device-code" >&2; exit 1; }
  log "Suscripción: $(az account show --query '[name,id]' -o tsv | tr '\t' ' ')"
}
# Ejecuta un .ps1 en la VM con Run Command y devuelve solo la salida estándar.
run_en_vm() {
  local script="$1"; shift
  az vm run-command invoke -g "$RG" -n "$VM" --command-id RunPowerShellScript --scripts @"$script" ${1:+--parameters "$@"} \
     --query "value[?contains(code,'StdOut')].message | [0]" -o tsv
}
