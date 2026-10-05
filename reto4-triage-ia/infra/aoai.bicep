// Reto 4 · Azure OpenAI para el triage (mismo grupo de recursos del laboratorio).
//   az deployment group create -g rg-portalpagos-lab -f infra/aoai.bicep -p principalId=$(az ad signed-in-user show --query id -o tsv)
// Sin claves: disableLocalAuth=true. Se accede solo con Entra ID (rol "Cognitive Services OpenAI User").
param location string = resourceGroup().location
param nombre string = 'aoai-portalpagos-${uniqueString(resourceGroup().id)}'
param modelo string = 'gpt-4.1-mini'
param versionModelo string = '2025-04-14'
@description('Miles de tokens por minuto. 30K sobra para el triage.')
param capacidadKTpm int = 30
@description('Usuario que ejecuta el triage desde su máquina.')
param principalId string
@allowed([ 'User', 'ServicePrincipal' ])
param principalType string = 'User'
@description('Identidad administrada adicional (por ejemplo, la cuenta de Automation del Reto 3). Vacío = ninguna.')
param principalIdAutomation string = ''

resource aoai 'Microsoft.CognitiveServices/accounts@2024-10-01' = {
  name: nombre
  location: location
  kind: 'OpenAI'
  sku: { name: 'S0' }
  tags: { proyecto: 'prueba-tecnica-observabilidad', eliminarAlTerminar: 'si' }
  properties: {
    customSubDomainName: nombre
    disableLocalAuth: true          // sin API keys
    publicNetworkAccess: 'Enabled'
  }
}

resource despliegue 'Microsoft.CognitiveServices/accounts/deployments@2024-10-01' = {
  parent: aoai
  name: 'triage'
  sku: { name: 'GlobalStandard', capacity: capacidadKTpm }
  properties: {
    model: { format: 'OpenAI', name: modelo, version: versionModelo }
    versionUpgradeOption: 'NoAutoUpgrade'   // el comportamiento validado no cambia sin que lo decidamos
  }
}

var rolOpenAiUser = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '5e0bd9bd-7b93-4f28-af87-19fc36ad61bd')
resource rbacUsuario 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(aoai.id, principalId, rolOpenAiUser)
  scope: aoai
  properties: { roleDefinitionId: rolOpenAiUser, principalId: principalId, principalType: principalType }
}
resource rbacAutomation 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalIdAutomation)) {
  name: guid(aoai.id, principalIdAutomation, rolOpenAiUser)
  scope: aoai
  properties: { roleDefinitionId: rolOpenAiUser, principalId: principalIdAutomation, principalType: 'ServicePrincipal' }
}

output endpoint string = aoai.properties.endpoint
output despliegue string = despliegue.name
