# syntax=docker/dockerfile:1.4
# =============================================================================
# EXPERIMENTAL: CPython 3.15 (+ experimental JIT) layered ON TOP of an already
# published Frappe/Granian image. Nothing of Frappe is rebuilt: no apt/node/
# chromium layers, no bench init, no asset build. Only the interpreter and the
# bench virtualenv are replaced.
#
#   builder : base + build toolchain. Records the base venv's package list,
#             swaps in python-build-standalone (compiled with the experimental
#             JIT, off until PYTHON_JIT=1), recreates the venv on 3.15 and
#             reinstalls the dependencies with the pins relaxed for 3.15.
#   final   : base + the same interpreter + the new venv.
#
# The base image's frappe-version/variant labels are inherited. The venv and the
# interpreter are replaced in a new layer, so the old ones stay in lower layers
# (larger image, but only the new layers are pulled on top of a cached base).
#
# Build context is this directory only:
#   docker build -f experiments/py315-jit/Dockerfile \
#     --build-arg BASE_IMAGE=ghcr.io/<owner>/frappe:latest-granian \
#     --build-arg PBS_URL=... --build-arg PBS_SHA256=... experiments/py315-jit
# =============================================================================
ARG BASE_IMAGE=ghcr.io/natindonesia/frappe:latest-granian

FROM ${BASE_IMAGE} AS builder
ARG PBS_URL
ARG PBS_SHA256
USER root

# Interpreter overlay. Mandatory checksum. PBS sysconfig hardcodes CC=clang,
# which is not installed here, so source builds are pointed at gcc/g++.
RUN set -eux; \
    [ -n "${PBS_URL}" ]; \
    [ -n "${PBS_SHA256}" ]; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        build-essential gcc pkg-config libffi-dev libmariadb-dev libyaml-dev; \
    rm -rf /var/lib/apt/lists/*; \
    # Record the base venv's packages while the base interpreter still exists.
    su frappe -c '/home/frappe/frappe-bench/env/bin/python -m pip list --format=freeze' > /tmp/old-freeze.txt; \
    # Also the GLOBAL interpreter's packages: the base installs the `bench` CLI
    # (frappe-bench) and honcho into /usr/local, not into the bench venv. Those
    # files survive in /usr/local/bin but their shebang points at the interpreter
    # being removed below, so their packages must exist in the new venv and the
    # shebangs are repointed in the final stage.
    /usr/local/bin/python3 -m pip list --format=freeze > /tmp/old-global-freeze.txt; \
    curl -fsSL -o /tmp/pbs.tar.gz "${PBS_URL}"; \
    echo "${PBS_SHA256}  /tmp/pbs.tar.gz" | sha256sum -c -; \
    rm -rf /usr/local/bin/python* /usr/local/bin/pip* /usr/local/bin/idle* /usr/local/bin/pydoc* \
           /usr/local/lib/python3* /usr/local/lib/libpython3* /usr/local/include/python3* \
           /usr/local/lib/pkgconfig/python3*; \
    mkdir /tmp/pbs; \
    tar -xzf /tmp/pbs.tar.gz -C /tmp/pbs --strip-components=1; \
    cp -a /tmp/pbs/. /usr/local/; \
    rm -rf /tmp/pbs /tmp/pbs.tar.gz; \
    ln -sf python3 /usr/local/bin/python; \
    sed -i -e 's/clang++/g++/g' -e 's/clang/gcc/g' /usr/local/lib/python3.*/_sysconfigdata__*.py; \
    ldconfig; \
    python3 --version; \
    python3 -c 'import sys; assert sys._jit.is_available(), "PBS build has no JIT"'

COPY relax-frappe-pyproject-py315.py /tmp/relax-frappe-pyproject-py315.py

USER frappe
WORKDIR /home/frappe/frappe-bench

# Same installs as the main Dockerfile (bench init, OTEL/pyinstrument layer,
# security upgrades) and Dockerfile.granian, on the new interpreter. Every extra
# is pinned EXACTLY at the base venv's version: an A/B against the base image
# must change only the interpreter, not the server, the OTEL SDK or pypdf.
RUN set -eux; \
    ver() { grep -i "^$1==" /tmp/old-freeze.txt | head -n1 | cut -d= -f3; }; \
    python3 /tmp/relax-frappe-pyproject-py315.py apps/frappe/pyproject.toml; \
    # Pin every OTHER dependency to the version the base image already had, so
    # the only version differences are the pins relaxed above (plus their own
    # transitive requirements, which the relaxed packages demand). Without this,
    # a fresh resolve silently picks newer releases published since the base was
    # built, which would contaminate the A/B.
    grep -v -i -E '^(duckdb|pyarrow|orjson|hiredis|pydantic|pydantic[-_]core|plutoprint|pypdf|pyjwt|urllib3|setuptools|msgpack|pip|wheel|uv)==' \
         /tmp/old-freeze.txt > /tmp/base-constraints.txt; \
    rm -rf env; \
    python3 -m venv env; \
    ./env/bin/pip install --no-cache-dir --upgrade pip wheel; \
    ./env/bin/pip install --no-cache-dir -c /tmp/base-constraints.txt -e apps/frappe; \
    extras=""; \
    for p in opentelemetry-sdk opentelemetry-api opentelemetry-exporter-otlp-proto-http \
             opentelemetry-instrumentation-wsgi opentelemetry-instrumentation-redis \
             pyinstrument pypdf pyjwt urllib3 setuptools msgpack; do \
      v="$(ver "$p")"; \
      [ -n "$v" ] || { echo "ERROR: $p not in base venv" >&2; exit 1; }; \
      extras="$extras $p==$v"; \
    done; \
    g="$(ver granian)"; [ -n "$g" ] || { echo "ERROR: granian not in base venv" >&2; exit 1; }; \
    ./env/bin/pip install --no-cache-dir -c /tmp/base-constraints.txt $extras "granian==$g"; \
    # Nothing present in the base venv may be missing from the new one.
    norm() { sed 's/==.*//' | tr '[:upper:]_.' '[:lower:]--' | sort -u; }; \
    norm < /tmp/old-freeze.txt > /tmp/old-names.txt; \
    ./env/bin/pip list --format=freeze | norm > /tmp/new-names.txt; \
    missing="$(comm -23 /tmp/old-names.txt /tmp/new-names.txt | grep -v -x -E 'pip|setuptools|wheel' || true)"; \
    [ -z "$missing" ] || { echo "ERROR: packages in base venv but not in new venv:" >&2; echo "$missing" >&2; exit 1; }; \
    # The `bench` CLI is NOT part of the bench venv in the base image: it lives in
    # the global interpreter (frappe-bench 5.31.1 + click 8.2.x), because this
    # venv's click (8.4.x) does not satisfy it. Merging them produces resolver
    # conflicts, so mirror the base layout with a dedicated CLI venv on 3.15 at
    # the base global versions; the final stage repoints /usr/local/bin/bench at
    # it. Without this, init/worker/schedule cannot import `bench` at all.
    grep -v -i -E '^(pip|setuptools|wheel|uv)==' /tmp/old-global-freeze.txt > /tmp/global-install.txt; \
    rm -rf .cli-env; \
    python3 -m venv .cli-env; \
    ./.cli-env/bin/pip install --no-cache-dir --upgrade pip; \
    ./.cli-env/bin/pip install --no-cache-dir -r /tmp/global-install.txt; \
    ./.cli-env/bin/bench --version; \
    grep -v -i -E '^(pip|setuptools|wheel|uv)==' /tmp/old-global-freeze.txt | norm > /tmp/old-global-names.txt; \
    ./.cli-env/bin/pip list --format=freeze | norm > /tmp/new-cli-names.txt; \
    missing_g="$(comm -23 /tmp/old-global-names.txt /tmp/new-cli-names.txt || true)"; \
    [ -z "$missing_g" ] || { echo "ERROR: packages in the base GLOBAL interpreter but not in the CLI venv:" >&2; echo "$missing_g" >&2; exit 1; }; \
    ./env/bin/pip list --format=freeze > /home/frappe/frappe-bench/env-py315-freeze.txt; \
    ./.cli-env/bin/pip list --format=freeze > /home/frappe/frappe-bench/cli-env-py315-freeze.txt

# =============================================================================
FROM ${BASE_IMAGE}
ARG PBS_URL
ARG PBS_SHA256
USER root

# libyaml-0-2: PyYAML was compiled against libyaml in the builder.
RUN set -eux; \
    [ -n "${PBS_URL}" ]; \
    [ -n "${PBS_SHA256}" ]; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y libyaml-0-2; \
    rm -rf /var/lib/apt/lists/*; \
    curl -fsSL -o /tmp/pbs.tar.gz "${PBS_URL}"; \
    echo "${PBS_SHA256}  /tmp/pbs.tar.gz" | sha256sum -c -; \
    rm -rf /usr/local/bin/python* /usr/local/bin/pip* /usr/local/bin/idle* /usr/local/bin/pydoc* \
           /usr/local/lib/python3* /usr/local/lib/libpython3* /usr/local/include/python3* \
           /usr/local/lib/pkgconfig/python3*; \
    mkdir /tmp/pbs; \
    tar -xzf /tmp/pbs.tar.gz -C /tmp/pbs --strip-components=1; \
    cp -a /tmp/pbs/. /usr/local/; \
    rm -rf /tmp/pbs /tmp/pbs.tar.gz; \
    ln -sf python3 /usr/local/bin/python; \
    ldconfig; \
    python3 --version

USER frappe
RUN rm -rf /home/frappe/frappe-bench/env /home/frappe/frappe-bench/.cli-env
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/env /home/frappe/frappe-bench/env
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/.cli-env /home/frappe/frappe-bench/.cli-env
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/env-py315-freeze.txt /home/frappe/frappe-bench/env-py315-freeze.txt
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/cli-env-py315-freeze.txt /home/frappe/frappe-bench/cli-env-py315-freeze.txt
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/apps/frappe/pyproject.toml /home/frappe/frappe-bench/apps/frappe/pyproject.toml
WORKDIR /home/frappe/frappe-bench

# The base image's `bench` CLI (and honcho/idna/normalizer) are console scripts
# in /usr/local/bin with `#!/usr/local/bin/python3.14`. That interpreter is gone
# after the swap, so every such script would die with "required file not found"
# (this is exactly what broke the init container, and what would break
# worker/schedule). The builder installed their packages into .cli-env at the
# base versions, so only the shebang has to be repointed. Fails the build if any
# script still points at a missing interpreter.
USER root
RUN set -eux; \
    for f in /usr/local/bin/*; do \
      [ -f "$f" ] || continue; \
      first="$(head -c 128 "$f" 2>/dev/null | head -1)"; \
      case "$first" in '#!'*) ;; *) continue ;; esac; \
      interp="$(printf '%s' "$first" | sed 's/^#!//' | awk '{print $1}')"; \
      [ -x "$interp" ] && continue; \
      echo "repointing shebang: $f ($interp -> .cli-env python)"; \
      sed -i '1s|^#!.*|#!/home/frappe/frappe-bench/.cli-env/bin/python|' "$f"; \
    done; \
    ! grep -rIl '^#!/usr/local/bin/python3\.14' /usr/local/bin

# Build-time proof that the CLI actually runs on the new interpreter (the same
# binary the init container, `bench worker` and `bench schedule` execute).
USER frappe
RUN set -eux; \
    bench --version; \
    ./.cli-env/bin/python -c 'import sys, bench, honcho, idna, charset_normalizer; print("bench CLI imports OK on", sys.version.split()[0], "| frappe-bench", bench.__version__ if hasattr(bench, "__version__") else "n/a")'; \
    ./env/bin/python -c 'import click, frappe; print("bench venv unaffected: click", click.__version__, "frappe", frappe.__version__)'
