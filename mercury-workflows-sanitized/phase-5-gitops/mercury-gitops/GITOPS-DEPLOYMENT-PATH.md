# GitOps Deployment Path: Base → Staging → App

A walkthrough of how a `git push` becomes a running application in the cluster.

---

## Layer 0 — Bootstrap (Terraform → AKS → Flux)

Everything starts in `main.tf`. Terraform provisions the AKS cluster and installs the Flux extension, then registers **three Flux `Kustomization` objects** that tell Flux what to watch and in what order:

```
main.tf
└── azurerm_kubernetes_flux_configuration "mercury-system"
      ├── kustomization: infra-controllers  → ./infrastructure/controllers/staging
      ├── kustomization: infra-configs      → ./infrastructure/configs/staging
      │     depends_on: [infra-controllers]
      └── kustomization: apps               → ./apps/staging
            depends_on: [infra-configs]
```

Flux polls `ssh://git@github.com/bmacharia/mercury-gitops` on a 5-minute interval. Every push to `main` eventually propagates through these three layers in order.

---

## Layer 1 — Infrastructure Controllers

**Flux Kustomization:** `infra-controllers` → `infrastructure/controllers/staging/`

```
infrastructure/controllers/staging/kustomization.yaml
  resources:
    - traefik      →  infrastructure/controllers/staging/traefik/kustomization.yaml
    - cert-manager →  infrastructure/controllers/staging/cert-manager/kustomization.yaml
    - cnpg         →  infrastructure/controllers/staging/cnpg/kustomization.yaml
```

Each staging overlay simply includes its base:

```
infrastructure/controllers/staging/traefik/kustomization.yaml
  resources:
    - ../../base/traefik/
```

The **base** for each controller has three files:

```
infrastructure/controllers/base/traefik/
  ├── namespace.yaml      →  Namespace: traefik
  ├── repository.yaml     →  HelmRepository: traefik  (https://traefik.github.io/charts)
  └── release.yaml        →  HelmRelease: traefik
                               chart: traefik v37.4.0
                               values:
                                 ingressClass.name: traefik

infrastructure/controllers/base/cert-manager/
  ├── namespace.yaml      →  Namespace: cert-manager
  ├── repository.yaml     →  HelmRepository: jetstack  (oci://quay.io/jetstack/charts)
  └── release.yaml        →  HelmRelease: cert-manager v1.19.1
                               crds.enabled: true
```

Flux applies these → Helm installs Traefik and cert-manager into the cluster.

---

## Layer 2 — Infrastructure Configs

**Flux Kustomization:** `infra-configs` → `infrastructure/configs/staging/`
*(only runs after `infra-controllers` is healthy)*

```
infrastructure/configs/staging/kustomization.yaml
  resources:
    - cert-manager  →  infrastructure/configs/staging/cert-manager/kustomization.yaml
                            resources:
                              - ../../base/cert-manager/

infrastructure/configs/base/cert-manager/
  └── cluster-issuers.yaml  →  ClusterIssuer: letsencrypt-staging
                                 solver: http01 via ingressClassName: traefik
                               ClusterIssuer: letsencrypt-prod
                                 solver: http01 via ingressClassName: traefik
```

cert-manager must already be running (Layer 1) before these CRDs can be applied — that is why `depends_on` exists.

---

## Layer 3 — Apps

**Flux Kustomization:** `apps` → `apps/staging/`
*(only runs after `infra-configs` is healthy — ClusterIssuers must exist before the Ingress is created)*

```
apps/staging/kustomization.yaml
  resources:
    - customer1  →  apps/staging/customer1/kustomization.yaml
```

This is where Kustomize's **base + overlay** pattern kicks in:

```
apps/staging/customer1/kustomization.yaml
  resources:
    - ../../base/customer1/      ← pulls in ALL base manifests
  patches:
    - target: SecretProviderClass/customer1-secrets
      patch:
        - op: replace  path: /spec/parameters/userAssignedIdentityID
          value: "e77a0f4b-..."   ← staging-specific managed identity
        - op: replace  path: /spec/parameters/tenantId
          value: "2f695754-..."   ← staging-specific tenant
```

The base contains everything environment-agnostic:

```
apps/base/customer1/
  ├── namespace.yaml    →  Namespace: customer1
  ├── secrets.yaml      →  SecretProviderClass: customer1-secrets
  │                          pulls DB credentials from Azure Key Vault
  │                          projects them as k8s Secrets: customer1-db-credentials
  │                                                         customer1-n8n-env
  ├── database.yaml     →  CNPG Cluster (Postgres)
  ├── configmap.yaml    →  ConfigMap: customer1-n8n-config  (env vars)
  ├── storage.yaml      →  PersistentVolumeClaim: customer1-n8n-data
  ├── deployment.yaml   →  Deployment: customer1-n8n
  │                          image: n8n:1.123.3
  │                          envFrom: configmap + secret (customer1-n8n-env)
  │                          volumes: PVC + CSI secrets-store mount
  ├── service.yaml      →  Service: customer1-n8n  (port 3008)
  └── ingress.yaml      →  Ingress: customer1-ingress
                             ingressClassName: traefik
                             tls: customer1-tls  (cert-manager issues this)
                             annotation: cert-manager.io/cluster-issuer: letsencrypt-prod
```

The staging overlay **only patches what differs** from base — in this case just the Azure identity IDs. Everything else is inherited unchanged.

---

## End-to-End Flow

```
git push → bmacharia/mercury-gitops (main)
    │
    ▼
Flux polls every 5m
    │
    ├─► [1] infra-controllers
    │        Traefik HelmRelease      → Traefik pods + LoadBalancer IP
    │        cert-manager HelmRelease → cert-manager pods + CRDs
    │        CNPG HelmRelease         → CNPG operator pods
    │
    ├─► [2] infra-configs  (after [1] ready)
    │        ClusterIssuer letsencrypt-prod    → registered with ACME
    │        ClusterIssuer letsencrypt-staging
    │
    └─► [3] apps  (after [2] ready)
             Namespace: customer1
             SecretProviderClass → fetches secrets from Azure Key Vault
             CNPG Cluster        → Postgres database
             PVC                 → persistent storage for n8n
             Deployment          → n8n pod
             Service             → ClusterIP on port 3008
             Ingress             → Traefik routes traffic in
                                    cert-manager sees annotation
                                    → issues Let's Encrypt cert
                                    → stores as Secret: customer1-tls
                                    → Traefik serves it on port 443
```

---

## Adding a New Environment

The staging overlay is the **only place environment-specific values live** — base is shared and reusable. To add a `production` environment, create:

```
apps/production/customer1/kustomization.yaml
  resources:
    - ../../base/customer1/
  patches:
    - target: SecretProviderClass/customer1-secrets
      patch:
        - op: replace  path: /spec/parameters/userAssignedIdentityID
          value: "<prod-managed-identity-id>"
        - op: replace  path: /spec/parameters/tenantId
          value: "<prod-tenant-id>"
```

And register a new Flux `Kustomization` pointing at `./apps/production` in `main.tf`.
