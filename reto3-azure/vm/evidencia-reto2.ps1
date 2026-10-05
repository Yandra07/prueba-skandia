#Requires -Version 5.1
<#
.SYNOPSIS
    Evidencia del Reto 2 en Windows Server 2022 / Windows PowerShell 5.1: pruebas Pester + ejecución real del mantenimiento.
    Salida compacta y en ASCII (Run Command devuelve solo 4 KB y no respeta la codificación).
#>
$ErrorActionPreference = 'Stop'
$salida = New-Object System.Collections.Generic.List[string]
# Run Command corre como SYSTEM y su temporal es C:\Windows\SystemTemp (GetTempPath2 ignora TMP para SYSTEM). Las salvaguardas del módulo (correctamente)
# se niegan a borrar bajo C:\Windows, así que las pruebas usan una carpeta temporal propia.
$tmp = 'C:\andina\tmp'; New-Item -ItemType Directory $tmp -Force | Out-Null; $env:PRUEBAS_RAIZ = $tmp
# versión vigente del Reto 2 (la envía evidencia-reto2.sh)
if ($Reto2B64) {
    $z = Join-Path $tmp 'reto2.zip'; [IO.File]::WriteAllBytes($z, [Convert]::FromBase64String($Reto2B64))
    Remove-Item 'C:\andina\payload\reto2' -Recurse -Force -ErrorAction SilentlyContinue
    Expand-Archive $z 'C:\andina\payload\reto2' -Force; Remove-Item $z
    Copy-Item 'C:\andina\payload\reto2\src\*' 'C:\Program Files\Andina\Mantenimiento' -Recurse -Force
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope AllUsers
}
$r2 = 'C:\andina\payload\reto2'
# Pester corre en un proceso aparte: los mensajes "What if:" de las pruebas de -WhatIf van directo al host y, en el mismo
# proceso, llenaban los 4 KB de Run Command y truncaban el resumen (le pasó a evidencias/reto2-en-vm.txt del 01-oct).
# El resultado se lee del XML NUnit.
$xmlPester = 'C:\andina\pester-reto2-vm.xml'; Remove-Item $xmlPester -ErrorAction SilentlyContinue
$runner = Join-Path $tmp 'correr-pester.ps1'
@"
Import-Module Pester -RequiredVersion 5.7.1
`$c = New-PesterConfiguration
`$c.Run.Path = '$r2\tests\MantenimientoPortal.Tests.ps1'; `$c.Output.Verbosity = 'None'
`$c.TestResult.Enabled = `$true; `$c.TestResult.OutputPath = '$xmlPester'
Invoke-Pester -Configuration `$c | Out-Null
"@ | Set-Content -LiteralPath $runner -Encoding ASCII
Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$runner`"" -Wait -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $tmp 'pester-out.txt') -RedirectStandardError (Join-Path $tmp 'pester-err.txt') | Out-Null
[xml]$x = Get-Content -LiteralPath $xmlPester -Raw
$tr = $x.'test-results'
$ok = [int]$tr.total - [int]$tr.failures - [int]$tr.errors - [int]$tr.'not-run'
$salida.Add("PESTER | PowerShell $($PSVersionTable.PSVersion) | $((Get-CimInstance Win32_OperatingSystem).Caption) | Pester 5.7.1: $ok ok, $($tr.failures) fallidas, $($tr.'not-run') sin correr (de $($tr.total))")
$x.SelectNodes('//test-case[@result="Failure"]') | ForEach-Object { $salida.Add("  FALLA: $($_.name) :: $($_.failure.message)") }

$m = 'C:\Program Files\Andina\Mantenimiento\Invoke-MantenimientoPortalPagos.ps1'
function Correr([string]$a) { (Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$m`" $a" -Wait -PassThru -WindowStyle Hidden).ExitCode }
$w = Correr "-RutaAuditoria C:\auditoria\WEB-PAGOS-01 -NombreServicio `"`" -WhatIf"
$e = Correr "-RutaAuditoria C:\auditoria\WEB-PAGOS-01 -NombreServicio `"`""
$i = Correr "-DiasRetencionIis 0"
$salida.Add("MANTENIMIENTO (sin Servicio Notificaciones: no existe en el laboratorio) | -WhatIf=$w | real=$e | parametro invalido=$i")
$log = Get-ChildItem 'C:\ProgramData\Andina\Mantenimiento\logs\*.jsonl' | Sort-Object LastWriteTime | Select-Object -Last 1
# el log es UTF-8 sin BOM: en 5.1 hay que indicarlo o los acentos salen dañados
Get-Content $log.FullName -Tail 3 -Encoding UTF8 | ForEach-Object { $j = $_ | ConvertFrom-Json; $salida.Add("  $($j.ts) $($j.nivel) $($j.paso): $($j.mensaje)") }
$t = Get-ScheduledTask -TaskPath '\Andina\' -TaskName 'MantenimientoPortalPagos'
$salida.Add("TAREA | $($t.TaskPath)$($t.TaskName) | estado=$($t.State) | usuario=$($t.Principal.UserId) | trigger=$($t.Triggers[0].StartBoundary)")
$pp = 'IIS:\AppPools\PortalPagosPool'; Import-Module WebAdministration
$salida.Add("POOL | privateMemory=$((Get-ItemProperty $pp -Name recycling.periodicRestart.privateMemory).Value) KB | schedule=$(((Get-ItemProperty $pp -Name recycling.periodicRestart.schedule).Collection | ForEach-Object { $_.value }) -join ',') | time=$((Get-ItemProperty $pp -Name recycling.periodicRestart.time).Value)")
$salida.Add("EVENTOS AndinaMantenimiento: " + ((Get-EventLog -LogName Application -Source AndinaMantenimiento -Newest 3 | ForEach-Object { "$($_.EventID)/$($_.EntryType)" }) -join ', '))
# Run Command no respeta la codificación: se quitan tildes y símbolos para que la evidencia se lea igual en cualquier terminal
$salida | ForEach-Object { ($_.Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '') -replace '[^\x20-\x7E]', '?' }
