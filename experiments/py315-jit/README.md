# Experimental: CPython 3.15 + JIT image

Manual GitHub workflow `Experimental - Python 3.15 + JIT image`
(`.github/workflows/build-experimental-py315.yml`). It is independent of
`build-images.yml`: it never runs on push or PR and never moves a floating tag.

## What it does

It does **not** rebuild Frappe. `Dockerfile` in this directory layers on top of an
already published granian image (workflow input `base_image`, default
`ghcr.io/natindonesia/frappe:latest-granian`) and replaces only two things:

1. **Interpreter**: the official `python:3.14` interpreter is replaced by a
   python-build-standalone 3.15.2 build (sha256-pinned in the workflow). Unlike
   the official Docker image it is compiled with `--enable-experimental-jit=yes-off`,
   the tail-call interpreter, PGO, full LTO and BOLT. The JIT is compiled in but
   **off** unless `PYTHON_JIT=1` is set.
2. **Bench virtualenv + CLI venv**: the bench venv is recreated on 3.15 from the
   `apps/frappe` already inside the base image, with the pins relaxed for 3.15 by
   `experiments/py315-jit/relax-frappe-pyproject-py315.py`. Every extra the main
   Dockerfiles install (OpenTelemetry, pyinstrument, pypdf, granian, ...) is
   pinned **exactly** at the base venv's version, so an A/B against the base
   changes only the interpreter. The build fails if any package in the base venv
   is missing from the new one.
   The `bench` CLI is special: in the base image it is installed into the
   *global* interpreter (`/usr/local/bin/bench`, frappe-bench 5.31.1 with click
   8.2.x), not into the bench venv, because the bench venv's click (8.4.x) does
   not satisfy it. Rebuilding it inside the bench venv produces resolver
   conflicts, so this layer mirrors the base layout with a dedicated
   `.cli-env` venv at the base global versions and repoints the console
   scripts from `#!/usr/local/bin/python3.14` to it. Without that, `init`,
   `worker`, `worker-long`, `worker-short` and `schedule` die with
   `bench: cannot execute: required file not found` (the old interpreter is
   gone) — only the `web` service would start.

Apt, node, chromium, `bench init` and the asset build are not repeated, so the
layer builds in a few minutes (about 3.5 minutes locally).

| Package | Pinned by Frappe | Used in this image |
|---|---|---|
| duckdb | `~=1.4.3` | `>=2.0.0,<3` |
| pyarrow | `~=25.0.0` | `>=26.0.0,<27` |
| orjson | `~=3.11.5` | `>=3.12.0,<4` |
| hiredis | `~=3.3.0` | `>=3.5.0,<4` |
| pydantic | `~=2.12.5` | `>=2.14.0,<2.15` |
| plutoprint | `~=0.22.0` | `>=0.23.0,<0.24` |

Each is the smallest jump with a cp315 wheel. `RestrictedPython`, `psutil`,
`mysqlclient` and `PyYAML` keep their pins. `mysqlclient`, `PyYAML` and
`pyinstrument` have no 3.15 wheels and are compiled from source in the builder
stage (PBS sysconfig is patched from `clang` to `gcc`); PyYAML is built against
libyaml, which the final stage installs at runtime.

The relax script requires every original pin to match exactly, so the base image
must come from a Frappe whose pins are the ones listed above; otherwise the build
fails instead of silently installing something else.

## Running it

Automatic: a push to `main` that changes `experiments/py315-jit/**`, this
workflow, or the contract scripts it is gated by (`scripts/ci/matrix-variant-test.sh`,
`scripts/ci/common.sh`, `scripts/ci/granian-verify.sh`, the compose overlays)
builds and gates the image with the defaults below. **A push run never
publishes** — it cannot move a tag someone is deployed from.

Manual (`workflow_dispatch`) inputs: `base_image`, `pbs_variant` (`x86_64`
baseline, or `x86_64_v3` which needs AVX2) and `push_to_registry`. On a push the
defaults are `base_image=ghcr.io/natindonesia/frappe:latest-granian` and
`pbs_variant=x86_64`.

Published tags (only on a manual run with `push_to_registry` set):

- `ghcr.io/<owner>/frappe:<frappe-version>-py315-granian`
- `ghcr.io/<owner>/frappe:<frappe-version>-py315-v3-granian`

The base image digest is recorded in the `org.opencontainers.image.base.*`
labels. Before publishing, the workflow checks the interpreter, JIT availability
and the compiled dependencies, then runs the same compose/OTEL/CRUD contract as
`latest-granian`.

The image is larger than the base (the old venv and interpreter stay in lower
layers; measured 1,256,141,062 bytes vs 917,352,463, i.e. about +339 MB), but a
node that already has the base only pulls the new layers.

## Dependency parity with the base

With the base venv as a pip constraint file (everything except the relaxed pins
and the packages the base itself upgrades after `bench init`: pypdf, pyjwt,
urllib3, setuptools, msgpack — those are installed at the base versions
explicitly), `pip freeze` in the new venv differs from the base in exactly:

```
duckdb        1.4.5  -> 2.0.1
hiredis       3.3.1  -> 3.5.0
orjson        3.11.9 -> 3.13.0
plutoprint    0.22.0 -> 0.23.0
pyarrow       25.0.1 -> 26.0.1
pydantic      2.12.5 -> 2.14.4
pydantic_core 2.41.5 -> 2.50.5   (follows pydantic)
+ wheel 0.48.0
```

Everything else — granian 2.8.8, pypdf 7.0.0, the OpenTelemetry SDK and
instrumentation, pyinstrument, PyYAML 6.0.3, every transitive dependency — is
byte-for-byte the same version as the base image.

## Verified locally

The image below was built and then run through `scripts/ci/matrix-variant-test.sh
latest-granian`, asserting that the **running** web container's image ID equals
the image under test (see the note on overlay order further down):

| Check | JIT off | `PYTHON_JIT=1` |
|---|---|---|
| web container image | py315 layer | py315 layer |
| `sys.version` | 3.15.2 | 3.15.2 |
| `sys._jit.is_available()` | true | true |
| `sys._jit.is_enabled()` | false | true |
| granian PID 1 sees `PYTHON_JIT=1` | no | yes |
| worker / worker-long / worker-short (`bench --version`) | 5.31.1 | 5.31.1 |
| CRUD (login/create/read/list/update/delete) | 6/6 | 6/6 |
| file upload + access (403/200 matrix) | 7/7 | 7/7 |
| OTEL trace continuity (nginx + app) | OK | OK |
| OTEL profiling samples | OK | OK |
| granian is the serving process | OK | OK |

`init` also ran (compose-init step), and `bench set-mariadb-host`,
`bench set-redis-cache-host`, `bench worker --help` and `bench schedule --help`
were run directly inside the image.

This is a correctness contract, not a benchmark: no RPS or CPU-per-request
comparison between the JIT on and off has been done.

### Local reproduction caveat (overlay order)

`scripts/ci/matrix-variant-test.sh latest-granian` passes
`resources/compose.variant-ci.yml` **before** `resources/compose.granian-ci.yml`,
but `compose.granian-ci.yml` pins `image: frappe-granian:latest` — so the later
file wins and the stack runs `frappe-granian:latest`, whatever `FRAPPE_TEST_IMAGE`
says. In CI that is harmless (the image under test *is* tagged
`frappe-granian:latest`); for any local check it silently tests the wrong image.
The comment in `compose.variant-ci.yml` ("appended LAST") and the call site
disagree. To reproduce locally, put the variant overlay last and assert the
container image:

```sh
EXTRA_FILES="resources/compose.granian-ci.yml resources/compose.variant-ci.yml" \
FRAPPE_TEST_IMAGE=frappe-granian:py315 \
bash scripts/ci/matrix-variant-test.sh latest-granian
```

and then compare `docker inspect -f '{{.Image}}' "$(docker compose -p ci-latest-granian ps -q web)"`
with `docker image inspect -f '{{.Id}}' "$FRAPPE_TEST_IMAGE"`.

## A/B testing on the cluster

Deploy the same image twice and only change the environment of the web pods:

- JIT off: no `PYTHON_JIT` (default)
- JIT on: `PYTHON_JIT=1`

Compare against the current `latest-granian` image on CPU per request, not only
RPS. The JIT adds per-worker memory; check RSS against pod limits.
