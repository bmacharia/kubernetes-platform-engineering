terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "8010b04e-0bd8-432f-b42b-7d3edfd19f5c"
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-cloud-course-aks"
  location = "westus2"
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = "mercury-cluster"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "mercury"
  kubernetes_version  = "1.32.0"

  default_node_pool {
    name       = "default"
    node_count = 1
    vm_size    = "Standard_D2s_v3"
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "cilium"
    network_data_plane = "cilium"
  }

}

# DB

resource "azurerm_postgresql_flexible_server" "n8n_db" {

  name                = "psql-n8n-mercury-neu"
  resource_group_name = azurerm_resource_group.aks.name
  location            = "northeurope"  # US regions restricted for PostgreSQL Flexible Server
  zone                = "1"

  administrator_login    = "n8nadmin"
  administrator_password = "n8n-password-123"

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  version    = "16"

  backup_retention_days = 7

  # Allow Azure services to access (needed for AKS)
  public_network_access_enabled = true
}

resource "azurerm_postgresql_flexible_server_configuration" "disable_ssl" {
  name      = "require_secure_transport"
  server_id = azurerm_postgresql_flexible_server.n8n_db.id
  value     = "OFF"
}

resource "azurerm_postgresql_flexible_server_database" "n8n" {
  name      = "n8n"
  server_id = azurerm_postgresql_flexible_server.n8n_db.id
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_azure_services" {
  name             = "AllowAzureServices"
  server_id        = azurerm_postgresql_flexible_server.n8n_db.id
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}

output "db_host" {
  value = azurerm_postgresql_flexible_server.n8n_db.fqdn
}

output "db_name" {
  value = azurerm_postgresql_flexible_server_database.n8n.name
}

output "db_user" {
  value = azurerm_postgresql_flexible_server.n8n_db.administrator_login
}

