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

This creates an immutable tag based on the upstream and repository SHAs. It does not
push anything. Use `--push` only after authenticating Docker to the registry; use
`--no-latest` to omit the mutable convenience tag.

## GitHub Actions

The Docker/CI workflows are the battle-tested originals from the parent Frappe
repo, adapted to this patch repository's submodule/patch model (the Dockerfile
applies `./patches` to `./frappe` before `bench init`; the build context vendors
the required `resources/`, `docker-compose.yml`, `Dockerfile.granian`, and the
custom OTEL overlay files in `runtime/`).

- `build-docker.yml` — on push / pull_request. Builds the patched image, runs
  the runtime + compose/OTEL integration tests, and on push pushes
  `${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest` and
  `.../frappe:<short-sha>` (no push on pull_request).
- `build-granian.yml` — optional Granian runtime build + compose test. NEVER
  pushes.
- `update-upstream.yml` is manual (`workflow_dispatch`). It advances `frappe/` to the
  latest `origin/version-16`, validates the patch set, and pushes only the parent
  repository's gitlink commit when validation succeeds.

Registry configuration (same as the parent workflow): set the variables
`REGISTRY_URL` (default `registry.digitalocean.com`) and `REGISTRY_NAMESPACE`
(default `natindonesia`), and the secrets `REGISTRY_USERNAME`/`REGISTRY_PASSWORD`
(or the `DIGITALOCEAN_EMAIL`/`DIGITALOCEAN_ACCESS_TOKEN` fallbacks). Secrets are
used only by the registry login action and are never printed.

Images are published as:

```text
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:latest
${REGISTRY_URL}/${REGISTRY_NAMESPACE}/frappe:<github-sha-prefix>
```

`latest` is only a convenience alias. Production deployments should pin the
short-SHA tag or, preferably, the image digest.

## Patch scope

The current patch propagates W3C `traceparent` context from `frappe.enqueue()` into the
RQ payload and restores it around worker execution. OpenTelemetry is optional and the
code falls back to a no-op when unavailable or disabled with `FRAPPE_DISABLE_OTEL=1`.
