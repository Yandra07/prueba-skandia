#!/usr/bin/env bash
# Despliega el laboratorio completo del Reto 3 (idempotente: se puede volver a correr).
#   CORREO=tu@correo ./scripts/desplegar.sh            # opcional: LOCATION=eastus2  IP_DEMO=$(curl -s ifconfig.me)/32
# No pide ni guarda secretos: la contraseña de la VM se genera al vuelo (no hay RDP) y el URI del webhook solo viaja como parámetro seguro.
source "$(dirname "$0")/comun.sh"
: "${CORREO:?Define CORREO=correo-para-alertas}"
LOCATION="${LOCATION:-eastus2}"
IP_DEMO="${IP_DEMO:-}"
requiere_login
az extension add --name automation --upgrade -y -o none 2>/dev/null || true

PASS="$(openssl rand -base64 24 | tr -d '/+=')Aa1!"
desplegar() {   # $1 = webhookUri ('' en la fase 1) · $2 = webhook del triage IA (opcional)
  az deployment sub create -n "portalpagos-$(date +%Y%m%d%H%M%S)" -l "$LOCATION" -f "$RAIZ/infra/main.bicep" \
    -p location="$LOCATION" correoAlertas="$CORREO" vmAdminPassword="$PASS" ipPermitidaHttp="$IP_DEMO" webhookUri="$1" webhookTriageUri="${2:-}" \
    --query properties.outputs -o json
}

log "Fase 1/4 · infraestructura (VM, AMA, DCR, Log Analytics, Automation, alertas, tablero, presupuesto) · ~8 min"
OUT=$(desplegar "")
# la evidencia va al repositorio: el ID de la suscripción se reemplaza por <sub>
echo "$OUT" | sed -E 's#/subscriptions/[0-9a-fA-F-]{36}#/subscriptions/<sub>#g' > "$RAIZ/evidencias/salidas-despliegue.json"
AA_ID=$(az automation account show -g "$RG" -n "$AA" --query id -o tsv)

log "Fase 2/4 · runbook $RUNBOOK (contenido + publicación)"
az automation runbook show -g "$RG" --automation-account-name "$AA" -n "$RUNBOOK" -o none 2>/dev/null || \
  az automation runbook create -g "$RG" --automation-account-name "$AA" -n "$RUNBOOK" --type PowerShell -l "$LOCATION" \
     --description "Auto-remediación de PortalPagosPool con salvaguardas (Reto 3)" -o none
az automation runbook replace-content -g "$RG" --automation-account-name "$AA" -n "$RUNBOOK" --content @"$RAIZ/runbook/Restaurar-PoolIIS.ps1" -o none
az automation runbook publish -g "$RG" --automation-account-name "$AA" -n "$RUNBOOK" -o none

log "Fase 3/4 · webhook (URI nuevo en cada despliegue; nunca se escribe en disco) + grupo de acciones con el runbook"
WH_URL="https://management.azure.com${AA_ID}/webhooks/wh-alerta-sitio-no-disponible?api-version=2015-10-31"
az rest --method delete --url "$WH_URL" -o none 2>/dev/null || true
for _ in $(seq 1 12); do az rest --method get --url "$WH_URL" -o none 2>/dev/null || break; sleep 5; done   # el borrado no es inmediato
WEBHOOK=$(az rest --method post --url "https://management.azure.com${AA_ID}/webhooks/generateUri?api-version=2015-10-31" -o tsv)
# Reto 4: si el runbook Triage-Alerta está publicado, la misma alerta también dispara el triage con IA
WEBHOOK_TRIAGE=""
if az rest --method get --url "https://management.azure.com${AA_ID}/runbooks/Triage-Alerta?api-version=2023-11-01" -o none 2>/dev/null; then
  WT_URL="https://management.azure.com${AA_ID}/webhooks/wh-triage-ia?api-version=2015-10-31"
  az rest --method delete --url "$WT_URL" -o none 2>/dev/null || true
  for _ in $(seq 1 12); do az rest --method get --url "$WT_URL" -o none 2>/dev/null || break; sleep 5; done
  WEBHOOK_TRIAGE=$(az rest --method post --url "https://management.azure.com${AA_ID}/webhooks/generateUri?api-version=2015-10-31" -o tsv)
  log "  + triage con IA (Reto 4) conectado a la alerta"
fi
desplegar "$WEBHOOK" "$WEBHOOK_TRIAGE" > /dev/null
unset WEBHOOK WEBHOOK_TRIAGE

log "Fase 4/4 · configuración de la VM (IIS, sitio de prueba, sonda, carga, mantenimiento Reto 2) · ~6 min"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/p/vm" "$TMP/p/reto2"
cp -r "$RAIZ/vm/sitio" "$TMP/p/sitio"; cp "$RAIZ"/vm/*.ps1 "$TMP/p/vm/"
cp -r "$RAIZ/../reto2-powershell/src" "$RAIZ/../reto2-powershell/tests" "$TMP/p/reto2/"
(cd "$TMP/p" && zip -qr "$TMP/payload.zip" .)
{ printf "\$PayloadB64 = '%s'\n" "$(b64_archivo "$TMP/payload.zip")"; cat "$RAIZ/vm/configurar-vm.ps1"; } > "$TMP/bootstrap.ps1"
log "  bootstrap: $(du -k "$TMP/bootstrap.ps1" | cut -f1) KB"
run_en_vm "$TMP/bootstrap.ps1" | tee "$RAIZ/evidencias/configuracion-vm.json"

WB=$(echo "$OUT" | python3 -c "import sys,json;print(json.load(sys.stdin)['workbookId']['value'])")
log "Listo. Tablero: https://portal.azure.com/#@/resource${WB}/workbook"
log "Los datos tardan ~5-10 min en aparecer. Siguiente: ./scripts/provocar-falla.sh crash"
