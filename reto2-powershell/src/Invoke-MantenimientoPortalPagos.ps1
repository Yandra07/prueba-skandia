#Requires -Version 5.1
<#
.SYNOPSIS
    Mantenimiento diario de WEB-PAGOS-01 (reemplaza C:\scripts\mantenimiento_diario.bat).

.DESCRIPTION
    Pasos, en este orden:
      1. Verifica el espacio en disco (aviso / crítico).
      2. Archiva los logs IIS cerrados en el share de auditoría: copia incremental, verificada con SHA-256.
      3. Purga los logs IIS locales más viejos que -DiasRetencionIis, SOLO si están archivados y verificados.
      4. Purga los logs de la aplicación más viejos que -DiasRetencionApp. Si el disco sigue por debajo del umbral
         de aviso, borra más logs de la aplicación (del más viejo al más nuevo) sin bajar de -DiasMinimosApp.
      5. Aplica la retención de volcados de memoria (nunca borra los recientes).
      6. Asegura que el servicio de notificaciones esté en ejecución (sin reinicio ciego).
      7. Verifica el estado del application pool (sin iisreset; el reciclaje lo hace IIS, ver Instalar-*.ps1).
      8. Verifica el espacio en disco final y escribe un evento resumen (fuente AndinaMantenimiento).

    No contiene credenciales: la tarea programada corre con una gMSA que tiene permiso de escritura
    en el share de auditoría. Se puede ejecutar varias veces: lo que ya está archivado o borrado no se repite.

    Códigos de salida (los lee el Programador de tareas y la alerta del Reto 3):
        0 OK · 1 Parámetros inválidos / no se pudo iniciar · 2 Aviso · 3 Error (algún paso falló o disco crítico)
        4 Otra ejecución en curso.

.EXAMPLE
    .\Invoke-MantenimientoPortalPagos.ps1 -WhatIf -Verbose
    Simulación: registra en el log JSON lo que haría, sin tocar nada.

.EXAMPLE
    .\Invoke-MantenimientoPortalPagos.ps1 -RutaAuditoria '\\fs-auditoria\logs$\WEB-PAGOS-01'
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateNotNullOrEmpty()]
    [ValidateScript({ if (Test-Path -LiteralPath $_ -PathType Container) { $true } else { throw "No existe la carpeta de logs IIS: $_" } })]
    [string]$RutaLogsIis = 'C:\inetpub\logs\LogFiles\W3SVC2',

    # Ruta UNC del share de auditoría. Vacía = no se archiva y NO se purgan los logs IIS.
    [ValidatePattern('^(\\\\[^\\]+\\[^\\]+.*|[A-Za-z]:\\.+|/.+)?$')]
    [string]$RutaAuditoria = '\\fs-auditoria\logs$\WEB-PAGOS-01',

    [ValidateScript({ foreach ($r in $_) { if (-not (Test-Path -LiteralPath $r -PathType Container)) { throw "No existe la carpeta de logs de la aplicación: $r" } }; $true })]
    [string[]]$RutasLogsApp = @(),

    # Ruta absoluta (unidad, UNC o /ruta). Vacía = se omite la retención de volcados.
    [ValidatePattern('^([A-Za-z]:\\.+|\\\\[^\\]+\\.+|/.+)?$')]
    [string]$RutaDumps = 'C:\CrashDumps',

    # Nombres de Windows: letras, números, espacio, punto, guion y guion bajo. Vacío = se omite el paso.
    [ValidatePattern('^[\w .-]{0,80}$')]
    [string]$NombreServicio = 'Servicio Notificaciones',

    [ValidatePattern('^[\w .-]{0,64}$')]
    [string]$NombrePool = 'PortalPagosPool',

    [ValidateRange(3, 365)][int]$DiasRetencionIis = 14,
    [ValidateRange(1, 90)][int]$DiasRetencionApp = 7,
    # piso del modo "presión de disco": nunca se borran logs de la app más nuevos que esto
    [ValidateRange(1, 90)][int]$DiasMinimosApp = 1,
    [ValidateRange(3, 365)][int]$DiasMinimosDumps = 14,
    [ValidateRange(1, 50)][int]$DumpsConservar = 5,
    [ValidateRange(5, 90)][int]$UmbralDiscoAvisoPct = 20,
    [ValidateRange(1, 50)][int]$UmbralDiscoCriticoPct = 10,

    [ValidateNotNullOrEmpty()]
    [string]$RutaLog = 'C:\ProgramData\Andina\Mantenimiento\logs',

    # no escribe el evento resumen en Application (pruebas y ejecuciones de laboratorio)
    [switch]$OmitirEvento
)

$ErrorActionPreference = 'Stop'
try {
    if ($UmbralDiscoCriticoPct -ge $UmbralDiscoAvisoPct) { throw 'UmbralDiscoCriticoPct debe ser menor que UmbralDiscoAvisoPct.' }
    if ($DiasMinimosApp -gt $DiasRetencionApp) { throw 'DiasMinimosApp no puede ser mayor que DiasRetencionApp.' }
    # los valores por defecto no pasan por ValidateScript: se revalida aquí
    if (-not (Test-Path -LiteralPath $RutaLogsIis -PathType Container)) { throw "No existe la carpeta de logs IIS: $RutaLogsIis" }
    Import-Module (Join-Path $PSScriptRoot 'MantenimientoPortal\MantenimientoPortal.psd1') -Force
    $p = @{} + $PSBoundParameters
    foreach ($k in 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction') { [void]$p.Remove($k) }
    foreach ($n in 'RutaLogsIis', 'RutaAuditoria', 'RutasLogsApp', 'RutaDumps', 'NombreServicio', 'NombrePool', 'DiasRetencionIis', 'DiasRetencionApp',
        'DiasMinimosApp', 'DiasMinimosDumps', 'DumpsConservar', 'UmbralDiscoAvisoPct', 'UmbralDiscoCriticoPct', 'RutaLog') {
        if (-not $p.ContainsKey($n)) { $p[$n] = Get-Variable -Name $n -ValueOnly }
    }
    $r = Invoke-Mantenimiento @p -WhatIf:$WhatIfPreference
    $r.Resultados | Format-Table Paso, Estado, Detalle -AutoSize | Out-String | Write-Verbose
    Write-Output ("Código de salida: {0} · log: {1}" -f $r.CodigoSalida, $r.Log)
    exit $r.CodigoSalida
} catch {
    Write-Error "No se pudo ejecutar el mantenimiento: $($_.Exception.Message)" -ErrorAction Continue
    exit 1
}
