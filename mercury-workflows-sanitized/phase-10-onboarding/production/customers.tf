## Customer Onboarding - Production

locals {
  customers = toset([
    "julius",
    "cicero",
    "crassus",
  ])

  environment      = "production"
  domain           = "mercury-prod.kubecraftlabs.com"
  gitops_repo_path = "/workspaces/mercury-gitops"

  customers_sorted = sort(tolist(local.customers))
}

module "customer" {
  source   = "../modules/customer-onboarding"
  for_each = local.customers

  customer_name = each.key
  environment   = local.environment

  # Azure resources
  key_vault_id                              = azurerm_key_vault.mercury_vault.id
  storage_account_id                        = azurerm_storage_account.cnpg_backups.id
  storage_account_name                      = azurerm_storage_account.cnpg_backups.name
  storage_account_primary_connection_string = azurerm_storage_account.cnpg_backups.primary_connection_string

  # Key Vault CSI configuration
  keyvault_name                   = azurerm_key_vault.mercury_vault.name
  keyvault_tenant_id              = data.azurerm_client_config.current.tenant_id
  aks_keyvault_identity_client_id = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id

  # GitOps
  gitops_repo_path = local.gitops_repo_path
  domain           = local.domain

  depends_on = [azurerm_role_assignment.kv_admin]
}

# Generate the production kustomization that includes all customers
resource "local_file" "production_kustomization" {
  filename = "${local.gitops_repo_path}/apps/production/kustomization.yaml"
  content  = <<-YAML
    apiVersion: kustomize.config.k8s.io/v1beta1
    kind: Kustomization
    resources:
    %{for customer in local.customers_sorted~}
      - ${customer}
    %{endfor~}
  YAML

  depends_on = [module.customer]
}
