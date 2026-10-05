// Recursos del laboratorio (alcance: grupo de recursos). Lo invoca main.bicep.
param location string
param correoAlertas string
@secure()
param vmAdminPassword string
param vmSize string
param ipPermitidaHttp string
param presupuestoUsd int
@secure()
param webhookUri string
@secure()
param webhookTriageUri string = ''
param inicioPresupuesto string
param etiquetas object

@description('Usuario administrador local (no se usa para entrar: no hay RDP).')
param vmAdminUsuario string = 'andinaadmin'

@description('Crear el presupuesto con alerta (algunas suscripciones de estudiante no permiten Cost Management por API).')
param crearPresupuesto bool = true

@description('Vencimiento del webhook del runbook.')
param vencimientoWebhook string = dateTimeAdd(utcNow(), 'P90D')

var nombreVm = 'web-pagos-01'
var nombreRunbook = 'Restaurar-PoolIIS'
var conRemediacion = !empty(webhookUri)
var conTriage = !empty(webhookTriageUri)   // Reto 4: triage con IA en paralelo a la remediación
var alertas = loadJsonContent('alertas.json')

// ------------------------------------------------------------------ red (sin RDP: la VM se administra con Run Command)
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: 'nsg-portalpagos'
  location: location
  tags: etiquetas
  properties: {
    securityRules: empty(ipPermitidaHttp) ? [] : [
      {
        name: 'http-demo-desde-mi-ip'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: ipPermitidaHttp
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: 'vnet-portalpagos'
  location: location
  tags: etiquetas
  properties: {
    addressSpace: { addressPrefixes: [ '10.20.0.0/16' ] }
    subnets: [
      {
        name: 'snet-web'
        properties: {
          addressPrefix: '10.20.4.0/24'
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}

// IP pública: da salida a internet explícita (AMA, Windows Update, PSGallery). Sin reglas de entrada salvo la demo HTTP.
resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: 'pip-web-pagos-01'
  location: location
  tags: etiquetas
  sku: { name: 'Standard' }
  properties: { publicIPAllocationMethod: 'Static' }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: 'nic-web-pagos-01'
  location: location
  tags: etiquetas
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          subnet: { id: vnet.properties.subnets[0].id }
          privateIPAllocationMethod: 'Static'
          privateIPAddress: '10.20.4.15'   // misma IP privada que WEB-PAGOS-01 en el caso
          publicIPAddress: { id: pip.id }
        }
      }
    ]
  }
}

// ------------------------------------------------------------------ VM
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: nombreVm
  location: location
  tags: etiquetas
  identity: { type: 'SystemAssigned' }   // la usa Azure Monitor Agent
  properties: {
    hardwareProfile: { vmSize: vmSize }
    osProfile: {
      computerName: 'WEB-PAGOS-01'
      adminUsername: vmAdminUsuario
      adminPassword: vmAdminPassword
      windowsConfiguration: {
        timeZone: 'SA Pacific Standard Time'
        enableAutomaticUpdates: true
        provisionVMAgent: true
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-smalldisk-g2'
        version: 'latest'
      }
      osDisk: {
        name: 'osdisk-web-pagos-01'
        createOption: 'FromImage'
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    networkProfile: { networkInterfaces: [ { id: nic.id, properties: { deleteOption: 'Delete' } } ] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}

resource ama 'Microsoft.Compute/virtualMachines/extensions@2024-03-01' = {
  parent: vm
  name: 'AzureMonitorWindowsAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorWindowsAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

// ------------------------------------------------------------------ Log Analytics + DCR
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'law-portalpagos'
  location: location
  tags: etiquetas
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }   // tope de costo: el laboratorio ingiere ~0,1 GB/día
    features: { enableLogAccessUsingOnlyResourcePermissions: true }
  }
}

resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: 'dcr-portalpagos-windows'
  location: location
  tags: etiquetas
  kind: 'Windows'
  properties: {
    description: 'IIS (W3C), eventos del pool/app/sonda/remediación y contadores de memoria, disco y pool de WEB-PAGOS-01'
    dataSources: {
      performanceCounters: [
        {
          name: 'contadores-60s'
          streams: [ 'Microsoft-Perf' ]
          samplingFrequencyInSeconds: 60
          counterSpecifiers: [
            '\\Processor(_Total)\\% Processor Time'
            '\\Memory\\Available MBytes'
            '\\LogicalDisk(C:)\\% Free Space'
            '\\LogicalDisk(C:)\\Free Megabytes'
            '\\Process(w3wp)\\Private Bytes'
            '\\Process(w3wp#1)\\Private Bytes'
            '\\Web Service(PortalPagos)\\Current Connections'
            '\\ASP.NET\\Requests Queued'
            '\\APP_POOL_WAS(PortalPagosPool)\\Current Application Pool State'
          ]
        }
      ]
      windowsEventLogs: [
        {
          name: 'eventos-portal'
          streams: [ 'Microsoft-Event' ]
          // Filtros DISJUNTOS: en la primera versión se solapaban y los eventos de advertencia/error de WAS y de las
          // fuentes Andina llegaban DUPLICADOS (una sola falla de la sonda contaba como 2 para la alerta).
          xPathQueries: [
            'System!*[System[Provider[@Name="Microsoft-Windows-WAS"]]]'
            'System!*[System[(Level=1 or Level=2) and Provider[@Name!="Microsoft-Windows-WAS"]]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3) and Provider[@Name!="AndinaSonda" and @Name!="AndinaMantenimiento" and @Name!="AndinaRemediacion" and @Name!="AndinaPrueba"]]]'
            'Application!*[System[Provider[@Name="AndinaSonda" or @Name="AndinaMantenimiento" or @Name="AndinaRemediacion" or @Name="AndinaPrueba"]]]'
          ]
        }
      ]
      iisLogs: [
        {
          name: 'iis-w3c'
          streams: [ 'Microsoft-W3CIISLog' ]
        }
      ]
    }
    destinations: {
      logAnalytics: [ { name: 'law', workspaceResourceId: law.id } ]
    }
    dataFlows: [
      { streams: [ 'Microsoft-Perf', 'Microsoft-Event' ], destinations: [ 'law' ] }
      { streams: [ 'Microsoft-W3CIISLog' ], destinations: [ 'law' ] }
    ]
  }
}

resource dcra 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = {
  name: 'dcra-portalpagos'
  scope: vm
  properties: { dataCollectionRuleId: dcr.id }
  dependsOn: [ ama ]
}

// ------------------------------------------------------------------ Automation (auto-remediación)
resource aa 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: 'aa-portalpagos'
  location: location
  tags: etiquetas
  identity: { type: 'SystemAssigned' }
  properties: {
    sku: { name: 'Basic' }
    publicNetworkAccess: true
  }
}

// salvaguardas configurables sin tocar el código del runbook
var variablesRunbook = {
  AutoRemediacionHabilitada: 'true'
  VmPermitidas: '"${vm.id}"'
  VentanaMantenimiento: '"02:00-02:30"'
  MaxIntentos: '3'
  HistorialRemediacion: '"[]"'
}
resource vars 'Microsoft.Automation/automationAccounts/variables@2023-11-01' = [for v in items(variablesRunbook): {
  parent: aa
  name: v.key
  properties: { value: v.value, isEncrypted: false }
}]

// mínimo privilegio: solo puede operar ESTA VM (Run Command incluido en Virtual Machine Contributor)
var rolVmContributor = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '9980e02c-c2be-4d73-94e8-173b1dc7cf3c')
resource rbac 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vm.id, aa.id, rolVmContributor)
  scope: vm
  properties: {
    roleDefinitionId: rolVmContributor
    principalId: aa.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource aaDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'aa-a-log-analytics'
  scope: aa
  properties: {
    workspaceId: law.id
    logs: [
      { category: 'JobLogs', enabled: true }
      { category: 'JobStreams', enabled: true }
    ]
  }
}

resource runbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' existing = if (conRemediacion) {
  parent: aa
  name: nombreRunbook
}

resource webhook 'Microsoft.Automation/automationAccounts/webhooks@2015-10-31' = if (conRemediacion) {
  parent: aa
  name: 'wh-alerta-sitio-no-disponible'
  properties: {
    isEnabled: true
    uri: webhookUri
    expiryTime: vencimientoWebhook
    runbook: { name: runbook.name }
  }
}

resource webhookTriage 'Microsoft.Automation/automationAccounts/webhooks@2015-10-31' = if (conTriage) {
  parent: aa
  name: 'wh-triage-ia'
  properties: {
    isEnabled: true
    uri: webhookTriageUri
    expiryTime: vencimientoWebhook
    runbook: { name: 'Triage-Alerta' }
  }
}

// ------------------------------------------------------------------ grupos de acciones
resource agNoc 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-portalpagos-noc'
  location: 'Global'
  tags: etiquetas
  properties: {
    groupShortName: 'pp-noc'
    enabled: true
    emailReceivers: [ { name: 'noc-correo', emailAddress: correoAlertas, useCommonAlertSchema: true } ]
  }
}

resource agRem 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-portalpagos-remediacion'
  location: 'Global'
  tags: etiquetas
  properties: {
    groupShortName: 'pp-remed'
    enabled: true
    emailReceivers: [ { name: 'noc-correo', emailAddress: correoAlertas, useCommonAlertSchema: true } ]
    automationRunbookReceivers: concat(conRemediacion ? [
      {
        name: 'runbook-restaurar-pool'
        automationAccountId: aa.id
        runbookName: nombreRunbook
        webhookResourceId: webhook.id
        isGlobalRunbook: false
        serviceUri: webhookUri
        useCommonAlertSchema: true
      }
    ] : [], conTriage ? [
      {
        name: 'runbook-triage-ia'
        automationAccountId: aa.id
        runbookName: 'Triage-Alerta'
        webhookResourceId: webhookTriage.id
        isGlobalRunbook: false
        serviceUri: webhookTriageUri
        useCommonAlertSchema: true
      }
    ] : [])
  }
}

// ------------------------------------------------------------------ alertas (definidas como datos en alertas.json)
resource reglas 'Microsoft.Insights/scheduledQueryRules@2023-03-15-preview' = [for a in alertas: {
  name: a.nombre
  location: location
  tags: etiquetas
  properties: {
    displayName: a.nombre
    description: a.descripcion
    severity: a.severidad
    enabled: true
    evaluationFrequency: a.frecuencia
    windowSize: a.ventana
    scopes: [ a.alcance == 'vm' ? vm.id : law.id ]
    skipQueryValidation: true   // las tablas aparecen recién con los primeros datos
    // Las alertas de logs con resolución automática tardaron ~16 min en resolverse en la prueba real: mientras siguen
    // "Fired" no vuelven a disparar. La de remediación no se auto-resuelve y se silencia 5 min, para que una recaída
    // vuelva a llegar al runbook (que la escala por reincidencia).
    autoMitigate: a.?autoMitigar ?? true
    muteActionsDuration: (a.?autoMitigar ?? true) ? null : a.silenciar
    criteria: {
      allOf: [
        {
          query: a.consulta
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: a.umbral
          failingPeriods: { numberOfEvaluationPeriods: 1, minFailingPeriodsToAlert: 1 }
        }
      ]
    }
    actions: { actionGroups: [ a.grupo == 'remediacion' ? agRem.id : agNoc.id ] }
  }
  dependsOn: [ dcra ]
}]

// ------------------------------------------------------------------ tablero
resource workbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'workbook-portalpagos')
  location: location
  tags: etiquetas
  kind: 'shared'
  properties: {
    displayName: 'PortalPagos · Dirección y NOC'
    category: 'workbook'
    sourceId: law.id
    version: '1.0'
    serializedData: replace(loadTextContent('workbook.json'), '__WORKSPACE_ID__', law.id)
  }
}

// ------------------------------------------------------------------ presupuesto con alerta
resource presupuesto 'Microsoft.Consumption/budgets@2023-11-01' = if (crearPresupuesto) {
  name: 'presupuesto-portalpagos-lab'
  properties: {
    category: 'Cost'
    amount: presupuestoUsd
    timeGrain: 'Monthly'
    timePeriod: { startDate: inicioPresupuesto }
    notifications: {
      real50: { enabled: true, operator: 'GreaterThan', threshold: 50, thresholdType: 'Actual', contactEmails: [ correoAlertas ] }
      real80: { enabled: true, operator: 'GreaterThan', threshold: 80, thresholdType: 'Actual', contactEmails: [ correoAlertas ] }
      pronostico100: { enabled: true, operator: 'GreaterThan', threshold: 100, thresholdType: 'Forecasted', contactEmails: [ correoAlertas ] }
    }
  }
}

output vmId string = vm.id
output vmNombre string = vm.name
output workspaceId string = law.id
output workspaceCustomerId string = law.properties.customerId
output automationCuenta string = aa.name
output workbookId string = workbook.id
output ipPublica string = pip.properties.ipAddress
