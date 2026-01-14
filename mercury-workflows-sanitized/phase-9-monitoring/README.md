# Phase 9: Monitoring & Alerting

This phase adds end-to-end application monitoring with Telegram notifications.

## Overview

- **kube-prometheus-stack**: Prometheus, Grafana, and related exporters
- **Grafana Alerting**: Native Grafana alerts (not Alertmanager)
- **Telegram Bot**: Real-time notifications for critical alerts

## Prerequisites

### 1. Create a Telegram Bot

1. Open Telegram and search for `@BotFather`
2. Send `/newbot` command
3. Follow the prompts:
   - Choose a name for your bot (e.g., "Mercury Alerts")
   - Choose a username (must end in `bot`, e.g., `mercury_alerts_bot`)
4. BotFather will respond with your **bot token** - save this securely

   ```
   Use this token to access the HTTP API:
   1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ
   ```

### 2. Get Your Chat ID

#### Option A: Private Chat (alerts to yourself)

1. Start a chat with your new bot (search for it and click Start)
2. Send any message to the bot
3. Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
4. Find `"chat":{"id":123456789}` - this is your chat ID

#### Option B: Group Chat (alerts to a team)

1. Create a new Telegram group
2. Add your bot to the group
3. Send a message in the group
4. Visit: `https://api.telegram.org/bot<YOUR_BOT_TOKEN>/getUpdates`
5. Find the chat ID (group IDs are negative, e.g., `-4259759959`)

### 3. Add Secrets to Azure Key Vault

```bash
# Set variables
KEY_VAULT_NAME="kv-mercury-staging"
BOT_TOKEN="8556621399:AAEhcYNniyBg33BKqVS3-AAbQ9BC1M_aSjs"  # From BotFather
CHAT_ID="6871863215"  # From getUpdates (use quotes for negative numbers)

# Add Telegram bot token
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "grafana-telegram-bot-token" \
  --value "$BOT_TOKEN"

# Add Telegram chat ID
az keyvault secret set \
  --vault-name "$KEY_VAULT_NAME" \
  --name "grafana-telegram-chat-id" \
  --value "$CHAT_ID"

# Verify secrets were created
az keyvault secret list --vault-name "$KEY_VAULT_NAME" -o table
```

## Deployment

### 1. Apply Terraform Changes

```bash
cd /workspaces/mercury-workflows/phase-9-monitoring
terraform init
terraform apply
```

This adds two new Flux kustomizations:

- `monitoring-controllers` - Deploys kube-prometheus-stack
- `monitoring-configs` - Deploys Grafana alert rules

### 2. Verify Deployment

```bash
# Watch Flux deploy monitoring
flux get kustomizations

# Check pods are running
kubectl get pods -n monitoring
```

### 3. Access Grafana

```bash

Access grafana through your configured domain

# Password: from Key Vault (or terraform output)
terraform output -raw grafana_admin_password

# Or retrieve from Key Vault directly
az keyvault secret show --vault-name kv-mercury-staging --name grafana-admin-password --query value -o tsv
```

## Testing Alerts

### Test 1: n8n Application Down

```bash

# First, suspend all kustomizations or else Flux will fix things!

flux suspend kustomization --all

# Scale any n8n deployment to 0 to trigger alert
# The alert monitors ALL n8n deployments across ALL namespaces
kubectl scale deployment customer1-n8n -n customer1 --replicas=0

# Wait ~1 minute for alert to fire
# Check Telegram for "FIRING" notification with namespace info

# Restore n8n
kubectl scale deployment customer1-n8n -n customer1 --replicas=1

# Check Telegram for "RESOLVED" notification
```

The n8n alert uses `deployment=~".*n8n.*"` to match all n8n deployments across all customer namespaces.

### Test 2: CNPG Operator Down

```bash
# Scale CNPG operator to 0
k -n cnpg-system scale deployment cnpg-system-cnpg-cloudnative-pg --replicas=0


# Wait ~1 minute for alert
# Check Telegram

# Restore operator
k -n cnpg-system scale deployment cnpg-system-cnpg-cloudnative-pg --replicas=1
```

### Test 3: Database Pod Failure

```bash
# Delete the primary database pod (it will be recreated)
kubectl delete pod customer1-db2-1 -n customer1

# Watch for replication alerts during failover
kubectl get pods -n customer1 -w

# Cluster should self-heal within a few minutes
```

### Test 4: Simulate Long-Running Transaction

```bash
# Connect to database
kubectl exec -it customer1-db2-1 -n customer1 -- psql -U postgres -d app

# Start a transaction and leave it open
BEGIN;
SELECT pg_sleep(600);


-- Sleep for 10 minutes
-- Don't COMMIT - leave transaction open

# Alert should fire after 5 minutes
# To cancel: ROLLBACK; or \q
```

### Test 5: Manual Bot Test (No Kubernetes)

```bash
# Test Telegram bot directly
BOT_TOKEN="your-bot-token"
CHAT_ID="your-chat-id"

curl -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{\"chat_id\": \"${CHAT_ID}\", \"text\": \"🔥 Test alert from Mercury!\"}"
```
