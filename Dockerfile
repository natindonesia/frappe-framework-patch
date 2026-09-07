# syntax=docker/dockerfile:1
#
# frappe-framework-patch -- reproducible base image containing the patched Frappe
# framework (version-16 at the pinned submodule SHA) plus OpenTelemetry deps.

# This repo is the patch/build layer: it installs the Frappe Python package from the
# pinned ./frappe submodule, applies our ./patches,and layers OpenTelemetry packages so
# W3C trace-context propagation works out of the box. Reproducible from:
#   `git submodule update --init --recursive` + this Dockerfile.

# Python version: the pinned v16.33.0 declares `requires-python = >=3.14,<3.15`,
# so BOTH build and runtime stages run python:3.14-slim-bookworm to stay in that window.

# Build labels carry the exact upstream + patch SHAs (see scripts/build.sh),and the
# immutable tag policy is `<upstream-short>-<patch-short>`; see README for tag guidance.


# Build args (set by scripts/build.sh / CI)：
#   UPSTREAM_SHA  - short SHA of the pinned ./frappe submodule commit
#   PATCH_REPO_SHA - short SHA of this (patch) repository's HEAD
#   OTEL=1         - install OpenTelemetry api+sdk+otlp (default on for this image)

# ---- stage  1: build a wheel from the patched framework ----
FROM python:3.14-slim-bookworm AS builder

ARG OTEL=1
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1

# System deps required to compile frappe's binary dependencies from source.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
        python3-dev \
        default-libmysqlclient-dev \
        libmariadb-dev \
        libjpeg62-turbo-dev \
        zlib1g-dev \
        libffi-dev \
        libxml2-dev \
        libxslt1-dev \
        libcairo2-dev \
        libpango1.0-dev \
        libgdk-pixbuf2.0-dev \
        libpq-dev \
        curl \
        git; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build
 # Bring the clean pinned submodule tree, patches,and helpers.
COPY frappe/ ./frappe/
COPY patches/ ./patches/
COPY scripts/ ./scripts/

# Apply our patches to the copied framework tree (no .git required at build time).
RUN chmod +x ./scripts/apply-patches.sh \
    && ./scripts/apply-patches.sh

# Install the patched framework as a wheel (--no-deps: just the framework itself;
# its runtime dependencies are installed in the runtime stage from the index).
RUN pip install --upgrade pip setuptools wheel "flit_core>=3.4,<4" \
    && pip wheel --use-pep517 --no-deps --no-build-isolation -w /build/wheels ./frappe

# ---- stage 2: runtime image with the patched frappe + otel ----
FROM python:3.14-slim-bookworm

ARG OTEL=1
ARG UPSTREAM_SHA=unknown
ARG PATCH_REPO_SHA=unknown

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

COPY --from=builder /build/wheels /wheels

# Minimal runtime system libs needed by frappe's compiled deps. `git` lets pip
# install the declared PyPika git+ dependency of the frappe wheel at runtime.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libmariadb3 libmagic1 libcairo2 libpango-1.0-0 libpangoft2-1.0-0 \
        shared-mime-info fonts-dejavu-core git; \
    rm -rf /var/lib/apt/lists/*

# Install the patched frappe wheel plus its declared runtime dependencies.
RUN pip install --upgrade pip \
    && pip install /wheels/frappe-*.whl

# OpenTelemetry deps (optional; default on). Installed in the runtime so the
# trace-context feature works out of the box; disabled vi FRAPPE_DISABLE_OTEL=1.
RUN if [ "$OTEL" = "1" ]; then \
        pip install \
            opentelemetry-api \
            opentelemetry-sdk \
            opentelemetry-exporter-otlp; \
    fi

# ---- labels & metadata ----
LABEL org.opencontainers.image.title="frappe-framework-patch"
LABEL org.opencontainers.image.description="Patched Frappe framework base image (version-16)"
LABEL org.opencontainers.image.source="https://github.com/natindonesia/frappe-framework-patch"
LABEL org.opencontainers.image.revision="${PATCH_REPO_SHA}"
LABEL org.natindonesia.frappe.upstream-sha="${UPSTREAM_SHA}"
LABEL org.natindonesia.frappe.patch-sha="${PATCH_REPO_SHA}"