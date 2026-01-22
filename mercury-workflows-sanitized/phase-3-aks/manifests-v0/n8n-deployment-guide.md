# n8n Deployment to AKS - Complete Guide

This guide explains each Kubernetes manifest in the `manifests-v0` folder and provides a reusable framework for deploying applications to AKS.

---

## Table of Contents

1. [Manifest Files Explained](#manifest-files-explained)
2. [Deployment Flow Diagram](#deployment-flow-diagram)
3. [Framework for Deploying Apps to AKS](#framework-for-deploying-apps-to-aks)
4. [Practice Apps to Deploy](#practice-apps-to-deploy)

---

## Manifest Files Explained

### 1. `namespace.yaml` - Isolation Boundary

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: n8n
```

**Purpose:** Creates a dedicated namespace called `n8n` to isolate the application from other workloads.

**Benefits:**

- Resource organization and logical grouping
- Access control boundaries (RBAC can be scoped to namespaces)
- Resource quota management
- Easier cleanup (delete namespace = delete everything in it)

---

### 2. `configmap.yaml` - Configuration Management

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: n8n-configmap
data:
  N8N_PORT: "3008"
  N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
  N8N_SECURE_COOKIE: "false"
```

**Purpose:** Externalizes application configuration from the container image.

| Key                                     | Description                         |
| --------------------------------------- | ----------------------------------- |
| `N8N_PORT`                              | The port n8n listens on             |
| `N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS` | Security setting for settings files |
| `N8N_SECURE_COOKIE`                     | Disabled for non-HTTPS development  |

**Why it matters:** Allows you to change configuration without rebuilding images. In production, you'd also use Secrets for sensitive data.

---

### 3. `storage.yaml` - Persistent Storage

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: n8n-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
```

**Purpose:** Requests persistent storage from AKS for n8n's data (SQLite database, workflows, credentials).

| Setting         | Description                          |
| --------------- | ------------------------------------ |
| `ReadWriteOnce` | Can be mounted by one node at a time |
| `1Gi`           | Requests 1 gigabyte of storage       |

AKS will dynamically provision an Azure Disk using the default StorageClass.

**Why it matters:** Without this, n8n data would be lost when pods restart.

---

### 4. `deployment.yaml` - The Workload Definition

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: n8n
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
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
      containers:
        - name: n8n
          image: docker.n8n.io/n8nio/n8n:1.118.2
          securityContext:
            allowPrivilegeEscalation: false
          envFrom:
            - configMapRef:
                name: n8n-configmap
          ports:
            - containerPort: 3008
              protocol: TCP
          volumeMounts:
            - mountPath: /home/node/.n8n
              name: n8n-data
      restartPolicy: Always
      volumes:
        - name: n8n-data
          persistentVolumeClaim:
            claimName: n8n-data
```

**Purpose:** Defines HOW to run n8n.

| Section                 | What it does                                                |
| ----------------------- | ----------------------------------------------------------- |
| `replicas: 1`           | Run one instance (SQLite doesn't support multiple replicas) |
| `securityContext`       | Runs as non-root user 1000 for security                     |
| `envFrom: configMapRef` | Injects ConfigMap values as environment variables           |
| `containerPort: 3008`   | Exposes port 3008 inside the container                      |
| `volumeMounts`          | Mounts the PVC at `/home/node/.n8n` (n8n's data directory)  |
| `volumes`               | Links the PVC claim to the volume mount                     |

---

### 5. `service.yaml` - Network Exposure

```yaml
apiVersion: v1
kind: Service
metadata:
  name: n8n
spec:
  ports:
    - port: 3008
  selector:
    app: n8n
  type: LoadBalancer
```

**Purpose:** Makes n8n accessible from outside the cluster.

| Setting              | Description                                     |
| -------------------- | ----------------------------------------------- |
| `selector: app: n8n` | Routes traffic to pods with this label          |
| `type: LoadBalancer` | Creates an Azure Load Balancer with a public IP |
| `port: 3008`         | External port that maps to the container        |

---

### 6. `kustomization.yaml` - The Orchestrator

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: n8n
resources:
  - namespace.yaml
  - deployment.yaml
  - storage.yaml
  - configmap.yaml
  - service.yaml
```

**Purpose:** Kustomize configuration that:

- Lists all resources to deploy in order
- Applies `namespace: n8n` to ALL resources automatically
- Enables `kubectl apply -k .` for one-command deployment

---

## Deployment Flow Diagram

```
┌─────────────────────────────────────────────────────────────────┐
│                     kubectl apply -k .                          │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Namespace  │───▶│  ConfigMap  │───▶│    PVC      │
│    n8n      │    │   (config)  │    │  (storage)  │
└─────────────┘    └─────────────┘    └─────────────┘
                              │              │
                              ▼              ▼
                   ┌─────────────────────────────────┐
                   │         Deployment              │
                   │  ┌─────────────────────────┐   │
                   │  │      Pod                │   │
                   │  │  ┌─────────────────┐   │   │
                   │  │  │   n8n container │   │   │
                   │  │  │   port 3008     │   │   │
                   │  │  └─────────────────┘   │   │
                   │  └─────────────────────────┘   │
                   └─────────────────────────────────┘
                              │
                              ▼
                   ┌─────────────────────────────────┐
                   │   Service (LoadBalancer)        │
                   │   Azure Public IP:3008          │
                   └─────────────────────────────────┘
                              │
                              ▼
                        Internet Access
```

---

## Framework for Deploying Apps to AKS

### Step 1: Plan Your Manifests

Create this folder structure for any new application:

```
my-app/
├── namespace.yaml       # Always first
├── configmap.yaml       # Non-sensitive config
├── secret.yaml          # Sensitive data (optional)
├── storage.yaml         # If app needs persistence
├── deployment.yaml      # The workload
├── service.yaml         # Network exposure
├── ingress.yaml         # Optional: HTTP routing
└── kustomization.yaml   # Ties it all together
```

### Step 2: Template for Each File

#### namespace.yaml

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
```

#### configmap.yaml

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: <app-name>-config
data:
  KEY: "value"
  ANOTHER_KEY: "another-value"
```

#### secret.yaml (for sensitive data)

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: <app-name>-secret
type: Opaque
stringData:
  PASSWORD: "your-secret-password"
  API_KEY: "your-api-key"
```

#### storage.yaml (if app needs persistence)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app-name>-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: <size>Gi
```

#### deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
spec:
  replicas: <count>
  selector:
    matchLabels:
      app: <app-name>
  template:
    metadata:
      labels:
        app: <app-name>
    spec:
      containers:
        - name: <app-name>
          image: <registry>/<image>:<tag>
          ports:
            - containerPort: <port>
          envFrom:
            - configMapRef:
                name: <app-name>-config
          # Add if using secrets:
          # - secretRef:
          #     name: <app-name>-secret
          # Add if using storage:
          # volumeMounts:
          #   - mountPath: /data
          #     name: <app-name>-data
      # Add if using storage:
      # volumes:
      #   - name: <app-name>-data
      #     persistentVolumeClaim:
      #       claimName: <app-name>-data
```

#### service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app-name>
spec:
  selector:
    app: <app-name>
  ports:
    - port: <external-port>
      targetPort: <container-port>
  type: ClusterIP # or LoadBalancer for external access
```

#### kustomization.yaml

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: <app-name>
resources:
  - namespace.yaml
  - configmap.yaml
  # - secret.yaml      # Uncomment if using
  # - storage.yaml     # Uncomment if using
  - deployment.yaml
  - service.yaml
```

### Step 3: Deployment Commands

```bash
# Preview what will be created
kubectl apply -k . --dry-run=client -o yaml

# Deploy the application
kubectl apply -k .

# Verify deployment
kubectl -n <app-name> get all
kubectl -n <app-name> get pvc
kubectl -n <app-name> logs deployment/<app-name>

# Access the application (if using LoadBalancer)
kubectl -n <app-name> get svc -w  # Wait for EXTERNAL-IP

# Port forward for testing (if using ClusterIP)
kubectl -n <app-name> port-forward svc/<app-name> 8080:<port>

# Clean up everything
kubectl delete -k .
```

### Step 4: Debugging Commands

```bash
# Check pod status
kubectl -n <app-name> get pods

# Describe pod for events and errors
kubectl -n <app-name> describe pod <pod-name>

# View logs
kubectl -n <app-name> logs <pod-name>
kubectl -n <app-name> logs <pod-name> --previous  # Previous container logs

# Exec into container
kubectl -n <app-name> exec -it <pod-name> -- /bin/sh

# Check events
kubectl -n <app-name> get events --sort-by='.lastTimestamp'
```

---

## Practice Apps to Deploy

Here are suggested applications to practice with, ordered by complexity:

| App                      | Complexity | What You'll Learn                          |
| ------------------------ | ---------- | ------------------------------------------ |
| **nginx**                | Easy       | Basic deployment, no storage needed        |
| **Redis**                | Easy       | In-memory storage, StatefulSet alternative |
| **PostgreSQL**           | Medium     | Secrets, persistent storage, health checks |
| **WordPress + MySQL**    | Medium     | Multi-container apps, service discovery    |
| **Prometheus + Grafana** | Advanced   | ConfigMaps, multiple services, dashboards  |

### Quick Practice: Deploy nginx

```bash
# Create a new folder
mkdir nginx-practice && cd nginx-practice

# Create manifests and deploy
# (Use the templates above with app-name=nginx, image=nginx:latest, port=80)
kubectl apply -k .

# Test
kubectl -n nginx port-forward svc/nginx 8080:80
# Visit http://localhost:8080
```

---

## Best Practices Checklist

- [ ] Always use namespaces to isolate applications
- [ ] Use ConfigMaps for non-sensitive configuration
- [ ] Use Secrets for sensitive data (passwords, API keys)
- [ ] Set resource requests and limits on containers
- [ ] Use health checks (liveness and readiness probes)
- [ ] Run containers as non-root users when possible
- [ ] Use specific image tags, not `latest`
- [ ] Use Kustomize for environment-specific configurations
- [ ] Store manifests in version control (Git)

---

## Additional Resources

- [Kubernetes Documentation](https://kubernetes.io/docs/)
- [Kustomize Documentation](https://kustomize.io/)
- [AKS Best Practices](https://docs.microsoft.com/en-us/azure/aks/best-practices)
- [n8n Documentation](https://docs.n8n.io/)
