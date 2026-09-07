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

- `update-upstream.yml` is manual (`workflow_dispatch`). It advances `frappe/` to the
  latest `origin/version-16`, validates the patch set, and pushes only the parent
  repository's gitlink commit when validation succeeds.
- `build-push.yml` runs on pushes to `main`, validates the patches, then builds and
  pushes `registry.digitalocean.com/natindonesia/frappe`.

Configure the repository secret `DIGITALOCEAN_ACCESS_TOKEN` with a DigitalOcean
Container Registry token. It is used only by the registry login action and is not
printed by the workflow.

Images are published with an immutable tag of the form:

```text
registry.digitalocean.com/natindonesia/frappe:<upstream-short-sha>-<patch-repo-short-sha>
```

`latest` is only a convenience alias. Production deployments should pin the immutable
tag or, preferably, the image digest. The image labels record the upstream and patch
repository revisions for provenance and rollback.

## Patch scope

The current patch propagates W3C `traceparent` context from `frappe.enqueue()` into the
RQ payload and restores it around worker execution. OpenTelemetry is optional and the
code falls back to a no-op when unavailable or disabled with `FRAPPE_DISABLE_OTEL=1`.
