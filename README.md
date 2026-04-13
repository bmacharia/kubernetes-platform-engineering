# Kubernetes Platform Engineering on Azure

[![Repo](https://img.shields.io/badge/GitHub-bmacharia%2Fkubernetes--platform--engineering-blue?logo=github)](https://github.com/bmacharia/kubernetes-platform-engineering)

A production-grade, multi-tenant Kubernetes platform built from the ground up on Microsoft Azure — from a single VM to a fully automated customer onboarding system, documented across 10 progressive phases.

> **Real infrastructure. Real workloads. Real decisions.**
> No toy examples — every phase deploys and runs [n8n](https://n8n.io), a production workflow automation platform, on actual Azure resources.

---

## What This Project Demonstrates

| Capability | Technologies |
|---|---|
| Infrastructure as Code | Terraform, Azure Provider |
| Container Orchestration | AKS (Kubernetes 1.32), Cilium |
| GitOps | Flux CD, Kustomize, Helm |
| Ingress & TLS | Traefik, cert-manager, Let's Encrypt |
| In-Cluster Databases | CloudNativePG, PostgreSQL 16, Barman |
| Secrets Management | Azure Key Vault, CSI Secret Store Driver |
| Identity & RBAC | Azure Entra ID, Azure RBAC |
| Observability | Prometheus, Grafana, Alertmanager, Telegram |
| Multi-Tenant Automation | Terraform modules, `for_each`, local_file provider |
| Workload Security | Pod Security Standards, CiliumNetworkPolicy |

---

## The Platform in One Sentence

By Phase 10, onboarding a new customer — with their own isolated Kubernetes namespace, PostgreSQL database, TLS-secured ingress, daily backups to Azure Blob Storage, and real-time Telegram alerts — requires adding **one line of code** and running `terraform apply`.

```hcl
locals {
  customers = toset([
    "julius",
    "cicero",
    "crassus",   # ← Add this. That's it.
  ])
}
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Azure Subscription                        │
│                                                                   │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │                   AKS Cluster                            │    │
│  │                                                          │    │
│  │   system node pool          user node pool              │    │
│  │   (CriticalAddonsOnly)      (workloads)                 │    │
│  │                                                          │    │
│  │   ┌─────────┐  ┌──────────┐  ┌──────────────────────┐ │    │
│  │   │ Traefik │  │   Flux   │  │  customer-julius      │ │    │
│  │   │ Ingress │  │   CD     │  │  ┌────┐ ┌──────────┐ │ │    │
│  │   └────┬────┘  └──────────┘  │  │n8n │ │ CNPG DB  │ │ │    │
│  │        │                      │  └────┘ └──────────┘ │ │    │
│  │        │       ┌──────────┐  └──────────────────────┘ │    │
│  │        │       │  Prom +  │  ┌──────────────────────┐ │    │
│  │        │       │  Grafana │  │  customer-cicero      │ │    │
│  │        │       └──────────┘  │  ┌────┐ ┌──────────┐ │ │    │
│  │        │                      │  │n8n │ │ CNPG DB  │ │ │    │
│  │        │                      │  └────┘ └──────────┘ │ │    │
│  └────────┼──────────────────────┴──────────────────────┴─┘    │
│           │                                                       │
│    ┌──────┴──────┐   ┌─────────────┐   ┌──────────────────┐    │
│    │  Public IP  │   │  Key Vault  │   │   Blob Storage   │    │
│    │  (Traefik)  │   │  (Secrets)  │   │  (DB Backups)    │    │
│    └─────────────┘   └─────────────┘   └──────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
          ↑
    Git push → Flux reconciles → cluster matches desired state
```

---

## The 10-Phase Journey

Each phase solves a real problem introduced by the previous one. The progression mirrors how a platform engineering team actually builds and matures a Kubernetes platform.

### Phase 1 — Infrastructure as Code Basics
**Problem solved:** Stop clicking in the Azure Portal.

Provisions a single Ubuntu VM with a full network stack (VNet, Subnet, NSG, Public IP) using a single Terraform file. SSH-only access, no passwords. The foundation for everything that follows.

**Key skills:** Terraform basics, Azure networking primitives, IaC mindset.

---

### Phase 2 — Terraform Modules
**Problem solved:** Don't repeat yourself for multiple customers.

Extracts the VM + PostgreSQL provisioning into a reusable `customer-infrastructure` module. Multiple isolated customer environments — separate VNets, separate databases — from a single module call.

**Key skills:** Module design, parameterization, multi-tenant isolation.

---

### Phase 3 — Azure Kubernetes Service
**Problem solved:** VMs don't scale. Kubernetes does.

Provisions an AKS cluster with Cilium networking and deploys n8n as the first real Kubernetes workload. Covers the full set of Kubernetes primitives: Namespace, Deployment, Service, PVC, ConfigMap. Kustomize used for manifest organisation.

**Key skills:** AKS provisioning, Kubernetes resource model, Kustomize overlays, Cilium.

---

### Phase 4 — Ingress, TLS, and Secrets
**Problem solved:** Raw LoadBalancer IPs are not production.

Installs Traefik as the cluster ingress controller and cert-manager with a Let's Encrypt ClusterIssuer. n8n is now accessible via HTTPS with automatically renewing certificates. Introduces the secrets placeholder pattern.

**Key skills:** Ingress controllers, ACME/Let's Encrypt, certificate lifecycle, Traefik routing.

---

### Phase 5 — GitOps with Flux CD
**Problem solved:** `kubectl apply` by hand is risky and unauditable.

Installs Flux CD via the Microsoft AKS extension and restructures all manifests into a GitOps repository. Changes to the cluster go through Git. Flux enforces dependency ordering: `infra-controllers` → `infra-configs` → `apps`. Garbage collection ensures deleted manifests are removed from the cluster.

**Key skills:** GitOps philosophy, Flux Kustomizations, HelmRelease CRDs, dependency chains, SSH deploy keys.

---

### Phase 6 — In-Cluster Databases with CloudNativePG
**Problem solved:** Managed Azure PostgreSQL is expensive and external.

Replaces Azure PostgreSQL Flexible Server with the CloudNativePG operator running in-cluster. PostgreSQL 16 with read replicas. WAL archiving and daily base backups to Azure Blob Storage via Barman ObjectStore.

**Key skills:** Kubernetes operator pattern, stateful workloads, WAL archiving, backup/restore architecture, SAS tokens.

---

### Phase 7 — AKS Cluster Hardening
**Problem solved:** A default AKS cluster is not production-ready.

| Feature | Before | After |
|---|---|---|
| Authentication | Local Kubernetes RBAC | Entra ID + Azure RBAC |
| Node pools | Single default pool | system + user (workload isolation) |
| System pool taint | None | `CriticalAddonsOnly:NoSchedule` |
| Cluster upgrades | Manual | Automatic patch channel |
| Node OS upgrades | Manual | NodeImage auto-upgrade |
| Maintenance window | Any time | Sunday 02:00 UTC |

**Key skills:** Entra ID integration, node pool separation, taint/toleration design, automated upgrade channels.

---

### Phase 8 — Workload Security (Pod Security Standards)
**Problem solved:** Containers running as root with excessive privileges.

Every workload is hardened to the `restricted` Pod Security Standard: non-root user, read-only root filesystem, all Linux capabilities dropped, explicit resource limits, liveness and readiness probes. CiliumNetworkPolicies enforce explicit allow-lists for all ingress and egress traffic.

**Key skills:** Pod Security Standards, Linux capabilities, seccomp profiles, Cilium microsegmentation, defence-in-depth.

---

### Phase 9 — Observability
**Problem solved:** You can't fix what you can't see.

Deploys the full `kube-prometheus-stack` via Flux HelmRelease. Grafana alert rules (PrometheusRule CRDs) cover application health, database state, node pressure, and pod crash loops. Alerts are delivered to a Telegram Bot. Grafana admin credentials are injected from Azure Key Vault via the CSI driver.

```
node-exporter + kube-state-metrics
        ↓
    Prometheus (scrape & store)
        ↓
Grafana Alerting (evaluate rules)
        ↓
   Telegram notification
```

**Key skills:** Prometheus metrics model, PromQL, Grafana alerting, PrometheusRule CRDs, Key Vault secret injection.

---

### Phase 10 — Automated Customer Onboarding
**Problem solved:** Each new customer requires hours of manual work.

A single `customer-onboarding` Terraform module provisions the complete per-customer stack. The only file ever edited is `customers.tf`.

**What the module provisions per customer, automatically:**

| Layer | Resource |
|---|---|
| Azure | Blob Storage container for DB backups |
| Azure Key Vault | DB password, connection string, SAS token, Telegram tokens |
| Kubernetes | Namespace (PSS restricted), SecretProviderClass, ConfigMap |
| Database | CNPG PostgreSQL Cluster + Barman backup + ScheduledBackup |
| Application | n8n Deployment (fully hardened), Service, Ingress + TLS |
| Security | CiliumNetworkPolicy |
| GitOps | Full Flux Kustomization hierarchy with dependency ordering |

**Key skills:** Terraform `for_each`, `local_file` provider for manifest generation, environment promotion (staging → production), Terraforming your GitOps.

---

## Technology Stack

```
Cloud             Microsoft Azure
IaC               Terraform
Cluster           AKS (Azure Kubernetes Service), Kubernetes 1.32
Networking        Cilium (CNI + network policy)
Package Mgmt      Helm, Kustomize
GitOps            Flux CD
Ingress           Traefik
TLS               cert-manager, Let's Encrypt (ACME)
Database          CloudNativePG (PostgreSQL 16), Barman ObjectStore
Secrets           Azure Key Vault, CSI Secret Store Driver
Identity          Azure Entra ID, Azure RBAC
Observability     Prometheus, Grafana, Alertmanager, kube-prometheus-stack
Alerting          Telegram Bot API
Storage           Azure Blob Storage (database backups)
Security          Pod Security Standards, CiliumNetworkPolicy
Toolchain         mise (version manager)
Workload          n8n workflow automation platform
```

---

## Repository Structure

```
mercury-workflows-sanitized/
├── phase-1-vm/              # Terraform: single VM + network
├── phase-2-modules/         # Terraform: customer-infrastructure module
├── phase-3-aks/             # Terraform: AKS cluster + first k8s manifests
├── phase-4-k8s-infra/       # Traefik, cert-manager, Ingress, TLS
├── phase-5-gitops/          # Flux CD + full GitOps repo structure
│   └── mercury-gitops/
│       ├── apps/            # Per-customer manifests + env overlays
│       └── infrastructure/  # controllers/ + configs/ (Helm releases)
├── phase-6-cnpg/            # CloudNativePG, Barman backups
├── phase-7-aks-hardening/   # Entra ID, node pools, auto-upgrades
├── phase-8-production-n8n/  # Pod Security Standards, network policies
├── phase-9-monitoring/      # kube-prometheus-stack, Grafana alerts
└── phase-10-onboarding/     # Customer onboarding module
    ├── modules/             # customer-onboarding module
    ├── staging/             # staging environment
    └── production/          # production environment

LEARNING_PROGRESSION.md      # Phase-by-phase technical summary
platform-engineering-deep-dive.md  # Mentor-style walkthrough
```

---

## Key Engineering Decisions

**Why CloudNativePG instead of managed Azure PostgreSQL?**
Cost, portability, and operator-native backup semantics. The CNPG operator manages HA, failover, and WAL archiving natively in Kubernetes, without a separate managed service dependency.

**Why Flux CD over Argo CD?**
Flux's AKS native extension simplifies bootstrap. Its pull-based model and Kustomization dependency chains map cleanly to the infra → config → apps layering used here.

**Why Traefik over NGINX Ingress?**
Traefik's native Let's Encrypt integration and dynamic configuration discovery reduce operational overhead for a multi-tenant setup where new ingress rules are continuously being added.

**Why Terraform generates GitOps manifests?**
At scale, maintaining per-customer YAML files by hand is error-prone. The `local_file` provider generates the GitOps manifests as part of `terraform apply`, keeping infrastructure state and cluster state in sync from a single source of truth.

---

## Running the Platform

### Prerequisites

```bash
# Tool versions managed via mise
mise install   # installs terraform, kubectl, helm at pinned versions
```

### Provision a Phase

```bash
cd mercury-workflows-sanitized/phase-3-aks
terraform init
terraform plan
terraform apply
```

### Onboard a New Customer (Phase 10)

```bash
# 1. Add one line to customers.tf
# 2. Apply
cd mercury-workflows-sanitized/phase-10-onboarding/staging
terraform apply

# 3. Flux detects new manifests in Git and reconciles
# 4. Customer is live with TLS, database, backups, and alerts
```

---

## Documentation

- [`LEARNING_PROGRESSION.md`](./LEARNING_PROGRESSION.md) — concise phase-by-phase reference (what's built, key concepts, milestone)
- [`platform-engineering-deep-dive.md`](./mercury-workflows-sanitized/platform-engineering-deep-dive.md) — mentor-style technical walkthrough explaining every decision

---

*Built on Azure · Kubernetes 1.32 · Terraform · Flux CD · CloudNativePG · Prometheus*
