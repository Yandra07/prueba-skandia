@{
    RootModule        = 'MantenimientoPortal.psm1'
    ModuleVersion     = '1.2.0'
    GUID              = '6f3f6a8e-2b1d-4c55-9a0e-3c1b8f0d7a21'
    Author            = 'Operaciones TI - Andina Financiera (caso ficticio)'
    Description       = 'Mantenimiento diario seguro e idempotente de WEB-PAGOS-01 (reemplaza mantenimiento_diario.bat).'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-Mantenimiento', 'Invoke-ArchivadoAuditoria', 'Invoke-PurgaArchivos', 'Invoke-PurgaPorPresion', 'Invoke-RetencionDumps',
        'Assert-ServicioEnEjecucion', 'Test-EspacioDisco', 'Test-EstadoPool', 'Test-RutaSegura', 'Get-CodigoSalida',
        'Initialize-MantLog', 'Write-MantLog', 'Get-EspacioLibre', 'Get-EstadoPool', 'Get-Ahora', 'Enter-Candado', 'Test-ArchivoEnUso')
}
