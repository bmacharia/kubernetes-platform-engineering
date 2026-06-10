# Cloud Translation: Azure → AWS & GCP

This document maps every Azure service, resource, and pattern used in the Mercury platform to its AWS and GCP equivalents. Structure follows the 10-phase progression of the repo.

---

## Quick-Reference Service Mapping

| Azure | AWS | GCP |
|---|---|---|
| Resource Group | No direct equivalent (use Tags + Account boundaries) | Project |
| Virtual Network (VNet) | VPC (Virtual Private Cloud) | VPC Network |
| Subnet | Subnet | Subnet |
| Public IP | Elastic IP (EIP) | External IP Address (static) |
| Network Security Group (NSG) | Security Group | Firewall Rule (VPC-level) |
| Network Interface Card (NIC) | Elastic Network Interface (ENI) | Network Interface |
| Linux VM (`Standard_D2s_v3`) | EC2 `m5.large` (2 vCPU, 8 GB) | Compute Engine `n2-standard-2` |
| Availability Zone | Availability Zone (AZ) | Zone |
| Azure Kubernetes Service (AKS) | Elastic Kubernetes Service (EKS) | Google Kubernetes Engine (GKE) |
| Azure Container Registry (ACR) | Elastic Container Registry (ECR) | Artifact Registry |
| PostgreSQL Flexible Server | RDS for PostgreSQL | Cloud SQL (PostgreSQL) |
| Azure Blob Storage | S3 (Simple Storage Service) | Cloud Storage (GCS) |
| Storage Account | S3 Bucket (account-scoped) | GCS Bucket |
| Storage Container | S3 Bucket or S3 Prefix | GCS Bucket |
| Storage Account SAS Token | S3 Pre-signed URL / IAM Policy | GCS Signed URL / IAM Policy |
| Azure Key Vault | AWS Secrets Manager + Parameter Store | Secret Manager |
| Key Vault Secrets CSI Driver | AWS Secrets & Config Provider (ASCP) | GKE Secret Manager CSI Driver |
| Managed Identity (System-Assigned) | EC2 Instance Profile / IRSA | Workload Identity |
| Entra ID (Azure AD) | AWS IAM Identity Center (SSO) / Cognito | Google Identity / Cloud Identity |
| Azure RBAC | IAM Roles + Policies | IAM Roles + Bindings |
| Azure CNI | AWS VPC CNI plugin | GKE Dataplane V2 (eBPF) |
| Cilium Network Policy | Cilium (self-managed) or VPC CNI Network Policy | GKE Dataplane V2 (built-in eBPF) |
| Azure Monitor | Amazon CloudWatch | Google Cloud Monitoring |
| Azure DNS | Route 53 | Cloud DNS |
| Log Analytics Workspace | CloudWatch Log Groups | Cloud Logging |
| AKS Maintenance Windows | EKS Managed Node Group Update Config | GKE Release Channel + Maintenance Window |
| AKS Auto-Upgrade (patch channel) | EKS Auto Mode / Managed Node Groups | GKE Release Channel (Stable/Regular) |
| Azure Load Balancer (L4) | Network Load Balancer (NLB) | Cloud Load Balancing (L4) |
| Azure Application Gateway (L7) | Application Load Balancer (ALB) | Cloud Load Balancing (L7) |
| Flux CD (via ARC extension) | Flux CD (self-managed) / CodePipeline | Flux CD (self-managed) / Config Connector |
| cert-manager | cert-manager (unchanged) | cert-manager (unchanged) |
| Traefik Ingress | Traefik (unchanged) or AWS Load Balancer Controller | Traefik (unchanged) or GKE Ingress |
| CloudNativePG (CNPG) | CloudNativePG (unchanged) | CloudNativePG (unchanged) |
| Barman Cloud (to Blob) | Barman Cloud (to S3) | Barman Cloud (to GCS) |
| Prometheus + Grafana | Amazon Managed Prometheus (AMP) + Managed Grafana, or self-hosted | Cloud Managed Prometheus + Managed Grafana, or self-hosted |
| kube-prometheus-stack | kube-prometheus-stack (unchanged) | kube-prometheus-stack (unchanged) |

---

## Terraform Provider Changes

### Azure (current)
```hcl
terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = "8010b04e-..."
}
```

### AWS equivalent
```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"   # westus2 → us-west-2 (Oregon)
  # region = "eu-west-1" # northeurope → eu-west-1 (Ireland)
}
```

### GCP equivalent
```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = "my-gcp-project-id"
  region  = "us-west1"    # westus2 → us-west1
  # region = "europe-west1" # northeurope → europe-west1
}
```

---

## Phase 1 — Single VM + Networking

### Azure (current)
```hcl
resource "azurerm_resource_group"        "rg"   {}
resource "azurerm_virtual_network"       "vnet" { address_space = ["10.0.0.0/16"] }
resource "azurerm_subnet"                "sub"  { address_prefixes = ["10.0.1.0/24"] }
resource "azurerm_public_ip"             "pip"  { allocation_method = "Static" }
resource "azurerm_network_security_group" "nsg" { security_rule { port = 22 } }
resource "azurerm_network_interface"     "nic"  {}
resource "azurerm_linux_virtual_machine" "vm"   {
  size = "Standard_D2s_v3"  # 2 vCPU, 8 GB RAM
  source_image_reference { offer = "ubuntu-24_04-lts" }
}
```

### AWS equivalent
```hcl
# No resource group concept — use tags and/or separate AWS accounts per environment

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "main" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "us-west-2a"
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

resource "aws_eip" "pip" {
  domain = "vpc"
}

resource "aws_security_group" "nsg" {
  vpc_id = aws_vpc.main.id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["YOUR_IP/32"]  # tighten from open SSH
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "vm" {
  ami                         = "ami-0c65adc9a5c1b5d7c"  # Ubuntu 24.04 LTS us-west-2
  instance_type               = "m5.large"               # ≈ Standard_D2s_v3 (2 vCPU, 8 GB)
  subnet_id                   = aws_subnet.main.id
  vpc_security_group_ids      = [aws_security_group.nsg.id]
  associate_public_ip_address = true

  key_name = aws_key_pair.deployer.key_name   # SSH public key

  root_block_device {
    volume_type = "gp3"
    volume_size = 30
  }
}

resource "aws_eip_association" "pip_assoc" {
  instance_id   = aws_instance.vm.id
  allocation_id = aws_eip.pip.id
}
```

> **Key difference**: AWS requires an Internet Gateway + Route Table to make a subnet public. Azure handles this automatically when a Public IP is attached.

### GCP equivalent
```hcl
resource "google_project" "demo" {
  name       = "terraform-demo"
  project_id = "terraform-demo-12345"
}

resource "google_compute_network" "vnet" {
  name                    = "vnet-demo"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "sub" {
  name          = "subnet-demo"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.vnet.id
  region        = "us-west1"
}

resource "google_compute_address" "pip" {
  name   = "pip-demo"
  region = "us-west1"
}

resource "google_compute_firewall" "nsg" {
  name    = "allow-ssh"
  network = google_compute_network.vnet.name
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["YOUR_IP/32"]
}

resource "google_compute_instance" "vm" {
  name         = "vm-demo"
  machine_type = "n2-standard-2"   # 2 vCPU, 8 GB ≈ Standard_D2s_v3
  zone         = "us-west1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts"
      size  = 30
      type  = "pd-ssd"
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.sub.id
    access_config {
      nat_ip = google_compute_address.pip.address
    }
  }

  metadata = {
    ssh-keys = "ubuntu:${file("~/.ssh/id_rsa.pub")}"
  }
}
```

> **Key difference**: GCP Firewall Rules are VPC-level (not instance-level like AWS Security Groups). GCP uses `access_config {}` block for public IPs instead of a separate resource association.

---

## Phase 2 — Reusable Modules + PostgreSQL

### Azure (current)
```hcl
resource "azurerm_postgresql_flexible_server" "psql" {
  sku_name   = "B_Standard_B1ms"   # 1 vCore, 2 GB RAM, burstable
  version    = "16"
  zone       = "1"
  storage_mb = 32768
}
```

### AWS equivalent
```hcl
resource "aws_db_subnet_group" "psql" {
  name       = "psql-subnet-group"
  subnet_ids = [aws_subnet.private_a.id, aws_subnet.private_b.id]
}

resource "aws_db_instance" "psql" {
  identifier           = "psql-n8n-mercury"
  engine               = "postgres"
  engine_version       = "16"
  instance_class       = "db.t3.micro"     # ≈ B_Standard_B1ms (2 vCPU, 1 GB; cheapest burstable)
  # instance_class     = "db.t3.small"     # (2 vCPU, 2 GB) — closer match to B1ms
  allocated_storage    = 32
  storage_type         = "gp3"
  db_subnet_group_name = aws_db_subnet_group.psql.name
  vpc_security_group_ids = [aws_security_group.psql_sg.id]
  publicly_accessible  = false
  skip_final_snapshot  = true

  username = "psqladmin"
  password = random_password.db.result

  multi_az = false   # set true for HA (≈ zone redundancy in Azure)
}
```

> **Key difference**: AWS RDS runs in a DB Subnet Group (requires 2 subnets in different AZs even for single-AZ). Multi-AZ replaces Azure's zone-redundant HA option.

### GCP equivalent
```hcl
resource "google_sql_database_instance" "psql" {
  name             = "psql-n8n-mercury"
  database_version = "POSTGRES_16"
  region           = "us-west1"

  settings {
    tier              = "db-f1-micro"   # 0.6 GB shared; cheapest
    # tier            = "db-g1-small"   # 1.7 GB; closer to B1ms
    availability_type = "ZONAL"         # REGIONAL for HA (≈ zone redundancy)
    disk_size         = 32
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.vnet.id
    }

    backup_configuration {
      enabled    = true
      start_time = "03:00"
    }
  }
}

resource "google_sql_database" "app_db" {
  name     = "n8n"
  instance = google_sql_database_instance.psql.name
}

resource "google_sql_user" "psql_admin" {
  name     = "psqladmin"
  instance = google_sql_database_instance.psql.name
  password = random_password.db.result
}
```

> **Key difference**: GCP Cloud SQL `REGIONAL` availability type enables automatic failover (≈ Azure zone-redundant). GCP uses Private Service Access for private connectivity instead of VNet service endpoints.

---

## Phase 3 — Kubernetes Cluster

### Azure (current)
```hcl
resource "azurerm_kubernetes_cluster" "aks" {
  name               = "mercury-cluster"
  kubernetes_version = "1.32.0"
  dns_prefix         = "mercury"

  default_node_pool {
    name       = "agentpool"
    node_count = 1
    vm_size    = "Standard_D2s_v3"
  }

  network_profile {
    network_plugin      = "azure"   # Azure CNI
    network_policy      = "cilium"
    network_data_plane  = "cilium"
  }

  identity { type = "SystemAssigned" }
}
```

### AWS equivalent
```hcl
resource "aws_eks_cluster" "mercury" {
  name     = "mercury-cluster"
  version  = "1.32"
  role_arn = aws_iam_role.eks_cluster.arn

  vpc_config {
    subnet_ids              = [aws_subnet.private_a.id, aws_subnet.private_b.id]
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.eks_cluster_sg.id]
  }
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.mercury.name
  node_group_name = "agentpool"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = [aws_subnet.private_a.id, aws_subnet.private_b.id]
  instance_types  = ["m5.large"]   # ≈ Standard_D2s_v3

  scaling_config {
    desired_size = 1
    min_size     = 1
    max_size     = 3
  }
}

# Cilium CNI: install via Helm after cluster creation
# AWS VPC CNI is the default; replace or overlay with Cilium:
# helm install cilium cilium/cilium --namespace kube-system \
#   --set eni.enabled=true --set ipam.mode=eni --set egressMasqueradeInterfaces=eth0

# IAM roles (no managed identity — use IRSA instead)
resource "aws_iam_role" "eks_cluster" {
  name               = "eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}
```

> **Key differences**:
> - AWS EKS requires explicit IAM roles for the control plane and node groups (no "SystemAssigned" magic).
> - Cilium can be deployed on EKS in ENI mode (replaces the default VPC CNI) or as a chained plugin.
> - EKS lacks a built-in Flux extension — install Flux via Helm or use `flux bootstrap`.

### GCP equivalent
```hcl
resource "google_container_cluster" "mercury" {
  name             = "mercury-cluster"
  location         = "us-west1"        # regional (multi-zone HA)
  # location       = "us-west1-a"      # zonal (single zone, cheaper)
  min_master_version = "1.32"

  # Use a separately managed node pool
  remove_default_node_pool = true
  initial_node_count       = 1

  network    = google_compute_network.vnet.name
  subnetwork = google_compute_subnetwork.sub.name

  networking_mode = "VPC_NATIVE"   # ≈ Azure CNI (pod IPs from VPC)

  datapath_provider = "ADVANCED_DATAPATH"  # GKE Dataplane V2 (eBPF, ≈ Cilium)

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"   # ≈ OIDC issuer
  }

  ip_allocation_policy {}  # required for VPC_NATIVE
}

resource "google_container_node_pool" "default" {
  name       = "agentpool"
  cluster    = google_container_cluster.mercury.name
  location   = "us-west1"
  node_count = 1

  node_config {
    machine_type = "n2-standard-2"   # ≈ Standard_D2s_v3
    disk_size_gb = 50
    disk_type    = "pd-ssd"
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }
}
```

> **Key differences**:
> - GKE Dataplane V2 (`ADVANCED_DATAPATH`) is the built-in eBPF/Cilium equivalent — no separate Cilium install needed.
> - GKE Workload Identity replaces Azure Managed Identity for pod-level cloud IAM access.
> - Regional GKE clusters span 3 zones automatically; Azure requires explicit zone configurations.

---

## Phase 4 — Secrets + TLS + Ingress

### Azure Key Vault → AWS Secrets Manager

**Azure (current)**
```hcl
resource "azurerm_key_vault" "kv" {
  name                      = "kv-mercury-staging"
  sku_name                  = "standard"
  enable_rbac_authorization = true
  soft_delete_retention_days = 7
  purge_protection_enabled  = false
}

resource "azurerm_key_vault_secret" "db_host" {
  name         = "db-host"
  value        = azurerm_postgresql_flexible_server.psql.fqdn
  key_vault_id = azurerm_key_vault.kv.id
}

# CSI driver extension on AKS
resource "azurerm_kubernetes_cluster_extension" "kv_csi" {
  extension_type = "Microsoft.AzureKeyVaultSecretsProvider"
}
```

**AWS equivalent**
```hcl
resource "aws_secretsmanager_secret" "db_host" {
  name                    = "/mercury/staging/db-host"
  recovery_window_in_days = 7   # ≈ soft_delete_retention_days
}

resource "aws_secretsmanager_secret_version" "db_host" {
  secret_id     = aws_secretsmanager_secret.db_host.id
  secret_string = aws_db_instance.psql.address
}

# IRSA: allow EKS pods to read secrets (replaces Managed Identity + RBAC)
resource "aws_iam_role" "secrets_csi" {
  name               = "mercury-secrets-csi-role"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume.json  # bound to OIDC
}

resource "aws_iam_role_policy" "secrets_csi_policy" {
  role = aws_iam_role.secrets_csi.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = "arn:aws:secretsmanager:*:*:secret:/mercury/*"
    }]
  })
}

# CSI driver: install AWS Secrets and Configuration Provider (ASCP)
# helm install secrets-store-csi-driver secrets-store-csi-driver/secrets-store-csi-driver
# helm install aws-secrets-manager aws-secrets-manager/secrets-store-csi-driver-provider-aws
```

**SecretProviderClass for AWS**
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: mercury-secrets
spec:
  provider: aws
  parameters:
    objects: |
      - objectName: "/mercury/staging/db-host"
        objectType: "secretsmanager"
      - objectName: "/mercury/staging/db-password"
        objectType: "secretsmanager"
```

**GCP equivalent**
```hcl
resource "google_secret_manager_secret" "db_host" {
  secret_id = "db-host"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_host" {
  secret      = google_secret_manager_secret.db_host.id
  secret_data = google_sql_database_instance.psql.private_ip_address
}

# Workload Identity binding (replaces Managed Identity + Key Vault RBAC)
resource "google_secret_manager_secret_iam_member" "ksa_access" {
  secret_id = google_secret_manager_secret.db_host.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.project}.svc.id.goog[mercury/mercury-sa]"
}

# GKE Secret Manager CSI driver: enabled via add-on
resource "google_container_cluster" "mercury" {
  addons_config {
    gcp_filestore_csi_driver_config { enabled = false }
    # Secret Manager CSI driver: install separately via Helm or use GKE Secret Sync
  }
}
```

**SecretProviderClass for GCP**
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: mercury-secrets
spec:
  provider: gcp
  parameters:
    secrets: |
      - resourceName: "projects/MY_PROJECT/secrets/db-host/versions/latest"
        path: "db-host"
      - resourceName: "projects/MY_PROJECT/secrets/db-password/versions/latest"
        path: "db-password"
```

### cert-manager, Traefik — No Change

Both are cloud-agnostic Kubernetes components. The only difference is the ACME DNS-01 solver if you use DNS validation:

| Provider | cert-manager ACME DNS Solver |
|---|---|
| Azure | `azureDNS` (uses Azure DNS) |
| AWS | `route53` |
| GCP | `clouddns` |

```yaml
# AWS Route 53 solver
solvers:
  - dns01:
      route53:
        region: us-west-2
        hostedZoneID: Z1234567890ABC

# GCP Cloud DNS solver
solvers:
  - dns01:
      cloudDNS:
        project: my-gcp-project
        serviceAccountSecretRef:
          name: clouddns-credentials
          key: key.json
```

---

## Phase 5 — GitOps with Flux CD

### Azure (current)
```hcl
# Flux installed as an AKS Arc extension
resource "azurerm_kubernetes_cluster_extension" "flux" {
  extension_type = "microsoft.flux"
}

resource "azurerm_kubernetes_flux_configuration" "mercury" {
  scope           = "cluster"
  namespace       = "flux-system"
  git_repository {
    url             = "ssh://git@github.com/bmacharia/mercury-gitops"
    sync_interval   = "5m"
  }
}
```

### AWS / GCP equivalent

There is no managed Flux extension on EKS or GKE. Bootstrap Flux directly:

```bash
# Bootstrap (same for both AWS EKS and GCP GKE — Flux is cloud-agnostic)
flux bootstrap github \
  --owner=bmacharia \
  --repository=mercury-gitops \
  --branch=main \
  --path=clusters/staging \
  --personal
```

Or via Terraform:
```hcl
resource "helm_release" "flux" {
  name             = "flux2"
  repository       = "https://fluxcd-community.github.io/helm-charts"
  chart            = "flux2"
  version          = "2.14.0"
  namespace        = "flux-system"
  create_namespace = true
}
```

The `GitRepository`, `Kustomization`, and `HelmRelease` manifests remain **identical** — Flux is fully cloud-agnostic.

> **Key difference**: AKS allowed Flux to be managed as a cluster extension (with Azure managing the Flux lifecycle). On EKS/GKE, you own the Flux installation and upgrade cycle.

---

## Phase 6 — In-Cluster Database + Backups (CNPG)

CloudNativePG itself is **cloud-agnostic** — the same Helm chart and CRDs work on EKS, GKE, and AKS. The only change is the backup object store.

### Backup Storage

**Azure (current)**
```hcl
resource "azurerm_storage_account" "backups" {
  name                     = "mercurybackupsstaging"
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "customer1" {
  name                  = "customer1"
  storage_account_id    = azurerm_storage_account.backups.id
  container_access_type = "private"
}

resource "azurerm_storage_account_blob_container_sas" "customer1" {
  # 2-year SAS token with read/write/delete/list/add/create
  expiry = timeadd(timestamp(), "17520h")
}
```

**AWS equivalent**
```hcl
resource "aws_s3_bucket" "backups" {
  bucket = "mercury-backups-staging"
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Per-customer "folder" (prefix) — no separate container concept in S3
# customer1/ prefix = s3://mercury-backups-staging/customer1/

# IAM policy for CNPG backup (use IRSA instead of SAS tokens)
resource "aws_iam_policy" "cnpg_backup_customer1" {
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::mercury-backups-staging/customer1/*",
        "arn:aws:s3:::mercury-backups-staging"
      ]
    }]
  })
}
```

**GCP equivalent**
```hcl
resource "google_storage_bucket" "backups" {
  name          = "mercury-backups-staging"
  location      = "US-WEST1"
  storage_class = "STANDARD"

  versioning { enabled = true }

  uniform_bucket_level_access = true
}

# Per-customer IAM binding (prefix-level access via IAM Conditions)
resource "google_storage_bucket_iam_member" "cnpg_customer1" {
  bucket = google_storage_bucket.backups.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:cnpg-customer1@${var.project}.iam.gserviceaccount.com"
  condition {
    title      = "customer1-prefix-only"
    expression = "resource.name.startsWith('projects/_/buckets/mercury-backups-staging/objects/customer1/')"
  }
}
```

### CNPG ObjectStore — Backup Target Changes

**Azure (current)**
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: customer1-backup-store
spec:
  configuration:
    destinationPath: "https://mercurybackupsstaging.blob.core.windows.net/customer1"
    azureCredentials:
      connectionString:
        name: customer1-azure-secret
        key: AZURE_STORAGE_CONNECTION_STRING
```

**AWS equivalent**
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: customer1-backup-store
spec:
  configuration:
    destinationPath: "s3://mercury-backups-staging/customer1"
    s3Credentials:
      inheritFromIAMRole: true   # use IRSA — no static credentials needed
    # Or with explicit credentials:
    # s3Credentials:
    #   accessKeyId:
    #     name: customer1-s3-secret
    #     key: ACCESS_KEY_ID
    #   secretAccessKey:
    #     name: customer1-s3-secret
    #     key: SECRET_ACCESS_KEY
    endpointURL: ""   # leave blank for AWS S3 (only needed for MinIO/custom)
    region: us-west-2
```

**GCP equivalent**
```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: customer1-backup-store
spec:
  configuration:
    destinationPath: "gs://mercury-backups-staging/customer1"
    googleCredentials:
      gkeEnvironment: true   # use Workload Identity — no key file needed
    # Or with a service account key:
    # googleCredentials:
    #   applicationCredentials:
    #     name: customer1-gcs-secret
    #     key: credentials.json
```

---

## Phase 7 — AKS Hardening

### Node Pools

The system/user node pool split (CriticalAddonsOnly taint) works identically on EKS and GKE:

**AWS EKS**
```hcl
# System node pool
resource "aws_eks_node_group" "system" {
  node_group_name = "agentpool"
  taint {
    key    = "CriticalAddonsOnly"
    value  = "true"
    effect = "NO_SCHEDULE"
  }
  labels = { "kubernetes.azure.com/mode" = "system" }  # rename to neutral label
}

# User node pool
resource "aws_eks_node_group" "user" {
  node_group_name = "userpool"
  # no taint
}

# Auto-upgrade: use EKS Managed Node Group update config
update_config {
  max_unavailable_percentage = 33   # ≈ max_surge = "33%"
}
```

**GCP GKE**
```hcl
# System node pool
resource "google_container_node_pool" "system" {
  name = "agentpool"
  node_config {
    taint {
      key    = "CriticalAddonsOnly"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
  management {
    auto_upgrade = true   # ≈ automatic_upgrade_channel = "patch"
    auto_repair  = true
  }
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}

# User node pool
resource "google_container_node_pool" "user" {
  name = "userpool"
  # no taint
}
```

### RBAC / Identity Integration

| Feature | Azure | AWS | GCP |
|---|---|---|---|
| Admin group | Entra ID group UUID in `admin_group_object_ids` | `aws-auth` ConfigMap or EKS Access Entries mapping IAM group/role | GKE RBAC bound to Google Group (via GSuite) |
| Pod identity | Managed Identity + Workload Identity (OIDC) | IRSA (IAM Roles for Service Accounts via OIDC) | GKE Workload Identity |
| SSO/IdP | Azure AD / Entra ID | AWS IAM Identity Center + OIDC provider | Google Identity / Cloud Identity |

**AWS IRSA setup**
```hcl
# OIDC provider for the cluster
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.mercury.identity[0].oidc[0].issuer
}

# Trust policy for a specific Kubernetes ServiceAccount
data "aws_iam_policy_document" "irsa_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.eks.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:mercury:mercury-sa"]
    }
  }
}
```

**GCP Workload Identity setup**
```hcl
# Bind Kubernetes SA to GCP SA
resource "google_service_account_iam_binding" "workload_identity" {
  service_account_id = google_service_account.mercury.name
  role               = "roles/iam.workloadIdentityUser"
  members = [
    "serviceAccount:${var.project}.svc.id.goog[mercury/mercury-sa]"
  ]
}
```

### Maintenance Windows

| Feature | Azure | AWS | GCP |
|---|---|---|---|
| Window | Sunday 02:00 UTC, 4h | Maintenance window on node group | GKE Maintenance Window |
| Upgrade channel | `patch` | No channel concept; use `release_version` pinning | `STABLE`, `REGULAR`, `RAPID` |

**GCP maintenance window**
```hcl
resource "google_container_cluster" "mercury" {
  maintenance_policy {
    recurring_window {
      start_time = "2024-01-07T02:00:00Z"  # Sunday 02:00 UTC
      end_time   = "2024-01-07T06:00:00Z"  # 4h window
      recurrence = "FREQ=WEEKLY;BYDAY=SU"
    }
  }
  release_channel {
    channel = "STABLE"   # ≈ patch upgrade channel
  }
}
```

---

## Phase 9 — Monitoring & Alerting

### Stack Options

Prometheus + Grafana + kube-prometheus-stack are **fully cloud-agnostic**. The manifests and HelmRelease remain identical.

| Component | Azure | AWS | GCP |
|---|---|---|---|
| kube-prometheus-stack | Helm (self-hosted) | Helm (self-hosted) OR Amazon Managed Prometheus | Helm (self-hosted) OR Google Cloud Managed Prometheus |
| Grafana | Self-hosted in cluster | Self-hosted OR Amazon Managed Grafana | Self-hosted OR Google Cloud Managed Grafana |
| Log aggregation | Azure Monitor / Log Analytics | CloudWatch Logs / Fluent Bit → CloudWatch | Cloud Logging / Fluent Bit → Cloud Logging |
| Alerting | Telegram (cloud-agnostic) | Telegram (cloud-agnostic) | Telegram (cloud-agnostic) |

### Managed Prometheus (optional cloud-native alternative)

**AWS Managed Prometheus**
```hcl
resource "aws_prometheus_workspace" "mercury" {
  alias = "mercury-staging"
}

# Prometheus RemoteWrite config (add to kube-prometheus-stack values)
# remoteWrite:
#   - url: https://aps-workspaces.us-west-2.amazonaws.com/workspaces/<ID>/api/v1/remote_write
#     sigv4:
#       region: us-west-2
```

**GCP Managed Prometheus**
```hcl
# Enable in GKE cluster
resource "google_container_cluster" "mercury" {
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
    managed_prometheus { enabled = true }
  }
}
```

### Key Vault Secrets for Grafana

Grafana admin credentials and Telegram tokens stored in Key Vault map directly:

| Azure | AWS | GCP |
|---|---|---|
| Key Vault secret `grafana-admin-password` | Secrets Manager `/mercury/staging/grafana-admin-password` | Secret Manager `grafana-admin-password` |
| Key Vault secret `telegram-bot-token` | Secrets Manager `/mercury/staging/telegram-bot-token` | Secret Manager `telegram-bot-token` |

All PrometheusRules (database alerts), Grafana dashboards, and Telegram alerting configs are **cloud-agnostic** — no changes needed.

---

## Phase 10 — Multi-Tenant Customer Onboarding

The customer onboarding module provisions per-customer resources. Here is the mapping of each provisioned resource:

| Azure Resource | AWS Equivalent | GCP Equivalent |
|---|---|---|
| Storage Container (per customer) | S3 prefix or separate S3 bucket | GCS bucket or prefix with IAM condition |
| SAS token (per customer) | IAM policy + IRSA (no static tokens) | Workload Identity binding per SA |
| Key Vault secret (db-user) | Secrets Manager secret | Secret Manager secret |
| Key Vault secret (db-password) | Secrets Manager secret | Secret Manager secret |
| Key Vault secret (blob-sas) | Not needed — use IRSA | Not needed — use Workload Identity |
| Key Vault secret (telegram creds) | Secrets Manager secret | Secret Manager secret |
| GitOps manifests (namespace, etc.) | Identical (cloud-agnostic) | Identical (cloud-agnostic) |
| CNPG cluster CRD | Identical (cloud-agnostic) | Identical (cloud-agnostic) |
| Ingress (Traefik) | Identical, or swap to AWS Load Balancer Controller | Identical, or swap to GKE Ingress |
| NetworkPolicy (Cilium) | Cilium CNI or native VPC CNI NetworkPolicy | GKE Dataplane V2 NetworkPolicy (built-in) |

### Terraform Module Refactor for AWS

```hcl
# modules/customer-onboarding/main.tf (AWS version)
variable "customer_name" {}
variable "environment"   {}
variable "cluster_oidc_issuer_url" {}
variable "aws_account_id" {}

# S3 prefix (no separate container resource needed)
# Convention: s3://mercury-backups-${var.environment}/${var.customer_name}/

# IAM role for CNPG backup (replaces SAS token)
resource "aws_iam_role" "cnpg_backup" {
  name = "cnpg-backup-${var.customer_name}-${var.environment}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = "arn:aws:iam::${var.aws_account_id}:oidc-provider/${local.oidc_host}" }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_host}:sub" = "system:serviceaccount:${var.customer_name}:cnpg-backup-sa"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "cnpg_backup" {
  role = aws_iam_role.cnpg_backup.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::mercury-backups-${var.environment}/${var.customer_name}/*",
        "arn:aws:s3:::mercury-backups-${var.environment}"
      ]
    }]
  })
}

# Secrets Manager entries
resource "aws_secretsmanager_secret" "db_password" {
  name = "/mercury/${var.environment}/${var.customer_name}/db-password"
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = random_password.db.result
}

# GitOps manifests — identical structure, generated via templatefile()
resource "local_file" "namespace" {
  filename = "${path.module}/../../gitops/apps/${var.environment}/${var.customer_name}/namespace.yaml"
  content  = templatefile("${path.module}/templates/namespace.yaml.tpl", {
    customer = var.customer_name
  })
}
```

### Terraform Module Refactor for GCP

```hcl
# modules/customer-onboarding/main.tf (GCP version)
variable "customer_name" {}
variable "environment"   {}
variable "project"       {}

# GCS prefix via IAM condition (no separate bucket per customer)
resource "google_storage_bucket_iam_member" "cnpg_backup" {
  bucket = "mercury-backups-${var.environment}"
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:cnpg-${var.customer_name}@${var.project}.iam.gserviceaccount.com"
  condition {
    title      = "${var.customer_name}-prefix"
    expression = "resource.name.startsWith('projects/_/buckets/mercury-backups-${var.environment}/objects/${var.customer_name}/')"
  }
}

# Workload Identity binding
resource "google_service_account_iam_member" "cnpg_workload_identity" {
  service_account_id = google_service_account.cnpg.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[${var.customer_name}/cnpg-backup-sa]"
}

# Secret Manager entries
resource "google_secret_manager_secret" "db_password" {
  secret_id = "${var.customer_name}-${var.environment}-db-password"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "db_password" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = random_password.db.result
}
```

---

## Azure Region → AWS / GCP Region Mapping

| Azure Region | AWS Region | GCP Region |
|---|---|---|
| `westus2` (Oregon) | `us-west-2` (Oregon) | `us-west1` (Oregon) |
| `northeurope` (Ireland) | `eu-west-1` (Ireland) | `europe-west1` (Belgium) |
| `eastus` (Virginia) | `us-east-1` (N. Virginia) | `us-east1` (S. Carolina) |
| `westeurope` (Netherlands) | `eu-west-3` (Paris) | `europe-west4` (Netherlands) |
| `southeastasia` (Singapore) | `ap-southeast-1` (Singapore) | `asia-southeast1` (Singapore) |

---

## VM SKU Mapping

| Azure SKU | vCPU | RAM | AWS Instance | GCP Machine Type |
|---|---|---|---|---|
| `Standard_D2s_v3` | 2 | 8 GB | `m5.large` | `n2-standard-2` |
| `Standard_D4s_v3` | 4 | 16 GB | `m5.xlarge` | `n2-standard-4` |
| `Standard_D8s_v3` | 8 | 32 GB | `m5.2xlarge` | `n2-standard-8` |
| `Standard_B2s` | 2 | 4 GB | `t3.medium` | `e2-medium` |
| `Standard_B4ms` | 4 | 16 GB | `t3.xlarge` | `e2-standard-4` |
| `B_Standard_B1ms` (PostgreSQL) | 1 | 2 GB | `db.t3.small` | `db-g1-small` |
| `B_Standard_B2ms` (PostgreSQL) | 2 | 4 GB | `db.t3.medium` | `db-custom-2-4096` |

---

## Storage Redundancy Mapping

| Azure | AWS | GCP |
|---|---|---|
| LRS (Locally Redundant, 3 copies in 1 AZ) | S3 Standard (3+ AZ by default) | GCS Standard (multi-region by default) |
| ZRS (Zone Redundant, 3 AZs same region) | S3 Standard (equivalent) | GCS (Regional, 2+ zones) |
| GRS (Geo-Redundant, 2 regions) | S3 Cross-Region Replication | GCS Dual-Region / Multi-Region |
| GZRS (Geo-Zone Redundant) | S3 CRR + Standard | GCS Multi-Region |

> **Note**: AWS S3 Standard and GCS Standard are already multi-AZ within a region by default — Azure LRS is the weakest tier (single AZ). When migrating, AWS/GCP standard storage is already more resilient than Azure LRS.

---

## Summary of Key Architectural Differences

| Concern | Azure | AWS | GCP |
|---|---|---|---|
| Organizational boundary | Resource Group | Account / Resource Tags | Project |
| Managed identity for pods | Managed Identity (OIDC) | IRSA (IAM Roles for Service Accounts) | Workload Identity |
| Kubernetes-native secrets | Key Vault CSI Driver | AWS Secrets & Config Provider (ASCP) | GKE Secret Manager CSI / Secret Sync |
| Network policy | Cilium (add-on) | VPC CNI NetworkPolicy or Cilium | GKE Dataplane V2 (built-in eBPF) |
| Flux GitOps | Managed AKS Arc extension | Self-managed via `flux bootstrap` | Self-managed via `flux bootstrap` |
| Cluster upgrade channel | `patch` (automatic) | Managed Node Group + version pinning | GKE Release Channel (STABLE) |
| Object storage auth | SAS tokens (time-limited URL) | IAM + IRSA (no static tokens) | Workload Identity (no key files) |
| Ingress L4 | Azure Load Balancer (auto) | NLB via `service.beta.kubernetes.io/aws-load-balancer-type: nlb` | Cloud L4 Load Balancer (auto via `type: LoadBalancer`) |
| Static credential risk | SAS tokens in Key Vault | Eliminated by IRSA | Eliminated by Workload Identity |
