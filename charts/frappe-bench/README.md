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

### Default outgoing mail (`smtp`)

Frappe resolves the outgoing account in this order:

1. a DB `Email Account` with `default_outgoing = 1`
2. `EmailAccount.find_from_config()` → the `mail_*` keys in
   `common_site_config.json`
3. a dummy `notifications@example.com` account, which fails and backs up the
   outgoing queue

The `smtp` block writes step 2 during the migrate Job. Because that file is
bench-wide, **every site inherits it, including sites created later** — no
per-site step, and no chart change when a new site is added.

```yaml
smtp:
  enabled: true
  host: smtp.mailersend.net
  port: 2525
  useTls: true                    # STARTTLS; 465 is not expressible from config
  autoEmailId: support@example.com
  senderName: Example Support
  alwaysUseAccountEmailIdAsSender: true
  existingSecret: my-bench-smtp   # Secret, normally a SealedSecret
  loginKey: mail_login
  passwordKey: mail_password
```

The credentials are read from `existingSecret` with **non-optional**
`secretKeyRef`s, so a missing Secret blocks the hook (fail-closed) instead of
shipping a bench whose mail silently piles up in `tabEmail Queue`. Apply the
SealedSecret in an earlier revision: Argo CD does not wait for the
sealed-secrets controller to materialise the Secret, so a same-sync race shows
up as a hook timeout.

Non-secret keys use `bench set-config -g --parse`, which evaluates
`ast.literal_eval`; credentials are passed verbatim because a quoted password
would be stored with the quotes.

Set `autoEmailId`. Without it Frappe falls back to `mail_login`, which is
usually a provider login (`MS_xxx@domain`) and not a deliverable sender, so the
relay rejects the message.

Caveats:

- `mail_password` lands **cleartext** in `sites/common_site_config.json` (mode
  `644`, owned by `frappe`) on the sites volume, and that file is part of the
  backup artifact uploaded to S3. Sealing protects the git history, not the
  cluster or the backups. Never rely on this for credentials that must stay
  confidential from cluster readers.
- A site that already has a default outgoing `Email Account` keeps it; config
  is the fallback, not an override.
- `use_ssl_for_outgoing` has no config equivalent, so implicit-SSL relays on
  465 cannot be expressed here.
- Disabling `smtp` does not delete the keys already written to
  `common_site_config.json`. Blank them (`bench set-config -g mail_server ""`)
  if you need the bench to stop pointing at the relay.

The pods that read the config once at startup (web, workers, scheduler,
socketio) carry a `checksum/site-config` annotation, so any change to
`commonSiteConfig` or `smtp` rolls them.

#### Rotating the credential

The annotation hashes the values, not the Secret, so **re-sealing
`existingSecret` does not roll the pods** and they keep using the password they
read at startup. After re-sealing, set `smtp.credentialVersion` to anything new
(e.g. the rotation date) and sync:

```yaml
smtp:
  credentialVersion: "2026-11-06"
```

That is the only reason the field exists. Leave it empty until the first
rotation.

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
