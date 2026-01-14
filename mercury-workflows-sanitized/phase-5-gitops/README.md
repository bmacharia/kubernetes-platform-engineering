# Phase 5: GitOps with Flux

This phase adds GitOps using the Azure Flux extension. Manifests are stored in the `mercury-gitops` repository.

## Prerequisites

Register the Kubernetes Configuration provider:

```bash
az provider register --namespace Microsoft.KubernetesConfiguration
```

## SSH Deploy Key Setup

1. Generate a key pair:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/mercury -N "" -C "mercury-gitops-deploy-key"
```

2. Add the public key to the mercury-gitops repo:

```bash
gh repo deploy-key add ~/.ssh/mercury.pub \
  --repo <your username>/mercury-gitops \
  --title "flux-deploy-key" \
  --allow-write
```

## Deploy

```bash
terraform init
terraform plan
terraform apply
```

## Verify

```bash
kubectl get pods -n flux-system
kubectl get gitrepositories -n flux-system
kubectl get kustomizations -n flux-system
```
