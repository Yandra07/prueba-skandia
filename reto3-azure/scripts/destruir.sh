#!/usr/bin/env bash
# Elimina TODO el laboratorio (exporta antes las evidencias). El workspace se borra con --force para que no quede en soft-delete.
source "$(dirname "$0")/comun.sh"
requiere_login
read -r -p "Se eliminará el grupo de recursos $RG completo. Escribe el nombre para confirmar: " C
[ "$C" = "$RG" ] || { echo "Cancelado"; exit 1; }
az monitor log-analytics workspace delete -g "$RG" -n "$LAW" --force --yes -o none 2>/dev/null || true
az group delete -n "$RG" --yes
log "Eliminado. Verifica en el portal: Cost Management → no debe quedar nada con la etiqueta proyecto=prueba-tecnica-observabilidad"
