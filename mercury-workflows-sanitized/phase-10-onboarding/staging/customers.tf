## Customer Onboarding
# Add a customer name to this list to provision their entire infrastructure
# Terraform will create: storage container, Key Vault secrets, and GitOps manifests

locals {
  # Add new customers here - just add a name to the list!
  customers = toset([
    "julius",
    "cicero",
    "crassus",
    "brutus",
  ])

  # Configuration shared across all customers
  environment      = "staging"
  domain           = "mercury-staging.kubecraftlabs.com"
  gitops_repo_path = "/workspaces/mercury-gitops"

  # Sorted customer list for consistent ordering in kustomization
  customers_sorted = sort(tolist(local.customers))
}

# Create all customer resources using for_each
module "customer" {
  source   = "../modules/customer-onboarding"
  for_each = local.customers

  # Customer identifier
  customer_name = each.key
  environment   = local.environment

  # Azure resources (from this phase)
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

  # Sizing (use defaults, override per-customer if needed)
  # db_instances     = 3
  # db_storage_size  = "1Gi"
  # n8n_storage_size = "1Gi"
  # n8n_version      = "1.73.1"

  depends_on = [azurerm_role_assignment.kv_admin]
}

# Generate the staging kustomization that includes all customers
resource "local_file" "staging_kustomization" {
  filename = "${local.gitops_repo_path}/apps/staging/kustomization.yaml"
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
