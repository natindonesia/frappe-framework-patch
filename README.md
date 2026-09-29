# frappe-framework-patch

Reproducible Frappe `version-16` patch/build layer. The `frappe/` directory is a Git
submodule pinned to the exact upstream revision used by a build; local changes live in
`patches/` and are never committed into the submodule.

## Local validation

```bash
git submodule update --init --recursive
bash tests/run_tests.sh --no-otel
bash scripts/verify-patches.sh
```

The test suite applies patches to a disposable archive of the pinned submodule, checks
the patched Python files compile, and leaves `frappe/` clean. OTel functional tests can
be run with `bash tests/run_tests.sh` when package installation is available.

## OpenTelemetry deployment

OpenTelemetry is optional and can export Frappe, worker, scheduler, and nginx traces
through the local OTel Collector to either local logs or a central OTLP backend. See
[OpenTelemetry deployment](docs/otel-deployment.md) for configuration, rollout,
verification, and troubleshooting instructions.

## Local image build

```bash
bash scripts/build.sh
```

This creates a local image and does not push anything. Registry publication is handled
by the consolidated GitHub Actions workflow after its runtime and integration tests pass.

## GitHub Actions

The Docker/CI workflow is adapted to this patch repository's submodule/patch model
(the Dockerfile applies `./patches` to `./frappe` before `bench init`; the build
context vendors the required `resources/`, `docker-compose.yml`,
`Dockerfile.granian`, and the custom OTEL overlay files in `runtime/`).

- `build-images.yml` — on push / pull_request. Builds and tests the patched `latest`,
  the unpatched `base`, and the Granian images, then on an approved main push
  publishes exactly `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest`,
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:base`, and
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest-granian` — and the same three
  tags to the GitHub Container Registry (`ghcr.io/<owner>/frappe:*`).
- `update-upstream.yml` is manual (`workflow_dispatch`). It advances `frappe/` to the
  latest `origin/version-16`, validates the patch set, and pushes only the parent
  repository's gitlink commit when validation succeeds.

## Security scanning

`build-images.yml` gates publish on three independent security jobs (all upload SARIF
to the GitHub Security tab when GHAS is enabled; upload failure never masks a scan):

- `sast` — Semgrep with the `p/owasp-top-ten` (OWASP Top 10) and `p/cwe-top-25`
  (CWE Top 25) packs over the owned `scripts/ resources/ runtime/ tests/ patches/`
  surface. Fails on `ERROR`-severity findings.
- `trivy-source` — Trivy filesystem + config scan (dependency CVEs, committed
  secrets, Dockerfile/compose/YAML hardening) over the checked-out tree.
- `trivy-images` — Trivy scan of the exact tested `frappe:latest`, `frappe:base`,
  and `frappe-granian:latest` images (vuln + secret + misconfig) after load, before
  any publish. Fails on `CRITICAL,HIGH`.

All jobs can run locally via `bash scripts/ci/security-scan-{sast,source,images}.sh`
(the image script requires the images be loaded locally). Tune versions and gates with
`TRIVY_VERSION`, `SEMGREP_VERSION`, `SECURITY_SEVERITY`, `SEMGREP_SEVERITY`, and
`SECURITY_FAIL_ON_FINDINGS`; `SEMGREP_EXTRA_CONFIGS` appends more rule packs.

Registry configuration (same as the parent workflow): set the variables
`REGISTRY_URL` (default `registry.digitalocean.com`) and `REGISTRY_NAMESPACE`
(default `natindonesia`), and the secrets `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`
(or the `DIGITALOCEAN_EMAIL`/`DIGITALOCEAN_ACCESS_TOKEN` fallbacks). Secrets are
used only by the registry login action and are never printed.

The second registry is the GitHub Container Registry and needs no secret — the
workflow logs in with its own `GITHUB_TOKEN` and `permissions: packages: write`.
Override the variables `SECONDARY_REGISTRY_URL` (default `ghcr.io`) and
`SECONDARY_REGISTRY_NAMESPACE` (default the repository owner, lowercased by the
publish scripts). Publishing to it is skipped only when `SECONDARY_REGISTRY_URL`
is set to an empty value.

Images are published to both registries only as:

```text
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:base
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest-granian

ghcr.io/<owner>/frappe:latest
ghcr.io/<owner>/frappe:base
ghcr.io/<owner>/frappe:latest-granian
```

Publication is `docker tag` + `docker push` of the images that already passed the
matrix, so both registries hold the identical digests; the final verification step
asserts the three tags resolve to three distinct digests in each registry and to
the same digest across registries.

The image relationships are:

```text
base       = unpatched reference variant
latest     = patched production variant
latest-granian = latest + Granian
```

`base` and `latest` are sibling variants, not a parent-child chain. Both are built from
the same pinned `./frappe` source and share the dependency/runtime setup, but `latest`
applies the local patches while `base` does not:

- `latest` — the production image: the pinned `./frappe` source with `patches/` applied
  (Dockerfile target `frappe`, `APPLY_PATCHES=true`).
- `base` — an unpatched reference image built from the same pinned `./frappe` source
  without any local patches (Dockerfile target `frappe-base`, `APPLY_PATCHES=false`).
- `latest-granian` — Granian layered directly on the patched `latest` image built in the
  same CI build/test job (Dockerfile.granian, `BASE_IMAGE=frappe:latest`).

Thus, the effective inheritance is `latest -> latest-granian`; `base` is the unpatched
sibling/reference image, not the parent of `latest`. No SHA, commit, run, variant, or
temporary registry tags are published.

## Patch scope

The current patch propagates W3C `traceparent` context from `frappe.enqueue()` into the
RQ payload and restores it around worker execution. OpenTelemetry is optional and the
code falls back to a no-op when unavailable or disabled with `FRAPPE_DISABLE_OTEL=1`.
