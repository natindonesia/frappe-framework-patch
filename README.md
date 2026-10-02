# Frappe Framework backend (patched) — container image

Reproducible Frappe `version-16` backend shipped as pre-initialized bench images.
The `frappe/` directory is a Git submodule pinned to the exact upstream revision
used by a build; local changes live in `patches/` and are never committed into
the submodule.

---

## Published images

`ghcr.io/natindonesia/frappe` — three tags, nothing else. Every commit-built
image also goes to `registry.digitalocean.com/natindonesia/frappe` with the same
digests.

| Tag | What it is | Pull |
|---|---|---|
| `latest` | **Patched production image** (default choice). Pinned Frappe + `patches/` applied, frappe app assets rebuilt. | `docker pull ghcr.io/natindonesia/frappe:latest` |
| `base` | Unpatched reference image: identical bench/runtime, no local patches. Use to diff behavior against upstream. | `docker pull ghcr.io/natindonesia/frappe:base` |
| `latest-granian` | `latest` + [Granian](https://github.com/emmett-framework/granian) installed in the bench venv as an alternative to gunicorn. | `docker pull ghcr.io/natindonesia/frappe:latest-granian` |

Pin by digest for production — tags move, digests do not:

```bash
docker pull ghcr.io/natindonesia/frappe@sha256:<digest>
```

GHCR additionally carries, per image: a keyless cosign signature, SLSA build
provenance, and an SPDX SBOM attestation (see
[Verifying published images](#verifying-published-images)).

`base` and `latest` share one layered build: a pristine `builder-base` stage
(bench init on the pinned source, all dependencies) is built once, then
`latest` layers patch application + asset rebuild on top; `base` deploys that
pristine builder as-is. `latest-granian` builds directly `FROM frappe:latest`.
So the lineage is `base → latest → latest-granian`, and `base` differs from
`latest` **only** by the patch set.

Every image carries OCI labels: `org.opencontainers.image.title`,
`.description`, `.url`, `.source`, `.revision`, `.created`, `.version`,
`.frappe-sha` (pinned Frappe submodule commit), `.variant`, and
`.patches-applied`. Only `latest`, `base`, and `latest-granian` are ever
published — no SHA, commit, run, or temporary tags.

## What's inside

- Debian `bookworm`, Python `3.14.2`, Node.js `24.13.0` (nvm, `yarn` + `pnpm`).
- A full bench at `/home/frappe/frappe-bench` with **only the `frappe` app**
  initialized (no site yet — the `init` role creates it). `bench` CLI installed.
- gunicorn + the OTel-aware WSGI entrypoint `frappe.otel_wsgi:application`
  (config: `apps/frappe/resources/gunicorn-otel-conf.py`).
- nginx `1.28` from nginx.org **with the dynamic `nginx-module-otel`** installed
  ABI-matched to the exact nginx binary, plus the bench's nginx templates and
  `nginx-entrypoint.sh`.
- PDF/print stack: `wkhtmltopdf 0.12.6.1-3`, `chromium-headless-shell`,
  weasyprint system libraries.
- OpenTelemetry SDK/exporter packages and `pyinstrument` **preinstalled** in the
  bench venv — tracing is configured at runtime via env, never at build time.
- `restic`, `mariadb-client`, `postgresql-client`, `redis-tools`, `jq`,
  `wait-for-it`.
- Runs as the **non-root `frappe` user**. `VOLUME`s:
  `/home/frappe/frappe-bench/sites` and `/home/frappe/frappe-bench/logs`.
- The image has **no default CMD** — it is meant to run one process role per
  container (below), orchestrated by the compose file in this repository.

## Quick start (docker compose)

This repository ships the matching `docker-compose.yml` (MariaDB, Redis,
OTel collector, `init`, `web`, workers, scheduler, socketio, nginx):

```bash
git clone https://github.com/natindonesia/frappe-framework-patch
cd frappe-framework-patch

SITE_NAME=myapp.localhost MYSQL_ROOT_PASSWORD=secret ADMIN_PASSWORD=secret \
  docker compose up -d
```

Then open `http://localhost:8085` (compose maps nginx's `8080` to
`${HTTP_PORT:-8085}`). The `init` one-shot creates the site, then the other
roles start against the shared `sites` volume.

The compose file builds images from source by default. To run the published
images instead, drop a `docker-compose.override.yml`:

```yaml
services:
  init:        { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  web:         { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  worker:      { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  worker-long: { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  worker-short:{ image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  schedule:    { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  socketio:    { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
  nginx:       { image: ghcr.io/natindonesia/frappe:latest, build: !reset null }
```

## Process roles

One container = one role. Reference commands (all run from
`/home/frappe/frappe-bench` with `env/bin/activate`; the compose file wires
them exactly):

| Role | Command | Notes |
|---|---|---|
| `init` | `/usr/local/bin/init.sh` (entrypoint) | One-shot site creation; all other roles depend on it. |
| `web` | `gunicorn --chdir=sites --bind=0.0.0.0:8000 --threads=4 --workers=2 --worker-class=gthread --timeout=120 --preload --config apps/frappe/resources/gunicorn-otel-conf.py frappe.otel_wsgi:application` | Stateless; scale horizontally. |
| `worker` | `bench worker` | Default queue. |
| `worker-long` / `worker-short` | `bench worker --queue long` / `--queue short` | Split long jobs off the default queue. |
| `schedule` | `bench schedule` | **Singleton** — never scale past 1 replica (double-fires scheduled jobs). |
| `socketio` | `node apps/frappe/socketio.js` | Listens on `:9000`; needs a sticky-session LB if scaled. |
| `nginx` | `/usr/local/bin/nginx-entrypoint.sh` | Serves `:8080`, proxies `BACKEND` (default `web:8000`) and `SOCKETIO` (default `socketio:9000`), serves static assets from the shared sites volume. |

With the Granian variant, run `web` as:

```bash
env/bin/granian --interface wsgi --host 0.0.0.0 --port 8000 \
  --workers 2 --blocking-threads 4 frappe.otel_wsgi:application
```

The WSGI entrypoint is unchanged — Granian is a pure server swap.

### What `init.sh` does

1. Points the bench at the `mariadb` / `redis` service names.
2. First run: `bench new-site` with `--mariadb-user-host-login-scope='%'` —
   the DB user gets a wildcard host grant so horizontally scaled web/worker
   replicas can all connect — then installs any apps present in the bench,
   sets `developer_mode 1`, and runs `/scripts/fix-db-users.sh`.
3. Subsequent runs: re-runs `fix-db-users.sh` and `bench --site all migrate`.
4. Restores the image-baked `sites/assets/assets.json` (from `/opt/defaults/`)
   onto the shared volume, overriding any stale copy.

### Environment variables

| Variable | Used by | Default | Purpose |
|---|---|---|---|
| `SITE_NAME` | init, nginx | `crm.localhost` | Site to create / route to. |
| `MYSQL_ROOT_PASSWORD` | init, mariadb | `admin` | MariaDB root password. |
| `ADMIN_PASSWORD` | init | `admin` | Site Administrator password. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | web, workers, scheduler, socketio, nginx | *(empty = tracing off)* | OTLP HTTP endpoint, e.g. `http://otel-collector:4318`. Tracing is opt-in: unset means nothing is traced. |
| `FRAPPE_DISABLE_OTEL` | any | *(unset)* | Force-disable tracing even when the endpoint is set. |
| `OTEL_SERVICE_NAME` | traced roles | role-specific | Span service name. |
| `OTEL_PYINSTRUMENT`, `OTEL_PYINSTRUMENT_INTERVAL`, `OTEL_PYINSTRUMENT_RSS_INTERVAL` | web | *(empty = off)* | Per-request pyinstrument profiling on HTTP spans. |
| `NGINX_OTEL_ENDPOINT` | nginx | *(derived)* | Scheme-less `host:port` for OTLP/gRPC (`:4317`); nginx's otel module rejects `http://` prefixes. |
| `BACKEND`, `SOCKETIO` | nginx | `web:8000`, `socketio:9000` | Upstream addresses. |
| `FRAPPE_SITE_NAME_HEADER` | nginx | `$SITE_NAME` | Site the nginx leg routes to. |
| `UPSTREAM_REAL_IP_ADDRESS` | nginx | `127.0.0.1` | Trusted proxy for real-IP restoration. |
| `HTTP_PORT` | compose | `8085` | Host port published for nginx. |

The compose `otel-collector` service (always running, receives OTLP on
`4317`/`4318`) is configured with `OTEL_COLLECTOR_CONFIG_URI`,
`CENTRAL_OTLP_ENDPOINT`, `CENTRAL_OTLP_INSECURE`, and `TRACE_EXPORTERS`; see
[OpenTelemetry deployment](docs/otel-deployment.md) for full rollout, routing,
and troubleshooting.

## Verifying published images

Supply-chain attestations (SLSA provenance, SPDX SBOM) and a keyless cosign
signature are attached in GHCR only:

```bash
IMAGE=ghcr.io/natindonesia/frappe
DIGEST=sha256:<digest>

# image signature
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/natindonesia/frappe-framework-patch/\.github/workflows/build-images\.yml@' \
  "${IMAGE}@${DIGEST}"

# SLSA build provenance attestation
cosign verify-attestation \
  --type https://slsa.dev/provenance/v1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/natindonesia/frappe-framework-patch/\.github/workflows/build-images\.yml@' \
  "${IMAGE}@${DIGEST}"

# SPDX SBOM attestation
cosign verify-attestation \
  --type https://spdx.dev/Document/v2.3 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github\.com/natindonesia/frappe-framework-patch/\.github/workflows/build-images\.yml@' \
  "${IMAGE}@${DIGEST}"
```

GitHub CLI equivalent:

```bash
gh attestation verify oci://${IMAGE}@${DIGEST} --owner natindonesia
```

## Patch scope

The current patch propagates W3C `traceparent` context from `frappe.enqueue()`
into the RQ payload and restores it around worker execution, so a job's spans
join the enqueueing request's trace. OpenTelemetry is optional and falls back
to a no-op when unavailable or disabled with `FRAPPE_DISABLE_OTEL=1`.

---

# Repository / maintainers

## Patch model

- `frappe/` — Git submodule pinned to the exact upstream `version-16` commit.
- `patches/` — local changes, applied by `scripts/apply-patches.sh` into the
  bench's cloned app (git-backed mode: strict clean check +
  `git apply --check --3way` preflight, so a stale patch fails loudly without
  modifying anything).
- `runtime/` — vendored OTEL overlay files copied onto the bench tree
  (`otel.py`, `otel_wsgi.py`, `pyinstrument_middleware.py`, `test_otel.py`,
  `resources/gunicorn-otel-conf.py`); committed in the image build so the
  patch preflight sees a clean tree.
- Build constraint: **no patch may change Python dependency declarations** —
  deps are installed into the bench venv *before* patching.

## Local validation

```bash
git submodule update --init --recursive
bash tests/run_tests.sh --no-otel
bash scripts/verify-patches.sh
```

The test suite applies patches to a disposable archive of the pinned submodule,
checks the patched Python files compile, and leaves `frappe/` clean. OTel
functional tests can be run with `bash tests/run_tests.sh` when package
installation is available.

## Local image build

```bash
bash scripts/build.sh
```

Creates local images only; nothing is pushed. Publication is handled by CI
after its runtime and integration tests pass.

## GitHub Actions

The Docker/CI workflow is adapted to this patch repository's submodule/patch
model (patches applied after `bench init`; the build context vendors
`resources/`, `docker-compose.yml`, `Dockerfile.granian`, and the `runtime/`
overlays).

- `build-images.yml` — on push / pull_request. Builds the unpatched `base`
  first (populating the shared registry cache ref), then the patched `latest`
  on top of it, then `latest-granian` from the tested local `frappe:latest`;
  validates all three, then on an approved main push publishes exactly
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest`,
  `frappe:base`, and `frappe:latest-granian` plus the same three tags to
  `ghcr.io/<owner>/frappe:*`.
- `cleanup-ghcr-versions.yml` — daily prune of stale GHCR package versions
  (keeps current-release digests, signatures, and attestations).
- `update-upstream.yml` — manual (`workflow_dispatch`). Advances `frappe/` to
  the latest `origin/version-16`, validates the patch set, and pushes only the
  parent repository's gitlink commit when validation succeeds.

Both variant builds share one buildx registry cache ref
(`ghcr.io/<owner>/frappe-buildcache:main`, overridable via
`BUILD_CACHE_REGISTRY` / `BUILD_CACHE_NAMESPACE` / `BUILD_CACHE_TAG`), so the
expensive bench-init layers are stored once and patch edits never re-run them.
`gha` cache is a restore-only fallback. The Granian build uses no cache flags
(thin layer on top of the tested local image).

## Security scanning

`build-images.yml` gates publish on three independent security jobs (all upload
SARIF to the GitHub Security tab when GHAS is enabled; upload failure never
masks a scan):

- `sast` — Semgrep with the `p/owasp-top-ten` and `p/cwe-top-25` packs over
  the owned `scripts/ resources/ runtime/ tests/ patches/` surface. Fails on
  `ERROR`-severity findings.
- `trivy-source` — Trivy filesystem + config scan (dependency CVEs, committed
  secrets, Dockerfile/compose/YAML hardening) over the checked-out tree.
- `trivy-images` — Trivy scan of the exact tested images (vuln + secret +
  misconfig) after load, before any publish. Fails on `CRITICAL,HIGH`.

All three run locally via `bash scripts/ci/security-scan-{sast,source,images}.sh`
(the image script requires the images be loaded locally). Tune versions and
gates with `TRIVY_VERSION`, `SEMGREP_VERSION`, `SECURITY_SEVERITY`,
`SEMGREP_SEVERITY`, `SECURITY_FAIL_ON_FINDINGS`; `SEMGREP_EXTRA_CONFIGS`
appends more rule packs.

## Registry configuration

Set the variables `REGISTRY_URL` (default `registry.digitalocean.com`) and
`REGISTRY_NAMESPACE` (default `natindonesia`), and the secrets
`REGISTRY_USERNAME`/`REGISTRY_PASSWORD` (or the
`DIGITALOCEAN_EMAIL`/`DIGITALOCEAN_ACCESS_TOKEN` fallbacks). Secrets are used
only by the registry login action and are never printed.

The second registry is the GitHub Container Registry and needs no secret — the
workflow logs in with its own `GITHUB_TOKEN` and `permissions: packages: write`.
Override the variables `SECONDARY_REGISTRY_URL` (default `ghcr.io`) and
`SECONDARY_REGISTRY_NAMESPACE` (default the repository owner, lowercased by the
publish scripts). Publishing to it is skipped only when `SECONDARY_REGISTRY_URL`
is set to an empty value.