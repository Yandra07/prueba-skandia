<#
.SYNOPSIS
    Runbook de auto-remediación: reinicia PortalPagosPool cuando la alerta "PortalPagos-Sitio-NoDisponible" se dispara.

.DESCRIPTION
    Lo invoca el grupo de acciones de Azure Monitor (webhook, esquema común de alertas).
    Salvaguardas, en este orden; si una falla, no se toca nada:
      1. Alerta "Resolved"                              -> no actúa.
      2. Interruptor AutoRemediacionHabilitada = false   -> no actúa y ESCALA.
      3. VM fuera de la lista VmPermitidas              -> no actúa y ESCALA.
      4. Ventana de mantenimiento (02:00–02:30 Bogotá)   -> no reinicia (el reciclaje programado es esperado), pero
         VERIFICA el estado real y ESCALA si el portal sigue caído: una caída real a las 02:10 no puede quedar sin aviso.
      5. Límite de intentos: MaxIntentos (3) en 60 min    -> no reinicia; VERIFICA el estado real y ESCALA si sigue caído.
      6. Reincidencia: la última remediación fue hace < 15 min -> no reinicia (no se entra en un bucle de reinicios);
         VERIFICA el estado real y ESCALA si sigue caído. Si el portal ya responde, es una alerta residual (la regla mira
         5 min hacia atrás y no se resuelve sola): no se escala. Corregido el 04-oct tras ver en la prueba en vivo una
         escalada falsa ("el pool volvió a caer") 4 min después de una recuperación exitosa.
      7. En la VM: si el pool está Started y /health responde 200 -> no actúa (falso positivo o ya recuperado).
         Si el pool está Started pero /health falla (otra causa, como una dependencia caída) -> no reinicia y ESCALA.
    Escalar = el job termina en estado Failed con el motivo. La alerta "PortalPagos-Remediacion-Escalada" lo convierte
    en un correo para una persona.

    Trazabilidad: cada decisión queda en (a) la salida JSON del job (JobStreams -> Log Analytics) y (b) eventos en la
    VM, fuente AndinaRemediacion: 3000 inicio · 3001 recuperado · 3002 falló · 3003 escalado sin acción.

    Identidad: identidad administrada de la cuenta de Automation, con el rol Virtual Machine Contributor solo sobre la VM.
#>
param([Parameter(Mandatory = $false)][object]$WebhookData)

$ErrorActionPreference = 'Stop'
$tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux) { 'America/Bogota' } else { 'SA Pacific Standard Time' }))

function Get-AhoraBogota { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz) }

function Write-Traza {
    param([string]$Decision, [string]$Detalle, [hashtable]$Datos = @{})
    $o = [ordered]@{ ts = (Get-Date).ToUniversalTime().ToString('o'); runbook = 'Restaurar-PoolIIS'; decision = $Decision; detalle = $Detalle; datos = $Datos }
    Write-Output ($o | ConvertTo-Json -Compress -Depth 6)
}

function ConvertFrom-Alerta {
    <# Extrae lo necesario del esquema común de alertas. #>
    param([object]$WebhookData)
    if (-not $WebhookData) { throw 'Sin WebhookData: este runbook solo se ejecuta desde una alerta.' }
    $body = if ($WebhookData.RequestBody -is [string]) { $WebhookData.RequestBody | ConvertFrom-Json } else { $WebhookData.RequestBody }
    if ($body.schemaId -ne 'azureMonitorCommonAlertSchema') { throw "Esquema no soportado: $($body.schemaId)" }
    $e = $body.data.essentials
    [pscustomobject]@{
        AlertId     = $e.alertId
        Regla       = $e.alertRule
        Severidad   = $e.severity
        Condicion   = $e.monitorCondition
        Disparo     = $e.firedDateTime
        VmId        = @($e.alertTargetIDs | Where-Object { $_ -match '/providers/microsoft\.compute/virtualmachines/' })[0]
    }
}

function Test-EnVentana {
    <# "HH:mm-HH:mm" en hora de Bogotá. #>
    param([string]$Ventana, [datetime]$Ahora)
    if ([string]::IsNullOrWhiteSpace($Ventana)) { return $false }
    $i, $f = $Ventana -split '-'
    $ini = [TimeSpan]::Parse($i); $fin = [TimeSpan]::Parse($f); $t = $Ahora.TimeOfDay
    if ($ini -le $fin) { return ($t -ge $ini -and $t -lt $fin) }
    return ($t -ge $ini -or $t -lt $fin)
}

function Get-DecisionPrevia {
    <# Salvaguardas 1–6. Devuelve $null si se puede actuar, o @{Accion; Motivo}. Función pura: se prueba con Pester. #>
    param($Alerta, [bool]$Habilitada, [string[]]$VmPermitidas, [string]$Ventana, [datetime[]]$Historial, [int]$MaxIntentos, [datetime]$AhoraUtc, [datetime]$AhoraLocal)
    if ($Alerta.Condicion -eq 'Resolved') { return @{ Accion = 'Omitir'; Motivo = 'Alerta resuelta' } }
    if (-not $Habilitada) { return @{ Accion = 'Escalar'; Motivo = 'Auto-remediación deshabilitada (AutoRemediacionHabilitada=false)' } }
    if (-not $Alerta.VmId -or -not ($VmPermitidas | Where-Object { $_ -ieq $Alerta.VmId })) { return @{ Accion = 'Escalar'; Motivo = "VM no autorizada para auto-remediación: $($Alerta.VmId)" } }
    if (Test-EnVentana -Ventana $Ventana -Ahora $AhoraLocal) { return @{ Accion = 'Verificar'; Motivo = "Ventana de mantenimiento $Ventana (reciclaje programado)" } }
    $recientes = @($Historial | Where-Object { $_ -gt $AhoraUtc.AddMinutes(-60) })
    # límite y reincidencia nunca reinician; 'Verificar' = mirar el estado real en la VM (solo lectura) y escalar si sigue caído
    if ($recientes.Count -ge $MaxIntentos) { return @{ Accion = 'Verificar'; Motivo = "Límite de intentos: $($recientes.Count) remediaciones en 60 min (máx $MaxIntentos)" } }
    $ultima = $recientes | Sort-Object | Select-Object -Last 1
    if ($ultima -and $ultima -gt $AhoraUtc.AddMinutes(-15)) {
        $min = [int][math]::Round(($AhoraUtc - $ultima).TotalMinutes)
        return @{ Accion = 'Verificar'; Motivo = "Reincidencia: alerta $min min después de la última remediación" }
    }
    $null
}

# Script que corre DENTRO de la VM (Run Command). Devuelve una sola línea JSON.
$ScriptVm = @'
param([string]$AlertId = '', [string]$Disparo = '', [string]$SoloVerificar = '')
$ErrorActionPreference = 'Stop'
if (Get-Module -ListAvailable -Name WebAdministration) { Import-Module WebAdministration }
$pool = 'PortalPagosPool'
function Ev($id, $tipo, $o) { Write-EventLog -LogName Application -Source AndinaRemediacion -EventId $id -EntryType $tipo -Message ($o | ConvertTo-Json -Compress) }
function Health { try { (Invoke-WebRequest 'http://localhost/health.aspx' -UseBasicParsing -TimeoutSec 10).StatusCode } catch { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 } } }
$antes = (Get-WebAppPoolState $pool).Value
$h0 = Health
$crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WAS'; Id = 5011; StartTime = (Get-Date).AddMinutes(-15) } -ErrorAction SilentlyContinue).Count
$r = [ordered]@{ alertId = $AlertId; disparo = $Disparo; estadoAntes = $antes; healthAntes = $h0; crashes15m = $crashes }
if ($antes -eq 'Started' -and $h0 -eq 200) {
    $r.resultado = 'SinAccion'; $r.motivo = 'Pool Started y /health 200: falso positivo o ya recuperado'
    Ev 3003 Information $r; $r | ConvertTo-Json -Compress; return
}
if ($SoloVerificar) {
    # límite de intentos o reincidencia: nunca reinicia, solo confirma que sigue caído y escala
    $r.resultado = 'Escalar'; $r.motivo = "$SoloVerificar y el portal sigue caído (pool $antes, /health=$h0)"
    Ev 3003 Warning $r; $r | ConvertTo-Json -Compress; return
}
if ($antes -eq 'Started') {
    $r.resultado = 'Escalar'; $r.motivo = "Pool Started pero /health=${h0}: la causa no es el pool, reiniciarlo no ayuda"
    Ev 3003 Warning $r; $r | ConvertTo-Json -Compress; return
}
$r.inicio = (Get-Date).ToString('o')
Ev 3000 Warning $r
try {
    Start-WebAppPool -Name $pool
    $ok = $false
    for ($i = 1; $i -le 6 -and -not $ok; $i++) { Start-Sleep -Seconds 5; $ok = ((Health) -eq 200) }
    $r.estadoDespues = (Get-WebAppPoolState $pool).Value; $r.healthDespues = Health; $r.fin = (Get-Date).ToString('o')
    if ($ok) { $r.resultado = 'Recuperado'; Ev 3001 Information $r } else { $r.resultado = 'Fallido'; $r.motivo = 'El pool no responde 200 tras el inicio'; Ev 3002 Error $r }
} catch {
    $r.resultado = 'Fallido'; $r.motivo = $_.Exception.Message; Ev 3002 Error $r
}
$r | ConvertTo-Json -Compress
'@

function Invoke-Remediacion {
    param($Alerta, [string]$SoloVerificar = '')
    $partes = $Alerta.VmId -split '/'
    $rg = $partes[4]; $vm = $partes[8]
    $res = Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName $vm -CommandId 'RunPowerShellScript' -ScriptString $ScriptVm `
        -Parameter @{ AlertId = ($Alerta.AlertId -split '/')[-1]; Disparo = "$($Alerta.Disparo)"; SoloVerificar = $SoloVerificar }
    $salida = ($res.Value | Where-Object Code -like 'ComponentStatus/StdOut*').Message
    $err = ($res.Value | Where-Object Code -like 'ComponentStatus/StdErr*').Message
    $json = ($salida -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | Select-Object -Last 1)
    if (-not $json) { throw "Run Command sin resultado JSON. stderr: $err" }
    $json | ConvertFrom-Json
}

# ------------------------------------------------------------------ principal (no corre cuando las pruebas lo importan)
if ($env:RUNBOOK_PRUEBAS -ne '1') {
    $alerta = ConvertFrom-Alerta -WebhookData $WebhookData
    Write-Traza -Decision 'Recibida' -Detalle "Alerta $($alerta.Regla) ($($alerta.Condicion))" -Datos @{ alerta = $alerta }

    $habilitada = [bool](Get-AutomationVariable -Name 'AutoRemediacionHabilitada')
    $permitidas = @((Get-AutomationVariable -Name 'VmPermitidas') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $ventana = Get-AutomationVariable -Name 'VentanaMantenimiento'
    $max = [int](Get-AutomationVariable -Name 'MaxIntentos')
    $histJson = Get-AutomationVariable -Name 'HistorialRemediacion'
    $hist = @(); if ($histJson) { $hist = @(($histJson | ConvertFrom-Json) | ForEach-Object { [datetime]::Parse($_).ToUniversalTime() }) }

    $previa = Get-DecisionPrevia -Alerta $alerta -Habilitada $habilitada -VmPermitidas $permitidas -Ventana $ventana -Historial $hist `
        -MaxIntentos $max -AhoraUtc ([DateTime]::UtcNow) -AhoraLocal (Get-AhoraBogota)
    if ($previa -and $previa.Accion -ne 'Verificar') {
        Write-Traza -Decision $previa.Accion -Detalle $previa.Motivo
        if ($previa.Accion -eq 'Escalar') { throw "ESCALAR: $($previa.Motivo)" }
        return
    }

    Connect-AzAccount -Identity | Out-Null
    if ($previa) {
        # Verificar: solo lectura en la VM. No cuenta como intento (no se reinicia nada)
        Write-Traza -Decision 'Verificar' -Detalle $previa.Motivo
        try { $r = Invoke-Remediacion -Alerta $alerta -SoloVerificar $previa.Motivo } catch {
            throw "ESCALAR: $($previa.Motivo); además la VM no respondió a Run Command ($($_.Exception.Message))"
        }
        Write-Traza -Decision $r.resultado -Detalle "$($r.motivo)" -Datos @{ vm = $r }
        if ($r.resultado -eq 'Escalar') { throw "ESCALAR: $($r.motivo)" }
        return
    }
    # el intento cuenta desde que se decide actuar, aunque luego falle
    $hist = @($hist | Where-Object { $_ -gt [DateTime]::UtcNow.AddHours(-24) }) + [DateTime]::UtcNow
    $histTexto = ConvertTo-Json -Compress -InputObject @($hist | ForEach-Object { $_.ToString('o') })
    Set-AutomationVariable -Name 'HistorialRemediacion' -Value $histTexto

    try { $r = Invoke-Remediacion -Alerta $alerta } catch {
        Write-Traza -Decision 'Escalar' -Detalle "No se pudo ejecutar en la VM: $($_.Exception.Message)"
        throw "ESCALAR: la VM no respondió a Run Command ($($_.Exception.Message))"
    }
    Write-Traza -Decision $r.resultado -Detalle "$($r.motivo)" -Datos @{ vm = $r }
    if ($r.resultado -in 'Escalar', 'Fallido') { throw "ESCALAR: $($r.resultado) - $($r.motivo)" }
}
