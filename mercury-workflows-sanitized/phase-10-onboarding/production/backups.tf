## CNPG Backup Storage

resource "azurerm_storage_account" "cnpg_backups" {
  name                     = "mercurybackupsprod"
  resource_group_name      = azurerm_resource_group.aks.name
  location                 = azurerm_resource_group.aks.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }
}
