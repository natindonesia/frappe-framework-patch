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

- `build-images.yml` — on push / pull_request. Builds and tests the vanilla and
  Granian images in one job, then on an approved main push publishes exactly
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest` and
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest-granian`.
- `update-upstream.yml` is manual (`workflow_dispatch`). It advances `frappe/` to the
  latest `origin/version-16`, validates the patch set, and pushes only the parent
  repository's gitlink commit when validation succeeds.

Registry configuration (same as the parent workflow): set the variables
`REGISTRY_URL` (default `registry.digitalocean.com`) and `REGISTRY_NAMESPACE`
(default `natindonesia`), and the secrets `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`
(or the `DIGITALOCEAN_EMAIL`/`DIGITALOCEAN_ACCESS_TOKEN` fallbacks). Secrets are
used only by the registry login action and are never printed.

Images are published only as:

```text
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest-granian
```

The Granian image is layered on the vanilla image built in the same CI build/test
job. No SHA, commit, run, variant, or temporary registry tags are published.

## Patch scope

The current patch propagates W3C `traceparent` context from `frappe.enqueue()` into the
RQ payload and restores it around worker execution. OpenTelemetry is optional and the
code falls back to a no-op when unavailable or disabled with `FRAPPE_DISABLE_OTEL=1`.
