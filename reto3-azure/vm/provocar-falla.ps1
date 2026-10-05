#Requires -Version 5.1
<#
.SYNOPSIS
    Provoca una falla controlada y deja la marca de tiempo T0 (evento AndinaPrueba 4000) para medir MTTD/MTTR.
.PARAMETER Escenario
    crash        5+ crashes de w3wp en < 5 min => Rapid-Fail Protection deshabilita el pool (como el 18-sep).
    detener-pool Stop-WebAppPool (falla "administrativa").
    dependencia  /health devuelve 503 con el pool sano: la remediación NO debe reiniciar nada y debe escalar.
    fuga         activa la fuga de memoria en /api/pagos/confirmar (alerta temprana + reciclaje por memoria).
    limpiar      quita los marcadores de dependencia y fuga.
#>
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][ValidateSet('crash', 'detener-pool', 'dependencia', 'fuga', 'limpiar')][string]$Escenario,
      [string]$Pool = 'PortalPagosPool')
$ErrorActionPreference = 'Stop'
Import-Module WebAdministration
$ctrl = 'C:\sitios\control'
if (-not (Test-Path $ctrl)) { New-Item -ItemType Directory $ctrl | Out-Null }
$t0 = Get-Date
if ($Escenario -ne 'limpiar') {
    Write-EventLog -LogName Application -Source AndinaPrueba -EventId 4000 -EntryType Warning `
        -Message ((@{ escenario = $Escenario; t0 = $t0.ToString('o'); usuario = "$env:USERDOMAIN\$env:USERNAME" }) | ConvertTo-Json -Compress)
}
switch ($Escenario) {
    'crash' {
        for ($i = 1; $i -le 8 -and (Get-WebAppPoolState $Pool).Value -eq 'Started'; $i++) {
            try { Invoke-WebRequest 'http://localhost/fallar.aspx?modo=crash' -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { Write-Verbose "falla esperada: $($_.Exception.Message)" }
            Start-Sleep -Seconds 4
            try { Invoke-WebRequest 'http://localhost/' -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { Write-Verbose "falla esperada: $($_.Exception.Message)" }   # arranca el siguiente w3wp
        }
    }
    'detener-pool' { if ($PSCmdlet.ShouldProcess($Pool, 'Stop-WebAppPool')) { Stop-WebAppPool -Name $Pool } }
    'dependencia'  { New-Item -ItemType File (Join-Path $ctrl 'dependencia.caida') -Force | Out-Null }
    'fuga' {
        # Activa la fuga y simula un "día de cierre": 2.200 pagos confirmados en unos minutos (~0,5 MB retenidos c/u).
        # Esperado: la memoria sube y IIS recicla el pool al pasar ~976 MB (privateMemory del Reto 2), SIN 503.
        New-Item -ItemType File (Join-Path $ctrl 'fuga.on') -Force | Out-Null
        $pid0 = (Get-Process w3wp -ErrorAction SilentlyContinue | Select-Object -First 1).Id
        for ($i = 1; $i -le 2200; $i++) { try { Invoke-WebRequest 'http://localhost/api/pagos/confirmar.aspx' -UseBasicParsing -TimeoutSec 15 | Out-Null } catch { Write-Verbose "falla esperada: $($_.Exception.Message)" } }
        Remove-Item (Join-Path $ctrl 'fuga.on') -Force
        $pid1 = (Get-Process w3wp -ErrorAction SilentlyContinue | Select-Object -First 1).Id
        Write-Output ("w3wp antes={0} despues={1} reciclado={2}" -f $pid0, $pid1, ($pid0 -ne $pid1))
    }
    'limpiar'      { Remove-Item (Join-Path $ctrl '*') -Force -ErrorAction SilentlyContinue }
}
[pscustomobject]@{ Escenario = $Escenario; T0 = $t0.ToString('o'); EstadoPool = (Get-WebAppPoolState $Pool).Value } | ConvertTo-Json -Compress
