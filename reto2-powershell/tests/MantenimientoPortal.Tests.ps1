#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
<#
    Pruebas del mantenimiento (Pester 5). Corren en Windows PowerShell 5.1 y en PowerShell 7 (Windows o Linux).
    Usan carpetas temporales de TestDrive y simulan servicios, pool y disco: no tocan el sistema real.

        Invoke-Pester -Path .\tests -Output Detailed
#>

BeforeAll {
    # Carpeta de trabajo de las pruebas. Por defecto TestDrive. Si se ejecuta como SYSTEM (Run Command en Azure),
    # Windows ubica el temporal en C:\Windows\SystemTemp y las salvaguardas del módulo se niegan, con razón, a borrar
    # bajo C:\Windows: en ese caso se define PRUEBAS_RAIZ con otra carpeta.
    $script:Tmp = if ($env:PRUEBAS_RAIZ) { Join-Path $env:PRUEBAS_RAIZ ([guid]::NewGuid().ToString('N')) } else { $TestDrive }
    New-Item -ItemType Directory -Path $script:Tmp -Force | Out-Null
    $script:Raiz = Split-Path -Parent $PSScriptRoot
    $script:Script = Join-Path $Raiz 'src/Invoke-MantenimientoPortalPagos.ps1'
    Import-Module (Join-Path $Raiz 'src/MantenimientoPortal/MantenimientoPortal.psd1') -Force
    $script:Exe = (Get-Process -Id $PID).Path   # pwsh o powershell, el mismo que ejecuta las pruebas

    function New-Escenario {
        <# Kit de prueba: logs IIS de distintas edades, share de auditoría vacío, dumps y logs de app. #>
        param([string]$Base)
        $e = [pscustomobject]@{
            Base = $Base
            Iis  = Join-Path $Base 'inetpub/logs/LogFiles'
            Aud  = Join-Path $Base 'auditoria/WEB-PAGOS-01'
            App  = Join-Path $Base 'portal/app/logs'
            Dmp  = Join-Path $Base 'crash/CrashDumps'
            Log  = Join-Path $Base 'programdata/mant/logs'
        }
        foreach ($d in $e.Iis, $e.Aud, $e.App, $e.Dmp) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
        New-Item -ItemType Directory -Path (Join-Path $e.Iis 'W3SVC2') -Force | Out-Null
        foreach ($dias in 0, 3, 13, 15, 30) {
            $f = Join-Path $e.Iis ("W3SVC2/u_ex{0:D2}.log" -f $dias)
            Set-Content -LiteralPath $f -Value ("linea de log hace $dias dias " * 50)
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$dias).AddHours(-3)
        }
        foreach ($dias in 1, 8, 20) {
            $f = Join-Path $e.App ("portal-{0:D2}.log" -f $dias); Set-Content $f "debug $dias"
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$dias)
        }
        foreach ($dias in 1, 2, 20, 21, 22, 23, 24, 25, 26) {
            $f = Join-Path $e.Dmp ("w3wp.exe.{0}.dmp" -f (1000 + $dias)); Set-Content $f "dump"
            (Get-Item $f).LastWriteTime = (Get-Date).AddDays(-$dias)
        }
        $e
    }

    function Invoke-Escenario {
        param($E, [switch]$WhatIf, [hashtable]$Extra = @{})
        # OmitirEvento: en Windows las pruebas no deben escribir en el registro Application real
        $p = @{ RutaLogsIis = $E.Iis; RutaAuditoria = $E.Aud; RutasLogsApp = @($E.App); RutaDumps = $E.Dmp
            NombreServicio = ''; NombrePool = ''; RutaLog = $E.Log; UmbralDiscoAvisoPct = 2; UmbralDiscoCriticoPct = 1; OmitirEvento = $true }
        foreach ($k in $Extra.Keys) { $p[$k] = $Extra[$k] }
        Invoke-Mantenimiento @p -WhatIf:$WhatIf
    }

    # En Linux no existen Get-Service/Start-Service: se crean stubs para poder simularlos (en Windows se usan los reales + Mock)
    if (-not (Get-Command Get-Service -ErrorAction SilentlyContinue)) {
        function global:Get-Service { param([string]$Name, $ErrorAction) }
        function global:Start-Service { param([string]$Name, $ErrorAction) }
    }

    function Get-LogJson { param($E) Get-ChildItem $E.Log -Filter *.jsonl | Get-Content | ForEach-Object { $_ | ConvertFrom-Json } }

    function Invoke-ScriptProceso {
        <# Ejecuta el script en un proceso nuevo y devuelve el código de salida real.
           Start-Process + comillas explícitas: en Windows PowerShell 5.1 "& exe ''" descarta los argumentos vacíos
           y convierte el stderr nativo en excepciones. #>
        param([string[]]$Argumentos)
        $q = ($Argumentos | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
        $o = Join-Path $Tmp ("out-" + [guid]::NewGuid().ToString('N'))
        $p = Start-Process -FilePath $Exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" $q" -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput "$o.out" -RedirectStandardError "$o.err"
        $p.ExitCode
    }
}

Describe 'Salvaguardas de rutas' {
    BeforeAll { Initialize-MantLog -RutaLog (Join-Path $Tmp ('log-' + [guid]::NewGuid())) | Out-Null }
    It 'rechaza ruta vacía e inexistente' {
        Test-RutaSegura -Ruta '' | Should -BeFalse
        Test-RutaSegura -Ruta (Join-Path $Tmp 'no-existe') | Should -BeFalse
    }
    # Las reglas de profundidad son lógica de rutas: se simula que la carpeta existe en lugar de crearla en la raíz
    # del disco (en macOS la raíz es de solo lectura y en Windows la prueba ensuciaría C:\).
    It 'rechaza la raíz de la unidad y una carpeta de un solo nivel' {
        Mock -ModuleName MantenimientoPortal Test-Path { $true } -ParameterFilter { $PathType -eq 'Container' }
        $raiz = [System.IO.Path]::GetPathRoot($Tmp)
        Test-RutaSegura -Ruta $raiz | Should -BeFalse
        Test-RutaSegura -Ruta (Join-Path $raiz 'logs') | Should -BeFalse
    }
    It 'volcados: acepta una carpeta de primer nivel como C:\CrashDumps, pero nunca la raíz' {
        Mock -ModuleName MantenimientoPortal Test-Path { $true } -ParameterFilter { $PathType -eq 'Container' }
        $raiz = [System.IO.Path]::GetPathRoot($Tmp)
        Test-RutaSegura -Ruta (Join-Path $raiz 'CrashDumps') -ProfundidadMinima 1 | Should -BeTrue
        Test-RutaSegura -Ruta $raiz -ProfundidadMinima 1 | Should -BeFalse
    }
    It 'acepta una carpeta de logs anidada' {
        $d = Join-Path $Tmp 'a/b/logs'; New-Item -ItemType Directory $d -Force | Out-Null
        Test-RutaSegura -Ruta $d | Should -BeTrue
    }
    It 'Invoke-PurgaArchivos no borra nada si la ruta es insegura (el caso %LOGDIR% vacío del .BAT)' {
        $r = Invoke-PurgaArchivos -Paso 't' -Ruta '' -Dias 7
        $r.Estado | Should -Be 'Error'
    }
}

Describe 'Modo simulación (-WhatIf)' {
    It 'no copia, no borra y deja registro de la simulación' {
        $e = New-Escenario (Join-Path $Tmp 'whatif')
        $antes = @(Get-ChildItem $e.Base -Recurse -File).Count
        $r = Invoke-Escenario $e -WhatIf
        @(Get-ChildItem $e.Aud -Recurse -File).Count | Should -Be 0
        @(Get-ChildItem $e.Base -Recurse -File | Where-Object Extension -ne '.jsonl').Count | Should -Be $antes
        (Get-LogJson $e | Select-Object -First 1).simulacion | Should -BeTrue
        $r.CodigoSalida | Should -Be 0
        ($r.Resultados | Where-Object Paso -eq 'archivado-auditoria').Datos.Copiados | Should -Be 0
    }
}

Describe 'Archivado y purga de logs IIS' {
    BeforeAll {
        $script:E = New-Escenario (Join-Path $Tmp 'normal')
        $script:R1 = Invoke-Escenario $E
    }
    It 'archiva todos los logs cerrados con hash idéntico' {
        foreach ($f in Get-ChildItem $E.Iis -Recurse -File) {
            $dst = Join-Path $E.Aud ($f.FullName.Substring($E.Iis.Length + 1))
            (Get-FileHash $dst).Hash | Should -Be (Get-FileHash $f.FullName).Hash
        }
        @(Get-ChildItem $E.Aud -Recurse -File).Count | Should -Be 5
    }
    It 'borra localmente solo lo que supera la retención (14 días) y está archivado' {
        (Get-ChildItem (Join-Path $E.Iis 'W3SVC2')).Name | Sort-Object | Should -Be @('u_ex00.log', 'u_ex03.log', 'u_ex13.log')
    }
    It 'no deja archivos .partial' {
        @(Get-ChildItem $E.Aud -Recurse -Filter '*.partial').Count | Should -Be 0
    }
    It 'termina con código 0' { $R1.CodigoSalida | Should -Be 0 }
}

Describe 'Idempotencia' {
    It 'una segunda ejecución no copia ni borra nada y vuelve a dar 0' {
        $e = New-Escenario (Join-Path $Tmp 'idem')
        Invoke-Escenario $e | Out-Null
        $foto = Get-ChildItem $e.Base -Recurse -File | Where-Object Extension -ne '.jsonl' | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        $r2 = Invoke-Escenario $e
        $foto2 = Get-ChildItem $e.Base -Recurse -File | Where-Object Extension -ne '.jsonl' | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }
        $foto2 | Should -Be $foto
        $r2.CodigoSalida | Should -Be 0
        ($r2.Resultados | Where-Object Paso -eq 'archivado-auditoria').Datos.Copiados | Should -Be 0
    }
}

Describe 'Share de auditoría caído' {
    It 'no purga ningún log IIS y termina en Error (3)' {
        $e = New-Escenario (Join-Path $Tmp 'sinshare')
        Remove-Item $e.Aud -Recurse -Force
        $r = Invoke-Escenario $e
        @(Get-ChildItem $e.Iis -Recurse -File).Count | Should -Be 5
        $r.CodigoSalida | Should -Be 3
        ($r.Resultados | Where-Object Paso -eq 'purga-logs-iis').Datos.RetenidosSinArchivar | Should -Be 2
    }
    It 'si la copia en auditoría está corrupta, la detecta, la recopia y solo entonces purga (Aviso)' {
        $e = New-Escenario (Join-Path $Tmp 'corrupto')
        Invoke-Escenario $e -WhatIf | Out-Null
        # copia "archivada" con mismo tamaño y fecha pero distinto contenido
        $src = Get-Item (Join-Path $e.Iis 'W3SVC2/u_ex30.log')
        $dst = Join-Path $e.Aud 'W3SVC2/u_ex30.log'; New-Item -ItemType Directory (Split-Path $dst) -Force | Out-Null
        [IO.File]::WriteAllBytes($dst, [byte[]]::new($src.Length)); (Get-Item $dst).LastWriteTimeUtc = $src.LastWriteTimeUtc
        $hashOriginal = (Get-FileHash $src.FullName).Hash
        $r = Invoke-Escenario $e
        (Get-FileHash $dst).Hash | Should -Be $hashOriginal
        Test-Path $src.FullName | Should -BeFalse
        ($r.Resultados | Where-Object Paso -eq 'archivado-auditoria').Datos.Corruptos | Should -Be 1
        $r.CodigoSalida | Should -Be 2
    }
}

Describe 'Logs abiertos por IIS (caso real de la VM, 02 al 04-oct)' {
    It 'un log en uso no es un error: no se copia, no se purga y se archivará después' {
        $e = New-Escenario (Join-Path $Tmp 'enuso')
        Mock -ModuleName MantenimientoPortal Test-ArchivoEnUso { $true } -ParameterFilter { $Ruta -like '*u_ex00.log' }
        $r = Invoke-Escenario $e
        $a = $r.Resultados | Where-Object Paso -eq 'archivado-auditoria'
        $a.Estado | Should -Be 'OK'; $a.Datos.EnUso | Should -Be 1
        Test-Path (Join-Path $e.Aud 'W3SVC2/u_ex00.log') | Should -BeFalse
        Test-Path (Join-Path $e.Iis 'W3SVC2/u_ex00.log') | Should -BeTrue
        $r.CodigoSalida | Should -Be 0
    }
    It 'un log de hace días que sigue bloqueado produce Aviso (2)' {
        $e = New-Escenario (Join-Path $Tmp 'enuso-viejo')
        Mock -ModuleName MantenimientoPortal Test-ArchivoEnUso { $true } -ParameterFilter { $Ruta -like '*u_ex13.log' }
        $r = Invoke-Escenario $e
        ($r.Resultados | Where-Object Paso -eq 'archivado-auditoria').Estado | Should -Be 'Aviso'
        $r.CodigoSalida | Should -Be 2
    }
    It 'Test-ArchivoEnUso detecta un archivo abierto sin permiso de lectura (Windows)' -Skip:(-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') {
        $f = Join-Path $Tmp 'bloqueado.log'; Set-Content $f 'x'
        $fs = [IO.File]::Open($f, 'Open', 'ReadWrite', 'None')
        try { Test-ArchivoEnUso -Ruta $f | Should -BeTrue } finally { $fs.Dispose() }
        Test-ArchivoEnUso -Ruta $f | Should -BeFalse
    }
}

Describe 'Logs de aplicación y volcados' {
    BeforeAll {
        $script:E2 = New-Escenario (Join-Path $Tmp 'dumps')
        Invoke-Escenario $E2 | Out-Null
    }
    It 'purga logs de app con más de 7 días' {
        (Get-ChildItem $E2.App).Name | Sort-Object | Should -Be @('portal-01.log')
    }
    It 'conserva los 5 volcados más recientes y nunca borra los de menos de 14 días' {
        $quedan = (Get-ChildItem $E2.Dmp).Name | Sort-Object
        $quedan | Should -Be @('w3wp.exe.1001.dmp', 'w3wp.exe.1002.dmp', 'w3wp.exe.1020.dmp', 'w3wp.exe.1021.dmp', 'w3wp.exe.1022.dmp')
    }
    It 'un volcado bloqueado da Error pero no aborta los pasos siguientes' {
        $e = New-Escenario (Join-Path $Tmp 'dump-bloqueado')
        Mock -ModuleName MantenimientoPortal Remove-Item { throw 'El archivo está en uso' } -ParameterFilter { $LiteralPath -like '*w3wp.exe.1026.dmp' }
        $r = Invoke-Escenario $e
        $d = $r.Resultados | Where-Object Paso -eq 'retencion-dumps'
        $d.Estado | Should -Be 'Error'
        $d.Datos.Borrados | Should -Be 3
        Test-Path (Join-Path $e.Dmp 'w3wp.exe.1026.dmp') | Should -BeTrue
        $r.Resultados.Paso | Should -Contain 'disco-final'
        $r.CodigoSalida | Should -Be 3
    }
}

Describe 'Presión de disco (logs de app en Debug, riesgo R1 del Reto 1)' {
    BeforeAll {
        Initialize-MantLog -RutaLog (Join-Path $Tmp ('log-' + [guid]::NewGuid())) | Out-Null
        function New-LogsApp {
            <# 4 logs de app de 1 MB: de hace 5 h, 2, 3 y 5 días #>
            param([string]$Base)
            New-Item -ItemType Directory -Path $Base -Force | Out-Null
            foreach ($h in 5, 48, 72, 120) {
                $f = Join-Path $Base ("portal-{0:D3}h.log" -f $h)
                [IO.File]::WriteAllBytes($f, [byte[]]::new(1MB))
                (Get-Item $f).LastWriteTime = (Get-Date).AddHours(-$h)
            }
            $Base
        }
    }
    BeforeEach {
        # disco de 100 MB con 10 MB libres (10 %): cada log borrado suma 1 punto porcentual
        Mock -ModuleName MantenimientoPortal Get-EspacioLibre { [pscustomobject]@{ Unidad = 'C:\'; LibreMB = 10; TotalMB = 100; LibrePct = 10 } }
    }
    It 'borra del más viejo al más nuevo solo hasta recuperar el umbral' {
        $d = New-LogsApp (Join-Path $Tmp 'presion/a/logs')
        $r = Invoke-PurgaPorPresion -Ruta $d -UmbralPct 12 -DiasMinimos 1
        (Get-ChildItem $d).Name | Sort-Object | Should -Be @('portal-005h.log', 'portal-048h.log')
        $r.Estado | Should -Be 'Aviso'
        $r.Datos.Recuperado | Should -BeTrue
    }
    It 'nunca baja del piso de días, aunque no alcance el umbral' {
        $d = New-LogsApp (Join-Path $Tmp 'presion/b/logs')
        $r = Invoke-PurgaPorPresion -Ruta $d -UmbralPct 50 -DiasMinimos 1
        (Get-ChildItem $d).Name | Should -Be @('portal-005h.log')
        $r.Datos.Recuperado | Should -BeFalse
        $r.Estado | Should -Be 'Aviso'
    }
    It 'sin presión no borra nada' {
        Mock -ModuleName MantenimientoPortal Get-EspacioLibre { [pscustomobject]@{ Unidad = 'C:\'; LibreMB = 30; TotalMB = 100; LibrePct = 30 } }
        $d = New-LogsApp (Join-Path $Tmp 'presion/c/logs')
        (Invoke-PurgaPorPresion -Ruta $d -UmbralPct 20).Estado | Should -Be 'OK'
        @(Get-ChildItem $d).Count | Should -Be 4
    }
    It 'en -WhatIf no borra, pero informa hasta dónde llegaría' {
        $d = New-LogsApp (Join-Path $Tmp 'presion/d/logs')
        $r = Invoke-PurgaPorPresion -Ruta $d -UmbralPct 12 -WhatIf
        @(Get-ChildItem $d).Count | Should -Be 4
        $r.Datos.Borrados | Should -Be 2
    }
    It 'nunca toca los logs IIS ni los volcados recientes' {
        Mock -ModuleName MantenimientoPortal Get-EspacioLibre { [pscustomobject]@{ Unidad = 'C:\'; LibreMB = 1; TotalMB = 100; LibrePct = 1 } }
        $e = New-Escenario (Join-Path $Tmp 'presion-total')
        $r = Invoke-Escenario $e -Extra @{ UmbralDiscoAvisoPct = 99; UmbralDiscoCriticoPct = 98 }
        ($r.Resultados | Where-Object Paso -eq 'purga-presion-disco').Estado | Should -Be 'Aviso'
        (Get-ChildItem (Join-Path $e.Iis 'W3SVC2')).Name | Sort-Object | Should -Be @('u_ex00.log', 'u_ex03.log', 'u_ex13.log')
        (Get-ChildItem $e.Dmp).Name | Should -Contain 'w3wp.exe.1001.dmp'
        @(Get-ChildItem $e.Dmp).Count | Should -Be 5
    }
}

Describe 'Servicio de notificaciones (sin reinicio ciego)' {
    BeforeAll { Initialize-MantLog -RutaLog (Join-Path $Tmp ('log-' + [guid]::NewGuid())) | Out-Null }
    It 'si está en ejecución no hace nada' {
        Mock -ModuleName MantenimientoPortal Get-Service { [pscustomobject]@{ Status = 'Running'; StartType = 'Automatic' } }
        Mock -ModuleName MantenimientoPortal Start-Service { }
        (Assert-ServicioEnEjecucion -Nombre 'X').Estado | Should -Be 'OK'
        Should -Invoke -ModuleName MantenimientoPortal Start-Service -Times 0
    }
    It 'si está detenido lo inicia y avisa' {
        Mock -ModuleName MantenimientoPortal Get-Service { [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
        Mock -ModuleName MantenimientoPortal Start-Service { }
        (Assert-ServicioEnEjecucion -Nombre 'X').Estado | Should -Be 'Aviso'
        Should -Invoke -ModuleName MantenimientoPortal Start-Service -Times 1
    }
    It 'si está deshabilitado no lo toca' {
        Mock -ModuleName MantenimientoPortal Get-Service { [pscustomobject]@{ Status = 'Stopped'; StartType = 'Disabled' } }
        Mock -ModuleName MantenimientoPortal Start-Service { }
        (Assert-ServicioEnEjecucion -Nombre 'X').Estado | Should -Be 'Aviso'
        Should -Invoke -ModuleName MantenimientoPortal Start-Service -Times 0
    }
    It 'en -WhatIf no inicia el servicio' {
        Mock -ModuleName MantenimientoPortal Get-Service { [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
        Mock -ModuleName MantenimientoPortal Start-Service { }
        Assert-ServicioEnEjecucion -Nombre 'X' -WhatIf | Out-Null
        Should -Invoke -ModuleName MantenimientoPortal Start-Service -Times 0
    }
    It 'si falla al iniciar devuelve Error' {
        Mock -ModuleName MantenimientoPortal Get-Service { [pscustomobject]@{ Status = 'Stopped'; StartType = 'Automatic' } }
        Mock -ModuleName MantenimientoPortal Start-Service { throw 'acceso denegado' }
        (Assert-ServicioEnEjecucion -Nombre 'X').Estado | Should -Be 'Error'
    }
}

Describe 'Disco y pool' {
    It 'disco por debajo del umbral crítico produce Error (3): la señal que faltó antes del 22-sep' {
        Mock -ModuleName MantenimientoPortal Get-EspacioLibre { [pscustomobject]@{ Unidad = 'C:\'; LibreMB = 11172; TotalMB = 122265; LibrePct = 9.1 } }
        $e = New-Escenario (Join-Path $Tmp 'disco')
        $r = Invoke-Escenario $e -Extra @{ UmbralDiscoAvisoPct = 20; UmbralDiscoCriticoPct = 10 }
        $r.CodigoSalida | Should -Be 3
        ($r.Resultados | Where-Object Paso -eq 'purga-presion-disco').Estado | Should -Be 'Aviso'
    }
    It 'pool detenido produce Aviso y no intenta reiniciarlo' {
        Initialize-MantLog -RutaLog (Join-Path $Tmp 'log-pool') | Out-Null
        Mock -ModuleName MantenimientoPortal Get-EstadoPool { 'Stopped' }
        (Test-EstadoPool -Nombre 'PortalPagosPool').Estado | Should -Be 'Aviso'
    }
}

Describe 'Ejecución única' {
    It 'si otra ejecución tiene el candado, sale con 4 sin tocar nada' {
        $e = New-Escenario (Join-Path $Tmp 'lock')
        New-Item -ItemType Directory $e.Log -Force | Out-Null
        $fs = [IO.File]::Open((Join-Path $e.Log 'mantenimiento.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try {
            $r = Invoke-Escenario $e
            $r.CodigoSalida | Should -Be 4
            @(Get-ChildItem $e.Aud -Recurse -File).Count | Should -Be 0
        } finally { $fs.Dispose() }
    }
}

Describe 'Log estructurado' {
    It 'cada línea es JSON válido con los campos obligatorios y un único runId por ejecución' {
        $e = New-Escenario (Join-Path $Tmp 'log')
        Invoke-Escenario $e | Out-Null
        $l = @(Get-LogJson $e)
        $l.Count | Should -BeGreaterThan 5
        foreach ($x in $l) { foreach ($c in 'ts', 'host', 'runId', 'nivel', 'paso', 'mensaje') { $x.PSObject.Properties.Name | Should -Contain $c } }
        @($l.runId | Select-Object -Unique).Count | Should -Be 1
        $l[-1].paso | Should -Be 'fin'
        $l[-1].datos.codigoSalida | Should -Be 0
    }
}

Describe 'Script de entrada: códigos de salida reales del proceso' {
    It 'parámetro inválido => 1' {
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-DiasRetencionIis', '0') | Should -Be 1
    }
    It 'umbral crítico mayor que aviso => 1' {
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-UmbralDiscoAvisoPct', '10', '-UmbralDiscoCriticoPct', '20') | Should -Be 1
    }
    It 'nombre de pool o servicio con caracteres no válidos, o ruta de volcados relativa => 1' {
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-NombrePool', 'Pool;Remove-Item') | Should -Be 1
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-NombreServicio', 'svc|malo') | Should -Be 1
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-RutaDumps', 'relativa/dumps') | Should -Be 1
    }
    It 'piso de presión mayor que la retención de app => 1' {
        Invoke-ScriptProceso @('-RutaLogsIis', $Tmp, '-DiasRetencionApp', '3', '-DiasMinimosApp', '5') | Should -Be 1
    }
    It 'ejecución normal => 0, y share caído => 3' {
        $e = New-Escenario (Join-Path $Tmp 'proc')
        $comun = @('-RutaLogsIis', $e.Iis, '-RutaDumps', $e.Dmp, '-NombreServicio', '', '-NombrePool', '',
            '-RutaLog', $e.Log, '-UmbralDiscoAvisoPct', '5', '-UmbralDiscoCriticoPct', '1', '-OmitirEvento')
        Invoke-ScriptProceso ($comun + @('-RutaAuditoria', $e.Aud)) | Should -Be 0
        Invoke-ScriptProceso ($comun + @('-RutaAuditoria', (Join-Path $e.Base 'share-caido'))) | Should -Be 3
    }
}

Describe 'Seguridad del código' {
    It 'no contiene credenciales ni net use' {
        $codigo = (Get-ChildItem (Join-Path $Raiz 'src') -Recurse -Include *.ps1, *.psm1, *.psd1 | Get-Content -Raw) -join "`n"
        $codigo | Should -Not -Match '(?i)net\s+use|/user:|ConvertTo-SecureString\s+.+-AsPlainText|password\s*=\s*[''"]'
        # la contraseña (ficticia) del .BAT se arma por partes para no dejarla literal en el repositorio
        $codigo | Should -Not -Match ('Andina' + '2019')
    }
}

AfterAll {
    if ($env:PRUEBAS_RAIZ -and $script:Tmp -and (Test-Path $script:Tmp)) { Remove-Item $script:Tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
