# Kubernetes-Platform-engineering

A self-directed Azure platform build, taken end to end from a single Terraform-provisioned VM to automated multi-tenant customer onboarding on AKS. Designed, deployed, and paid for on my own Azure account over ten progressive phases — each phase solving a real problem introduced by the previous one.

The workload running on top of the platform is [n8n](https://n8n.io), a workflow automation tool. Each "customer" gets their own isolated Kubernetes namespace, PostgreSQL database, TLS-secured ingress, daily backups to Azure Blob Storage, and real-time alerts to Telegram — all provisioned from a single Terraform module.

## The headline

By the final phase, onboarding a new customer means adding one line to `customers.tf` and running `terraform apply`:

```hcl
locals {
  customers = toset([
    "julius",
    "cicero",
    "crassus",   # ← Add this line. That's it.
  ])
}
```

Terraform `for_each` then generates the full per-customer stack: Azure Blob container, Key Vault secrets, Kubernetes Namespace with Pod Security Standards, CloudNativePG cluster with scheduled Barman backups, n8n Deployment with network policy, Traefik Ingress with cert-manager TLS, and the Flux Kustomization hierarchy that wires it all together. The `local_file` provider writes the generated GitOps manifests back into the repo, Flux picks them up, and the new customer is live.

I think of this pattern as *Terraforming your GitOps* — Terraform owns the cloud resources, Flux owns the in-cluster state, and Terraform generates the manifests that bridge the two so they stay in sync from a single source of truth.

## Architecture

```
┌──────────────────────── Azure Subscription ────────────────────────┐
│                                                                     │
│   ┌──────────────────── AKS Cluster ────────────────────┐          │
│   │                                                      │          │
│   │   system pool (CriticalAddonsOnly)   user pool      │          │
│   │                                                      │          │
│   │   ┌─────────┐  ┌──────┐   ┌─── customer-julius ──┐ │          │
│   │   │ Traefik │  │ Flux │   │  ┌────┐  ┌────────┐  │ │          │
│   │   │ Ingress │  │  CD  │   │  │ n8n│  │ CNPG DB│  │ │          │
│   │   └────┬────┘  └──────┘   │  └────┘  └────────┘  │ │          │
│   │        │                   └──────────────────────┘ │          │
│   │        │      ┌──────────┐ ┌─── customer-cicero ──┐│          │
│   │        │      │ Prom +   │ │  ┌────┐  ┌────────┐  ││          │
│   │        │      │ Grafana  │ │  │ n8n│  │ CNPG DB│  ││          │
│   │        │      └──────────┘ │  └────┘  └────────┘  ││          │
│   │        │                    └──────────────────────┘│          │
│   └────────┼──────────────────────────────────────────┘           │
│            │                                                       │
│      ┌─────┴─────┐  ┌───────────┐  ┌──────────────────┐          │
│      │ Public IP │  │ Key Vault │  │   Blob Storage    │          │
│      │ (Traefik) │  │ (Secrets) │  │  (DB Backups)     │          │
│      └───────────┘  └───────────┘  └──────────────────┘          │
└─────────────────────────────────────────────────────────────────────┘
         ↑
   git push  →  Flux reconciles  →  cluster matches desired state
```

## Stack

| Layer | Tool |
|---|---|
| Cloud | Microsoft Azure |
| IaC | Terraform (AzureRM provider) |
| Cluster | AKS, Kubernetes 1.32 |
| Networking | Cilium (CNI + NetworkPolicy) |
| GitOps | Flux CD (AKS extension), Kustomize, Helm |
| Ingress | Traefik |
| TLS | cert-manager + Let's Encrypt |
| Database | CloudNativePG (PostgreSQL 16) with Barman backups |
| Secrets | Azure Key Vault + CSI Secret Store Driver |
| Identity | Azure Entra ID + Azure RBAC |
| Observability | kube-prometheus-stack (Prometheus, Grafana, Alertmanager) |
| Alerts | Telegram Bot API |
| Workload | n8n |

## The ten phases

The repo is structured as a phase-by-phase progression because that's how I actually built it — each phase solved a problem introduced by the previous one. This isn't a curriculum; it's the order in which the problems arose.

**Phase 1 — A single VM.** Terraform + Azure networking primitives (VNet, Subnet, NSG). Stop clicking in the portal.

**Phase 2 — Reusable Terraform modules.** A `customer-infrastructure` module so multiple isolated environments come from a single module call. Don't repeat yourself.

**Phase 3 — AKS.** Provision the cluster with Cilium, deploy n8n as the first real workload. Cover the core Kubernetes primitives (Namespace, Deployment, Service, PVC, ConfigMap) with Kustomize.

**Phase 4 — Ingress and TLS.** Traefik + cert-manager + Let's Encrypt. No more raw LoadBalancer IPs.

**Phase 5 — GitOps with Flux CD.** Restructure all manifests into a GitOps repo. Flux enforces dependency order: `infra-controllers` → `infra-configs` → `apps`. Garbage collection removes deleted manifests from the cluster.

**Phase 6 — In-cluster databases with CloudNativePG.** Replace managed Azure PostgreSQL with the CNPG operator. PostgreSQL 16 with read replicas, WAL archiving, and scheduled base backups to Azure Blob via Barman.

**Phase 7 — AKS hardening.** This is the phase that turns a default cluster into something I'd actually trust:

| | Default AKS | After Phase 7 |
|---|---|---|
| Auth | Local Kubernetes RBAC | Entra ID + Azure RBAC |
| Node pools | Single pool | system + user, separated |
| System taint | None | `CriticalAddonsOnly:NoSchedule` |
| Cluster upgrades | Manual | Automatic patch channel |
| Node OS upgrades | Manual | NodeImage auto-upgrade |
| Maintenance window | Any time | Sunday 02:00 UTC |

**Phase 8 — Pod Security Standards + network policy.** Every workload runs as non-root, with a read-only root filesystem, all Linux capabilities dropped, explicit resource limits, and liveness/readiness probes. CiliumNetworkPolicies enforce explicit allow-lists for ingress and egress.

**Phase 9 — Observability.** `kube-prometheus-stack` via Flux HelmRelease. PrometheusRule CRDs for application health, database state, node pressure, and pod crash loops. Grafana alerts route to Telegram. Grafana admin credentials are injected from Key Vault via the CSI driver — no secrets in Git.

**Phase 10 — Automated customer onboarding.** The `customer-onboarding` Terraform module ties it all together. `for_each` over the customer set, `local_file` provider generates the per-customer GitOps manifests, Flux applies them. One line in `customers.tf` provisions the entire per-customer stack.

## Engineering decisions worth calling out

**Why CloudNativePG instead of managed Azure PostgreSQL?** Cost is part of it, but the bigger reason is that the operator pattern keeps the database lifecycle inside the same GitOps loop as everything else. Failover, WAL archiving, and backup scheduling are Kubernetes resources I can review in PRs. Managed services pull state out of Git.

**Why Flux CD over Argo CD?** Both are pull-based, so that's not the differentiator. The real reasons: Flux is Kustomize-native (a `Kustomization` CR maps almost one-to-one to `kustomize build`), the AKS extension simplifies bootstrap, and Flux's Kustomization dependency chains map cleanly to the layered infra → config → apps structure I'm using. If I were running a multi-team platform with developers who need a UI to self-serve, I'd reconsider Argo's `ApplicationSets` and built-in UI.

**Why Traefik over NGINX Ingress?** Native ACME integration and dynamic configuration discovery — both reduce friction for a multi-tenant setup where new ingress rules are continuously being added by the onboarding module.

**Why have Terraform generate GitOps manifests?** This is the architectural choice I'm most proud of. Customer state lives in Azure (Key Vault, Blob Storage) *and* in Kubernetes (namespaces, secrets, Flux Kustomizations). Maintaining those by hand drifts immediately. Letting Terraform generate the Kubernetes manifests via `local_file` keeps both sides of the customer state in sync from a single `terraform apply`.

## What this project is, and isn't

It's a self-directed build on real Azure infrastructure that I paid for personally. Every phase was deployed and exercised end to end. The platform onboards new customers in a single `terraform apply`, and I've watched that work.

It's not a battle-tested production platform — I haven't run it under load, simulated a region failure, or operated it for a team of users. For incident-driven operational experience, see my [pi-cluster](https://github.com/bmacharia/pi-cluster) repo, which is where I do the messier work of debugging real outages and writing postmortems.

## Repo layout

```
mercury-workflows-sanitized/
├── phase-1-vm/              # Terraform: VM + network
├── phase-2-modules/         # customer-infrastructure module
├── phase-3-aks/             # AKS cluster + first manifests
├── phase-4-k8s-infra/       # Traefik, cert-manager, ingress, TLS
├── phase-5-gitops/          # Flux CD + GitOps repo structure
│   └── mercury-gitops/
│       ├── apps/            # per-customer manifests + overlays
│       └── infrastructure/  # controllers/ + configs/
├── phase-6-cnpg/            # CloudNativePG + Barman
├── phase-7-aks-hardening/   # Entra ID, node pools, upgrades
├── phase-8-production-n8n/  # Pod Security Standards, network policy
├── phase-9-monitoring/      # kube-prometheus-stack, alerts
└── phase-10-onboarding/     # customer-onboarding module
    ├── modules/
    ├── staging/
    └── production/

LEARNING_PROGRESSION.md
platform-engineering-deep-dive.md
```

## Running it

```sh
mise install                                    # pinned tool versions
cd mercury-workflows-sanitized/phase-3-aks
terraform init && terraform plan && terraform apply

# To onboard a new customer (phase 10):
cd ../phase-10-onboarding/staging
# add one line to customers.tf, then:
terraform apply
# Flux picks up the new manifests and the customer is live
```

---

**Maintainer:** Babu Macharia · [linkedin.com/in/babu-macharia](https://linkedin.com/in/babu-macharia) · [babumacharia.com](https://babumacharia.com)