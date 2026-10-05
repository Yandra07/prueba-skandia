#Requires -Version 5.1
<#
.SYNOPSIS
    Generador de tráfico de usuarios simulados (~1 solicitud/s durante 55 s). Lo ejecuta una tarea cada minuto.
    Sin tráfico no hay tasa de 5xx ni latencia que medir.
#>
param([string]$Base = 'http://localhost', [int]$DuracionS = 55)
$rutas = @('/', '/api/saldos.aspx', '/api/saldos.aspx', '/api/pagos/iniciar.aspx', '/api/pagos/confirmar.aspx')
$fin = (Get-Date).AddSeconds($DuracionS)
while ((Get-Date) -lt $fin) {
    $u = $Base + ($rutas | Get-Random)
    try { Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 15 -UserAgent 'Andina-CargaSintetica/1.0' | Out-Null } catch { Write-Verbose "falla esperada: $($_.Exception.Message)" }
    Start-Sleep -Milliseconds (Get-Random -Minimum 400 -Maximum 1400)
}
