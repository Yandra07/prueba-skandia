<#
.SYNOPSIS
    Valida sintaxis y semántica de las consultas KQL (archivo .kql, alertas y workbook) contra el esquema real
    de las tablas de Log Analytics, usando el parser oficial Microsoft.Azure.Kusto.Language (sin conectarse a Azure).
.EXAMPLE
    ./tests/Test-Kql.ps1 -Dll /opt/kusto/pkg/lib/netstandard2.0/Kusto.Language.dll
#>
param(
    [Parameter(Mandatory)][string]$Dll,
    [string]$Raiz = (Split-Path -Parent $PSScriptRoot)
)
Add-Type -Path $Dll
$K = 'Kusto.Language'
function Tabla([string]$nombre, [hashtable]$cols) {
    $c = foreach ($k in $cols.Keys) {
        $t = switch ($cols[$k]) { 'string' { [Kusto.Language.Symbols.ScalarTypes]::String } 'int' { [Kusto.Language.Symbols.ScalarTypes]::Int }
            'long' { [Kusto.Language.Symbols.ScalarTypes]::Long } 'real' { [Kusto.Language.Symbols.ScalarTypes]::Real }
            'datetime' { [Kusto.Language.Symbols.ScalarTypes]::DateTime } 'guid' { [Kusto.Language.Symbols.ScalarTypes]::Guid } 'dynamic' { [Kusto.Language.Symbols.ScalarTypes]::Dynamic } }
        New-Object Kusto.Language.Symbols.ColumnSymbol($k, $t)
    }
    New-Object Kusto.Language.Symbols.TableSymbol($nombre, [Kusto.Language.Symbols.ColumnSymbol[]]$c)
}
# Esquemas según learn.microsoft.com/azure/azure-monitor/reference/tables (solo columnas relevantes)
$tablas = @(
    (Tabla 'W3CIISLog' @{ TimeGenerated = 'datetime'; Computer = 'string'; csUriStem = 'string'; csMethod = 'string'; csUriQuery = 'string'; scStatus = 'string'; scSubStatus = 'string'; scWin32Status = 'string'; TimeTaken = 'long'; sSiteName = 'string'; cIP = 'string'; csUserAgent = 'string'; _ResourceId = 'string' }),
    (Tabla 'Event' @{ TimeGenerated = 'datetime'; Computer = 'string'; Source = 'string'; EventID = 'int'; EventLevelName = 'string'; EventLog = 'string'; RenderedDescription = 'string'; _ResourceId = 'string' }),
    (Tabla 'Perf' @{ TimeGenerated = 'datetime'; Computer = 'string'; ObjectName = 'string'; CounterName = 'string'; InstanceName = 'string'; CounterValue = 'real'; _ResourceId = 'string' }),
    (Tabla 'Heartbeat' @{ TimeGenerated = 'datetime'; Computer = 'string'; _ResourceId = 'string' }),
    (Tabla 'AzureDiagnostics' @{ TimeGenerated = 'datetime'; ResourceProvider = 'string'; Category = 'string'; RunbookName_s = 'string'; ResultType = 'string'; StreamType_s = 'string'; ResultDescription = 'string'; JobId_g = 'string'; _ResourceId = 'string' })
)
$db = New-Object Kusto.Language.Symbols.DatabaseSymbol('law', [Kusto.Language.Symbols.Symbol[]]$tablas)
$globals = [Kusto.Language.GlobalState]::Default.WithDatabase($db)

function Test-Consulta([string]$origen, [string]$q) {
    $code = [Kusto.Language.KustoCode]::ParseAndAnalyze($q, $globals)
    $d = @($code.GetDiagnostics() | Where-Object { $_.Severity -eq 'Error' })
    [pscustomobject]@{ Origen = $origen; Errores = $d.Count; Detalle = ($d | ForEach-Object { $_.Message + ' @' + $q.Substring($_.Start, [math]::Min(40, $q.Length - $_.Start)).Replace("`n", ' ') }) -join ' | ' }
}
$res = New-Object System.Collections.Generic.List[object]
# 1) archivo de consultas: bloques separados por línea en blanco tras ';'
$txt = Get-Content (Join-Path $Raiz 'kql/consultas.kql') -Raw
$bloques = [regex]::Split($txt, ";\s*\r?\n\s*\r?\n") | ForEach-Object { ($_ -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" } | Where-Object { $_.Trim() }
$i = 0; foreach ($b in $bloques) { $i++; $res.Add((Test-Consulta "consultas.kql#$i" $b.Trim().TrimEnd(';'))) }
# 2) consultas de alertas y workbook (si existen)
$al = Join-Path $Raiz 'infra/alertas.json'
if (Test-Path $al) { foreach ($a in (Get-Content $al -Raw | ConvertFrom-Json)) { $res.Add((Test-Consulta "alerta:$($a.nombre)" $a.consulta)) } }
$wb = Join-Path $Raiz 'infra/workbook.json'
if (Test-Path $wb) {
    $j = Get-Content $wb -Raw | ConvertFrom-Json
    function Recorre($n) { if ($n -is [System.Array]) { $n | ForEach-Object { Recorre $_ } } elseif ($n -is [pscustomobject]) {
        if ($n.PSObject.Properties.Name -contains 'query' -and $n.query -is [string] -and $n.queryType -eq 0) { $script:qs += , @($n.title, $n.query) }
        $n.PSObject.Properties | ForEach-Object { Recorre $_.Value } } }
    $script:qs = @(); Recorre $j
    foreach ($q in $script:qs) { $res.Add((Test-Consulta "workbook:$($q[0])" ($q[1] -replace '\{TimeRange\}', 'ago(1d)'))) }
}
$res | Format-Table -AutoSize -Wrap | Out-String -Width 220
$tot = ($res | Measure-Object Errores -Sum).Sum
"Consultas: $($res.Count) · con errores: $(@($res | Where-Object Errores).Count)"
exit [int]($tot -gt 0)
