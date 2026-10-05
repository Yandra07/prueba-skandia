#Requires -Version 5.1
<#
.SYNOPSIS
    Configura la VM de laboratorio WEB-PAGOS-01 (Reto 3). Idempotente: se puede volver a ejecutar.
.DESCRIPTION
    Lo ejecuta scripts/desplegar.sh vía "az vm run-command". Antes de este bloque, el despliegue antepone la línea
    $PayloadB64 = '<zip en base64>' con el sitio de prueba, los scripts de la VM y el módulo del Reto 2.

    1. Zona horaria de Bogotá (como el servidor real).
    2. IIS + ASP.NET 4.8 + herramientas de scripting.
    3. Sitio PortalPagos (ID 2 => logs en W3SVC2) y pool PortalPagosPool (.NET 4, 32 bits, Rapid-Fail por defecto: 5 fallas/5 min).
    4. Fuentes de eventos AndinaSonda / AndinaMantenimiento / AndinaRemediacion / AndinaPrueba.
    5. Volcados de w3wp en C:\CrashDumps (WER LocalDumps).
    6. Tareas programadas: sonda (cada minuto), carga sintética (cada minuto) y mantenimiento del Reto 2 (02:15).
#>
$ErrorActionPreference = 'Stop'
$log = New-Object System.Collections.Generic.List[string]
function Paso($m) { $log.Add(("{0:HH:mm:ss} {1}" -f (Get-Date), $m)) }

# 1. Zona horaria
if ((Get-TimeZone).Id -ne 'SA Pacific Standard Time') { Set-TimeZone -Id 'SA Pacific Standard Time'; Paso 'zona horaria = SA Pacific' }

# 2. Roles
$features = 'Web-Server', 'Web-Asp-Net45', 'Web-Scripting-Tools', 'Web-Http-Logging', 'Web-Request-Monitor', 'Web-Http-Tracing', 'Web-Mgmt-Console'
$faltan = @(Get-WindowsFeature $features | Where-Object { -not $_.Installed })
if ($faltan) { Install-WindowsFeature -Name $faltan.Name | Out-Null; Paso "instalado: $($faltan.Name -join ',')" }
Import-Module WebAdministration

# 3. Payload
$raiz = 'C:\andina'
$zip = Join-Path $env:TEMP 'andina-payload.zip'
[IO.File]::WriteAllBytes($zip, [Convert]::FromBase64String($PayloadB64))
if (Test-Path "$raiz\payload") { Remove-Item "$raiz\payload" -Recurse -Force }
Expand-Archive -Path $zip -DestinationPath "$raiz\payload" -Force
Remove-Item $zip -Force
foreach ($d in 'C:\sitios\PortalPagos', 'C:\sitios\control', 'C:\CrashDumps', 'C:\auditoria\WEB-PAGOS-01', "$raiz\scripts") {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
}
Copy-Item "$raiz\payload\sitio\*" 'C:\sitios\PortalPagos' -Recurse -Force
Copy-Item "$raiz\payload\vm\*.ps1" "$raiz\scripts" -Force
Paso 'payload desplegado'

# 4. Fuentes de eventos
foreach ($src in 'AndinaSonda', 'AndinaMantenimiento', 'AndinaRemediacion', 'AndinaPrueba') {
    if (-not [Diagnostics.EventLog]::SourceExists($src)) { New-EventLog -LogName Application -Source $src; Paso "fuente $src" }
}

# 5. Pool y sitio
$pool = 'PortalPagosPool'
if (-not (Test-Path "IIS:\AppPools\$pool")) { New-WebAppPool -Name $pool | Out-Null; Paso "pool $pool creado" }
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedRuntimeVersion -Value 'v4.0'
Set-ItemProperty "IIS:\AppPools\$pool" -Name managedPipelineMode -Value 'Integrated'
Set-ItemProperty "IIS:\AppPools\$pool" -Name enable32BitAppOnWin64 -Value $true      # hipótesis C7 del Reto 1
Set-ItemProperty "IIS:\AppPools\$pool" -Name failure.rapidFailProtection -Value $true
if (Get-Website -Name 'Default Web Site' -ErrorAction SilentlyContinue) { Remove-Website -Name 'Default Web Site'; Paso 'Default Web Site eliminado' }
if (-not (Get-Website -Name 'PortalPagos' -ErrorAction SilentlyContinue)) {
    New-Website -Name 'PortalPagos' -Id 2 -Port 80 -PhysicalPath 'C:\sitios\PortalPagos' -ApplicationPool $pool | Out-Null
    Paso 'sitio PortalPagos (ID 2) creado'
}
# campos W3C útiles para el Reto 1/3 (incluye time-taken, substatus y win32-status)
Set-ItemProperty 'IIS:\Sites\PortalPagos' -Name logFile.logExtFileFlags -Value 'Date,Time,ClientIP,UserName,ServerIP,Method,UriStem,UriQuery,HttpStatus,Win32Status,TimeTaken,ServerPort,UserAgent,Referer,HttpSubStatus,Host'
icacls 'C:\sitios\control' /grant 'IIS AppPool\PortalPagosPool:(OI)(CI)R' | Out-Null
if ((Get-WebAppPoolState $pool).Value -ne 'Started') { Start-WebAppPool $pool }

# 6. Volcados de w3wp (como en WEB-PAGOS-01: C:\CrashDumps)
$wer = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\w3wp.exe'
if (-not (Test-Path $wer)) { New-Item $wer -Force | Out-Null }
Set-ItemProperty $wer -Name DumpFolder -Value 'C:\CrashDumps' -Type ExpandString
Set-ItemProperty $wer -Name DumpCount -Value 5 -Type DWord
Set-ItemProperty $wer -Name DumpType -Value 1 -Type DWord   # minidump: el laboratorio no necesita volcados completos

# 7. Tareas: sonda y carga cada minuto, como SYSTEM
function Register-TareaMinuto($nombre, $script) {
    $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$script`""
    $t = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 3650)
    $p = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $s = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -MultipleInstances IgnoreNew -StartWhenAvailable
    Register-ScheduledTask -TaskPath '\Andina\' -TaskName $nombre -Action $a -Trigger $t -Principal $p -Settings $s -Force | Out-Null
}
Register-TareaMinuto 'SondaPortalPagos' "$raiz\scripts\sonda.ps1"
Register-TareaMinuto 'CargaSintetica' "$raiz\scripts\carga.ps1"
Paso 'tareas sonda y carga registradas'

# 8. Mantenimiento del Reto 2 (tarea 02:15 + reciclaje del pool por memoria, que reemplaza al iisreset)
& "$raiz\payload\reto2\src\Instalar-MantenimientoPortalPagos.ps1" -CuentaGmsa 'NT AUTHORITY\SYSTEM' `
    -ArgumentosTarea @('-RutaAuditoria', 'C:\auditoria\WEB-PAGOS-01', '-NombreServicio', '""') | Out-Null   # la VM de laboratorio no tiene "Servicio Notificaciones"
Paso 'mantenimiento Reto 2 instalado'

# Azure Monitor Agent arrancó antes de que existiera IIS: no encuentra la configuración (CoCreateInstance
# AppHostWritableAdminManager 0x80040154) y no recolecta W3CIISLog hasta reiniciar su colector. El launcher lo relanza.
if ($faltan) { Stop-Process -Name MonAgentCore, MonAgentManager -Force -ErrorAction SilentlyContinue; Paso 'colector AMA reiniciado para detectar IIS' }

$health = try { (Invoke-WebRequest 'http://localhost/health.aspx' -UseBasicParsing -TimeoutSec 60).StatusCode } catch { "$($_.Exception.Message)" }
$estado = [ordered]@{
    host = $env:COMPUTERNAME; zona = (Get-TimeZone).Id; ps = $PSVersionTable.PSVersion.ToString()
    pool = (Get-WebAppPoolState $pool).Value
    privateMemoryKB = (Get-ItemProperty "IIS:\AppPools\$pool" -Name recycling.periodicRestart.privateMemory).Value
    health = $health
    tareas = @(Get-ScheduledTask -TaskPath '\Andina\' | ForEach-Object TaskName)
    pasos = $log
}
$estado | ConvertTo-Json -Compress
