# Frappe Bench Helm Chart

A production-grade, open-source Helm chart for deploying Frappe / ERPNext workloads on Kubernetes using the **Frappe OCI Composition Model**.

Published as a public OCI chart at:
```
oci://ghcr.io/natindonesia/charts/frappe-bench
```

---

## Architecture Overview

```
                      [ Envoy Gateway :443 ]
                                 │
                 ┌───────────────┴───────────────┐
                 │ (HTTPRoute /)                 │ (HTTPRoute /socket.io)
                 ▼                               ▼
      [ Nginx Edge (:8080) ]            [ SocketIO (:9000) ]
                 │                               │
                 │ (Proxy to WSGI)               │
                 ▼                               │
       [ Granian WSGI (:8000) ]                  │
                 │                               │
                 ├───────────────────────────────┤
                 ▼                               ▼
       [ Shared Sites Storage (JuiceFS RWX / NVMe RWO) ]
                 ▲                               ▲
                 │                               │
     [ Default RQ Worker ]              [ Bench Scheduler ]
                 │                               │
                 └───────────────┬───────────────┘
                                 │
           ┌─────────────────────┴─────────────────────┐
           ▼                                           ▼
  [ MariaDB / Operator ]                       [ Redis Cache/Queue ]
```

### Key Highlights

1. **OCI Composition Model (Zero-Copy Image Volumes)**:
   - Python virtual environment and core runtime run from an immutable base image (`runtime`).
   - Applications (`apps`) are declared as pure OCI artifacts (`ghcr.io/natindonesia/<app>:latest-standalone`).
   - The Kubernetes kubelet mounts application payloads directly as read-only image volumes (`volume.image.reference`), eliminating the need for init-container code copying or bloated monolithic container builds.
2. **Unhashed Asset Serving**:
   - Because bundles are unhashed, Nginx resolves static assets straight from the mounted trees (`subPath: opt/frappe/apps/<app>/assets` or symlinked `/sites/assets/<app>`). No `assets.json` manifest merging is required.
3. **Automated Canonical Naming**:
   - Strictly enforces canonical naming (`{{ .Release.Namespace }}-<component>`) across OTel service names, deployments, network policies, and metrics.
4. **Declarative Multi-Tenancy**:
   - One bench deployment can serve multiple sites. Each site automatically gets its own Envoy Gateway `HTTPRoute` with proper headers (`X-Frappe-Site-Name`, `Origin`).
5. **Observability Built-In**:
   - Bundles a local OpenTelemetry Collector relay (`:4317` gRPC / `:4318` HTTP) with trace/log scrubbing and upstream forwarding.
6. **Self-Healing Migration Job**:
   - Runs `bench --site all migrate` on sync hooks, self-heals ephemeral MariaDB user scopes (`fix-db-users.sh`), and links app public asset directories automatically.
7. **Zero-Downtime Backup CronJob**:
   - Hourly database dumping and append-only S3 synchronization for sites and configuration backups.

---

## Quickstart

### 1. Direct Helm Installation

```bash
helm install my-bench oci://ghcr.io/natindonesia/charts/frappe-bench \
  --version 0.2.0 \
  --namespace my-bench-namespace \
  --create-namespace \
  -f values.yaml
```

### 2. Argo CD Multi-Source Application (GitOps)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: my-bench
  namespace: devtroncd
spec:
  project: default
  sources:
    # 1. Config and values from Git repo
    - repoURL: git@github.com:natindonesia/infrastructure-playbook.git
      targetRevision: main
      ref: config
    # 2. Public OCI Helm Chart
    - repoURL: ghcr.io/natindonesia/charts
      chart: frappe-bench
      targetRevision: 0.2.0
      helm:
        releaseName: my-bench
        valueFiles:
          - $config/multicloud/gcore/gitops/my-bench/values.yaml
    # 3. Sealed secrets (credentials)
    - repoURL: git@github.com:natindonesia/infrastructure-playbook.git
      targetRevision: main
      path: multicloud/gcore/gitops/my-bench/secrets
  destination:
    server: https://kubernetes.default.svc
    namespace: my-bench
```

---

## Configuration Reference

### Minimal `values.yaml`

```yaml
canonicalName: my-bench

runtime:
  repository: ghcr.io/natindonesia/fayolex-working-staging-runtime
  tag: latest
  pullPolicy: Always

apps:
  - name: frappe
    primary: true
    image:
      repository: ghcr.io/natindonesia/fayolex-working-staging-frappe
      tag: latest-standalone
  - name: crm
    image:
      repository: ghcr.io/natindonesia/crm
      tag: latest-standalone

sites:
  - name: crm.example.com
    gateway:
      name: grafana
      namespace: observability
      sectionName: http-listener

sitesStorage:
  storageClassName: juicefs-s3
  size: 10Gi

mariadb:
  operator:
    enabled: true
    storageSize: 20Gi

backup:
  enabled: true
  schedule: "0 * * * *"
```

---

## License

Apache-2.0 or MIT. See repository LICENSE for full details.
