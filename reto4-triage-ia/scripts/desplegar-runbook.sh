#!/usr/bin/env bash
# Publica el runbook Triage-Alerta (Python 3.10) en la cuenta de Automation del Reto 3, con identidad administrada:
#   - rol "Log Analytics Reader" en el workspace (contexto) y "Cognitive Services OpenAI User" en Azure OpenAI (infra/aoai.bicep)
#   - variables WorkspaceId y AoaiEndpoint (no son secretos)
# Luego ../reto3-azure/scripts/desplegar.sh lo conecta a la alerta (segundo receptor del grupo de acciones).
set -euo pipefail
cd "$(dirname "$0")/.."
RG="${RG:-rg-portalpagos-lab}"; AA="${AA:-aa-portalpagos}"; LAW="${LAW:-law-portalpagos}"
python3 runbook/empaquetar.py
AA_ID=$(az automation account show -g "$RG" -n "$AA" --query id -o tsv)
MI=$(az automation account show -g "$RG" -n "$AA" --query identity.principalId -o tsv)
WS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query id -o tsv)
WS_CID=$(az monitor log-analytics workspace show -g "$RG" -n "$LAW" --query customerId -o tsv)
AOAI=$(az cognitiveservices account list -g "$RG" --query "[?kind=='OpenAI'] | [0].properties.endpoint" -o tsv)
az role assignment create --assignee-object-id "$MI" --assignee-principal-type ServicePrincipal \
   --role "Log Analytics Reader" --scope "$WS_ID" -o none 2>/dev/null || true
API="api-version=2023-11-01"
for v in "WorkspaceId=$WS_CID" "AoaiEndpoint=$AOAI"; do
  n=${v%%=*}; val=${v#*=}
  az rest --method put --url "https://management.azure.com${AA_ID}/variables/$n?$API" \
     --body "{\"name\":\"$n\",\"properties\":{\"value\":\"\\\"$val\\\"\",\"isEncrypted\":false}}" -o none
done
az rest --method put --url "https://management.azure.com${AA_ID}/runbooks/Triage-Alerta?api-version=2024-10-23" \
   --body '{"location":"'"$(az automation account show -g "$RG" -n "$AA" --query location -o tsv)"'","properties":{"runbookType":"Python","runtimeEnvironment":"Python-3.10","logProgress":false,"logVerbose":false,"description":"Triage IA de alertas (Reto 4): sugiere, no ejecuta"}}' -o none
az rest --method put --url "https://management.azure.com${AA_ID}/runbooks/Triage-Alerta/draft/content?$API" \
   --headers "Content-Type=text/powershell" --body @dist/Triage-Alerta.py -o none
az rest --method post --url "https://management.azure.com${AA_ID}/runbooks/Triage-Alerta/publish?$API" -o none
echo "Runbook Triage-Alerta publicado. Endpoint OpenAI: $AOAI · workspace: $WS_CID"
