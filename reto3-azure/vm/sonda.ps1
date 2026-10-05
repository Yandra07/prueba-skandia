#Requires -Version 5.1
<#
.SYNOPSIS
    Sonda sintética de PortalPagos: 3 verificaciones por minuto (cada 20 s) a /health.aspx.
.DESCRIPTION
    Cada resultado queda como evento en Application, fuente AndinaSonda (lo recoge AMA vía la DCR):
      2000 Information = OK · 2001 Error = falla (status, ms y motivo en el mensaje JSON)
    Mide lo que vive el cliente (status y latencia del endpoint). Si el pool está caído, HTTP.sys
    responde 503 y la sonda lo ve, aunque el log W3C de IIS no registre nada (lección del Reto 1).
#>
param([string]$Url = 'http://localhost/health.aspx', [int]$Repeticiones = 3, [int]$IntervaloS = 20, [int]$TimeoutS = 10)
$ErrorActionPreference = 'Stop'
for ($i = 0; $i -lt $Repeticiones; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $status = 0; $motivo = ''
    try {
        $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec $TimeoutS
        $status = [int]$r.StatusCode
    } catch [System.Net.WebException] {
        if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode } else { $motivo = $_.Exception.Status.ToString() }
    } catch { $motivo = $_.Exception.Message }
    $sw.Stop()
    $ok = ($status -eq 200)
    $msg = (@{ url = $Url; status = $status; ms = $sw.ElapsedMilliseconds; motivo = $motivo } | ConvertTo-Json -Compress)
    if ($ok) { Write-EventLog -LogName Application -Source AndinaSonda -EventId 2000 -EntryType Information -Message $msg }
    else     { Write-EventLog -LogName Application -Source AndinaSonda -EventId 2001 -EntryType Error -Message $msg }
    if ($i -lt $Repeticiones - 1) { Start-Sleep -Seconds ([math]::Max(1, $IntervaloS - [int]($sw.ElapsedMilliseconds / 1000))) }
}
# IIS (HTTP.sys) mantiene el log W3C en un búfer y el archivo en disco no cambia de tamaño hasta vaciarlo:
# sin esto, Azure Monitor Agent ve los logs con minutos de retraso y la alerta de 5xx llega tarde.
& netsh.exe http flush logbuffer | Out-Null
