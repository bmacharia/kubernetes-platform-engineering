# Troubleshooting: customer1 Namespace Pod Failures

**Cluster:** AKS (staging)  
**Namespace:** `customer1`  
**Components affected:** CNPG Cluster (`customer1-db2`), n8n Deployment  
**Root causes found:** 4 (chained)

---

## Initial Triage

First pass was a broad sweep of the namespace to understand scope:

```bash
kubectl get pods -n customer1
```

Output showed 7 pods in `Error` state — all `customer1-db2-1-full-recovery-*` — plus n8n in `CrashLoopBackOff`. The recovery pods are Kubernetes `Job`-controlled pods spawned by the CNPG operator to restore a PostgreSQL cluster from backup. A job backing off and retrying 7 times over 13 hours is a clear signal the failure is not transient.

```bash
kubectl get events -n customer1 --sort-by='.lastTimestamp'
kubectl describe pod customer1-db2-1-full-recovery-2q9ql -n customer1
```

The events surfaced an immediately useful clue:

```
Warning  FailedToCreateSecret  csi-secrets-store-controller
failed to get data in spc customer1/customer1-secrets for secret
customer1-backup-creds, err: file matching objectName storage-account-name
not found in the pod
```

The pod describe confirmed the `full-recovery` container was exiting 1, and the init containers (`bootstrap-controller`, `plugin-barman-cloud`) had both completed — meaning the failure was happening in the main container during the actual restore handshake.

---

## Root Cause 1: Missing Kubernetes Secret (`customer1-backup-creds`)

```bash
kubectl logs customer1-db2-1-full-recovery-2q9ql -n customer1 -c full-recovery
```

```
Error while restoring a backup: secrets "customer1-backup-creds" not found
```

```bash
kubectl get secrets -n customer1
```

Confirmed: `customer1-backup-creds` did not exist in the namespace. The CNPG barman-cloud plugin references this secret (via the `ObjectStore` resource) to authenticate against Azure Blob Storage. Without it, every recovery attempt fails immediately.

### Tracing the Secret Provisioning Chain

The secret is supposed to be synced from Azure Key Vault via the Secrets Store CSI driver, declared in a `SecretProviderClass`:

```bash
kubectl get secretproviderclass customer1-secrets -n customer1 -o yaml
```

The SPC was correctly configured — it referenced `storage-account-name` and `customer1-blob-sas` from Key Vault `kv-mercury-staging` and mapped them into a Kubernetes secret named `customer1-backup-creds`.

The CSI driver only materialises `secretObjects` when a pod mounts the CSI volume. The only pod doing that was `customer1-n8n`:

```bash
kubectl get secretproviderclasspodstatus -n customer1
# → only one entry: the n8n pod
```

Inspecting that pod status revealed the core issue:

```bash
kubectl get secretproviderclasspodstatus \
  customer1-n8n-655b4ccf7d-5nnhh-customer1-customer1-secrets \
  -n customer1 -o yaml
```

```yaml
status:
  mounted: true
  objects:
  - id: secret/customer1-db-password
  - id: secret/customer1-db-user
  # storage-account-name and customer1-blob-sas are MISSING
```

The n8n pod was started **before** `storage-account-name` and `customer1-blob-sas` were added to the SPC `objects` array. The CSI volume was mounted with only the two original KV secrets. Subsequent SPC updates don't retroactively remount running pods — the volume is frozen at mount time.

### Fix

Force the n8n pod to remount the CSI volume by rolling the deployment:

```bash
kubectl rollout restart deployment/customer1-n8n -n customer1
kubectl rollout status deployment/customer1-n8n -n customer1
```

After the pod came back up, `customer1-backup-creds` was created immediately.

**Verification:**
```bash
kubectl get secret customer1-backup-creds -n customer1
# NAME                     TYPE     DATA   AGE
# customer1-backup-creds   Opaque   2      44s
```

---

## Root Cause 2: Stale PVC Blocking Operator Reconciliation

With the secret now present, the next step was to let the CNPG operator retry recovery. The failed job was deleted:

```bash
kubectl delete job customer1-db2-1-full-recovery -n customer1
```

However, the CNPG operator logs showed it was stuck in a tight loop:

```
Selected PVC is not ready yet, waiting for 1 second
pvc: customer1-db2-1, status: initializing
```

CNPG annotates PVCs with `cnpg.io/pvcStatus` to track lifecycle. On recovery job creation the PVC is set to `initializing`; on successful completion the operator transitions it to `ready`. Since every job had failed and been deleted, the PVC was permanently stuck in `initializing`:

```bash
kubectl get pvc customer1-db2-1 -n customer1 -o jsonpath=\
  '{.metadata.annotations.cnpg\.io/pvcStatus}'
# initializing
```

Because CNPG waits for `ready` before proceeding, it would never attempt a new recovery. The PVC had no useful data (recovery never completed), so it was safe to delete:

```bash
kubectl delete pvc customer1-db2-1 -n customer1
```

After deletion a second blocker appeared in the operator logs:

```
refusing to create the primary instance while the latest generated serial is not zero
latestGeneratedNode: 1
```

CNPG persists a monotonically increasing node serial in `cluster.status.latestGeneratedNode` to avoid duplicate instance names. With the PVC gone but the counter still at `1`, the operator refused to bootstrap a new primary. A status patch reset it:

```bash
kubectl patch cluster customer1-db2 -n customer1 \
  --subresource=status --type=merge \
  -p '{"status":{"latestGeneratedNode":0,"instanceNames":[],"instances":0,"initializingPVC":[]}}'
```

The operator immediately reconciled, created a new PVC, and spawned a fresh `full-recovery` job.

---

## Root Cause 3: Empty Backup Catalog (`no target backup found`)

The new recovery pod progressed further — credentials worked, barman connected to Azure Blob Storage — but then:

```bash
kubectl logs customer1-db2-1-full-recovery-r2c5v -n customer1 -c plugin-barman-cloud
```

```json
{"msg":"Downloaded backup catalog","backupCatalog":[]}
{"error":"no target backup found"}
```

Barman successfully authenticated and reached `jupiterbackupsstaging.blob.core.windows.net/customer1`, but the container was **empty** — no base backups existed to restore from.

Reviewing the `database.yaml` in the gitops repo made the situation clear:

```yaml
# Original intent (commented out):
# name: customer1-db
# bootstrap:
#   initdb: ...

# Current config:
name: customer1-db2
bootstrap:
  recovery:
    source: source   # expects backups of "customer1-db" in blob storage
externalClusters:
  - name: source
    parameters:
      serverName: customer1-db   # ← this cluster was never backed up
```

The workflow assumed `customer1-db` had previously run, accumulated WAL-based backups via barman, and those backups were sitting in blob storage. In practice `customer1-db` had been deleted (or never ran long enough) before any backup landed in the container.

### Fix

Revert to `initdb` bootstrap — create a fresh cluster rather than attempting a restore with no source data:

```yaml
# database.yaml
metadata:
  name: customer1-db     # restored original name
spec:
  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: customer1-db-credentials
  # removed: recovery, externalClusters
```

The old `customer1-db2` cluster was deleted and the corrected manifest applied:

```bash
kubectl delete cluster customer1-db2 -n customer1
kubectl apply -k gitops/apps/staging/customer1/
```

CNPG created a new `initdb` job which completed in ~25 seconds, and the primary instance came up cleanly.

---

## Root Cause 4: n8n Hardcoded to Old DB Service Name

With the cluster renamed from `customer1-db2` back to `customer1-db`, the CNPG-managed services changed:

| Old | New |
|-----|-----|
| `customer1-db2-rw` | `customer1-db-rw` |
| `customer1-db2-ro` | `customer1-db-ro` |
| `customer1-db2-r`  | `customer1-db-r`  |

n8n's ConfigMap still had the old hostname hardcoded:

```yaml
DB_POSTGRESDB_HOST: "customer1-db2-rw.customer1.svc.cluster.local"
```

n8n was hitting `ECONNREFUSED` because `customer1-db2-rw` no longer existed. The configmap was updated:

```yaml
DB_POSTGRESDB_HOST: "customer1-db-rw.customer1.svc.cluster.local"
```

After applying and rolling the deployment, n8n came up cleanly with no restarts.

---

## Flux GitOps — Applying Fixes to the Right Repo

During the fix, it was discovered that Flux was tracking a **separate** repo (`bmacharia/mercury-gitops`) — not the workflow/development repo where the initial file edits were made. This caused Flux to continuously reconcile back to the broken state, re-spawning `customer1-db2-1-full-recovery` pods.

```bash
kubectl get gitrepository -n flux-system -o jsonpath='{.items[0].spec.url}'
# ssh://git@github.com/bmacharia/mercury-gitops
```

The same changes were applied to `mercury-gitops`, committed, and pushed. Flux was then forced to reconcile immediately:

```bash
flux reconcile source git mercury-system -n flux-system
flux reconcile kustomization mercury-system-apps -n flux-system
# ✔ applied revision main@sha1:a6dfdad...
```

After reconciliation all ghost pods disappeared and the cluster reached a stable, Flux-managed state.

---

## Final State

```
NAME                    READY   STATUS
customer1-db-1          2/2     Running   ← primary
customer1-db-2          2/2     Running   ← replica
customer1-db-3          2/2     Running   ← replica
customer1-n8n           1/1     Running

cluster/customer1-db    3/3     Cluster in healthy state
```

---

## Lessons Learned

**1. CSI SecretProviderClass volumes are mounted once at pod start.**  
Updating the SPC `objects` array after pods are running has no effect on existing mounts. Any pods that need the new secrets must be restarted to remount.

**2. CNPG tracks PVC lifecycle via annotations — stale state blocks the operator.**  
If a recovery job is deleted without completing, the PVC stays in `initializing` forever. Manual cleanup of both the PVC and the `latestGeneratedNode` counter is required to unblock reconciliation.

**3. Validate backup catalogs before deploying a recovery cluster.**  
A CNPG cluster bootstrapped via `recovery` will fail immediately if no base backup exists in the objectstore. Confirm backups are present with `barman-cloud-catalog` or by listing the blob container before switching a cluster to recovery mode.

**4. Know which repo Flux is actually watching.**  
Local gitops repos used for development/workflows are not necessarily the repo Flux reconciles from. Always verify with `kubectl get gitrepository -n flux-system` before committing fixes.
