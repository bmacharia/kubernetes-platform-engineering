# n8n Deployment Plan for AKS

## Overview

Deploy n8n workflow automation tool to the existing AKS cluster (`mercury-cluster`) using custom Kubernetes manifests with SQLite storage mode.

## Requirements Summary

| Requirement | Implementation |
|-------------|----------------|
| Run as user 1000 | `securityContext.runAsUser: 1000` |
| Non-root container | `securityContext.runAsNonRoot: true` |
| Persistent storage | PersistentVolumeClaim with default storage class |
| Database mode | SQLite (default, no DB_TYPE env var needed) |
| Configuration | ConfigMap for environment variables |
| Access method | kubectl port-forward |

## n8n Technical Details

Based on [n8n documentation](https://docs.n8n.io/hosting/):
- **Default port**: 5678
- **Data directory**: `/home/node/.n8n`
- **Default user**: `node` (UID 1000)
- **Docker image**: `docker.n8n.io/n8nio/n8n:latest` (or specific version)

## Manifest Structure

I will create a new directory `manifests-n8n-sqlite/` with the following files:

```
manifests-n8n-sqlite/
├── namespace.yaml      # Dedicated namespace for n8n
├── configmap.yaml      # Environment variables
├── pvc.yaml            # Persistent volume claim
├── deployment.yaml     # n8n deployment
├── service.yaml        # ClusterIP service
└── kustomization.yaml  # Kustomize for easy deployment
```

## Detailed Manifest Specifications

### 1. namespace.yaml
```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: n8n
```

### 2. configmap.yaml
Environment variables for n8n configuration:
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: n8n-config
  namespace: n8n
data:
  # Port configuration
  N8N_PORT: "5678"
  # Timezone (adjust as needed)
  GENERIC_TIMEZONE: "UTC"
  TZ: "UTC"
  # File permissions enforcement
  N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
  # Disable secure cookies for local dev (port-forward)
  N8N_SECURE_COOKIE: "false"
  # Data directory (matches volume mount)
  N8N_USER_FOLDER: "/home/node/.n8n"
```

**Note**: No `DB_TYPE` variable - n8n defaults to SQLite mode.

### 3. pvc.yaml
Persistent storage using default storage class:
```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
  namespace: n8n
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 5Gi
  # Uses default storage class (managed-csi on AKS)
```

### 4. deployment.yaml
Main deployment with security requirements:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
spec:
  replicas: 1
  selector:
    matchLabels:
      app: n8n
  template:
    metadata:
      labels:
        app: n8n
    spec:
      # Pod-level security context
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        runAsNonRoot: true

      containers:
        - name: n8n
          image: docker.n8n.io/n8nio/n8n:latest

          # Container-level security context
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: false  # n8n needs to write temp files
            capabilities:
              drop:
                - ALL

          # Environment from ConfigMap
          envFrom:
            - configMapRef:
                name: n8n-config

          ports:
            - name: http
              containerPort: 5678
              protocol: TCP

          # Health checks
          livenessProbe:
            httpGet:
              path: /healthz
              port: 5678
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 3

          readinessProbe:
            httpGet:
              path: /healthz
              port: 5678
            initialDelaySeconds: 10
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3

          # Resource limits
          resources:
            requests:
              memory: "256Mi"
              cpu: "100m"
            limits:
              memory: "1Gi"
              cpu: "1000m"

          # Volume mount for persistent data
          volumeMounts:
            - name: n8n-data
              mountPath: /home/node/.n8n

      volumes:
        - name: n8n-data
          persistentVolumeClaim:
            claimName: n8n-data
```

### 5. service.yaml
ClusterIP service for port-forward access:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: n8n
  namespace: n8n
  labels:
    app: n8n
spec:
  type: ClusterIP
  selector:
    app: n8n
  ports:
    - name: http
      port: 5678
      targetPort: 5678
      protocol: TCP
```

### 6. kustomization.yaml
For easy deployment:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: n8n
resources:
  - namespace.yaml
  - configmap.yaml
  - pvc.yaml
  - deployment.yaml
  - service.yaml
```

## Security Considerations

1. **runAsUser: 1000** - Matches the `node` user in the n8n container
2. **runAsNonRoot: true** - Ensures container cannot escalate to root
3. **fsGroup: 1000** - Ensures mounted volumes are writable by the n8n user
4. **allowPrivilegeEscalation: false** - Prevents privilege escalation
5. **capabilities.drop: ALL** - Drops all Linux capabilities

## Deployment Steps

After manifests are created:

```bash
# 1. Apply all manifests
kubectl apply -k manifests-n8n-sqlite/

# 2. Verify deployment
kubectl get pods -n n8n
kubectl get pvc -n n8n

# 3. Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app=n8n -n n8n --timeout=120s

# 4. Port forward to access n8n
kubectl port-forward svc/n8n 5678:5678 -n n8n

# 5. Access n8n at http://localhost:5678
```

## Files to Create

1. `manifests-n8n-sqlite/namespace.yaml`
2. `manifests-n8n-sqlite/configmap.yaml`
3. `manifests-n8n-sqlite/pvc.yaml`
4. `manifests-n8n-sqlite/deployment.yaml`
5. `manifests-n8n-sqlite/service.yaml`
6. `manifests-n8n-sqlite/kustomization.yaml`

## Sources

- [n8n Hosting Documentation](https://docs.n8n.io/hosting/)
- [n8n Docker Hub](https://hub.docker.com/r/n8nio/n8n)
- [n8n Deployment Environment Variables](https://docs.n8n.io/hosting/configuration/environment-variables/deployment/)
