terraform {
  # Endereço do backend fornecido por -backend-config, após conferência do state.
  # Autenticação local: Azure CLI. Pipeline: ARM_USE_OIDC=true e ARM_USE_CLI=false.
  backend "azurerm" {
    use_azuread_auth = true
  }
}
