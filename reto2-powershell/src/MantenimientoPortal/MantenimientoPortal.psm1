#Requires -Version 5.1
<#
    MantenimientoPortal — funciones del mantenimiento diario de WEB-PAGOS-01.
    Compatible con Windows PowerShell 5.1 y PowerShell 7.

    Reemplaza a C:\scripts\mantenimiento_diario.bat (2019). Ver PROBLEMAS_Y_DECISIONES.md.
    Cada paso devuelve un objeto de resultado. El código de salida se calcula con el peor resultado:
        0 = OK · 2 = Aviso · 3 = Error · 4 = Otra ejecución en curso (candado)
        1 = Parámetros inválidos o no se pudo iniciar (PowerShell ya devuelve 1 cuando falla la validación
            de parámetros, así que se reserva para eso y nunca se confunde con un aviso)
#>

Set-StrictMode -Version 3.0

$script:Codigo = @{ OK = 0; Omitido = 0; Aviso = 2; Error = 3; Precondicion = 4 }
$script:Contexto = $null

# ------------------------------------------------------------------ utilidades mockeables
function Get-Ahora {
    <#
    .SYNOPSIS
        Hora actual (envoltura para poder simularla en pruebas).
    #>
    [CmdletBinding()]
    param()
    Get-Date
}

function Get-EspacioLibre {
    <#
    .SYNOPSIS
        Devuelve LibreMB / TotalMB / LibrePct de la unidad que contiene la ruta (Windows y Linux).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Ruta)
    $full = [System.IO.Path]::GetFullPath($Ruta)
    $drive = [System.IO.DriveInfo]::GetDrives() |
        Where-Object { $_.IsReady -and $full.StartsWith($_.RootDirectory.FullName, [StringComparison]::OrdinalIgnoreCase) } |
        Sort-Object { $_.RootDirectory.FullName.Length } -Descending | Select-Object -First 1
    if (-not $drive) { throw "No se encontró la unidad de '$Ruta'." }
    [pscustomobject]@{
        Unidad   = $drive.Name
        LibreMB  = [math]::Round($drive.AvailableFreeSpace / 1MB, 0)
        TotalMB  = [math]::Round($drive.TotalSize / 1MB, 0)
        LibrePct = [math]::Round(100.0 * $drive.AvailableFreeSpace / $drive.TotalSize, 2)
    }
}

function Get-EstadoPool {
    <#
    .SYNOPSIS
        Estado del application pool. Devuelve $null si el módulo WebAdministration no está disponible.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Nombre)
    if (-not (Get-Module -ListAvailable -Name WebAdministration)) { return $null }
    Import-Module WebAdministration -ErrorAction Stop
    (Get-WebAppPoolState -Name $Nombre -ErrorAction Stop).Value
}

# ------------------------------------------------------------------ log estructurado
function Initialize-MantLog {
    <#
    .SYNOPSIS
        Crea el contexto de ejecución y el archivo de log JSONL del día.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RutaLog,
        [switch]$Simulacion
    )
    if (-not (Test-Path -LiteralPath $RutaLog)) {
        # el log se crea incluso en -WhatIf: registrar la simulación es parte de la evidencia
        New-Item -ItemType Directory -Path $RutaLog -Force -WhatIf:$false | Out-Null
    }
    $ahora = Get-Ahora
    $script:Contexto = [pscustomobject]@{
        RunId      = [guid]::NewGuid().ToString()
        Archivo    = Join-Path $RutaLog ("mantenimiento-{0}.jsonl" -f $ahora.ToString('yyyyMMdd'))
        Simulacion = [bool]$Simulacion
        Inicio     = $ahora
    }
    $script:Contexto
}

function Write-MantLog {
    <#
    .SYNOPSIS
        Una línea JSON por evento: ts, host, runId, simulacion, nivel, paso, mensaje, datos.
    #>
    [CmdletBinding()]
    param(
        [ValidateSet('INFO', 'AVISO', 'ERROR')][string]$Nivel = 'INFO',
        [Parameter(Mandatory)][string]$Paso,
        [Parameter(Mandatory)][string]$Mensaje,
        [hashtable]$Datos = @{}
    )
    $registro = [ordered]@{
        ts         = (Get-Ahora).ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
        host       = [Environment]::MachineName
        runId      = if ($script:Contexto) { $script:Contexto.RunId } else { $null }
        simulacion = if ($script:Contexto) { $script:Contexto.Simulacion } else { $false }
        nivel      = $Nivel
        paso       = $Paso
        mensaje    = $Mensaje
        datos      = $Datos
    }
    $linea = $registro | ConvertTo-Json -Depth 6 -Compress
    if ($script:Contexto) {
        # el log de la simulación también se escribe
        # UTF-8 sin BOM (en 5.1 Add-Content -Encoding UTF8 agrega BOM y ensucia la primera línea para los colectores)
        try {
            [System.IO.File]::AppendAllText($script:Contexto.Archivo, $linea + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            # que falle el log no debe tumbar el mantenimiento; queda en la salida de la tarea
            Write-Warning "No se pudo escribir el log ($($script:Contexto.Archivo)): $($_.Exception.Message) · $linea"
        }
    }
    switch ($Nivel) {
        'ERROR' { Write-Warning "[$Paso] $Mensaje" }
        'AVISO' { Write-Warning "[$Paso] $Mensaje" }
        default { Write-Verbose "[$Paso] $Mensaje" }
    }
}

function New-Resultado {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Solo crea un objeto en memoria')]
    <#
    .SYNOPSIS
        Objeto de resultado de un paso.
    #>
    param([string]$Paso, [ValidateSet('OK', 'Aviso', 'Error', 'Omitido', 'Precondicion')][string]$Estado, [string]$Detalle, [hashtable]$Datos = @{})
    [pscustomobject]@{ Paso = $Paso; Estado = $Estado; Codigo = $script:Codigo[$Estado]; Detalle = $Detalle; Datos = $Datos }
}

function Get-CodigoSalida {
    <#
    .SYNOPSIS
        Código de salida = peor código de los resultados.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Resultados)
    if (-not $Resultados) { return 0 }
    [int](($Resultados | Measure-Object -Property Codigo -Maximum).Maximum)
}

# ------------------------------------------------------------------ salvaguardas
function Test-RutaSegura {
    <#
    .SYNOPSIS
        Una ruta es segura para borrar si existe, es una carpeta, no es la raíz de una unidad,
        tiene al menos 2 niveles de profundidad y no es una carpeta del sistema.
        Evita el caso del .BAT: "del /q /s %LOGDIR%\*.tmp" con %LOGDIR% vacío borra *.tmp en toda la unidad.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ruta,
        # 2 por defecto (logs). Los volcados usan 1 porque WER escribe en C:\CrashDumps; ahí solo se borran *.dmp viejos.
        [ValidateRange(1, 10)][int]$ProfundidadMinima = 2
    )
    if ([string]::IsNullOrWhiteSpace($Ruta)) { return $false }
    if (-not (Test-Path -LiteralPath $Ruta -PathType Container)) { return $false }
    $abs = [System.IO.Path]::GetFullPath($Ruta)
    $root = ([System.IO.Path]::GetPathRoot($abs) + '').TrimEnd('\', '/')
    $full = $abs.TrimEnd('\', '/')
    if ($full -eq $root -or $full -eq '') { return $false }
    $relativa = $full.Substring($root.Length).Trim('\', '/')
    if (($relativa -split '[\\/]').Count -lt $ProfundidadMinima) { return $false }
    $raicesProhibidas = @($env:ProgramData, $env:SystemDrive + '\Users', '/home', '/root') | Where-Object { $_ -and $_ -notmatch '^\\Users$' } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
    if ($raicesProhibidas | Where-Object { $full.Equals($_, [StringComparison]::OrdinalIgnoreCase) }) { return $false }
    $prohibidas = @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:SystemRoot, '/etc', '/usr', '/bin', '/var/lib') |
        Where-Object { $_ } | ForEach-Object { [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/') }
    foreach ($p in $prohibidas) {
        if ($full.Equals($p, [StringComparison]::OrdinalIgnoreCase) -or
            $full.StartsWith($p + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    }
    $true
}

function Enter-Candado {
    <#
    .SYNOPSIS
        Candado de ejecución única: archivo abierto en modo exclusivo. Devuelve el stream (cerrar en finally).
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param([Parameter(Mandatory)][string]$RutaCandado)
    try {
        [System.IO.File]::Open($RutaCandado, 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [System.IO.IOException] {
        $null
    }
}

# ------------------------------------------------------------------ helpers de archivos
function Get-HashArchivo {
    <#
    .SYNOPSIS
        SHA-256 de un archivo.
    #> param([string]$Ruta) (Get-FileHash -LiteralPath $Ruta -Algorithm SHA256).Hash }

function Test-ArchivoEnUso {
    <#
    .SYNOPSIS
        $true si otro proceso tiene el archivo abierto sin permitir lectura (p. ej. IIS con el log del día).
        No se puede confiar en LastWriteTime: en NTFS no se actualiza mientras el archivo sigue abierto, así que el log
        del día parecía "inactivo" y la copia fallaba cada noche (visto en la VM del Reto 3, 02 al 04-oct).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$Ruta)
    try { $s = [System.IO.File]::Open($Ruta, 'Open', 'Read', 'ReadWrite'); $s.Dispose(); $false } catch [System.IO.IOException] { $true }
}

function Get-RutaRelativa {
    <#
    .SYNOPSIS
        Ruta relativa a una base.
    #>
    param([string]$Base, [string]$Ruta)
    $b = [System.IO.Path]::GetFullPath($Base).TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    [System.IO.Path]::GetFullPath($Ruta).Substring($b.Length)
}

# ------------------------------------------------------------------ pasos
function Invoke-ArchivadoAuditoria {
    <#
    .SYNOPSIS
        Copia incremental y verificada de logs cerrados al share de auditoría.
        - Solo copia archivos sin escritura en los últimos -MinutosInactividad (IIS mantiene abierto el del día).
        - Copia a <archivo>.partial, verifica el SHA-256 y luego renombra: una ejecución interrumpida no deja copias corruptas.
        - Si el destino ya tiene el mismo tamaño y fecha, no lo copia de nuevo (idempotente).
        Devuelve un resultado con Datos.Archivados = rutas de origen cuya copia está confirmada en auditoría.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Origen,
        [Parameter(Mandatory)][string]$Destino,
        [string]$Filtro = '*.log',
        [int]$MinutosInactividad = 120,
        # Para archivos que ya están por purgarse no basta tamaño+fecha: se compara el hash y, si difiere, se recopia.
        [int]$VerificarHashSiMasViejoQueDias = 0
    )
    $paso = 'archivado-auditoria'
    if (-not (Test-Path -LiteralPath $Destino -PathType Container)) {
        Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "Destino de auditoría no accesible: $Destino" -Datos @{ destino = $Destino }
        return New-Resultado -Paso $paso -Estado 'Error' -Detalle "Destino de auditoría no accesible" -Datos @{ Archivados = @(); Copiados = 0 }
    }
    $limite = (Get-Ahora).AddMinutes(-$MinutosInactividad)
    $candidatos = @(Get-ChildItem -LiteralPath $Origen -Filter $Filtro -File -Recurse -ErrorAction Stop | Where-Object { $_.LastWriteTime -lt $limite })
    $archivados = New-Object System.Collections.Generic.List[string]
    $copiados = 0; $errores = 0; $bytes = 0; $corruptos = 0; $enUso = 0; $enUsoViejos = 0
    $limiteHash = (Get-Ahora).AddDays(-$VerificarHashSiMasViejoQueDias)
    foreach ($f in $candidatos) {
        if (Test-ArchivoEnUso -Ruta $f.FullName) {
            # sigue abierto (el log del día): no es un error, se archiva en la próxima ejecución. Como no queda archivado,
            # tampoco se purga. Si un log de hace más de 1 día sigue bloqueado, algo raro pasa: Aviso.
            $enUso++
            if ($f.LastWriteTime -lt (Get-Ahora).AddDays(-1)) {
                $enUsoViejos++
                Write-MantLog -Nivel AVISO -Paso $paso -Mensaje "$($f.Name) lleva más de 1 día bloqueado por otro proceso: no se archiva" -Datos @{ archivo = $f.Name }
            } else {
                Write-MantLog -Paso $paso -Mensaje "$($f.Name) sigue abierto (en uso): se archivará en la próxima ejecución" -Datos @{ archivo = $f.Name }
            }
            continue
        }
        $rel = Get-RutaRelativa -Base $Origen -Ruta $f.FullName
        $dst = Join-Path $Destino $rel
        if ((Test-Path -LiteralPath $dst) -and ((Get-Item -LiteralPath $dst).Length -eq $f.Length) -and
            ((Get-Item -LiteralPath $dst).LastWriteTimeUtc -eq $f.LastWriteTimeUtc)) {
            $verificar = $VerificarHashSiMasViejoQueDias -gt 0 -and $f.LastWriteTime -lt $limiteHash
            if (-not $verificar -or (Get-HashArchivo $dst) -eq (Get-HashArchivo $f.FullName)) { $archivados.Add($f.FullName); continue }
            $corruptos++
            Write-MantLog -Nivel AVISO -Paso $paso -Mensaje "La copia en auditoría de $rel no coincide con el original (hash distinto): se recopia" -Datos @{ archivo = $rel }
        }
        if (-not $PSCmdlet.ShouldProcess($dst, "Copiar $($f.Name) a auditoría")) {
            # en simulación se da por archivado para mostrar qué purgaría la corrida real
            if ($WhatIfPreference) { $archivados.Add($f.FullName) }
            continue
        }
        try {
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            $tmp = "$dst.partial"
            Copy-Item -LiteralPath $f.FullName -Destination $tmp -Force -ErrorAction Stop
            if ((Get-HashArchivo $tmp) -ne (Get-HashArchivo $f.FullName)) { throw "El hash no coincide tras copiar" }
            Move-Item -LiteralPath $tmp -Destination $dst -Force -ErrorAction Stop
            (Get-Item -LiteralPath $dst).LastWriteTimeUtc = $f.LastWriteTimeUtc
            $archivados.Add($f.FullName); $copiados++; $bytes += $f.Length
        } catch {
            $errores++
            Remove-Item -LiteralPath "$dst.partial" -Force -ErrorAction SilentlyContinue
            Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "Falló la copia de $($f.FullName): $($_.Exception.Message)"
        }
    }
    $estado = if ($errores) { 'Error' } elseif ($corruptos -or $enUsoViejos) { 'Aviso' } else { 'OK' }
    $datos = @{ EnUso = $enUso; Corruptos = $corruptos; Candidatos = $candidatos.Count; Copiados = $copiados; MB = [math]::Round($bytes / 1MB, 1); Errores = $errores; Archivados = $archivados.ToArray() }
    $datosLog = @{ Candidatos = $candidatos.Count; Copiados = $copiados; MB = $datos.MB; Errores = $errores; Confirmados = $archivados.Count; EnUso = $enUso }
    Write-MantLog -Nivel $(if ($errores) { 'ERROR' } else { 'INFO' }) -Paso $paso -Mensaje "Archivado: $copiados copiados, $($archivados.Count) confirmados, $errores errores" -Datos $datosLog
    New-Resultado -Paso $paso -Estado $estado -Detalle "$copiados copiados, $errores errores" -Datos $datos
}

function Invoke-PurgaArchivos {
    <#
    .SYNOPSIS
        Borra archivos más viejos que -Dias. Con -SoloArchivados, solo borra los que están en -Archivados
        y cuyo hash coincide con la copia de auditoría: un log que no se pudo archivar NUNCA se borra.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Paso,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ruta,
        [Parameter(Mandatory)][ValidateRange(1, 3650)][int]$Dias,
        [string]$Filtro = '*.log',
        [string[]]$Archivados = @(),
        [string]$RaizAuditoria,
        [switch]$SoloArchivados
    )
    if (-not (Test-RutaSegura -Ruta $Ruta)) {
        Write-MantLog -Nivel ERROR -Paso $Paso -Mensaje "Ruta no segura o inexistente para borrar: '$Ruta'"
        return New-Resultado -Paso $Paso -Estado 'Error' -Detalle "Ruta no segura: '$Ruta'"
    }
    $limite = (Get-Ahora).AddDays(-$Dias)
    $vencidos = @(Get-ChildItem -LiteralPath $Ruta -Filter $Filtro -File -Recurse -ErrorAction Stop | Where-Object { $_.LastWriteTime -lt $limite })
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($a in $Archivados) { [void]$set.Add($a) }
    $borrados = 0; $retenidos = 0; $liberado = 0; $errores = 0
    foreach ($f in $vencidos) {
        if ($SoloArchivados) {
            $ok = $set.Contains($f.FullName)
            if ($ok -and $RaizAuditoria -and -not $WhatIfPreference) {
                $dst = Join-Path $RaizAuditoria (Get-RutaRelativa -Base $Ruta -Ruta $f.FullName)
                $ok = (Test-Path -LiteralPath $dst) -and ((Get-HashArchivo $dst) -eq (Get-HashArchivo $f.FullName))
            }
            if (-not $ok) { $retenidos++; continue }
        }
        if ($PSCmdlet.ShouldProcess($f.FullName, "Borrar (antigüedad > $Dias días)")) {
            try {
                $len = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $borrados++; $liberado += $len
            } catch {
                $errores++
                Write-MantLog -Nivel ERROR -Paso $Paso -Mensaje "No se pudo borrar $($f.FullName): $($_.Exception.Message)"
            }
        }
    }
    $estado = if ($errores) { 'Error' } elseif ($retenidos) { 'Aviso' } else { 'OK' }
    $datos = @{ Vencidos = $vencidos.Count; Borrados = $borrados; RetenidosSinArchivar = $retenidos; LiberadoMB = [math]::Round($liberado / 1MB, 1); Errores = $errores }
    $nivel = if ($errores) { 'ERROR' } elseif ($retenidos) { 'AVISO' } else { 'INFO' }
    Write-MantLog -Nivel $nivel -Paso $Paso -Mensaje "Purga: $borrados borrados, $retenidos retenidos por no estar archivados" -Datos $datos
    New-Resultado -Paso $Paso -Estado $estado -Detalle "$borrados borrados, $retenidos retenidos" -Datos $datos
}

function Invoke-RetencionDumps {
    <#
    .SYNOPSIS
        Los volcados son evidencia forense (el del 18-sep es la prueba de la fuga).
        Regla: nunca borrar volcados más nuevos que -DiasMinimos; de los más viejos, conservar los -Conservar más recientes.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [ValidateRange(1, 365)][int]$DiasMinimos = 14,
        [ValidateRange(0, 100)][int]$Conservar = 5
    )
    $paso = 'retencion-dumps'
    if (-not (Test-Path -LiteralPath $Ruta)) {
        Write-MantLog -Paso $paso -Mensaje "Carpeta de volcados inexistente: $Ruta (sin acción)"
        return New-Resultado -Paso $paso -Estado 'OK' -Detalle 'Sin carpeta de volcados'
    }
    if (-not (Test-RutaSegura -Ruta $Ruta -ProfundidadMinima 1)) {
        Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "Ruta de volcados no segura para borrar: '$Ruta'"
        return New-Resultado -Paso $paso -Estado 'Error' -Detalle "Ruta no segura: '$Ruta'"
    }
    $todos = @(Get-ChildItem -LiteralPath $Ruta -Filter '*.dmp' -File | Sort-Object LastWriteTime -Descending)
    $limite = (Get-Ahora).AddDays(-$DiasMinimos)
    $candidatos = @($todos | Select-Object -Skip $Conservar | Where-Object { $_.LastWriteTime -lt $limite })
    $borrados = 0; $liberado = 0; $errores = 0
    foreach ($d in $candidatos) {
        if ($PSCmdlet.ShouldProcess($d.FullName, 'Borrar volcado')) {
            # un volcado bloqueado (p. ej. WER todavía escribiéndolo) no debe abortar los pasos siguientes
            try {
                $len = $d.Length; Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop; $borrados++; $liberado += $len
            } catch {
                $errores++
                Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "No se pudo borrar $($d.FullName): $($_.Exception.Message)"
            }
        }
    }
    $datos = @{ Total = $todos.Count; Borrados = $borrados; Errores = $errores; LiberadoMB = [math]::Round($liberado / 1MB, 1); TotalMB = [math]::Round(($(if ($todos.Count) { ($todos | Measure-Object Length -Sum).Sum } else { 0 })) / 1MB, 1) }
    Write-MantLog -Nivel $(if ($errores) { 'ERROR' } else { 'INFO' }) -Paso $paso -Mensaje "Volcados: $($todos.Count) encontrados, $borrados borrados, $errores errores" -Datos $datos
    New-Resultado -Paso $paso -Estado $(if ($errores) { 'Error' } else { 'OK' }) -Detalle "$borrados borrados de $($todos.Count), $errores errores" -Datos $datos
}

function Invoke-PurgaPorPresion {
    <#
    .SYNOPSIS
        Si después de la retención normal el disco sigue por debajo de -UmbralPct, borra logs de la aplicación
        del más viejo al más nuevo hasta recuperar el umbral, sin bajar nunca de -DiasMinimos.
        Solo actúa sobre logs de la aplicación: los logs IIS son de auditoría y los volcados recientes son evidencia.
        Motivo (Reto 1): con los logs en Debug (~7 GB por día hábil) una retención de 7 días ocupa ~39 GB y llena C:.
        El espacio liberado se estima con el tamaño de cada archivo borrado, así que también funciona en -WhatIf.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Ruta,
        [Parameter(Mandatory)][ValidateRange(1, 99)][int]$UmbralPct,
        [ValidateRange(1, 90)][int]$DiasMinimos = 1,
        [string]$Filtro = '*.*'
    )
    $paso = 'purga-presion-disco'
    if (-not (Test-RutaSegura -Ruta $Ruta)) {
        Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "Ruta no segura o inexistente para borrar: '$Ruta'"
        return New-Resultado -Paso $paso -Estado 'Error' -Detalle "Ruta no segura: '$Ruta'"
    }
    $e = Get-EspacioLibre -Ruta $Ruta
    if ($e.LibrePct -ge $UmbralPct) {
        Write-MantLog -Paso $paso -Mensaje ("Sin presión de disco: {0} % libre (umbral {1} %)" -f $e.LibrePct, $UmbralPct)
        return New-Resultado -Paso $paso -Estado 'OK' -Detalle 'Sin presión de disco'
    }
    $limite = (Get-Ahora).AddDays(-$DiasMinimos)
    $candidatos = @(Get-ChildItem -LiteralPath $Ruta -Filter $Filtro -File -Recurse -ErrorAction Stop |
        Where-Object { $_.LastWriteTime -lt $limite } | Sort-Object LastWriteTime)
    $borrados = 0; $liberado = 0; $errores = 0
    $estimadoPct = $e.LibrePct
    foreach ($f in $candidatos) {
        if ($estimadoPct -ge $UmbralPct) { break }
        if ($PSCmdlet.ShouldProcess($f.FullName, "Borrar por presión de disco ($estimadoPct % libre < $UmbralPct %)")) {
            try {
                $len = $f.Length
                Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
                $borrados++; $liberado += $len
            } catch {
                $errores++
                Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "No se pudo borrar $($f.FullName): $($_.Exception.Message)"
                continue
            }
        } elseif ($WhatIfPreference) {
            # en simulación se cuenta como liberado para mostrar hasta dónde llegaría la corrida real
            $borrados++; $liberado += $f.Length
        }
        $estimadoPct = [math]::Round(100.0 * ($e.LibreMB + $liberado / 1MB) / $e.TotalMB, 2)
    }
    $recuperado = $estimadoPct -ge $UmbralPct
    $datos = @{ LibrePctInicial = $e.LibrePct; LibrePctEstimado = $estimadoPct; UmbralPct = $UmbralPct; DiasMinimos = $DiasMinimos
        Candidatos = $candidatos.Count; Borrados = $borrados; LiberadoMB = [math]::Round($liberado / 1MB, 1); Errores = $errores; Recuperado = $recuperado }
    $msg = "Presión de disco: {0} logs de app borrados ({1} MB), {2} % -> ~{3} % libre{4}" -f $borrados, $datos.LiberadoMB, $e.LibrePct, $estimadoPct,
        $(if ($recuperado) { '' } else { ". No alcanza: queda por debajo del umbral sin bajar de $DiasMinimos día(s) de logs" })
    # siempre es Aviso como mínimo: que haga falta purgar por presión significa que algo (nivel Debug, fuga) sigue llenando el disco
    Write-MantLog -Nivel $(if ($errores) { 'ERROR' } else { 'AVISO' }) -Paso $paso -Mensaje $msg -Datos $datos
    New-Resultado -Paso $paso -Estado $(if ($errores) { 'Error' } else { 'Aviso' }) -Detalle $msg -Datos $datos
}

function Assert-ServicioEnEjecucion {
    <#
    .SYNOPSIS
        En vez de reiniciar a ciegas: si el servicio está detenido lo inicia; si está Disabled, avisa y no lo toca.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Nombre)
    $paso = 'servicio'
    $svc = Get-Service -Name $Nombre -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "Servicio '$Nombre' no existe"
        return New-Resultado -Paso $paso -Estado 'Error' -Detalle "Servicio '$Nombre' no existe"
    }
    if ($svc.Status -eq 'Running') {
        Write-MantLog -Paso $paso -Mensaje "Servicio '$Nombre' en ejecución (sin acción)"
        return New-Resultado -Paso $paso -Estado 'OK' -Detalle 'En ejecución'
    }
    if ("$($svc.StartType)" -eq 'Disabled') {
        Write-MantLog -Nivel AVISO -Paso $paso -Mensaje "Servicio '$Nombre' deshabilitado: no se inicia (decisión humana)"
        return New-Resultado -Paso $paso -Estado 'Aviso' -Detalle 'Deshabilitado'
    }
    if ($PSCmdlet.ShouldProcess($Nombre, 'Iniciar servicio')) {
        try {
            Start-Service -Name $Nombre -ErrorAction Stop
            Write-MantLog -Nivel AVISO -Paso $paso -Mensaje "Servicio '$Nombre' estaba $($svc.Status); se inició" -Datos @{ estadoPrevio = "$($svc.Status)" }
            return New-Resultado -Paso $paso -Estado 'Aviso' -Detalle "Estaba $($svc.Status); se inició"
        } catch {
            Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "No se pudo iniciar '$Nombre': $($_.Exception.Message)"
            return New-Resultado -Paso $paso -Estado 'Error' -Detalle 'No se pudo iniciar'
        }
    }
    New-Resultado -Paso $paso -Estado 'Aviso' -Detalle "Estaba $($svc.Status) (simulación: no se inició)"
}

function Test-EspacioDisco {
    <#
    .SYNOPSIS
        Compara el espacio libre con los umbrales de aviso y crítico.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Ruta,
        [ValidateRange(1, 99)][int]$AvisoPct = 20,
        [ValidateRange(1, 99)][int]$CriticoPct = 10,
        [string]$Momento = 'final'
    )
    $paso = "disco-$Momento"
    $e = Get-EspacioLibre -Ruta $Ruta
    $estado = if ($e.LibrePct -lt $CriticoPct) { 'Error' } elseif ($e.LibrePct -lt $AvisoPct) { 'Aviso' } else { 'OK' }
    $nivel = @{ OK = 'INFO'; Aviso = 'AVISO'; Error = 'ERROR' }[$estado]
    Write-MantLog -Nivel $nivel -Paso $paso -Mensaje ("{0}: {1} % libre ({2} MB)" -f $e.Unidad, $e.LibrePct, $e.LibreMB) `
        -Datos @{ unidad = $e.Unidad; libreMB = $e.LibreMB; librePct = $e.LibrePct; avisoPct = $AvisoPct; criticoPct = $CriticoPct }
    New-Resultado -Paso $paso -Estado $estado -Detalle ("{0} % libre" -f $e.LibrePct) -Datos @{ LibrePct = $e.LibrePct; LibreMB = $e.LibreMB }
}

function Test-EstadoPool {
    <#
    .SYNOPSIS
        Solo verifica e informa. La remediación automática del pool es del Reto 3, con límite de intentos y escalamiento.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Nombre)
    $paso = 'pool'
    try { $estado = Get-EstadoPool -Nombre $Nombre } catch {
        Write-MantLog -Nivel ERROR -Paso $paso -Mensaje "No se pudo consultar el pool '$Nombre': $($_.Exception.Message)"
        return New-Resultado -Paso $paso -Estado 'Error' -Detalle 'Consulta fallida'
    }
    if ($null -eq $estado) {
        Write-MantLog -Paso $paso -Mensaje 'WebAdministration no disponible: verificación omitida'
        return New-Resultado -Paso $paso -Estado 'Omitido' -Detalle 'WebAdministration no disponible'
    }
    if ($estado -ne 'Started') {
        Write-MantLog -Nivel AVISO -Paso $paso -Mensaje "Pool '$Nombre' en estado $estado" -Datos @{ estado = "$estado" }
        return New-Resultado -Paso $paso -Estado 'Aviso' -Detalle "Pool $estado"
    }
    Write-MantLog -Paso $paso -Mensaje "Pool '$Nombre' Started"
    New-Resultado -Paso $paso -Estado 'OK' -Detalle 'Started'
}

function Write-EventoResumen {
    <#
    .SYNOPSIS
        Evento en el registro Application (fuente AndinaMantenimiento) para que Azure Monitor lo recoja (Reto 3).
    #>
    [CmdletBinding()]
    param([int]$Codigo, [string]$Mensaje)
    $isWin = [System.Environment]::OSVersion.Platform -eq 'Win32NT'
    if (-not $isWin) { return }
    try {
        if (-not [System.Diagnostics.EventLog]::SourceExists('AndinaMantenimiento')) {
            Write-MantLog -Nivel AVISO -Paso 'evento' -Mensaje "Fuente 'AndinaMantenimiento' no registrada (ejecute Instalar-MantenimientoPortalPagos.ps1)"
            return
        }
        $tipo = switch ($Codigo) { 0 { 'Information' } 2 { 'Warning' } default { 'Error' } }
        [System.Diagnostics.EventLog]::WriteEntry('AndinaMantenimiento', $Mensaje, $tipo, 1000 + $Codigo)
    } catch {
        Write-MantLog -Nivel AVISO -Paso 'evento' -Mensaje "No se pudo escribir el evento: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------------ orquestador
function Invoke-Mantenimiento {
    <#
    .SYNOPSIS
        Ejecuta el mantenimiento diario y devuelve el resumen (incluye CodigoSalida).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RutaLogsIis,
        [string]$RutaAuditoria,
        [string[]]$RutasLogsApp = @(),
        [string]$RutaDumps,
        [string]$NombreServicio,
        [string]$NombrePool,
        [int]$DiasRetencionIis = 14,
        [int]$DiasRetencionApp = 7,
        [int]$DiasMinimosApp = 1,
        [int]$DiasMinimosDumps = 14,
        [int]$DumpsConservar = 5,
        [int]$UmbralDiscoAvisoPct = 20,
        [int]$UmbralDiscoCriticoPct = 10,
        [Parameter(Mandatory)][string]$RutaLog,
        # no escribe el evento resumen en Application (pruebas: no ensuciar el registro real de Windows)
        [switch]$OmitirEvento
    )
    $simul = [bool]$WhatIfPreference
    Initialize-MantLog -RutaLog $RutaLog -Simulacion:$simul | Out-Null
    $candado = Enter-Candado -RutaCandado (Join-Path $RutaLog 'mantenimiento.lock')
    if (-not $candado) {
        Write-MantLog -Nivel ERROR -Paso 'inicio' -Mensaje 'Otra ejecución está en curso (candado tomado). No se hace nada.'
        return [pscustomobject]@{ CodigoSalida = 4; Resultados = @(New-Resultado -Paso 'inicio' -Estado 'Precondicion' -Detalle 'Candado tomado'); Log = $script:Contexto.Archivo }
    }
    $res = New-Object System.Collections.Generic.List[object]
    try {
        Write-MantLog -Paso 'inicio' -Mensaje 'Inicio de mantenimiento' -Datos @{
            usuario = [Environment]::UserName; rutaLogsIis = $RutaLogsIis; rutaAuditoria = $RutaAuditoria
            rutasLogsApp = $RutasLogsApp; rutaDumps = $RutaDumps; diasIis = $DiasRetencionIis; diasApp = $DiasRetencionApp; diasMinimosApp = $DiasMinimosApp
        }
        $res.Add((Test-EspacioDisco -Ruta $RutaLogsIis -AvisoPct $UmbralDiscoAvisoPct -CriticoPct $UmbralDiscoCriticoPct -Momento 'inicial'))

        # 1) Archivar en auditoría ANTES de purgar (el .BAT lo hacía al revés)
        $archivados = @()
        if ($RutaAuditoria) {
            $r = Invoke-ArchivadoAuditoria -Origen $RutaLogsIis -Destino $RutaAuditoria -VerificarHashSiMasViejoQueDias $DiasRetencionIis -WhatIf:$WhatIfPreference
            $res.Add($r); $archivados = @($r.Datos.Archivados)
        } else {
            Write-MantLog -Nivel AVISO -Paso 'archivado-auditoria' -Mensaje 'Sin RutaAuditoria: no se archiva ni se purgan logs IIS'
            $res.Add((New-Resultado -Paso 'archivado-auditoria' -Estado 'Aviso' -Detalle 'No configurado'))
        }
        # 2) Purgar logs IIS solo si ya están archivados y verificados
        if ($RutaAuditoria) {
            $res.Add((Invoke-PurgaArchivos -Paso 'purga-logs-iis' -Ruta $RutaLogsIis -Dias $DiasRetencionIis -Archivados $archivados -RaizAuditoria $RutaAuditoria -SoloArchivados -WhatIf:$WhatIfPreference))
        }
        # 3) Logs de la aplicación (no son de auditoría): retención local
        foreach ($ra in $RutasLogsApp) {
            $res.Add((Invoke-PurgaArchivos -Paso "purga-logs-app" -Ruta $ra -Dias $DiasRetencionApp -Filtro '*.*' -WhatIf:$WhatIfPreference))
            # 3b) si el disco sigue por debajo del aviso, más logs de app (nunca IIS ni volcados recientes) hasta DiasMinimosApp
            $res.Add((Invoke-PurgaPorPresion -Ruta $ra -UmbralPct $UmbralDiscoAvisoPct -DiasMinimos $DiasMinimosApp -WhatIf:$WhatIfPreference))
        }
        # 4) Volcados con retención (no borrado ciego)
        if ($RutaDumps) { $res.Add((Invoke-RetencionDumps -Ruta $RutaDumps -DiasMinimos $DiasMinimosDumps -Conservar $DumpsConservar -WhatIf:$WhatIfPreference)) }
        # 5) Servicio: asegurar estado, no reiniciar
        if ($NombreServicio) { $res.Add((Assert-ServicioEnEjecucion -Nombre $NombreServicio -WhatIf:$WhatIfPreference)) }
        # 6) Pool: verificar (sin iisreset)
        if ($NombrePool) { $res.Add((Test-EstadoPool -Nombre $NombrePool)) }
        $res.Add((Test-EspacioDisco -Ruta $RutaLogsIis -AvisoPct $UmbralDiscoAvisoPct -CriticoPct $UmbralDiscoCriticoPct -Momento 'final'))
    } catch {
        Write-MantLog -Nivel ERROR -Paso 'general' -Mensaje "Error no controlado: $($_.Exception.Message)" -Datos @{ linea = $_.InvocationInfo.ScriptLineNumber }
        $res.Add((New-Resultado -Paso 'general' -Estado 'Error' -Detalle $_.Exception.Message))
    } finally {
        $codigo = Get-CodigoSalida -Resultados $res.ToArray()
        $dur = [math]::Round(((Get-Ahora) - $script:Contexto.Inicio).TotalSeconds, 1)
        $resumen = ($res | ForEach-Object { "$($_.Paso)=$($_.Estado)" }) -join '; '
        Write-MantLog -Nivel $(if ($codigo -ge 3) { 'ERROR' } elseif ($codigo -eq 2) { 'AVISO' } else { 'INFO' }) -Paso 'fin' `
            -Mensaje "Fin de mantenimiento: código $codigo" -Datos @{ codigoSalida = $codigo; duracionS = $dur; pasos = $resumen }
        if (-not $simul -and -not $OmitirEvento) { Write-EventoResumen -Codigo $codigo -Mensaje "Mantenimiento PortalPagos: código $codigo. $resumen" }
        $candado.Dispose()
        Remove-Item -LiteralPath (Join-Path $RutaLog 'mantenimiento.lock') -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
    [pscustomobject]@{ CodigoSalida = $codigo; Resultados = $res.ToArray(); Log = $script:Contexto.Archivo }
}

Export-ModuleMember -Function Invoke-Mantenimiento, Invoke-ArchivadoAuditoria, Invoke-PurgaArchivos, Invoke-PurgaPorPresion, Invoke-RetencionDumps,
    Assert-ServicioEnEjecucion, Test-EspacioDisco, Test-EstadoPool, Test-RutaSegura, Get-CodigoSalida, Initialize-MantLog, Write-MantLog,
    Get-EspacioLibre, Get-EstadoPool, Get-Ahora, Enter-Candado, Test-ArchivoEnUso
