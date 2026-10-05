#!/usr/bin/env bash
# Corre en la VM (Windows PowerShell 5.1) las pruebas Pester del Reto 2 y una ejecución -WhatIf + real del mantenimiento.
# Envía la versión vigente del Reto 2 junto con el script.
source "$(dirname "$0")/comun.sh"
requiere_login
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
(cd "$RAIZ/../reto2-powershell" && zip -qr "$TMP/r2.zip" src tests)
{ printf "\$Reto2B64 = '%s'\n" "$(b64_archivo "$TMP/r2.zip")"; cat "$RAIZ/vm/evidencia-reto2.ps1"; } > "$TMP/ev.ps1"
run_en_vm "$TMP/ev.ps1" | tee "$RAIZ/evidencias/reto2-en-vm-$(date +%Y%m%d-%H%M%S).txt"
