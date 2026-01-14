# Phase 8: Production-Ready n8n Deployment

This phase hardens the n8n deployment for production use by implementing Pod Security Standards (PSS), resource management, health checks, and Cilium network policies.

**References:**

[AKS Best Practices](https://learn.microsoft.com/en-us/azure/aks/best-practices)

[Pod Security Best Practices](https://learn.microsoft.com/en-us/azure/aks/developer-best-practices-pod-security)

[Resource Management Best Practices](https://learn.microsoft.com/en-us/azure/aks/developer-best-practices-resource-management)

[Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/)

[Cilium Network Policies](https://docs.cilium.io/en/stable/security/policy/)

## What's New in Phase 8

| Component | Phase 7 | Phase 8 |
|-----------|---------|---------|
| Pod Security | Basic | PSS Restricted compliant |
| Root filesystem | Writable | Read-only + emptyDir |
| Capabilities | Default | Drop ALL |
| Seccomp | None | RuntimeDefault |
| Resources | None | Requests + Limits |
| Health checks | None | Liveness + Readiness |
| Network policy | None | CiliumNetworkPolicy |

## Pod Security Standards (PSS)

<https://learn.microsoft.com/en-us/azure/aks/developer-best-practices-pod-security#secure-pod-access-to-resources>

<https://learn.microsoft.com/en-us/azure/aks/use-psa>

<https://kubernetes.io/docs/tasks/configure-pod-container/enforce-standards-namespace-labels/>

<https://kubernetes.io/docs/concepts/security/pod-security-standards/>

### Namespace Labels

The customer1 namespace now enforces the **restricted** security level:

```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
```

**Three Levels:**

| Level | Description | Use Case |
|-------|-------------|----------|
| privileged | Unrestricted | System/infrastructure workloads |
| baseline | Prevents known privilege escalations | Most workloads (AKS default) |
| restricted | Current hardening best practices | Sensitive data environments |

We use `restricted` as the strictest level. Microsoft recommends `baseline` for most workloads, but `restricted` for environments handling sensitive data.

### Deployment Security Context

**Pod-level:**

- `runAsNonRoot: true` - Prevents running as root
- `runAsUser/Group: 1000` - Runs as node user
- `fsGroup: 1000` - File ownership for volumes
- `seccompProfile: RuntimeDefault` - Kernel syscall filtering

**Container-level:**

- `allowPrivilegeEscalation: false` - No privilege escalation
- `readOnlyRootFilesystem: true` - Immutable container filesystem
- `capabilities.drop: [ALL]` - No Linux capabilities

### Read-Only Filesystem and emptyDir Volumes

<https://kubernetes.io/docs/tasks/configure-pod-container/security-context/>

<https://kubernetes.io/docs/concepts/storage/volumes/#emptydir>

With `readOnlyRootFilesystem: true`, the container's filesystem becomes immutable. This is recommended by the [NSA/CISA Kubernetes Hardening Guidance](https://kubernetes.io/blog/2021/10/05/nsa-cisa-kubernetes-hardening-guidance/) to limit execution and tampering of containers at runtime.

However, most applications need to write temporary files. We use `emptyDir` volumes to provide writable paths for specific directories:

| Path | Purpose |
|------|---------|
| `/tmp` | Node.js temp files, workflow execution scratch space |
| `/home/node/.cache` | npm cache, n8n credential cache |

An `emptyDir` volume:

- Is created when a Pod is assigned to a node (initially empty)
- Persists across container crashes (data survives restarts)
- Is deleted permanently when the Pod is removed from the node
- Is isolated per-pod (not shared between pods)

```yaml
volumeMounts:
  - mountPath: /tmp
    name: tmp
  - mountPath: /home/node/.cache
    name: cache

volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
```

**Security benefit**: The root filesystem stays read-only, so an attacker who compromises the container cannot modify application binaries, install malware persistently, or tamper with config files. They can only write to the explicitly allowed ephemeral paths.

## Resource Management

<https://learn.microsoft.com/en-us/azure/aks/developer-best-practices-resource-management#define-pod-resource-requests-and-limits>

```yaml
resources:
  requests:
    memory: "256Mi"
    cpu: "100m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

- **Requests**: Guaranteed resources for scheduling
- **Limits**: Maximum resources the container can use

## Health Probes

### Liveness Probe

Restarts the container if it becomes unresponsive:

```yaml
livenessProbe:
  httpGet:
    path: /healthz
    port: 3008
  initialDelaySeconds: 30
  periodSeconds: 10
  failureThreshold: 3
```

### Readiness Probe

Removes pod from service endpoints until ready:

```yaml
readinessProbe:
  httpGet:
    path: /healthz
    port: 3008
  initialDelaySeconds: 5
  periodSeconds: 5
  failureThreshold: 3
```

## Cilium Network Policy

We use CiliumNetworkPolicy instead of standard Kubernetes NetworkPolicy for better integration with AKS Cilium networking.

### Ingress (Incoming Traffic)

- Allow from Traefik namespace on port 3008

### Egress (Outgoing Traffic)

- Allow to CNPG database pods on port 5432
- Allow DNS resolution (kube-dns on port 53/UDP)
- Allow external HTTPS on port 443 (for webhooks/integrations)

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: customer1-n8n
spec:
  endpointSelector:
    matchLabels:
      app: customer1-n8n
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: traefik
      toPorts:
        - ports:
            - port: "3008"
  egress:
    - toEndpoints:
        - matchLabels:
            cnpg.io/cluster: customer1-db
      toPorts:
        - ports:
            - port: "5432"
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
    - toEntities:
        - world
      toPorts:
        - ports:
            - port: "443"
```

## GitOps Changes

All changes are in `mercury-gitops/apps/base/customer1/`:

| File | Change |
|------|--------|
| `namespace.yaml` | Added PSS labels |
| `deployment.yaml` | Full security context, resources, probes, emptyDir volumes |
| `network-policy.yaml` | New file |
| `kustomization.yaml` | Added network-policy.yaml |
