# CNPG Barman Cloud Plugin Troubleshooting

## Incident Summary

The `cnpg-plugin-barman-cloud` workload in namespace `cnpg-system` presented with repeated volume mount failures:

```text
Warning  FailedMount  MountVolume.SetUp failed for volume "client" : secret "barman-cloud-client-tls" not found
Warning  FailedMount  MountVolume.SetUp failed for volume "server" : secret "barman-cloud-server-tls" not found
```

At first glance, this looked like a missing `Secret` issue. Live cluster inspection showed that the missing `Secret` condition was a downstream symptom. The actual control-plane failure was an earlier stalled `HelmRelease` install caused by an unavailable cert-manager admission webhook during initial reconciliation.

## Impact

- `HelmRelease/flux-system/cnpg-plugin-barman-cloud` remained in `Failed/Stalled`.
- `Deployment/cnpg-system/cnpg-plugin-barman-cloud` did not complete a healthy install path.
- Required TLS assets for the plugin were absent from `cnpg-system`.
- `Kustomization/flux-system/mercury-system-infra-controllers` remained unhealthy due to the failed `HelmRelease`.

## Initial Symptom

Observed pod state:

```bash
kubectl -n cnpg-system get pod cnpg-plugin-barman-cloud-79c49bf84d-6rgzt -o wide
```

Observed status:

```text
0/1 ContainerCreating
```

Observed missing secrets:

```bash
kubectl -n cnpg-system get secret barman-cloud-client-tls barman-cloud-server-tls barman-cloud-ca-tls
```

Result:

```text
Error from server (NotFound): secrets "barman-cloud-client-tls" not found
Error from server (NotFound): secrets "barman-cloud-server-tls" not found
Error from server (NotFound): secrets "barman-cloud-ca-tls" not found
```

## Root Cause Analysis

### 1. Namespace Ownership Mismatch Was Identified

The first repository under review contained Barman TLS certificate manifests scoped outside the controller namespace. Since the plugin runs in `cnpg-system`, any `Secret` used as a projected volume must also exist in `cnpg-system`.

This was a valid configuration gap, but it was not the only issue.

### 2. Flux Was Not Reconciling the Workspace Being Edited

Live Flux inspection showed the cluster source of truth was:

```text
ssh://git@github.com/bmacharia/mercury-gitops
```

This meant edits made in the local `kubernetes-platform-engineering` workspace would not affect the cluster until the same change was made in `mercury-gitops`.

Validation command:

```bash
kubectl -n flux-system get gitrepository mercury-system -o yaml
```

Relevant result:

```text
spec.url: ssh://git@github.com/bmacharia/mercury-gitops
```

### 3. Helm Release Had Already Failed Before Secrets Could Be Created

Live `HelmRelease` status showed the initial install failure was due to the cert-manager webhook being unavailable at install time.

Validation command:

```bash
kubectl -n flux-system get helmrelease cnpg-plugin-barman-cloud -o yaml
```

Relevant failure:

```text
failed calling webhook "webhook.cert-manager.io"
no endpoints available for service "cert-manager-cert-manager-webhook"
```

This is the primary root cause. The missing TLS `Secret` objects were a consequence of the failed chart install and stalled reconciliation state.

### 4. cert-manager Recovered, But the HelmRelease Stayed Stalled

Subsequent validation showed cert-manager was healthy:

```bash
kubectl -n cert-manager get deploy,pod,svc,endpoints
```

All cert-manager components, including the webhook, were `Ready` with populated endpoints. However, the plugin `HelmRelease` remained `Stalled`, so it did not self-heal without operator intervention.

## Diagnostic Workflow

The following checks were used to drive the troubleshooting process:

### Workload and Secret Checks

```bash
kubectl -n cnpg-system get pod cnpg-plugin-barman-cloud-79c49bf84d-6rgzt -o wide
kubectl -n cnpg-system get secret barman-cloud-client-tls barman-cloud-server-tls barman-cloud-ca-tls
kubectl -n cnpg-system get certificate,issuer
kubectl -n cnpg-system get pods
kubectl -n cnpg-system get deploy cnpg-plugin-barman-cloud -o wide
```

### Flux Health and Source Checks

```bash
kubectl -n flux-system get helmrelease,kustomization
kubectl -n flux-system get helmrelease cnpg-plugin-barman-cloud -o yaml
kubectl -n flux-system get kustomization mercury-system-infra-controllers -o yaml
kubectl -n flux-system get gitrepository mercury-system -o yaml
```

### cert-manager Control-Plane Checks

```bash
kubectl -n cert-manager get deploy,pod,svc,endpoints
```

### Render Validation

Local render validation was used before promotion:

```bash
kubectl kustomize /home/devopbiddy/Repos/github/bmacharia/mercury-gitops/infrastructure/controllers/staging/cnpg
```

## Corrective Action

### 1. Move Plugin TLS Certificate Management Into the Controller Stack

The Barman TLS certificate resources were added to the Flux-managed controller path:

- `infrastructure/controllers/staging/cnpg/kustomization.yaml`
- `infrastructure/controllers/staging/cnpg/barman-tls-certificates.yaml`

This ensured the following resources are created in `cnpg-system`:

- `Issuer/barman-cloud-selfsigned-issuer`
- `Issuer/barman-cloud-ca-issuer`
- `Certificate/barman-cloud-ca`
- `Certificate/barman-cloud-client-tls`
- `Certificate/barman-cloud-server-tls`

This in turn creates:

- `Secret/barman-cloud-ca-tls`
- `Secret/barman-cloud-client-tls`
- `Secret/barman-cloud-server-tls`

### 2. Commit and Push to the Actual Flux Source Repository

Change was committed in `mercury-gitops`:

```text
cd78c10 Add CNPG Barman TLS certs in controller namespace
```

### 3. Trigger Flux Reconciliation

```bash
kubectl -n flux-system annotate gitrepository mercury-system reconcile.fluxcd.io/requestedAt="2026-04-14T20:45:00Z" --overwrite
kubectl -n flux-system annotate kustomization mercury-system-infra-controllers reconcile.fluxcd.io/requestedAt="2026-04-14T20:45:05Z" --overwrite
```

### 4. Clear the Stalled HelmRelease State

Because the release remained stalled after the original install failure, a reconcile annotation alone was insufficient. The release was forced through a new generation by toggling suspension:

```bash
kubectl -n flux-system patch helmrelease cnpg-plugin-barman-cloud --type=merge -p '{"spec":{"suspend":true}}'
kubectl -n flux-system patch helmrelease cnpg-plugin-barman-cloud --type=merge -p '{"spec":{"suspend":false}}'
```

This triggered a fresh Helm action after cert-manager and the TLS dependencies were available.

## Recovery Validation

### TLS Assets Present

```bash
kubectl -n cnpg-system get certificate,issuer,secret
```

Confirmed:

- `Certificate/barman-cloud-ca` -> `Ready=True`
- `Certificate/barman-cloud-client-tls` -> `Ready=True`
- `Certificate/barman-cloud-server-tls` -> `Ready=True`
- `Issuer/barman-cloud-selfsigned-issuer` -> `Ready=True`
- `Issuer/barman-cloud-ca-issuer` -> `Ready=True`
- All required TLS `Secret` objects present in `cnpg-system`

### Plugin Workload Healthy

```bash
kubectl -n cnpg-system get pods
kubectl -n cnpg-system get deploy cnpg-plugin-barman-cloud -o wide
```

Confirmed:

- `Pod/cnpg-plugin-barman-cloud-79c49bf84d-6rgzt` -> `1/1 Running`
- `Deployment/cnpg-plugin-barman-cloud` -> `1/1 Available`

### Flux Healthy

```bash
kubectl -n flux-system get helmrelease cnpg-plugin-barman-cloud
kubectl -n flux-system get kustomization mercury-system-infra-controllers
```

Confirmed:

- `HelmRelease/cnpg-plugin-barman-cloud` -> `Ready=True`
- `Kustomization/mercury-system-infra-controllers` -> `Ready=True`
- Applied revision:

```text
main@sha1:cd78c103f81477dcf2ce0d478936b48f712739f9
```

## Operator Lessons Learned

- Do not assume missing projected-volume secrets are the primary failure. Validate upstream reconciliation and release health first.
- For Flux-managed clusters, confirm the actual `GitRepository` source before applying repository-side remediation.
- cert-manager webhook readiness is a hard dependency for any install path that creates `Issuer` or `Certificate` resources.
- A `HelmRelease` in `Stalled` state may require explicit operator action to force a fresh attempt, even after dependencies recover.
- Namespace alignment matters for mounted `Secret` resources. Controller-owned TLS material should be created in the namespace where the controller or plugin workload runs.

## Recommended SRE Follow-Up

- Add readiness gating or dependency ordering so the CNPG plugin does not install before cert-manager webhook endpoints are available.
- Consider explicit Flux dependency modeling if the plugin install path depends on cert-manager CRDs and webhook health.
- Add a standard post-bootstrap validation check for:
  - `kubectl -n cert-manager get deploy,pod,svc,endpoints`
  - `kubectl -n flux-system get helmrelease,kustomization`
  - `kubectl -n cnpg-system get pods,certificate,issuer,secret`
- Keep controller-scoped PKI material in controller GitOps paths rather than tenant application paths.
