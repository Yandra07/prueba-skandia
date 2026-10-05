#!/usr/bin/env bash
# Regenera evidencias/ejecucion-demo.txt y ejemplo-log.jsonl con un escenario sintético (requiere pwsh).
# Funciona en Linux (date GNU) y en macOS (date BSD).
set -u
cd "$(dirname "$0")/.."
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
# fecha de hace N días (y H horas) en el formato pedido: GNU primero, BSD si falla
hace() { date -d "$1 days ago $2 hours ago" "+$3" 2>/dev/null || date -v-"$1"d -v-"$2"H "+$3"; }
mkdir -p $S/inetpub/logs/LogFiles/W3SVC2 $S/fs-auditoria/WEB-PAGOS-01 $S/CrashDumps $S/PortalPagos/logs $S/ProgramData/logs
for i in 0 3 13 15 16 20; do f=$S/inetpub/logs/LogFiles/W3SVC2/u_ex$(hace $i 0 %y%m%d).log; head -c 200000 /dev/urandom | base64 > $f; touch -t "$(hace $i 3 %Y%m%d%H%M.%S)" $f; done
for i in 0 2 3 8 9; do f=$S/PortalPagos/logs/portal-$(hace $i 0 %Y%m%d).log; head -c 100000 /dev/urandom > $f; touch -t "$(hace $i 1 %Y%m%d%H%M.%S)" $f; done
for n in 4471 7364 7138 5703 3533; do f=$S/CrashDumps/w3wp.exe.$n.dmp; echo d > $f; touch -t "$(hace 13 0 %Y%m%d%H%M.%S)" $f; done
run() { pwsh -NoProfile -File src/Invoke-MantenimientoPortalPagos.ps1 -RutaLogsIis $S/inetpub/logs/LogFiles -RutaAuditoria "$1" \
  -RutasLogsApp $S/PortalPagos/logs -RutaDumps $S/CrashDumps -NombreServicio '' -NombrePool '' -RutaLog $S/ProgramData/logs \
  ${UMB:--UmbralDiscoAvisoPct 10 -UmbralDiscoCriticoPct 5} "${@:2}"; echo "exit=$?"; }
so() { if [ -r /etc/os-release ]; then . /etc/os-release; echo "$PRETTY_NAME"; else echo "$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null)"; fi; }
{ echo "# Evidencia de ejecución · $(date +%Y-%m-%dT%H:%M:%S%z) · $(pwsh -v) en $(so)"
  echo "# Escenario: 6 logs IIS (0, 3, 13, 15, 16 y 20 días), 5 logs de app (0, 2, 3, 8 y 9 días), 5 dumps de hace 13 días"
  echo "### Estado inicial"; (cd $S && find . -type f | sort)
  echo; echo "### 1) Simulación: -WhatIf (no cambia nada)"; run $S/fs-auditoria/WEB-PAGOS-01 -WhatIf
  echo "archivos en auditoría tras -WhatIf: $(find $S/fs-auditoria -type f | wc -l | tr -d ' ')"
  echo; echo "### 2) Ejecución real"; run $S/fs-auditoria/WEB-PAGOS-01
  echo; echo "### 3) Segunda ejecución (idempotencia)"; run $S/fs-auditoria/WEB-PAGOS-01
  echo; echo "### 4) Share de auditoría caído"; run $S/fs-caido
  echo; echo "### 5) Parámetro inválido (-DiasRetencionIis 0)"; run $S/fs-auditoria/WEB-PAGOS-01 -DiasRetencionIis 0
  echo; echo "### 6) Presión de disco: umbral de aviso 90 % (forzado: el disco de la demo está por debajo), piso de 1 día de logs de app"
  echo "# Esperado: borra los logs de app de 2 y 3 días, conserva el de hoy, no toca IIS ni volcados; los 100 KB liberados no alcanzan el umbral, así que el resultado es Aviso (2) o Error (3) según el disco real"
  UMB="-UmbralDiscoAvisoPct 90 -UmbralDiscoCriticoPct 50" run $S/fs-auditoria/WEB-PAGOS-01
  echo; echo "### Estado final"; (cd $S && find . -type f | grep -v ProgramData | sort)
} 2>&1 | perl -pe "s|\Q$S\E|<demo>|g; s/\e\[[0-9;]*m//g" > evidencias/ejecucion-demo.txt
# el equipo y el usuario se reemplazan: la evidencia no debe depender de (ni exponer) la máquina donde se generó
perl -pe "s|\Q$S\E|<demo>|g; s|\"host\":\"[^\"]*\"|\"host\":\"demo\"|g; s|\"usuario\":\"[^\"]*\"|\"usuario\":\"demo\"|g" $S/ProgramData/logs/*.jsonl > evidencias/ejemplo-log.jsonl
