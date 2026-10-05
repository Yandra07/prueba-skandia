<#
.SYNOPSIS
    Corre las pruebas Pester y guarda la evidencia (NUnit XML + resumen) en ..\evidencias.
#>
param([string]$Salida = (Join-Path (Split-Path -Parent $PSScriptRoot) 'evidencias'))
Import-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.PassThru = $true
$cfg.Output.Verbosity = 'Detailed'
$cfg.TestResult.Enabled = $true
$cfg.TestResult.OutputFormat = 'NUnitXml'
$cfg.TestResult.OutputPath = Join-Path $Salida 'pester-resultados.xml'
New-Item -ItemType Directory -Path $Salida -Force | Out-Null
$r = Invoke-Pester -Configuration $cfg
# la evidencia va al repositorio: se quitan el nombre del equipo, el usuario y la ruta local del repo
$xml = $cfg.TestResult.OutputPath.Value
$raiz = Split-Path -Parent $PSScriptRoot
(Get-Content -LiteralPath $xml -Raw) -replace 'machine-name="[^"]*"', 'machine-name="equipo"' -replace 'user="[^"]*"', 'user="usuario"' `
    -replace [regex]::Escape($raiz), '<repo>' | Set-Content -LiteralPath $xml -Encoding UTF8 -NoNewline
"{0} · PowerShell {1} · {2} · Pester {3}: {4} pasaron, {5} fallaron, {6} omitidas" -f (Get-Date -Format s), $PSVersionTable.PSVersion,
    [System.Runtime.InteropServices.RuntimeInformation]::OSDescription, (Get-Module Pester).Version, $r.PassedCount, $r.FailedCount, $r.SkippedCount |
    Tee-Object -FilePath (Join-Path $Salida 'pester-resumen.txt') -Append
exit $r.FailedCount
