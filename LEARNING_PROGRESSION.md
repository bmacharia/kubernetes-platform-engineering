# Mercury Platform Engineering: Learning Progression (Phases 1–10)

## Overview

A 10-phase journey from zero cloud knowledge to running a production-grade, multi-tenant Kubernetes platform. Each phase builds directly on the last.

**Application deployed throughout:** [n8n](https://n8n.io) — a workflow automation platform used as the real workload across all phases.

**Cloud provider:** Microsoft Azure
**Primary IaC tool:** Terraform
**GitOps engine:** Flux CD

---

## Phase 1 — The Foundation
### Infrastructure as Code Basics

**Focus:** Azure VM, networking fundamentals, Terraform intro

**What you build:**
- Single Ubuntu 24.04 LTS VM on Azure (`Standard_D2s_v3` — 2 vCPU, 8 GB RAM)
- VNet (`10.0.0.0/16`), Subnet (`10.0.1.0/24`), NSG, Public IP — all in one `vm.tf` file
- SSH key authentication (no passwords)

**Key concepts:**
- Infrastructure as Code (IaC) with Terraform
- Azure networking primitives: VNet → Subnet → NSG → NIC → VM
- Security-first from day one (SSH only, no password auth)

**Milestone:** You can provision and SSH into a cloud VM using only code.

---

## Phase 2 — Reusable Infrastructure
### Terraform Modules

**Focus:** DRY principle, tenant isolation, parameterization

**What you build:**
- A `customer-infrastructure` Terraform module
- Per-customer: isolated VNet, VM, and PostgreSQL Flexible Server v16
- Multiple customer instances from a single module definition

**Key concepts:**
- Module inputs, outputs, and variables
- Multi-tenant isolation via separate VNets (no network overlap between customers)
- Managed database provisioning (7-day backup retention)

**Milestone:** You can provision identical but isolated environments for multiple customers by calling one module.

---

## Phase 3 — Moving to Kubernetes
### Azure Kubernetes Service (AKS)

**Focus:** Container orchestration, Kubernetes basics, Kustomize

**What you build:**
- AKS cluster (`mercury-cluster`, Kubernetes 1.32) with Cilium networking
- First Kubernetes manifests: Namespace, Deployment, Service, PVC, ConfigMap
- n8n deployed with a LoadBalancer Service for external access
- Two manifest generations (`v0`, `v1`) showing iterative improvement

**Key concepts:**
- VMs → Kubernetes mental model shift
- Kubernetes resource types and their relationships
- Kustomize for manifest organisation
- Persistent storage (PersistentVolumeClaim)
- Cilium as the network data plane

**Milestone:** A real application is running in Kubernetes and accessible from the internet.

---

## Phase 4 — Cluster Infrastructure
### Ingress, TLS, and Secrets

**Focus:** Ingress controllers, certificate management, proper networking

**What you build:**
- **Traefik** ingress controller (replaces raw LoadBalancer Service)
- **cert-manager** with Let's Encrypt ClusterIssuer (automated TLS certificates)
- Ingress resource with automatic HTTPS
- Secrets placeholder pattern

**Key concepts:**
- Ingress vs. LoadBalancer Service tradeoffs
- ACME protocol and certificate lifecycle
- DNS → ingress controller → pod traffic flow
- Separating secrets from config

**Milestone:** Your app is HTTPS with auto-renewing certificates. No more manual cert management.

---

## Phase 5 — GitOps
### Flux CD

**Focus:** Git as single source of truth, declarative operations

**What you build:**
- Flux CD installed via the Microsoft AKS extension
- Full GitOps repo structure:
  - `apps/base/` — per-customer manifests
  - `apps/staging/` — environment overlays
  - `infrastructure/controllers/` — Helm releases (cert-manager, CNPG, Traefik)
  - `infrastructure/configs/` — ClusterIssuers and other configs
- Dependency ordering enforced: `infra-controllers` → `infra-configs` → `apps`
- Helm releases managed declaratively via Flux `HelmRelease` CRDs

**Key concepts:**
- GitOps philosophy: desired state lives in Git, Flux reconciles actual state to match
- Kustomize overlay pattern (base + environment overlays)
- Flux Kustomization dependency chains
- SSH deploy keys for secure Git access
- Garbage collection (resources deleted from Git are removed from the cluster)

**Milestone:** No more `kubectl apply`. All changes go through Git. Flux handles the rest.

---

## Phase 6 — In-Cluster Databases
### CloudNativePG

**Focus:** Stateful applications, PostgreSQL operator, backup strategies

**What you build:**
- Replace Azure PostgreSQL Flexible Server with **CloudNativePG** (in-cluster operator)
- PostgreSQL `Cluster` resource (multi-replica, v16)
- **Barman ObjectStore** → Azure Blob Storage for WAL archiving and base backups
- `ScheduledBackup` resource (daily, with configurable retention)

**Key concepts:**
- Kubernetes operator pattern (CRDs extending the Kubernetes API)
- Stateful workloads in Kubernetes
- Backup/restore architecture (WAL archiving + base backups)
- SAS tokens for Azure Blob Storage access
- Database HA with read replicas managed by the operator

**Milestone:** Database lives in Kubernetes with automated daily backups to cloud storage.

---

## Phase 7 — AKS Hardening
### Production Cluster Configuration

**Focus:** Security hardening, RBAC, node pool separation, automated upgrades

**What you change:**

| Feature | Before (Phase 6) | After (Phase 7) |
|---|---|---|
| Authentication | Local Kubernetes RBAC | **Entra ID + Azure RBAC** |
| Node pools | Single `default` pool | `system` (critical addons) + `user` (workloads) |
| System pool taint | None | `CriticalAddonsOnly:NoSchedule` |
| Cluster upgrades | Manual | **Automatic `patch` channel** |
| Node OS upgrades | Manual | **`NodeImage` auto-upgrade** |
| Maintenance window | Any time | **Sunday 02:00 UTC** |
| Max surge | Not set | **33%** |

**Key concepts:**
- System vs. user node pool separation — critical addons never compete with workloads for resources
- Taint/toleration mechanics for workload placement control
- Azure Entra ID for cluster authentication and RBAC
- Key Vault integration for secrets
- Rolling upgrade strategies

**Milestone:** Cluster can run unattended in production. No manual patching required.

---

## Phase 8 — Workload Hardening
### Pod Security Standards

**Focus:** Defence in depth, Pod Security Standards, network policies

**What you add to every workload:**

```yaml
# Namespace level
pod-security.kubernetes.io/enforce: restricted

# Pod security context
runAsNonRoot: true
runAsUser: 1000
fsGroup: 1000
seccompProfile:
  type: RuntimeDefault

# Container security context
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]

# Resources
requests: { memory: 256Mi, cpu: 100m }
limits:   { memory: 1Gi,  cpu: 1000m }

# Health probes
livenessProbe:  { httpGet: /healthz, initialDelaySeconds: 30 }
readinessProbe: { httpGet: /healthz, periodSeconds: 5 }
```

**CiliumNetworkPolicy (explicit allow-list):**
- Ingress: allow from Traefik namespace on port 3008
- Egress: allow to CNPG pods (5432), kube-dns (53/UDP), external HTTPS (443)

**Key concepts:**
- NSA/CISA Kubernetes Hardening Guide principles
- Linux capabilities and privilege escalation attack surface
- Immutable containers (`readOnlyRootFilesystem` + `emptyDir` for writable paths)
- Resource requests vs. limits and OOM behaviour
- Cilium network policies as a microsegmentation layer

**Milestone:** Every pod runs with least privilege. The blast radius of a compromise is minimised.

---

## Phase 9 — Observability
### Monitoring, Dashboards, and Alerts

**Focus:** Prometheus metrics, Grafana dashboards, Telegram notifications

**What you build:**
- **kube-prometheus-stack** via Flux HelmRelease (Prometheus + Grafana + AlertManager + exporters)
- Grafana alert rules (PrometheusRule CRDs) covering:
  - n8n application down
  - CNPG operator down
  - Database cluster degraded
  - Long-running transactions (> 5 minutes)
  - Node disk/memory pressure
  - Pod crash looping
- **Telegram Bot** as the alert notification contact point
- Grafana admin password injected from Azure Key Vault via CSI driver

**Monitoring data flow:**
```
node-exporter + kube-state-metrics
        ↓
    Prometheus (scrape & store)
        ↓
Grafana Alerting (evaluate rules)
        ↓
   Telegram notification
```

**Key concepts:**
- Prometheus metrics model (labels, scrape targets, PromQL)
- Grafana native alerting vs. Alertmanager routing
- External notification channels (Telegram Bot API)
- Secrets injection from Key Vault into Grafana
- The four golden signals: latency, traffic, errors, saturation

**Milestone:** You receive a Telegram message when anything breaks — before customers notice.

---

## Phase 10 — Customer Onboarding
### Automation at Scale

**Focus:** Multi-tenant provisioning, infrastructure code generation, one-line customer add

**What you build:**
- `customer-onboarding` Terraform module that generates **everything** per customer
- `customers.tf` — the only file you ever edit to add a new customer:

```hcl
locals {
  customers = toset([
    "julius",
    "cicero",
    "crassus",   # Add this line → terraform apply → done
  ])
}
```

**What the module auto-provisions per customer:**

| Layer | Resource |
|---|---|
| Azure | Blob Storage container for DB backups |
| Azure Key Vault | DB password, connection string, SAS token, Telegram bot token + chat ID |
| Kubernetes | Namespace (PSS restricted), SecretProviderClass, ConfigMap |
| Database | CNPG PostgreSQL Cluster, Barman backup config, ScheduledBackup |
| Application | n8n Deployment (hardened), Service, Ingress with TLS |
| Security | CiliumNetworkPolicy |
| GitOps | Full Flux Kustomization hierarchy with dependency ordering |

**Flux dependency chain (enforced ordering):**
```
infra-controllers  (Traefik, cert-manager, CNPG operator)
        ↓
infra-configs      (ClusterIssuers, cert-manager config)
        ↓
cnpg-plugin        (Barman cloud plugin — needs cert-manager webhooks ready)
        ↓
apps               (Customer workloads — needs CNPG plugin ready for backups)
```

**Environments:**
- `staging/` — test environment (`cd staging && terraform apply`)
- `production/` — production environment (`cd production && terraform apply`)

**Key concepts:**
- Terraform `local_file` provider for YAML manifest generation
- `for_each` on module instantiation (one module call per customer)
- Terraforming your GitOps — infrastructure generates GitOps manifests
- Multi-environment promotion (staging → production)
- Scale without linear toil

**Milestone:** A new customer goes from request to fully running, monitored, and backed-up n8n in minutes. You write one line of code.

---

## Full Progression at a Glance

```
Phase 1   VM + VNet                           IaC Fundamentals
Phase 2   Terraform Modules                   Reusability + Multi-tenancy
Phase 3   AKS + Kubernetes Basics             Container Orchestration
Phase 4   Traefik + cert-manager              Ingress + TLS
Phase 5   Flux CD GitOps                      Declarative Operations
Phase 6   CloudNativePG + Backups             Stateful Workloads
Phase 7   AKS Hardening + Entra ID            Production Cluster
Phase 8   Pod Security Standards              Workload Hardening
Phase 9   Prometheus + Grafana + Telegram     Observability
Phase 10  Automated Onboarding Module         Platform at Scale
```

**Full technology stack by Phase 10:**
Terraform · Azure (AKS, Key Vault, Blob Storage, Entra ID, PostgreSQL Flexible Server) · Kubernetes · Cilium · Kustomize · Helm · Flux CD · Traefik · cert-manager · Let's Encrypt · CloudNativePG · Barman · Prometheus · Grafana · Telegram Bot API
