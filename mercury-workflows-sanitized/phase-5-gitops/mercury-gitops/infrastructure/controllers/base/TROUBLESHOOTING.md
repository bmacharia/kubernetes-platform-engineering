# Troubleshooting: cert-manager, CNPG & Traefik HelmRelease Deployment

## Symptom

All three Flux `Kustomization` objects stuck in `False / Source artifact not found`:

```
NAME                               READY   STATUS
mercury-system-apps                False   Source artifact not found, retrying in 30s
mercury-system-infra-configs       False   Source artifact not found, retrying in 30s
mercury-system-infra-controllers   False   Source artifact not found, retrying in 30s
```

No `HelmRelease` or `HelmRepository` objects existed yet.

---

## Investigation

### Step 1 — Verify the cluster and Flux pods

```bash
kubectl get nodes
kubectl get -n flux-system all
```

Cluster was healthy (2 nodes Ready). All Flux controllers (source, kustomize, helm, notification) were running.

### Step 2 — Check the Flux `GitRepository` status

```bash
kubectl get gitrepository -A
```

```
NAME             READY   STATUS
mercury-system   False   failed to checkout and determine revision: unable to clone:
                         repository not found: git repository: 'ssh://git@github.com//mercury-gitops'
```

Two problems identified:

1. **Double slash in URL** — `ssh://git@github.com//mercury-gitops` should be `ssh://git@github.com/bmacharia/mercury-gitops`
2. **Empty remote repo** — `bmacharia/mercury-gitops` existed on GitHub but had no branches or content

### Step 3 — Confirm the remote repo state

```bash
gh repo list bmacharia | grep mercury   # repo exists but is empty
gh api repos/bmacharia/mercury-gitops/branches  # returns []
```

### Step 4 — Trace the URL back to `main.tf`

The `azurerm_kubernetes_flux_configuration` resource in `main.tf` contained:

```hcl
git_repository {
  url = "ssh://git@github.com//mercury-gitops"   # <-- double slash, missing owner
  ...
}
```

---

## Fix

### 1. Push the `mercury-gitops` content to GitHub

The `mercury-gitops/` directory had all the manifests locally but had never been initialised as a git repo or pushed.

```bash
cd mercury-gitops/
git init
git add .
git commit -m "feat: Initial mercury-gitops content with controllers and apps"
git remote add origin git@github.com:bmacharia/mercury-gitops.git
git push -u origin main
```

### 2. Fix the URL in `main.tf`

```hcl
# Before
url = "ssh://git@github.com//mercury-gitops"

# After
url = "ssh://git@github.com/bmacharia/mercury-gitops"
```

### 3. Patch the `GitRepository` in the cluster (immediate fix, no terraform re-apply)

```bash
kubectl patch gitrepository mercury-system -n flux-system \
  --type=merge \
  -p '{"spec":{"url":"ssh://git@github.com/bmacharia/mercury-gitops"}}'
```

---

## Result

```
NAME             READY   STATUS
mercury-system   True    stored artifact for revision 'main@sha1:6de9ae4...'

NAME                               READY   STATUS
mercury-system-infra-controllers   True    Applied revision: main@sha1:6de9ae4...
mercury-system-infra-configs       True    Applied revision: main@sha1:6de9ae4...

NAME           READY   STATUS
cert-manager   True    Helm install succeeded ... chart cert-manager@v1.19.1
cnpg           True    Helm install succeeded ... chart cloudnative-pg@0.26.1
traefik        True    Helm install succeeded ... chart traefik@37.4.0
```

---

## Follow-up Action Required

Run `terraform apply` in `phase-5-gitops/` to persist the corrected URL in Terraform state.
If the URL is not updated in state, a future `terraform apply` will revert it to the broken value.

```bash
cd phase-5-gitops/
terraform apply
```
