#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Instala el mantenimiento nuevo en WEB-PAGOS-01 y retira el .BAT. Idempotente y con -WhatIf.

.DESCRIPTION
    1. Copia el script y el módulo a C:\Program Files\Andina\Mantenimiento (solo lectura para usuarios).
    2. Registra la fuente de eventos 'AndinaMantenimiento' (la usa Azure Monitor en el Reto 3).
    3. Configura el reciclaje de PortalPagosPool, que REEMPLAZA al iisreset nocturno:
         - reciclaje por memoria privada (por defecto 1.000.000 KB ≈ 1 GB), por debajo del techo de
           OutOfMemory observado el 18-sep (≈1,4–1,5 GB);
         - reciclaje programado a las 02:00;
         - sin reciclaje por intervalo fijo (el valor por defecto de IIS es cada 29 h, a cualquier hora);
         - overlapped recycle activo: el proceso nuevo atiende antes de que el viejo termine (sin 503).
    4. Registra la tarea programada \Andina\MantenimientoPortalPagos a las 02:15 con una gMSA
       (sin contraseña almacenada) y deshabilita la tarea vieja \Mantenimiento\MantenimientoDiarioIIS.

    La gMSA (por ejemplo ANDINA\gmsa-mant-web$) la crea el equipo de AD, con permiso de escritura en
    \\fs-auditoria\logs$\WEB-PAGOS-01 y "Iniciar sesión como proceso por lotes" en el servidor.

.EXAMPLE
    .\Instalar-MantenimientoPortalPagos.ps1 -CuentaGmsa 'ANDINA\gmsa-mant-web$' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # gMSA (dominio\cuenta$) en producción. 'NT AUTHORITY\SYSTEM' solo para la VM de laboratorio sin dominio (Reto 3):
    # SYSTEM accede a la red como la cuenta de equipo; en ningún caso hay contraseña.
    [Parameter(Mandatory)]
    [ValidatePattern('^([\w.-]+\\[\w.-]+\$|NT AUTHORITY\\SYSTEM)$')]
    [string]$CuentaGmsa,

    [string]$NombrePool = 'PortalPagosPool',
    [ValidateRange(300000, 4000000)][int]$LimiteMemoriaPrivadaKB = 1000000,
    [ValidatePattern('^\d{2}:\d{2}$')][string]$HoraReciclaje = '02:00',
    [ValidatePattern('^\d{2}:\d{2}$')][string]$HoraTarea = '02:15',
    [string]$Destino = 'C:\Program Files\Andina\Mantenimiento',
    [string[]]$ArgumentosTarea = @()
)

$ErrorActionPreference = 'Stop'

# 1. Archivos
$origen = $PSScriptRoot
if ($PSCmdlet.ShouldProcess($Destino, 'Copiar script y módulo')) {
    New-Item -ItemType Directory -Path $Destino -Force | Out-Null
    Copy-Item -Path (Join-Path $origen 'Invoke-MantenimientoPortalPagos.ps1') -Destination $Destino -Force
    Copy-Item -Path (Join-Path $origen 'MantenimientoPortal') -Destination $Destino -Recurse -Force
}

# 2. Fuente de eventos
if (-not [System.Diagnostics.EventLog]::SourceExists('AndinaMantenimiento')) {
    if ($PSCmdlet.ShouldProcess('Application/AndinaMantenimiento', 'Registrar fuente de eventos')) {
        New-EventLog -LogName Application -Source 'AndinaMantenimiento'
    }
}

# 3. Reciclaje del pool (reemplaza iisreset)
Import-Module WebAdministration
$pp = "IIS:\AppPools\$NombrePool"
if (-not (Test-Path $pp)) { throw "No existe el application pool $NombrePool" }
$actual = Get-ItemProperty $pp -Name recycling.periodicRestart
if ($actual.privateMemory -ne $LimiteMemoriaPrivadaKB -and $PSCmdlet.ShouldProcess($NombrePool, "privateMemory = $LimiteMemoriaPrivadaKB KB")) {
    Set-ItemProperty $pp -Name recycling.periodicRestart.privateMemory -Value $LimiteMemoriaPrivadaKB
}
if ($actual.time -ne [TimeSpan]::Zero -and $PSCmdlet.ShouldProcess($NombrePool, 'Desactivar reciclaje por intervalo fijo')) {
    Set-ItemProperty $pp -Name recycling.periodicRestart.time -Value ([TimeSpan]::Zero)
}
$horas = @((Get-ItemProperty $pp -Name recycling.periodicRestart.schedule).Collection | ForEach-Object { $_.value.ToString('hh\:mm') })
if (($horas -join ',') -ne $HoraReciclaje -and $PSCmdlet.ShouldProcess($NombrePool, "Reciclaje programado a las $HoraReciclaje")) {
    Clear-ItemProperty $pp -Name recycling.periodicRestart.schedule
    Set-ItemProperty $pp -Name recycling.periodicRestart.schedule -Value @{ value = $HoraReciclaje }
}
if ((Get-ItemProperty $pp -Name recycling.disallowOverlappingRotation).Value -and $PSCmdlet.ShouldProcess($NombrePool, 'Activar overlapped recycle')) {
    Set-ItemProperty $pp -Name recycling.disallowOverlappingRotation -Value $false
}
# que cada reciclaje quede en el visor de eventos (WAS 5077/5080/5186) para auditarlo en el Reto 3
if ($PSCmdlet.ShouldProcess($NombrePool, 'Registrar eventos de reciclaje')) {
    Set-ItemProperty $pp -Name recycling.logEventOnRecycle -Value 'Time,Requests,Schedule,Memory,IsapiUnhealthy,OnDemand,ConfigChange,PrivateMemory'
}

# 4. Tarea programada
$script = Join-Path $Destino 'Invoke-MantenimientoPortalPagos.ps1'
$argumentos = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"") + $ArgumentosTarea
$accion = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($argumentos -join ' ')
$disparador = New-ScheduledTaskTrigger -Daily -At $HoraTarea
if ($CuentaGmsa -eq 'NT AUTHORITY\SYSTEM') {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
} else {
    $principal = New-ScheduledTaskPrincipal -UserId $CuentaGmsa -LogonType Password -RunLevel Highest   # gMSA: sin contraseña guardada
}
$config = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -StartWhenAvailable
if ($PSCmdlet.ShouldProcess('\Andina\MantenimientoPortalPagos', 'Registrar tarea programada')) {
    Register-ScheduledTask -TaskPath '\Andina\' -TaskName 'MantenimientoPortalPagos' -Action $accion -Trigger $disparador `
        -Principal $principal -Settings $config -Description 'Mantenimiento diario PortalPagos (reemplaza mantenimiento_diario.bat)' -Force | Out-Null
}
$vieja = Get-ScheduledTask -TaskPath '\Mantenimiento\' -TaskName 'MantenimientoDiarioIIS' -ErrorAction SilentlyContinue
if ($vieja -and $vieja.State -ne 'Disabled' -and $PSCmdlet.ShouldProcess('\Mantenimiento\MantenimientoDiarioIIS', 'Deshabilitar tarea vieja (se conserva para rollback)')) {
    Disable-ScheduledTask -InputObject $vieja | Out-Null
}
Write-Output 'Instalación completa. Siguiente paso: rotar la contraseña de ANDINA\svc_mantenimiento (estaba en texto plano en el .BAT).'
