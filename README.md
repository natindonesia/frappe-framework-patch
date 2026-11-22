# Frappe Framework backend (patched) — container image

Reproducible Frappe `version-16` backend shipped as pre-initialized bench images.
The `frappe/` directory is a Git submodule pinned to the exact upstream revision
used by a build; local changes live in `patches/` and are never committed into
the submodule.

---

## Published images

`ghcr.io/natindonesia/frappe` — three variants under two tag families. When a
primary registry is configured (`REGISTRY_URL`), every commit-built image is
mirrored there with the same digests; the two registries are independent, so an
unavailable one never blocks the other.

| Tag | What it is | Pull |
|---|---|---|
| `latest` | **Patched production image** (default choice). Pinned Frappe + `patches/` applied, frappe app assets rebuilt. | `docker pull ghcr.io/natindonesia/frappe:latest` |
| `base` | Unpatched reference image: identical bench/runtime, no local patches. Use to diff behavior against upstream. | `docker pull ghcr.io/natindonesia/frappe:base` |
| `latest-granian` | `latest` + [Granian](https://github.com/emmett-framework/granian) installed in the bench venv as an alternative to gunicorn. | `docker pull ghcr.io/natindonesia/frappe:latest-granian` |

The floating tags above only move from the default branch. Every publish also
writes the same three images under the pinned Frappe release version
(`org.opencontainers.image.frappe-version`), which never move:

| Immutable tag | Equals |
|---|---|
| `<version>` | `latest` (patched production) |
| `<version>-base` | `base` (unpatched reference) |
| `<version>-granian` | `latest-granian` |

So `docker pull ghcr.io/natindonesia/frappe:16.55.2-granian` pins a release,
and an older release can be re-published from its `release/frappe-<version>`
branch without touching `latest`. Release tags are exempt from the GHCR cleanup
job.

### Architectures

Every published tag is a **multi-arch index** covering `linux/amd64` and
`linux/arm64`; `docker pull` selects the platform of the host automatically.
Each platform is built natively (x64 runner for amd64, ARM runner for arm64 —
never QEMU), so the two manifests are real toolchain outputs, not emulation.

Each index points at permanent per-architecture child tags. They are published
because the index references its children **by digest**, so they must outlive
the tag that first introduced them (the GHCR cleanup keeps them):

| Child tag | Platform |
|---|---|
| `<tag>-amd64` | `linux/amd64` manifest (e.g. `latest-amd64`, `16.55.2-base-amd64`) |
| `<tag>-arm64` | `linux/arm64` manifest (e.g. `latest-arm64`, `16.55.2-granian-arm64`) |

Pull a child tag directly only when you need to pin one platform; otherwise use
the multi-arch tag and let Docker choose.

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
`.patches-applied`. Only `latest`, `base`, and `latest-granian` (plus their
immutable release equivalents and the per-arch child tags described above) are
ever published — no SHA, commit, or run tags.

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
   replicas can all connect — then installs any apps present in the bench.
   If `DEVELOPER_MODE=1`, developer mode is set bench-wide before site creation;
   finally runs `/scripts/fix-db-users.sh`.
3. Subsequent runs: re-runs `fix-db-users.sh` and `bench --site all migrate`.

No asset manifest is involved: bundle filenames are unhashed (see
`patches/0007-drop-assets-json-manifest.patch`), so there is no
`sites/assets/assets.json` to bake, seed or refresh.

### Environment variables

| Variable | Used by | Default | Purpose |
|---|---|---|---|
| `SITE_NAME` | init, nginx | `crm.localhost` | Site to create / route to. |
| `MYSQL_ROOT_PASSWORD` | init, mariadb | `admin` | MariaDB root password. |
| `ADMIN_PASSWORD` | init | `admin` | Site Administrator password. A weak value is allowed only in developer mode. |
| `DEVELOPER_MODE` | init | `1` in compose | Enable Frappe developer mode before site creation. Set `0` for hosted production. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | web, workers, scheduler, socketio, nginx | *(empty = tracing off)* | OTLP HTTP endpoint, e.g. `http://otel-collector:4318`. Tracing is opt-in: unset means nothing is traced. |
| `FRAPPE_DISABLE_OTEL` | any | *(unset)* | Force-disable tracing even when the endpoint is set. |
| `OTEL_SERVICE_NAME` | traced roles | role-specific | Span service name. |
| `OTEL_PYINSTRUMENT`, `OTEL_PYINSTRUMENT_INTERVAL`, `OTEL_PYINSTRUMENT_RSS_INTERVAL` | web | *(empty = off)* | Per-request pyinstrument profiling on HTTP spans. |
| `ENABLE_WALL_PROFILING`, `WALL_PROFILING_DIR`, `WALL_PROFILING_IGNORE` | web | *(empty = off)* | Deterministic wall-time WSGI profiling, percentile distribution analysis, and OTel trace correlation. See [Wall-Time Profiling](docs/wall-time-profiling.md). |
| `NGINX_OTEL_ENDPOINT` | nginx | *(derived)* | Scheme-less `host:port` for OTLP/gRPC (`:4317`); nginx's otel module rejects `http://` prefixes. |
| `BACKEND`, `SOCKETIO` | nginx | `web:8000`, `socketio:9000` | Upstream addresses. |
| `FRAPPE_SITE_NAME_HEADER` | nginx | `$SITE_NAME` | Site the nginx leg routes to. |
| `UPSTREAM_REAL_IP_ADDRESS` | nginx | `127.0.0.1` | Trusted proxy for real-IP restoration. |
| `FRAPPE_BUILD_VERSION` | web, workers | `$IMAGE_VERSION` | Cache-busting suffix appended to asset URLs. Bundle filenames are unhashed, so assets are versioned per release instead of by content hash. |
| `HTTP_PORT` | compose | `8085` | Host port published for nginx. |

> **Administrator password policy:** local compose defaults (`DEVELOPER_MODE=1`,
> `ADMIN_PASSWORD=admin`) exist to keep developer setup frictionless. Hosted
> production must set `DEVELOPER_MODE=0` and a strong `ADMIN_PASSWORD`; site
> creation refuses a weak Administrator password outside developer mode.
> `bench set-admin-password` and `bench set-password ... Administrator` always
> reject common or low-score passwords, regardless of developer mode. Do not
> enable `Server Script` with a weak Administrator password.
>
> The Administrator account can be login-disabled only when
> `allow_disable_administrator` is set in site config:
> `bench --site <site> set-config allow_disable_administrator 1`, then
> `bench --site <site> disable-administrator`. Recover with
> `bench --site <site> enable-administrator`. Internal code running as
> Administrator (`set_user`, scheduler, migrations) is unaffected.

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

- `build-images.yml` — on push / pull_request. Runs once per architecture
  (`linux/amd64` on `blacksmith-4vcpu-ubuntu-2404`, `linux/arm64` on
  `blacksmith-4vcpu-ubuntu-2404-arm` — native, never QEMU). Each leg builds the
  unpatched `base` first, then the patched `latest` on top of it, then
  `latest-granian` from the tested local `frappe:latest`; validates all three
  and exports them as one archive. One job per variant **per architecture** then
  loads that archive, runs the common contract, and Trivy-scans the same image
  (no second download). On an approved main push each leg pushes its
  single-arch manifests (`latest-amd64`, `latest-arm64`, …, plus the immutable
  release tags), and a merge job folds them into the multi-arch
  `ghcr.io/<owner>/frappe:latest`, `frappe:base`, and
  `frappe:latest-granian` indexes (and the same tags in the optional primary
  registry `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:*` when configured).
  The merge only rewrites the index — the tested per-arch bytes are never
  rebuilt, and their digests are asserted against the pushed arch tags.
  A dedicated `upstream-tests` job runs Frappe's own `bench run-tests` modules
  (`test_password`, `test_password_strength`, `user/test_user`, and
  `TestCommands.test_set_password`) against the patched `latest` image — the
  fast signal for the auth/password/CLI surface this repository patches.
  `upstream-full-suite` then runs the complete upstream suite (~4k tests) with
  `bench run-parallel-tests`, split into four weighted shards on both the
  gunicorn (`latest`) and Granian (`latest-granian`) images, with a
  compose-network SMTP sink (`mailpit`) for mail tests. It is **advisory**:
  the production runtime image lacks dev-parity bits (`.git` in `apps/frappe`,
  `developer_mode=0`), and the same failures reproduce on the unpatched
  `frappe:base` image, so it must not block publish until those gaps close. A
  separate `patch-tests` job runs this repository's Python unittest suite
  (patch applicability, markers, workflow structure). Publish is gated on the
  targeted suite, patch tests, static analysis, and the per-variant matrix.
- `cleanup-ghcr-versions.yml` — daily prune of stale GHCR package versions
  (keeps current-release digests, per-arch children, signatures, and
  attestations).
- `update-upstream.yml` — manual (`workflow_dispatch`). Advances `frappe/` to
  the latest `origin/version-16`, validates the patch set, and pushes only the
  parent repository's gitlink commit when validation succeeds.

Every workflow in this repository runs on Blacksmith managed runners
(`blacksmith-{2,4}vcpu-ubuntu-2404`, `-arm` only for the native arm64 build
leg), per infrastructure-playbook#53 — there is no `ubuntu-latest` left, and the
arm64 leg is the one documented exception to that ADR's "no ARM container
builds" rule: the payload is arm64, so the runner is arm64 and no emulation is
involved.

The **only** layer cache is Blacksmith's sticky disk
(`useblacksmith/setup-docker-builder`, `cache-key: Dockerfile-<arch>`). There is
no registry cache and no `gha` cache: nothing is written to a registry for
caching, so there is no `frappe-buildcache` package to store, prune or
authenticate, and the build job needs no registry credentials at all. The
trade-off is explicit — a cold sticky disk means a cold `bench init`. The
Granian build uses no cache flags either (thin layer on top of the tested local
image).

## Security scanning

`build-images.yml` gates publish on security work in two places (all upload
SARIF to the GitHub Security tab when GHAS is enabled; upload failure never
masks a scan):

- `static-analysis` — one job, two scans. Semgrep with the `p/owasp-top-ten`
  and `p/cwe-top-25` packs over the owned
  `scripts/ resources/ runtime/ tests/ patches/` surface, failing on
  `ERROR`-severity findings; then Trivy filesystem + config (dependency CVEs,
  committed secrets, Dockerfile/compose/YAML hardening) over the checked-out
  tree, report-only and run even when Semgrep fails.
- `variant-matrix` — Trivy image scan (vuln + secret + misconfig) of the exact
  tested image, in the same job that already loaded and exercised it, so the
  scan needs no extra artifact download. Report-only.

All scans run locally via `bash scripts/ci/security-scan-{sast,source,images}.sh`
(the image script requires the images be loaded locally). Tune versions and
gates with `TRIVY_VERSION`, `SEMGREP_VERSION`, `SECURITY_SEVERITY`,
`SEMGREP_SEVERITY`, `SECURITY_FAIL_ON_FINDINGS`; `SEMGREP_EXTRA_CONFIGS`
appends more rule packs.

## Registry configuration

The GitHub Container Registry is always published and needs no secret — the
workflow logs in with its own `GITHUB_TOKEN` and `permissions: packages: write`.
It is configured by the variables `SECONDARY_REGISTRY_URL` (default `ghcr.io`)
and `SECONDARY_REGISTRY_NAMESPACE` (default the repository owner, lowercased by
the publish scripts). Publishing to it is skipped only when
`SECONDARY_REGISTRY_URL` is empty.

A second, optional registry can mirror the same tested images. Set the
variables `REGISTRY_URL` and `REGISTRY_NAMESPACE` (both empty by default, which
disables it) plus the secrets `REGISTRY_USERNAME`/`REGISTRY_PASSWORD` (or the
`DIGITALOCEAN_EMAIL`/`DIGITALOCEAN_ACCESS_TOKEN` fallbacks). Secrets are used
only by the registry login action and are never printed. Every configured
registry is pushed independently: a 401 or a missing repository fails the job
but never prevents the images from reaching the other registry.