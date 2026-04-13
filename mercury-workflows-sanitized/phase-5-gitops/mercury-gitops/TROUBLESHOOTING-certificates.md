# Troubleshooting: Certificates Not Being Served

## Symptom

TLS certificate not being served on `customer1.mercury.airmanbabu.net`. Instead, Traefik's self-signed default certificate was returned for all HTTPS connections.

---

## Environment

| Component       | Version        |
|-----------------|----------------|
| cert-manager    | v1.19.1        |
| Traefik (chart) | v37.4.0        |
| Flux            | GitOps via AKS |
| Issuer          | Let's Encrypt (letsencrypt-prod, HTTP01) |
| Ingress host    | customer1.mercury.airmanbabu.net |

---

## Investigation

### Step 1 — Check certificate and ACME challenge state

```bash
kubectl get certificate -A
kubectl get challenges -A
kubectl get clusterissuer -o wide
kubectl get svc -n traefik
```

**Findings:**
- `customer1-tls` certificate: `Ready: True` — the cert was already issued
- No pending challenges — ACME had already completed successfully
- Both ClusterIssuers (`letsencrypt-prod`, `letsencrypt-staging`): `Ready: True`
- Traefik LoadBalancer had a public IP: `20.80.129.48`

The problem was not certificate issuance — the cert existed and was valid.

### Step 2 — Check what the site is actually serving

```bash
openssl s_client -connect customer1.mercury.airmanbabu.net:443 \
  -servername customer1.mercury.airmanbabu.net 2>&1 | head -30
```

**Finding:** Traefik was serving `CN = TRAEFIK DEFAULT CERT` (its self-signed fallback), not the Let's Encrypt cert.

### Step 3 — Check DNS

```bash
dig customer1.mercury.airmanbabu.net +short
```

**Finding:** DNS resolved correctly to `20.80.129.48` (Traefik's LoadBalancer IP). Not the issue.

### Step 4 — Describe the ingress

```bash
kubectl describe ingress customer1-ingress -n customer1
```

**Findings:**
- `Address:` field was **empty** — Traefik had not claimed the ingress
- TLS was configured correctly: `customer1-tls` terminating the right host
- `ingressClassName: traefik` was set on the ingress

The empty `Address` field was the key signal that Traefik was not processing this ingress at all.

### Step 5 — Verify the TLS secret and Traefik RBAC

```bash
kubectl get secret customer1-tls -n customer1 -o yaml
kubectl auth can-i get secrets --namespace customer1 \
  --as=system:serviceaccount:traefik:traefik-traefik
```

**Findings:**
- Secret existed, correct type (`kubernetes.io/tls`), issued by `letsencrypt-prod`
- Traefik service account **could** read secrets in `customer1` namespace

### Step 6 — Check the IngressClass

```bash
kubectl get ingressclass
```

**Finding — Root Cause:**

```
NAME              CONTROLLER                      PARAMETERS   AGE
traefik-traefik   traefik.io/ingress-controller   <none>       2d3h
```

The IngressClass resource was named **`traefik-traefik`** (Helm naming convention: `<release-name>-<chart-name>`), but the ingress was specifying `ingressClassName: traefik`. **The names did not match**, so Traefik ignored the ingress entirely — no routing, no TLS, just the default cert.

---

## Root Cause

The Traefik Helm release was named `traefik` and deployed from the `traefik` chart with `values: {}`. The Helm chart's default fullname template produced `traefik-traefik` for the IngressClass name. The ingress in `apps/base/customer1/ingress.yaml` referenced `ingressClassName: traefik`, which matched nothing.

**Secondary issue (already fixed):** The ClusterIssuers in `infrastructure/configs/base/cert-manager/cluster-issuers.yaml` used the deprecated `class: traefik` field in the HTTP01 solver instead of `ingressClassName: traefik`. This was fixed as part of the investigation, though the cert had already been issued successfully before this fix was needed.

---

## Fix

### 1. Set the IngressClass name in the Traefik HelmRelease

`infrastructure/controllers/base/traefik/release.yaml`:

```yaml
# Before
values: {}

# After
values:
  ingressClass:
    name: traefik
```

This causes Traefik to create an IngressClass named `traefik`, matching what the ingress expects.

### 2. Fix the ClusterIssuer HTTP01 solver (already applied)

`infrastructure/configs/base/cert-manager/cluster-issuers.yaml`:

```yaml
# Before
solvers:
  - http01:
      ingress:
        class: traefik   # deprecated

# After
solvers:
  - http01:
      ingress:
        ingressClassName: traefik   # current API
```

---

## Verification

After pushing the fix and reconciling Flux:

```bash
# Force reconciliation
flux reconcile source git mercury-system -n flux-system
flux reconcile kustomization mercury-system-infra-controllers -n flux-system --with-source

# Wait for HelmRelease to update
kubectl get helmrelease traefik -n flux-system -w

# Confirm IngressClass name
kubectl get ingressclass
# Expected: traefik   traefik.io/ingress-controller

# Confirm ingress has an address
kubectl get ingress customer1-ingress -n customer1
# Expected: ADDRESS = 20.80.129.48

# Confirm the real cert is being served
openssl s_client -connect customer1.mercury.airmanbabu.net:443 \
  -servername customer1.mercury.airmanbabu.net 2>&1 | grep "CN ="
# Expected: CN = customer1.mercury.airmanbabu.net
```

---

## Lessons Learned

- **Empty `Address` on an ingress** is a reliable signal that the ingress controller is not processing it — check that `ingressClassName` matches an actual `IngressClass` resource name.
- **Helm release naming**: when the release name equals the chart name (e.g. release `traefik` + chart `traefik`), the Helm fullname helper may produce `traefik-traefik`. Always verify with `kubectl get ingressclass` after deploying Traefik.
- **`kubectl get certificate -A` being Ready does not mean TLS is working end-to-end** — the ingress controller must also be configured to pick up and serve the secret.
- Use `kubectl auth can-i` early to rule out RBAC as a cause before looking elsewhere.
