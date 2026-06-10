# CNPG Disaster Recovery Lab

Simulate a total database loss and recover from the barman-cloud backup in Azure Blob Storage.

## Architecture

```
customer1-db (CNPG Cluster, 3 instances)
  └── WAL archiving → barman-cloud plugin → customer1-objectstore
                                               (Azure Blob Storage)
  └── ScheduledBackup → daily at 03:00
```

Recovery works by replaying the base backup + WAL segments from the objectstore. The
`externalClusters` entry tells the new cluster where to find those files.

## Prerequisites

- Cluster `customer1-db` is healthy (`kubectl get cluster -n customer1`)
- ObjectStore and scheduled backups have been running long enough for at least one backup to exist
- You have `kubectl` access and `cnpg` kubectl plugin installed (`kubectl cnpg status customer1-db -n customer1`)

---

## Step 1 — Seed test data

Connect to the primary and insert identifiable rows you can verify after recovery.

```bash
kubectl cnpg psql customer1-db -n customer1 -- -c "
CREATE TABLE IF NOT EXISTS dr_test (id serial PRIMARY KEY, msg text, ts timestamptz DEFAULT now());
INSERT INTO dr_test (msg) VALUES ('row-before-disaster-1'), ('row-before-disaster-2');
SELECT * FROM dr_test;
"
```

Note the timestamp of the last insert — you may need it for PITR.

---

## Step 2 — Trigger an on-demand backup

The daily scheduled backup may be hours away. Apply a one-shot `Backup` resource directly
(do **not** add it to the kustomization — it is a one-time imperative operation).

```bash
kubectl apply -f apps/base/customer1/backup-ondemand.yaml
```

Wait for the backup to complete:

```bash
kubectl get backup customer1-db-pre-dr -n customer1 -w
# STATUS column should reach: completed
```

Verify it landed in Azure:

```bash
kubectl cnpg status customer1-db -n customer1
# Look for: "First Point of Recoverability" and "Last backup"
```

---

## Step 3 — Prepare the recovery manifest in git

Before deleting the cluster, switch `database.yaml` to use the recovery bootstrap.
Flux will pick up this change; since the cluster still exists, the bootstrap section is
**ignored** (CNPG only reads bootstrap on first cluster creation). This is safe to commit now.

```bash
cp apps/base/customer1/database.yaml apps/base/customer1/database.yaml.initdb.bak
cp apps/base/customer1/database-recovery.yaml apps/base/customer1/database.yaml

git add apps/base/customer1/database.yaml
git commit -m "chore: switch customer1-db to recovery bootstrap for DR lab"
git push
```

Wait for Flux to reconcile the change (it will be a no-op since the cluster is running):

```bash
flux get kustomization apps -n flux-system
```

---

## Step 4 — Destroy the database (the disaster)

```bash
kubectl delete cluster customer1-db -n customer1
```

Watch the fallout — pods and PVCs disappear:

```bash
kubectl get pods -n customer1 -w
kubectl get pvc -n customer1
```

The application (n8n) will start returning database errors. This is expected.

---

## Step 5 — Recovery (Flux reconciles)

Flux will detect the missing `Cluster` resource and recreate it from git. Because
`database.yaml` now contains `bootstrap.recovery`, CNPG will:

1. Spin up a restore pod
2. Download the base backup from Azure Blob Storage
3. Replay WAL segments up to the latest consistent point
4. Promote the primary
5. Start replica instances

Watch the recovery phases:

```bash
kubectl get cluster customer1-db -n customer1 -w
# Phases: Setting up primary | Joining replica | Cluster in healthy state
```

Follow the restore pod logs:

```bash
kubectl logs -n customer1 -l cnpg.io/cluster=customer1-db --follow
```

Check the CNPG plugin status:

```bash
kubectl cnpg status customer1-db -n customer1
```

Expected timeline: ~3–10 minutes depending on WAL volume.

---

## Step 6 — Verify data restored

```bash
kubectl cnpg psql customer1-db -n customer1 -- -c "SELECT * FROM dr_test;"
```

You should see the rows inserted in Step 1.

---

## Bonus: Point-in-Time Recovery (PITR)

To recover to a specific moment (e.g., before an accidental `DROP TABLE`), add
`recoveryTarget` to `database-recovery.yaml`:

```yaml
bootstrap:
  recovery:
    source: customer1-source
    recoveryTarget:
      targetTime: "2026-05-11 10:30:00"   # UTC timestamp
```

CNPG will replay WAL only up to that point. Everything after the target time is discarded.
Use `targetLSN` instead of `targetTime` for LSN-level precision.

---

## Step 7 — Cleanup after the lab

Once the cluster is healthy, the `bootstrap` section is inert — CNPG ignores it for
existing clusters. You can leave it in place or restore the original initdb manifest:

```bash
cp apps/base/customer1/database.yaml.initdb.bak apps/base/customer1/database.yaml
rm apps/base/customer1/database.yaml.initdb.bak

git add apps/base/customer1/database.yaml
git commit -m "chore: restore customer1-db to initdb bootstrap post-DR lab"
git push
```

Delete the one-time Backup resource:

```bash
kubectl delete backup customer1-db-pre-dr -n customer1
```

---

## Key CNPG concepts

| Concept | What it means |
|---|---|
| `bootstrap.initdb` | Creates a fresh empty database |
| `bootstrap.recovery` | Restores from a backup + WAL replay |
| `externalClusters` | Tells CNPG where to find the source backup/WAL |
| `recoveryTarget.targetTime` | Stop WAL replay at this point (PITR) |
| WAL archiving | Continuous shipping of WAL segments; enables recovery to any point after the base backup |
| `isWALArchiver: true` | Marks the barman-cloud plugin as the WAL archiver for this cluster |
