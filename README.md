```markdown
# Kubernetes Platform Engineering on Azure AKS

A production-grade, multi-tenant Kubernetes platform built from the ground up on Microsoft Azure — from a single VM to a fully automated customer onboarding system, documented across 10 progressive phases.

Every phase deploys and runs **n8n** (a real workflow automation platform) on actual Azure resources.

---

## The Platform in One Sentence

By Phase 10, onboarding a new customer — with an isolated namespace, PostgreSQL database, TLS-secured ingress, daily backups to Azure Blob Storage, network policies, and real-time alerts — requires adding **one line of code** and running `terraform apply`.

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
Azure Subscription
└── AKS Cluster
    ├── system node pool (CriticalAddonsOnly)
    ├── user node pool (workloads)
    ├── Traefik (Ingress) + cert-manager (TLS)
    ├── Flux CD (GitOps reconciliation)
    ├── Prometheus + Grafana + Alertmanager
    └── Per-customer resources:
        ├── Namespace (restricted Pod Security Standards)
        ├── n8n Deployment (fully hardened)
        ├── CloudNativePG PostgreSQL Cluster + Barman backups
        └── CiliumNetworkPolicy
```

Git is the single source of truth. Flux continuously reconciles the live cluster to match the desired state in Git.

---

## 10-Phase Journey

| Phase | Focus                          | Key Outcome                                      |
|-------|--------------------------------|--------------------------------------------------|
| 1     | IaC Basics                     | Single VM + networking with Terraform            |
| 2     | Terraform Modules              | Reusable, isolated customer environments         |
| 3     | AKS + Kubernetes               | First real workloads running with Cilium         |
| 4     | Ingress + TLS                  | Traefik + cert-manager + automatic HTTPS         |
| 5     | GitOps                         | Full FluxCD with dependency ordering             |
| 6     | Stateful Workloads             | CloudNativePG + automated backups to Blob Storage|
| 7     | Cluster Hardening              | Entra ID, system/user node pools, auto-upgrades  |
| 8     | Workload Security              | Restricted PSS + Cilium network policies         |
| 9     | Observability                  | Prometheus, Grafana, and Telegram alerts         |
| 10    | Automated Onboarding           | One-line tenant provisioning                     |

---

## Technology Stack

| Category               | Technologies                                      |
|------------------------|---------------------------------------------------|
| Cloud                  | Microsoft Azure (AKS, Key Vault, Blob Storage, Entra ID) |
| Infrastructure as Code | Terraform                                         |
| Orchestration          | AKS (Kubernetes 1.32), Cilium                     |
| GitOps                 | Flux CD, Kustomize, Helm                          |
| Ingress & TLS          | Traefik, cert-manager, Let's Encrypt              |
| Database               | CloudNativePG (PostgreSQL 16) + Barman            |
| Secrets                | Azure Key Vault + CSI Secret Store Driver         |
| Observability          | kube-prometheus-stack, Telegram Bot               |
| Security               | Pod Security Standards (restricted), CiliumNetworkPolicy |

---

## Repository Structure

```
├── LEARNING_PROGRESSION.md
├── phase-1-vm/
├── phase-2-modules/
├── phase-3-aks/
├── phase-4-k8s-infra/
├── phase-5-gitops/
├── phase-6-cnpg/
├── phase-7-aks-hardening/# Kubernetes Platform Engineering on Azure
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

├── phase-8-production-n8n/
├── phase-9-observability/
└── phase-10-onboarding/
```

---

## Connect

- LinkedIn: [linkedin.com/in/babu-macharia](https://www.linkedin.com/in/babu-macharia)
- GitHub: [github.com/bmacharia](https://github.com/bmacharia)
```
