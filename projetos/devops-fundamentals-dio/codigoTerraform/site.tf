# Recursos recuperados do índice Git, mantendo seus endereços e nomes.
resource "azurerm_resource_group" "rg" {
  location = var.location
  name     = "rg-auladevops-002"
  tags = merge(var.tags, {
    workspace = terraform.workspace
  })
}

resource "azurerm_storage_account" "site" {
  name                       = "staccdevopsrg21605"
  resource_group_name        = azurerm_resource_group.rg.name
  location                   = azurerm_resource_group.rg.location
  account_kind               = "StorageV2"
  account_tier               = "Standard"
  account_replication_type   = "LRS"
  https_traffic_only_enabled = true

  static_website {
    index_document = "index.html"
  }

  tags = merge(var.tags, {
    workspace = terraform.workspace
  })
}
