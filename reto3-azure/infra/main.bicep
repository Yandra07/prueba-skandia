// Reto 3 · Observabilidad y auto-remediación de PortalPagos (laboratorio)
// Despliegue a nivel de suscripción: crea el grupo de recursos y todo lo demás dentro de él.
//   Lo invoca scripts/desplegar.sh:  az deployment sub create -l eastus2 -f infra/main.bicep -p correoAlertas=... vmAdminPassword=... webhookUri=...
targetScope = 'subscription'

@description('Región. eastus2 suele estar disponible en suscripciones de estudiante.')
param location string = 'eastus2'

@description('Nombre del grupo de recursos (se elimina completo al terminar).')
param grupoRecursos string = 'rg-portalpagos-lab'

@description('Correo que recibe las alertas y el presupuesto.')
param correoAlertas string

@description('Contraseña del administrador local de la VM. La genera desplegar.sh, no se guarda y no se usa: no hay RDP abierto.')
@secure()
param vmAdminPassword string

@description('Tamaño de la VM. B2s (2 vCPU, 4 GB) alcanza para IIS + AMA; B1s es gratis 750 h/mes pero con 1 GB va muy lenta con Windows.')
param vmSize string = 'Standard_B2s'

@description('IP pública (CIDR) que puede abrir el sitio por HTTP para la demo. Vacío = sin acceso entrante.')
param ipPermitidaHttp string = ''

@description('Presupuesto mensual del grupo de recursos (USD).')
param presupuestoUsd int = 15

@description('Fase 2: URI del webhook del runbook (la genera desplegar.sh). Vacío en la fase 1. Es un secreto: no se versiona.')
@secure()
param webhookUri string = ''

@description('Reto 4: URI del webhook del runbook Triage-Alerta (lo genera desplegar.sh si el runbook existe). Secreto.')
@secure()
param webhookTriageUri string = ''

@description('Inicio del presupuesto (primer día del mes actual).')
param inicioPresupuesto string = utcNow('yyyy-MM-01')

var etiquetas = {
  proyecto: 'prueba-tecnica-observabilidad'
  entorno: 'laboratorio'
  eliminarAlTerminar: 'si'
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: grupoRecursos
  location: location
  tags: etiquetas
}

module recursos 'recursos.bicep' = {
  name: 'recursos-portalpagos'
  scope: rg
  params: {
    location: location
    correoAlertas: correoAlertas
    vmAdminPassword: vmAdminPassword
    vmSize: vmSize
    ipPermitidaHttp: ipPermitidaHttp
    presupuestoUsd: presupuestoUsd
    webhookUri: webhookUri
    webhookTriageUri: webhookTriageUri
    inicioPresupuesto: inicioPresupuesto
    etiquetas: etiquetas
  }
}

output grupoRecursos string = rg.name
output vmId string = recursos.outputs.vmId
output vmNombre string = recursos.outputs.vmNombre
output workspaceId string = recursos.outputs.workspaceId
output workspaceCustomerId string = recursos.outputs.workspaceCustomerId
output automationCuenta string = recursos.outputs.automationCuenta
output workbookId string = recursos.outputs.workbookId
output ipPublica string = recursos.outputs.ipPublica
