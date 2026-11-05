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
8. **Built-in KEDA Autoscaling**:
   - Autoscales Granian WSGI web pods based on real-time internal blocking queue pressure (`sustained_queue`) with CPU backstops.
   - Autoscales background RQ workers based on Redis queue depths (`default`, `long`, `short`).

---

## Quickstart

### 1. Direct Helm Installation

```bash
helm install my-bench oci://ghcr.io/natindonesia/charts/frappe-bench \
  --version 0.3.3 \
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
      targetRevision: 0.3.3
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
  includeFiles: false # default: skips public/files and private/files to protect S3 storage
  uptimeKumaPushSecretName: "my-bench-backup-kuma"
  uptimeKumaPushSecretKey: url
```

The Secret's `url` key should contain the Uptime Kuma push endpoint. Successful
heartbeats include the compressed database and config archive sizes in bytes,
their combined artifact size, and elapsed seconds in the push message. Failures
send a down heartbeat. Uploaded site files remain excluded unless
`includeFiles` is enabled.

The latest site config files remain under `sites/`. The same current files are
also copied to `sites/hourly/` on every run and to `sites/daily/` at 00:00 UTC.
This applies to `common_site_config.json`, `apps.txt`, and each site's
`site_config.json`.

### Outbound SMTP (`networkPolicy.smtpEgress`)

The rendered NetworkPolicies are default-deny with explicit allow-lists, so
sending mail fails silently until the submission port is allowed. The chart
ships that grant **disabled**:

```yaml
networkPolicy:
  smtpEgress:
    enabled: false # enable only if the cluster has no cluster-wide rule
    port: 2525     # 25/465 are often filtered upstream; 2525 works on Gcore
    cidr: 0.0.0.0/0
```

Enabling it adds the port to `web-policy` and `workers-scheduler-policy` egress
for any public destination outside `podCidr`/`serviceCidr`/`nodeCidr`. A
Kubernetes NetworkPolicy cannot match a hostname, so the grant is necessarily
CIDR-wide — accept that TCP 2525 reaches any public host, not just your relay.

On Cilium clusters prefer a cluster-scoped `CiliumClusterwideNetworkPolicy`
with an explicit system-namespace exclusion instead: it covers future
namespaces and cannot be defeated by additive per-namespace rules. Note that a
Cilium egress policy is an allow-list for every endpoint it selects, so a
wildcard `endpointSelector` replaces kube-dns' own egress and breaks DNS
cluster-wide.

### Site encryption keys (`migrateJob.validateEncryptionKeys`)

Frappe stores a per-site Fernet key in `sites/<site>/site_config.json`. A key
that is not 44-char url-safe base64 (32 decoded bytes) makes every encrypted
read/write fail at runtime with `Encryption key is in invalid format` — long
after the chart has reported a healthy sync.

The pre-sync `migrate` Job therefore validates every site config before running
`bench --site all migrate`, naming the offending site and aborting the hook:

```yaml
migrateJob:
  validateEncryptionKeys: true # default
```

- Malformed key (wrong length, not base64, wrong decoded length) → Job fails, sync blocked.
- Missing key → warning only; `bench new-site` generates one for fresh sites.

This is the shared layer: every namespace that installs the chart gets the check,
including ones whose site configs are seeded outside Helm (gitops hooks, sealed
secrets). Set it to `false` only if you need a sync to proceed with a known-bad
site for a repair.

---

## License

Apache-2.0 or MIT. See repository LICENSE for full details.
