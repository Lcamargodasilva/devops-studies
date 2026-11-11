provider "azurerm" {
  features {}

  # IDs e autenticação são fornecidos pelo ambiente ARM_*.
  storage_use_azuread             = true
  resource_provider_registrations = "none"
}
