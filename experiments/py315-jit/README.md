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
2. **Bench virtualenv**: recreated on 3.15 from the `apps/frappe` already inside
   the base image, with the pins relaxed for 3.15 by
   `experiments/py315-jit/relax-frappe-pyproject-py315.py`. The extras that the
   main Dockerfiles install (OpenTelemetry, pyinstrument, security upgrades,
   granian) are reinstalled starting from the versions in the base venv;
   `granian` is pinned exactly so an A/B against the base does not also change
   the server version. The build fails if any package in the base venv is
   missing from the new one.

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

Inputs: `base_image`, `pbs_variant` (`x86_64` baseline, or `x86_64_v3` which
needs AVX2) and `push_to_registry`.

Published tags (only when `push_to_registry` is set):

- `ghcr.io/<owner>/frappe:<frappe-version>-py315-granian`
- `ghcr.io/<owner>/frappe:<frappe-version>-py315-v3-granian`

The base image digest is recorded in the `org.opencontainers.image.base.*`
labels. Before publishing, the workflow checks the interpreter, JIT availability
and the compiled dependencies, then runs the same compose/OTEL/CRUD contract as
`latest-granian`.

The image is larger than the base (the old venv and interpreter stay in lower
layers, about +300 MB measured), but a node that already has the base only pulls
the new layers.

## A/B testing on the cluster

Deploy the same image twice and only change the environment of the web pods:

- JIT off: no `PYTHON_JIT` (default)
- JIT on: `PYTHON_JIT=1`

Compare against the current `latest-granian` image on CPU per request, not only
RPS. The JIT adds per-worker memory; check RSS against pod limits.
