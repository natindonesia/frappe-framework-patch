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
# security upgrades) and Dockerfile.granian, on the new interpreter. Versions of
# the extras start from what the base venv has; granian is pinned exactly so an
# A/B against the base image does not also change the server version.
RUN set -eux; \
    ver() { grep -i "^$1==" /tmp/old-freeze.txt | head -n1 | cut -d= -f3; }; \
    python3 /tmp/relax-frappe-pyproject-py315.py apps/frappe/pyproject.toml; \
    rm -rf env; \
    python3 -m venv env; \
    ./env/bin/pip install --no-cache-dir --upgrade pip wheel; \
    ./env/bin/pip install --no-cache-dir -e apps/frappe; \
    extras=""; \
    for p in opentelemetry-sdk opentelemetry-api opentelemetry-exporter-otlp-proto-http \
             opentelemetry-instrumentation-wsgi opentelemetry-instrumentation-redis \
             pyinstrument pypdf pyjwt urllib3 setuptools msgpack; do \
      v="$(ver "$p")"; \
      [ -n "$v" ] || { echo "ERROR: $p not in base venv" >&2; exit 1; }; \
      extras="$extras $p>=$v"; \
    done; \
    g="$(ver granian)"; [ -n "$g" ] || { echo "ERROR: granian not in base venv" >&2; exit 1; }; \
    ./env/bin/pip install --no-cache-dir $extras "granian==$g"; \
    # Nothing present in the base venv may be missing from the new one.
    norm() { sed 's/==.*//' | tr '[:upper:]_.' '[:lower:]--' | sort -u; }; \
    norm < /tmp/old-freeze.txt > /tmp/old-names.txt; \
    ./env/bin/pip list --format=freeze | norm > /tmp/new-names.txt; \
    missing="$(comm -23 /tmp/old-names.txt /tmp/new-names.txt | grep -v -x -E 'pip|setuptools|wheel' || true)"; \
    [ -z "$missing" ] || { echo "ERROR: packages in base venv but not in new venv:" >&2; echo "$missing" >&2; exit 1; }; \
    ./env/bin/pip list --format=freeze > /home/frappe/frappe-bench/env-py315-freeze.txt

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
RUN rm -rf /home/frappe/frappe-bench/env
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/env /home/frappe/frappe-bench/env
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/env-py315-freeze.txt /home/frappe/frappe-bench/env-py315-freeze.txt
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/apps/frappe/pyproject.toml /home/frappe/frappe-bench/apps/frappe/pyproject.toml
WORKDIR /home/frappe/frappe-bench
