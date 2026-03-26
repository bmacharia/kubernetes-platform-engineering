# Kubernetes Platform Engineering — Deep Dive Walkthrough

> A mentor-style walkthrough of building a production Kubernetes platform on Azure, phase by phase.

---

## Table of Contents

- [The Big Picture](#the-big-picture)
- [Phase 1: The Virtual Machine](#phase-1-the-virtual-machine--crawl-before-you-walk)
- [Phase 2: Terraform Modules](#phase-2-terraform-modules--dont-repeat-yourself)
- [Phase 3: Azure Kubernetes Service](#phase-3-azure-kubernetes-service--the-platform-shift)
- [Phase 4: Kubernetes Infrastructure](#phase-4-kubernetes-infrastructure--making-it-real)
- [Phase 5: GitOps with Flux CD](#phase-5-gitops-with-flux-cd--git-is-the-source-of-truth)
- [Phase 6: CloudNativePG](#phase-6-cloudnativepg--the-database-goes-in-cluster)
- [Phase 7: AKS Hardening](#phase-7-aks-hardening--production-grade-cluster)
- [Phase 8: Production n8n](#phase-8-production-n8n--hardening-the-workload)
- [Phase 9: Monitoring & Alerting](#phase-9-monitoring--alerting--you-cant-fix-what-you-cant-see)
- [Phase 10: Customer Onboarding](#phase-10-customer-onboarding--the-platform-is-complete)

---

## The Big Picture

Before we dive in, understand what we're building: a **platform** that can onboard customers to their own isolated n8n workflow automation instance, running on Kubernetes in Azure, with automated TLS, database backups, monitoring, alerting, and GitOps-driven deployments. By Phase 10, adding a new customer is literally adding one line to a file and running `terraform apply`.

But we don't start there. We start with a VM.

---

## Phase 1: The Virtual Machine — "Crawl Before You Walk"

**What's in it:** A single `vm.tf` file. That's it.

**What it builds:**
- 1 Resource Group (`rg-terraform-demo`)
- 1 Virtual Network (`10.0.0.0/16`) with 1 Subnet (`10.0.1.0/24`)
- 1 Network Security Group (only SSH port 22 open)
- 1 Public IP (static)
- 1 Linux VM — Ubuntu 24.04 LTS, `Standard_D2s_v3` (2 vCPU, 8GB RAM)
- SSH key auth only, no passwords

**Why this matters:**

This is your foundation. Every cloud journey starts here. You're learning:

1. **Infrastructure as Code (IaC)** — Instead of clicking around the Azure portal, you describe what you want in code. Reproducible, version-controlled, reviewable.
2. **Azure networking fundamentals** — VNet, Subnet, NSG, NIC, Public IP. These are the building blocks. Even when we get to Kubernetes, these concepts don't go away — they just get abstracted.
3. **Security from day one** — SSH-only access, key-based auth, no password login. This is the right habit.

**The problem with this approach:** Everything is manual. If you need 5 customers, you copy-paste this file 5 times. If a customer needs a database, you manually SSH in and install PostgreSQL. It doesn't scale.

### Deep Dive: The Tooling

The `mise.toml` at the repo root defines the **toolchain**:

```toml
terraform = "latest"
kubectl   = "latest"
helm      = "latest"
```

[mise](https://mise.jdx.dev/) is a tool version manager (like `nvm` for Node, but for everything). This ensures every engineer on the team runs the same version of `terraform`, `kubectl`, etc. Without this, you get "works on my machine" issues. **Pinning your tools is one of the first things a mature team does.**

### Deep Dive: The `.gitignore` — What Never Goes Into Git

```
*.tfstate
*.tfstate.*
*.tfvars
.terraform/
```

- **`.terraform/`** — Where `terraform init` downloads provider binaries. Like `node_modules/`. Generated, huge, never committed.
- **`*.tfstate`** — Terraform's **state file**. Contains a mapping between your code and actual Azure resources. Contains sensitive data (resource IDs, IPs, sometimes passwords). **If this leaks, an attacker knows your entire infrastructure topology.** Never commit it.
- **`*.tfvars`** — Variable files that often contain secrets like passwords and subscription IDs. Keep them local.

### Deep Dive: Block by Block

#### The Terraform Configuration (Lines 2-10)

```hcl
terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
  }
}
```

Declares two constraints:

- **`required_version = ">= 1.0"`** — If someone has Terraform 0.15, they get an error immediately instead of cryptic failures halfway through. It's a guardrail.
- **`required_providers`** — Terraform itself doesn't know how to talk to Azure. It uses **providers** — plugins that translate HCL code into Azure API calls. `~> 4.0` means "any 4.x version" (4.0, 4.52, 4.57... but not 5.0). The `~>` is a **pessimistic constraint** — allows patch/minor updates but blocks major versions with breaking changes.

**Think of it this way:** Terraform is the engine. The provider is the steering wheel that knows how to drive on Azure's roads.

#### The Provider Configuration (Lines 12-19)

```hcl
provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }
  subscription_id = "..."
}
```

- **`subscription_id`** — Azure organizes everything under subscriptions (billing and access boundaries). Tells Terraform where to put resources.
- **`prevent_deletion_if_contains_resources = false`** — Allows `terraform destroy` to wipe a resource group and everything in it. Useful for dev/demo. In production, leave as `true`.
- **Authentication** — Uses the Azure CLI session (`az login`). The provider picks it up automatically.

#### Resource Groups (Lines 22-30)

```hcl
resource "azurerm_resource_group" "main" {
  name     = "rg-terraform-demo"
  location = "westus2"
}
```

- **Resource Group** — Azure's top-level organizational container. Every resource must live inside one. Think of it as a folder.
- **`westus2`** — Oregon, US. Common choice for demos — large region with good service availability.
- **Naming convention** (`rg-` prefix) follows Azure's recommended naming standards. At 200 resources, `rg-terraform-demo` vs `myresourcegroup1` makes a huge difference.

**Terraform syntax:**
- `resource` — keyword for "create this thing"
- `"azurerm_resource_group"` — resource type (from provider)
- `"main"` — local name for referencing in other blocks (never shows up in Azure)

#### Virtual Network (Lines 33-38)

```hcl
resource "azurerm_virtual_network" "main" {
  name                = "vnet-demo"
  address_space       = ["10.0.0.0/16"]
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
}
```

- **VNet** — Your private network in the cloud. Nothing outside can reach in unless explicitly allowed.
- **`10.0.0.0/16`** — CIDR notation. `/16` = 65,536 IP addresses (10.0.0.0 through 10.0.255.255). Private range (RFC 1918).
- **Why so many IPs?** Over-provision. It costs nothing, and running out later forces painful re-architecture.
- **Resource references** (`azurerm_resource_group.main.location`) create **dependency declarations**. Terraform knows the VNet depends on the RG and must be created second.

#### Subnet (Lines 41-46)

```hcl
resource "azurerm_subnet" "main" {
  name                 = "subnet-demo"
  resource_group_name  = azurerm_resource_group.main.name
  virtual_network_name = azurerm_virtual_network.main.name
  address_prefixes     = ["10.0.1.0/24"]
}
```

- **Subnet** — A segment within the VNet. Carve VNets into subnets for isolation, security, and routing.
- **`10.0.1.0/24`** — 256 IPs. A slice of the parent `/16`.

#### Public IP (Lines 49-54)

```hcl
resource "azurerm_public_ip" "main" {
  name                = "pip-demo"
  allocation_method   = "Static"
}
```

- **Static** — The IP stays the same even if you stop/start the VM. Essential for SSH and DNS.

#### Network Security Group (Lines 57-73)

```hcl
resource "azurerm_network_security_group" "main" {
  security_rule {
    name                       = "SSH"
    priority                   = 1001
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}
```

Read as a sentence: "Allow inbound TCP traffic from any source IP, any source port, to any destination IP, on port 22."

- **`priority = 1001`** — Rules evaluated lowest first. Azure reserves 65000-65500. 1001 leaves room for higher-priority rules later.
- **`source_address_prefix = "*"`** — Any IP can connect. **In production, lock this to your office IP or VPN.**
- **What's NOT here:** No rules for port 80, 443, 3306, etc. Default Azure NSG behavior is **deny all inbound** unless explicitly allowed.

#### Network Interface (Lines 76-87)

```hcl
resource "azurerm_network_interface" "main" {
  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.main.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.main.id
  }
}
```

- **NIC** — Connects a VM to a subnet. Has two IPs:
  - **Private** (Dynamic from `10.0.1.x`) — For intra-VNet communication
  - **Public** — The static IP for SSH access from the internet

#### NSG-to-NIC Association (Lines 90-93)

```hcl
resource "azurerm_network_interface_security_group_association" "main" {
  network_interface_id      = azurerm_network_interface.main.id
  network_security_group_id = azurerm_network_security_group.main.id
}
```

Separate resource because NSGs have a many-to-many relationship with NICs. One NSG can protect multiple NICs.

#### The Virtual Machine (Lines 96-123)

```hcl
resource "azurerm_linux_virtual_machine" "main" {
  name                = "vm-demo"
  size                = "Standard_D2s_v3"
  admin_username      = "azureuser"

  admin_ssh_key {
    username   = "azureuser"
    public_key = file(pathexpand("~/.ssh/mercury.pub"))
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }
}
```

- **`Standard_D2s_v3`** — D=General purpose, 2=vCPUs, s=Premium storage, v3=3rd gen. 2 vCPU, 8GB RAM (~$70-100/month).
- **`file(pathexpand("~/.ssh/mercury.pub"))`** — Reads your SSH public key from local filesystem. Asymmetric crypto — VM gets public key, you keep private key.
- **`Standard_LRS`** — Locally Redundant Storage. 3 copies within one datacenter. Cheapest option.
- **Ubuntu 24.04 LTS** — Long Term Support = 5 years of security updates. Always use LTS for servers.

#### Outputs (Lines 126-132)

```hcl
output "public_ip" {
  value = azurerm_public_ip.main.ip_address
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/mercury azureuser@${azurerm_public_ip.main.ip_address}"
}
```

After `terraform apply`, prints the SSH command you need. Copy, paste, connect.

### The Dependency Graph

```
Resource Group (rg-terraform-demo)
├── Virtual Network (10.0.0.0/16)
│   └── Subnet (10.0.1.0/24)
│       └── Network Interface
│           ├── ← Public IP (static)
│           ├── ← NSG Association ← Network Security Group (SSH only)
│           └── → Virtual Machine (Ubuntu 24.04, 2 vCPU, 8GB)
└── (all resources live here)
```

Terraform parallelizes everything it can. You declare the end state; Terraform figures out the execution order.

### The Workflow

```bash
az login                    # Authenticate to Azure
cd phase-1-vm
terraform init              # Download azurerm provider
terraform plan              # Preview: "8 to add, 0 to change, 0 to destroy"
terraform apply             # Create everything (~2-3 minutes)
ssh -i ~/.ssh/mercury azureuser@<the-ip>   # Connect
terraform destroy           # Delete everything when done
```

### What Phase 1 Teaches

1. **Everything is code.** 133 lines describes the entire environment.
2. **Azure networking is layered.** VNet → Subnet → NIC → VM.
3. **Security is explicit.** Only SSH is open. No "default allow all."
4. **Dependencies are implicit.** Reference resources; Terraform figures out the order.
5. **State matters.** `terraform.tfstate` tracks what was created.

### What's Wrong (Setting Up Phase 2)

1. Everything in one file — doesn't scale.
2. No variables — all hardcoded.
3. No remote state — local tfstate = risk.
4. NSG source is wide open (`*`).
5. Single resource group pattern — 10 customers = 10 copies.

---

## Phase 2: Terraform Modules — "Don't Repeat Yourself"

**What changes:** The monolithic `vm.tf` gets refactored into a **reusable module**.

**Directory structure shift:**

```
phase-1-vm/
└── vm.tf                              ← Everything in one file

phase-2-modules/
├── main.tf                            ← The "caller" — declares WHAT you want
└── modules/
    └── customer-infrastructure/
        ├── main.tf                    ← The "blueprint" — declares HOW to build it
        ├── variables.tf               ← The inputs (the knobs you can turn)
        └── outputs.tf                 ← The results (what comes out)
```

**Separation of concerns:** The root `main.tf` says "I want infrastructure for customer Cato and customer Cicero." The module defines what "customer infrastructure" actually means. The caller doesn't care about subnets and NICs. The module doesn't care who's calling it or how many times.

### Deep Dive: The Variables — The Module Contract

`modules/customer-infrastructure/variables.tf`

Variables define the **contract** — read a function's signature before reading its body.

```hcl
variable "customer_name" {
  description = "Name of the customer (used for resource naming)"
  type        = string
}
```

**No default = required.** If you call this module without providing `customer_name`, Terraform errors immediately. `type = string` means Terraform rejects non-strings at plan time. **Fail fast, fail early.**

```hcl
variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "westus2"
}
```

**Has a default = optional.** Falls back to `westus2` if not specified. The caller can override (and does — passes `"northeurope"`).

```hcl
variable "postgres_admin_password" {
  description = "Admin password for PostgreSQL"
  type        = string
  sensitive   = true
}
```

**`sensitive = true`** — Terraform replaces the value with `(sensitive value)` in all output. Without it, the password appears in plain text in `terraform plan` output and CI/CD logs.

**Variable contract summary:**

| Variable | Required? | Why |
|----------|-----------|-----|
| `customer_name` | Yes | Every resource is named after the customer |
| `location` | No (default: westus2) | Most customers go to the same region |
| `vnet_cidr` | Yes | Each customer needs a unique IP range |
| `admin_username` | No (default: azureuser) | Standard convention |
| `ssh_public_key` | Yes | Unique per deployer |
| `postgres_admin_password` | Yes, sensitive | Unique per customer |

### Deep Dive: The Module — What Gets Built

`modules/customer-infrastructure/main.tf`

#### Parameterized Naming

**Phase 1:**
```hcl
name = "rg-terraform-demo"
```

**Phase 2:**
```hcl
name = "rg-${var.customer_name}"
```

String interpolation. `customer_name = "cato"` → `"rg-cato"`. **The module is a template.** Structure is identical for every customer; names, IPs, and credentials are unique.

#### SSH Key Handling Change

**Phase 1:**
```hcl
public_key = file(pathexpand("~/.ssh/mercury.pub"))
```

**Phase 2:**
```hcl
public_key = var.ssh_public_key
```

The module doesn't read the file itself — it receives the key as a string input. **Modules should not have side effects like reading local files.** This makes the module portable — works whether the key comes from a file, CI/CD secret, or Key Vault.

#### New: `disable_password_authentication = true`

Explicitly tells Azure "do not allow password-based SSH login." Even if someone set a password on the account, SSH rejects it. Keys only. **Defense in depth.**

#### New: Data Source

```hcl
data "azurerm_client_config" "current" {}
```

**Data sources** read existing infrastructure without creating anything. `azurerm_client_config` returns info about the current Azure session (subscription ID, tenant ID, object ID). Preparation for Key Vault integration in later phases.

#### New: PostgreSQL Flexible Server

```hcl
resource "azurerm_postgresql_flexible_server" "customer" {
  name                = "psql-${var.customer_name}"
  administrator_login    = "psqladmin"
  administrator_password = var.postgres_admin_password

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768
  version    = "16"
  zone       = "2"

  backup_retention_days        = 7
  geo_redundant_backup_enabled = false
  public_network_access_enabled = true
}
```

- **`B_Standard_B1ms`** — Burstable tier. 1 vCore, 2 GB RAM (~$12-15/month). `B`=Burstable (dev/test), `GP`=General Purpose (production), `MO`=Memory Optimized (analytics).
- **`version = "16"`** — PostgreSQL 16, latest stable. Always pick latest for new deployments.
- **`zone = "2"`** — Availability Zone 2 (arbitrary for demo). Production uses zone-redundant HA.
- **`backup_retention_days = 7`** — Azure auto-takes daily backups with 7-day retention. Built-in, no cron jobs.
- **`public_network_access_enabled = true`** — Demo convenience. Production uses **Private Endpoints** (database only reachable from within VNet).

#### New: Database Firewall Rule

```hcl
resource "azurerm_postgresql_flexible_server_firewall_rule" "customer" {
  start_ip_address = "0.0.0.0"
  end_ip_address   = "0.0.0.0"
}
```

Azure magic value: `0.0.0.0` to `0.0.0.0` means **"allow connections from other Azure services"** (not the entire internet). Required for the VM to reach the database.

### Deep Dive: The Outputs

`modules/customer-infrastructure/outputs.tf`

```hcl
output "vm_public_ip" {
  value = azurerm_public_ip.customer.ip_address
}

output "postgres_fqdn" {
  value = azurerm_postgresql_flexible_server.customer.fqdn
}

output "ssh_connection" {
  value = "ssh ${var.admin_username}@${azurerm_public_ip.customer.ip_address}"
}
```

**Outputs are the module's return values.** The root config accesses them via `module.cato.vm_public_ip`. Without outputs, the module is a black box with no window.

**`postgres_fqdn`** — Fully Qualified Domain Name like `psql-cato.postgres.database.azure.com`. More stable than an IP — Azure can change the IP, but the FQDN always resolves.

### Deep Dive: The Root Configuration — How Modules Are Called

`main.tf`

```hcl
module "cato" {
  source = "./modules/customer-infrastructure"

  customer_name           = "cato"
  location                = "northeurope"
  vnet_cidr               = "10.1.0.0/16"
  ssh_public_key          = file("~/.ssh/mercury.pub")
  postgres_admin_password = "CatoP@ssw0rd123!"
}

module "cicero" {
  source = "./modules/customer-infrastructure"

  customer_name           = "cicero"
  location                = "northeurope"
  vnet_cidr               = "10.2.0.0/16"
  ssh_public_key          = file("~/.ssh/mercury.pub")
  postgres_admin_password = "CiceroP@ssw0rd123!"
}
```

**Two module calls, same source, different inputs.** This is the payoff:

- **`module "cato"`** creates: `rg-cato`, `vnet-cato` (10.1.0.0/16), `vm-cato`, `psql-cato`
- **`module "cicero"`** creates: `rg-cicero`, `vnet-cicero` (10.2.0.0/16), `vm-cicero`, `psql-cicero`

**16 resources from 36 lines.** Phase 1 needed 133 lines for 8 resources. Adding a third customer? 10 more lines.

**Network isolation:** Cato gets `10.1.0.0/16`, Cicero gets `10.2.0.0/16`. Completely separate VNets. Cato's VM cannot reach Cicero's database. **Tenant isolation by design.**

### The Dependency Graph: Parallel Stacks

```
                ┌──────────────────┐     ┌──────────────────┐
                │  module "cato"   │     │ module "cicero"  │
                ├──────────────────┤     ├──────────────────┤
                │ rg-cato          │     │ rg-cicero        │
                │ ├── vnet-cato    │     │ ├── vnet-cicero  │
                │ │   └── subnet   │     │ │   └── subnet   │
                │ ├── pip-cato     │     │ ├── pip-cicero   │
                │ ├── nic-cato     │     │ ├── nic-cicero   │
                │ ├── vm-cato      │     │ ├── vm-cicero    │
                │ └── psql-cato    │     │ └── psql-cicero  │
                └──────────────────┘     └──────────────────┘
                       ↕                        ↕
                Totally isolated          Totally isolated
```

Terraform processes both modules **in parallel** — no dependencies between them.

### Phase 1 vs Phase 2 Comparison

| Concern | Phase 1 | Phase 2 |
|---------|---------|---------|
| File structure | 1 file (vm.tf) | 4 files across 2 directories |
| Customers | 1, hardcoded | N, parameterized |
| Resource naming | `"rg-terraform-demo"` | `"rg-${var.customer_name}"` |
| Database | None | PostgreSQL per customer |
| Network isolation | Single VNet | Separate VNet per customer |
| Reusability | Zero — copy-paste | Module call to duplicate |
| Secrets | None | Password marked `sensitive` |

### The Key Mental Model

Phase 2 teaches **layers of abstraction**:

```
Layer 3 (Operator):    "I need infrastructure for customer Cato"     → main.tf
Layer 2 (Module):      "Customer infrastructure means VM + DB + Net" → module/main.tf
Layer 1 (Provider):    "A VM means these Azure API calls"            → azurerm provider
Layer 0 (Azure):       Actual hardware in a datacenter               → Microsoft's problem
```

This layering is the same pattern in Kubernetes: Deployment → ReplicaSet → Pod → Container → Process.

### What's Still Wrong (Setting Up Phase 3)

1. **Passwords in plain text** in `main.tf` — in Git for anyone to see.
2. **No remote state** — two engineers can't work simultaneously.
3. **No NSG in the module** — VM has no firewall rules.
4. **VM-per-customer doesn't scale** — $80-115/month per customer. At 50 customers = $4,000-5,000/month.
5. This is the problem **Kubernetes solves in Phase 3** — shared compute with isolated workloads.

---

## Phase 3: Azure Kubernetes Service — "The Platform Shift"

**What changes:** We throw away the VMs entirely and provision an AKS cluster.

**What it builds:**
- 1 AKS cluster (`mercury-cluster`, Kubernetes 1.32.0)
- 1 node (`Standard_D2s_v3`)
- Azure CNI with **Cilium** for networking and network policies
- Azure PostgreSQL Flexible Server (external managed DB)
- Kubernetes manifests for **n8n** (the workflow automation app)

**Two versions of manifests show the learning progression:**

- **`manifests-v0/`** (SQLite) — n8n running with embedded SQLite. Quick to set up but not production-ready (single replica only, data lives on a PVC).
- **`manifests-v1/`** (PostgreSQL) — n8n connected to the external Azure-managed PostgreSQL. Database credentials in a ConfigMap (not ideal yet, but works).

**Key concepts introduced:**

1. **Namespaces** — Isolation boundaries within the cluster (`n8n` namespace)
2. **Deployments** — Declarative workload management ("I want 1 replica of n8n running")
3. **Services** — Internal DNS and load balancing
4. **PersistentVolumeClaims** — Stateful storage that survives pod restarts
5. **ConfigMaps** — Externalized configuration
6. **Kustomize** — Compose and customize manifests without templating
7. **Security contexts** — Running as non-root (UID 1000), disabling privilege escalation

**The problem:** Secrets in plain text. No TLS. No ingress controller. No GitOps — manual `kubectl apply`.

---

## Phase 4: Kubernetes Infrastructure — "Making It Real"

**New components:**
- **Azure Key Vault** — Secrets stored securely, not in YAML files
- **Secrets Store CSI Driver** — Injects Key Vault secrets into pods as env vars
- **cert-manager** — Automatic TLS certificates from Let's Encrypt
- **Traefik Ingress Controller** — Routes external traffic to services
- **Ingress resource** — `customer1.mercury.mischavandenburg.net` with HTTPS

Service type changes from `LoadBalancer` to `ClusterIP` (Traefik handles external traffic).

**What you learn:**
1. **Secrets management** — Never store credentials in Git. Key Vault + CSI Driver.
2. **TLS/HTTPS** — cert-manager auto-provisions Let's Encrypt certificates.
3. **Ingress** — One ingress controller routes by hostname instead of one LoadBalancer per service.
4. **RBAC** — Key Vault access via Azure RBAC roles, principle of least privilege.

---

## Phase 5: GitOps with Flux CD — "Git Is the Source of Truth"

Manual `kubectl apply` replaced by **Flux CD** — continuous sync from Git.

```
Git Repository (mercury-gitops/)
  ├── infrastructure/controllers/    ← Helm releases (Traefik, cert-manager, CNPG)
  ├── infrastructure/configs/        ← Cluster-wide configs (certificate issuers)
  └── apps/base/customer1/           ← Application manifests
```

**What you learn:**
1. **Auditability** — Every change is a Git commit
2. **Rollbacks** — Revert a commit, cluster rolls back
3. **Dependency ordering** — Flux handles infra → configs → apps
4. **Drift detection** — Cluster always matches Git
5. **Pull-based deployment** — Cluster pulls desired state, no CI/CD needs cluster creds

---

## Phase 6: CloudNativePG — "The Database Goes In-Cluster"

External Azure PostgreSQL replaced by **CNPG (CloudNativePG)** — PostgreSQL inside the cluster.

- 3-instance PostgreSQL clusters (1 primary, 2 replicas)
- WAL archiving to Azure Blob Storage via Barman
- Daily scheduled backups at 3 AM UTC
- 14-day backup retention
- Point-in-time recovery capability

**Why:** Cost (no per-instance Azure charges), consistency (everything managed the same way), control (you choose PostgreSQL version/extensions).

---

## Phase 7: AKS Hardening — "Production-Grade Cluster"

| Before | After |
|--------|-------|
| Single node pool | **System pool** (tainted) + **User pool** |
| Local Kubernetes RBAC | **Entra ID (Azure AD) + Kubernetes RBAC** |
| Manual upgrades | **Automatic patch-level upgrades** |
| No maintenance window | **Sundays 02:00 UTC, 4-hour window** |
| No surge control | **33% max surge** for rolling upgrades |

**System pool taint (`CriticalAddonsOnly`)** — Only critical components (CoreDNS, kube-proxy, Cilium) run there. If a user workload goes crazy, it can't take down control components.

---

## Phase 8: Production n8n — "Hardening the Workload"

**Pod Security Standards (Restricted level):**
```yaml
securityContext:
  runAsNonRoot: true
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
  seccompProfile:
    type: RuntimeDefault
```

**Resource management:** Requests (256Mi/100m) and Limits (1Gi/1000m). Health checks on `/healthz`.

**Cilium Network Policy:**
- Ingress: Only Traefik → n8n on port 3008
- Egress: Database (5432), DNS (53), HTTPS (443)
- Everything else denied by default

---

## Phase 9: Monitoring & Alerting — "You Can't Fix What You Can't See"

- **Prometheus** — Metrics collection, 7-day retention
- **Grafana** — Dashboards with Let's Encrypt TLS
- **Telegram integration** — Critical alerts to your phone

**Alert rules:**

| Alert | Severity |
|-------|----------|
| n8n pod not running | Critical |
| Failed backup (24h) | Critical |
| WAL archiving failure | Warning |
| Replication lag > 5min | Warning |
| Replica not streaming | Critical |
| Long-running transaction > 5min | Warning |
| Database fenced | Critical |

---

## Phase 10: Customer Onboarding — "The Platform Is Complete"

Adding a new customer:

```hcl
locals {
  customers = toset([
    "julius",
    "cicero",
    "crassus",
    "brutus",
    "new_customer"    # ← Add one line
  ])
}
```

`terraform apply` auto-generates: namespace, secrets, configmap, CNPG database cluster, backups, deployment, service, ingress, network policy. Flux picks up the manifests and deploys everything.

**Flux dependency chain:**
```
infra-controllers → infra-configs → cnpg-plugin → apps → monitoring-controllers → monitoring-configs
```

---

## The Journey Summarized

| Phase | What You Learn | Key Concept |
|-------|---------------|-------------|
| **1** | Provision a VM on Azure | Infrastructure as Code |
| **2** | Reusable modules, multi-tenancy | DRY principle, modularization |
| **3** | Kubernetes fundamentals | Container orchestration |
| **4** | Secrets, TLS, ingress | Production infrastructure |
| **5** | GitOps with Flux | Declarative, auditable deployments |
| **6** | In-cluster databases with CNPG | Stateful workloads on K8s |
| **7** | Node pools, RBAC, auto-upgrades | Cluster hardening |
| **8** | PSS, network policies, probes | Workload hardening |
| **9** | Prometheus, Grafana, alerting | Observability |
| **10** | Automated customer onboarding | Platform engineering |

**Phase 1** is one person deploying one VM. **Phase 10** is a platform team running a multi-tenant SaaS platform where onboarding a customer is a one-line code change.
