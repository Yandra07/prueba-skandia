#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pruebas de las salvaguardas del runbook y del script que corre en la VM (sin Azure: todo simulado).
        Invoke-Pester ./tests/Runbook.Tests.ps1 -Output Detailed
#>
BeforeAll {
    $env:RUNBOOK_PRUEBAS = '1'
    . (Join-Path (Split-Path -Parent $PSScriptRoot) 'runbook/Restaurar-PoolIIS.ps1')
    $script:Vm = '/subscriptions/0000/resourceGroups/rg-portalpagos-lab/providers/Microsoft.Compute/virtualMachines/web-pagos-01'
    function New-Payload([string]$condicion = 'Fired', [string]$vm = $script:Vm) {
        @{ RequestBody = (@{ schemaId = 'azureMonitorCommonAlertSchema'; data = @{ essentials = @{
            alertId = '/subscriptions/0000/providers/Microsoft.AlertsManagement/alerts/abc'; alertRule = 'PortalPagos-Sitio-NoDisponible'
            severity = 'Sev1'; monitorCondition = $condicion; firedDateTime = '2026-10-01T19:00:00Z'; alertTargetIDs = @($vm.ToLower()) } } } | ConvertTo-Json -Depth 6) }
    }
    $script:Base = @{ Habilitada = $true; VmPermitidas = @($Vm); Ventana = '02:00-02:30'; Historial = @(); MaxIntentos = 3
        AhoraUtc = [datetime]'2026-10-01T19:01:00Z'; AhoraLocal = [datetime]'2026-10-01T14:01:00' }
}

Describe 'Lectura de la alerta (esquema común)' {
    It 'extrae regla, condición, disparo y VM' {
        $a = ConvertFrom-Alerta -WebhookData (New-Payload)
        $a.Regla | Should -Be 'PortalPagos-Sitio-NoDisponible'; $a.Condicion | Should -Be 'Fired'; $a.VmId | Should -Be $Vm.ToLower()
    }
    It 'rechaza una invocación sin alerta y un esquema desconocido' {
        { ConvertFrom-Alerta -WebhookData $null } | Should -Throw '*Sin WebhookData*'
        { ConvertFrom-Alerta -WebhookData @{ RequestBody = '{"schemaId":"otro"}' } } | Should -Throw '*no soportado*'
    }
    It 'lee el ejemplo del kit (alertas/alerta_ejemplo.json)' -Skip:(-not $env:KIT) {
        $a = ConvertFrom-Alerta -WebhookData @{ RequestBody = (Get-Content (Join-Path $env:KIT 'alertas/alerta_ejemplo.json') -Raw) }
        $a.Regla | Should -Be 'PortalPagos-5xx-alto'; $a.VmId | Should -Match 'web-pagos-01'
    }
}

Describe 'Salvaguardas (cuándo NO actuar)' {
    BeforeEach { $script:A = ConvertFrom-Alerta -WebhookData (New-Payload) }
    It 'actúa cuando todo está en orden' { Get-DecisionPrevia -Alerta $A @Base | Should -BeNullOrEmpty }
    It 'alerta resuelta => omitir' {
        (Get-DecisionPrevia -Alerta (ConvertFrom-Alerta -WebhookData (New-Payload 'Resolved')) @Base).Accion | Should -Be 'Omitir'
    }
    It 'interruptor apagado => escalar' {
        $p = $Base.Clone(); $p.Habilitada = $false
        (Get-DecisionPrevia -Alerta $A @p).Accion | Should -Be 'Escalar'
    }
    It 'VM no autorizada => escalar' {
        $otra = ConvertFrom-Alerta -WebhookData (New-Payload -vm ($Vm -replace 'web-pagos-01', 'sql-core-01'))
        (Get-DecisionPrevia -Alerta $otra @Base).Motivo | Should -Match 'no autorizada'
    }
    It 'ventana de mantenimiento 02:00–02:30 Bogotá => no reinicia, verifica (escala si sigue caído)' {
        $p = $Base.Clone(); $p.AhoraLocal = [datetime]'2026-10-01T02:10:00'
        $d = Get-DecisionPrevia -Alerta $A @p
        $d.Accion | Should -Be 'Verificar'; $d.Motivo | Should -Match 'Ventana de mantenimiento'
    }
    It 'ventana que cruza medianoche' {
        Test-EnVentana -Ventana '23:30-00:30' -Ahora ([datetime]'2026-10-01T00:10:00') | Should -BeTrue
        Test-EnVentana -Ventana '23:30-00:30' -Ahora ([datetime]'2026-10-01T12:00:00') | Should -BeFalse
    }
    It '3 intentos en 60 min => no reinicia: verifica y escala si sigue caído (límite)' {
        $p = $Base.Clone(); $p.Historial = @($p.AhoraUtc.AddMinutes(-50), $p.AhoraUtc.AddMinutes(-40), $p.AhoraUtc.AddMinutes(-30))
        $d = Get-DecisionPrevia -Alerta $A @p
        $d.Accion | Should -Be 'Verificar'; $d.Motivo | Should -Match 'Límite de intentos'
    }
    It 'reincidencia: menos de 15 min tras la última remediación => no reinicia (no entrar en bucle), verifica' {
        $p = $Base.Clone(); $p.Historial = @($p.AhoraUtc.AddMinutes(-6))
        $d = Get-DecisionPrevia -Alerta $A @p
        $d.Accion | Should -Be 'Verificar'; $d.Motivo | Should -Match 'Reincidencia'
    }
    It 'intentos viejos (> 60 min) no cuentan' {
        $p = $Base.Clone(); $p.Historial = @($p.AhoraUtc.AddHours(-3), $p.AhoraUtc.AddHours(-2), $p.AhoraUtc.AddMinutes(-61))
        Get-DecisionPrevia -Alerta $A @p | Should -BeNullOrEmpty
    }
}

Describe 'Script en la VM (decisión final con datos reales del servidor)' {
    BeforeAll {
        # stubs de los comandos de Windows/IIS que no existen en Linux
        $script:Estado = 'Stopped'; $script:Health = @(503); $script:Eventos = New-Object System.Collections.Generic.List[object]
        function global:Get-WebAppPoolState { param($Name) [pscustomobject]@{ Value = $script:Estado } }
        function global:Start-WebAppPool { param($Name) $script:Estado = 'Started'; $script:Inicios++ }
        function global:Get-WinEvent { param($FilterHashtable, $ErrorAction) @() }
        function global:Write-EventLog { param($LogName, $Source, $EventId, $EntryType, $Message) $script:Eventos.Add([pscustomobject]@{ Id = $EventId; Msg = $Message }) }
        function global:Start-Sleep { param($Seconds) }
        function global:Invoke-WebRequest {
            param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
            $c = if ($script:Health.Count -gt 1) { $s = $script:Health[0]; $script:Health = $script:Health[1..($script:Health.Count - 1)]; $s } else { $script:Health[0] }
            if ($c -eq 200) { return [pscustomobject]@{ StatusCode = 200 } }
            throw "HTTP $c"
        }
        $script:Sb = [scriptblock]::Create($ScriptVm)
    }
    BeforeEach { $script:Eventos.Clear(); $script:Inicios = 0 }
    AfterAll { 'Get-WebAppPoolState', 'Start-WebAppPool', 'Get-WinEvent', 'Write-EventLog', 'Start-Sleep', 'Invoke-WebRequest' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue } }

    It 'pool detenido => lo inicia, verifica /health y registra 3000 + 3001' {
        $script:Estado = 'Stopped'; $script:Health = @(503, 503, 200)
        $r = (& $Sb -AlertId 'abc' | Select-Object -Last 1) | ConvertFrom-Json
        $r.resultado | Should -Be 'Recuperado'; $script:Inicios | Should -Be 1
        $script:Eventos.Id | Should -Be @(3000, 3001)
    }
    It 'pool Started y /health 200 => no hace nada (falso positivo)' {
        $script:Estado = 'Started'; $script:Health = @(200)
        ((& $Sb | Select-Object -Last 1) | ConvertFrom-Json).resultado | Should -Be 'SinAccion'
        $script:Inicios | Should -Be 0
    }
    It 'pool Started pero /health 503 (dependencia caída) => NO reinicia y escala' {
        $script:Estado = 'Started'; $script:Health = @(503)
        ((& $Sb | Select-Object -Last 1) | ConvertFrom-Json).resultado | Should -Be 'Escalar'
        $script:Inicios | Should -Be 0; $script:Eventos.Id | Should -Be @(3003)
    }
    It 'verificar tras reincidencia con el portal ya sano => alerta residual: no escala ni reinicia (caso real del 04-oct)' {
        $script:Estado = 'Started'; $script:Health = @(200)
        ((& $Sb -SoloVerificar 'Reincidencia' | Select-Object -Last 1) | ConvertFrom-Json).resultado | Should -Be 'SinAccion'
        $script:Inicios | Should -Be 0
    }
    It 'verificar tras reincidencia con el pool caído => escala sin reiniciar' {
        $script:Estado = 'Stopped'; $script:Health = @(503)
        $r = (& $Sb -SoloVerificar 'Reincidencia' | Select-Object -Last 1) | ConvertFrom-Json
        $r.resultado | Should -Be 'Escalar'; $r.motivo | Should -Match 'sigue caído'
        $script:Inicios | Should -Be 0; $script:Eventos.Id | Should -Be @(3003)
    }
    It 'inicia el pool pero nunca responde 200 => Fallido (3002)' {
        $script:Estado = 'Stopped'; $script:Health = @(503)
        ((& $Sb | Select-Object -Last 1) | ConvertFrom-Json).resultado | Should -Be 'Fallido'
        $script:Eventos.Id | Should -Contain 3002
    }
}
