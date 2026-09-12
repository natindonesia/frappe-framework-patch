# syntax=docker/dockerfile:1.4
ARG PYTHON_VERSION=3.14.2
ARG DEBIAN_BASE=bookworm

# =============================================================================
# Two published variants share ALL dependency/runtime/build layers and differ
# ONLY by whether the local patch set is applied to the pinned ./frappe source
# before `bench init`:
#
#   APPLY_PATCHES=true  -> variant=latest (patched, production default)
#                          built as `frappe:latest` / `<reg>/frappe:latest`
#   APPLY_PATCHES=false -> variant=base (unpatched reference image)
#                          built as `frappe:base` / `<reg>/frappe:base`
#
# Select a variant with `--target`:
#   docker build --target frappe      (latest / patched)  -- DEFAULT target
#   docker build --target frappe-base (base / unpatched)
#
# Both final targets COPY the bench tree from the SAME named `builder` stage;
# the builder's patch behavior is gated by the `APPLY_PATCHES` ARG, so each
# variant is a real, distinct artifact (separate BuildKit cache keys because
# the resolved ARG differs), not a relabel of the other.
# =============================================================================
ARG APPLY_PATCHES=true

FROM python:${PYTHON_VERSION}-slim-${DEBIAN_BASE} AS base

ARG WKHTMLTOPDF_VERSION=0.12.6.1-3
ARG WKHTMLTOPDF_DISTRO=bookworm
ARG INSTALL_CHROMIUM=true

# =============================================================================
# Layer 1 — Runtime system dependencies
# Changes only when base image bumps or we add/remove a package. Very stable.
# =============================================================================
RUN useradd -ms /bin/bash frappe \
    && apt-get update \
    && apt-get install --no-install-recommends -y \
        curl \
        git \
        vim \
        gettext-base \
        file \
        # weasyprint dependencies
        libpango-1.0-0 \
        libharfbuzz0b \
        libpangoft2-1.0-0 \
        libpangocairo-1.0-0 \
        # For backups
        restic \
        gpg \
        # MariaDB
        mariadb-client \
        less \
        # Postgres
        libpq-dev \
        postgresql-client \
        # For healthcheck
        wait-for-it \
        jq \
        # For MIME type detection
        media-types

# =============================================================================
# Layer 1b — nginx from nginx.org with the prebuilt OpenTelemetry dynamic
# module. Debian's stock nginx (1.22) ships no otel module, and a dynamic
# module's ABI must match the exact nginx binary it loads into. nginx.org
# packages nginx-module-otel built against their own nginx, installed together
# here so the ABI always matches. Pinned to the stable branch; bump together
# with DEBIAN_BASE.
# =============================================================================
ARG DEBIAN_BASE=bookworm
RUN apt-get update \
    && curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor -o /usr/share/keyrings/nginx-archive-keyring.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/debian ${DEBIAN_BASE} nginx" > /etc/apt/sources.list.d/nginx.list \
    && printf "Package: *\nPin: origin nginx.org\nPin-Priority: 900\n" > /etc/apt/preferences.d/nginx \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        nginx=1.28.* \
        nginx-module-otel=1.28.* \
    && rm -rf /var/lib/apt/lists/*
# =============================================================================
# Layer 2 — Node.js via nvm
# Changes when NODE_VERSION changes. nvm install.sh is fetched from GitHub so
# pinning the version here is the sole cache-control.
# =============================================================================
ARG NODE_VERSION=24.13.0
ENV NVM_DIR=/home/frappe/.nvm
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/:${PATH}

RUN mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use v${NODE_VERSION} \
    && npm install -g yarn \
    && corepack enable pnpm \
    && nvm alias default v${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >> /home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> /home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> /home/frappe/.bashrc \
    && echo 'export PATH="${NVM_DIR}/versions/node/v'${NODE_VERSION}'/bin:${PATH}"' >> /home/frappe/.profile

# =============================================================================
# Layer 3 — wkhtmltopdf + chromium-headless-shell
# Changes when WKHTMLTOPDF_VERSION changes. Independent of Node version.
# =============================================================================
RUN apt-get update \
    && if [ "$(uname -m)" = "aarch64" ]; then export ARCH=arm64; fi \
    && if [ "$(uname -m)" = "x86_64" ]; then export ARCH=amd64; fi \
    && downloaded_file=wkhtmltox_${WKHTMLTOPDF_VERSION}.${WKHTMLTOPDF_DISTRO}_${ARCH}.deb \
    && curl -sLO https://github.com/wkhtmltopdf/packaging/releases/download/$WKHTMLTOPDF_VERSION/$downloaded_file \
    && apt-get install -y ./$downloaded_file \
    && rm $downloaded_file \
    && if [ "$INSTALL_CHROMIUM" != "false" ]; then \
        DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        chromium-headless-shell; \
    fi \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Layer 4 — frappe-bench (Python) + nginx config for non-root
# Changes when frappe-bench releases a new version. Independent of Node or PDF.
# =============================================================================
COPY resources/nginx-template.conf /templates/nginx/frappe.conf.template
COPY resources/nginx-entrypoint.sh /usr/local/bin/nginx-entrypoint.sh

RUN pip3 install frappe-bench \
    && chmod +x /usr/local/bin/nginx-entrypoint.sh \
    && rm -fr /etc/nginx/sites-enabled/default \
    && rm -f /etc/nginx/conf.d/default.conf \
    && mkdir -p /etc/nginx/snippets \
    && sed -i '/user www-data/d' /etc/nginx/nginx.conf \
    && ln -sf /dev/stdout /var/log/nginx/access.log \
    && ln -sf /dev/stderr /var/log/nginx/error.log \
    && chown -R frappe:frappe /templates/nginx \
    && chown -R frappe:frappe /etc/nginx/conf.d \
    && chown -R frappe:frappe /etc/nginx/nginx.conf \
    && chown -R frappe:frappe /etc/nginx/snippets \
    && chown -R frappe:frappe /var/log/nginx \
    && mkdir -p /var/lib/nginx /var/cache/nginx \
    && chown -R frappe:frappe /var/lib/nginx /var/cache/nginx \
    && touch /run/nginx.pid \
    && chown -R frappe:frappe /run/nginx.pid

# =============================================================================
# Build stage — build-time C toolchain and headers
# Changes only when we add/remove a build dep. NOT in final image.
# =============================================================================
FROM base AS build

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        wget \
        # psycopg2 / C extensions
        libffi-dev \
        liblcms2-dev \
        libldap2-dev \
        libmariadb-dev \
        libsasl2-dev \
        libtiff5-dev \
        libwebp-dev \
        pkg-config \
        redis-tools \
        rlwrap \
        tk8.6-dev \
        cron \
        # pandas / numpy
        gcc \
        build-essential \
        libbz2-dev \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# Builder stage — shared by BOTH variants. Copies pinned ./frappe source,
# applies ./patches ONLY when APPLY_PATCHES=true, then bench-inits the tree.
# This is the only frequently-invalidated layer; identical to the upstream
# recipe except the patch gate.
# =============================================================================
FROM build AS builder

# Must re-declare APPLY_PATCHES INSIDE this stage. A global ARG declared before
# the first FROM is NOT in scope for RUN instructions in a later stage; without
# this re-declaration $APPLY_PATCHES resolves to EMPTY inside the RUN below, so
# the patch gate `[ "$APPLY_PATCHES" = "true" ]` would be false for BOTH
# variants and `latest` would silently be built unpatched.
ARG APPLY_PATCHES

# Assemble source from the pinned submodule; conditionally apply the patch set.
COPY --chown=frappe:frappe frappe/ /tmp/frappe/
COPY --chown=frappe:frappe patches/ /tmp/patches/
COPY --chown=frappe:frappe scripts/ /tmp/scripts/

# bench init (frappe-bench) requires --frappe-path to be a Git repository, but
# the submodule .git is unusable inside the image. Remove it, then re-initialise
# a fresh repo here so bench init succeeds. apply-patches.sh then runs in
# git-backed mode when the patch set is requested.
#
# CRITICAL: bench init does a REAL `git clone` of --frappe-path into apps/frappe,
# so it only sees COMMITTED tree state. apply-patches.sh modifies the working
# tree; we MUST commit it afterwards, otherwise the bench clone would carry the
# unpatched `base` commit into apps/frappe and `latest` would be silently built
# unpatched. base keeps only the pristine `base` commit (genuinely unpatched);
# latest adds a `patched` commit on top so the clone gets the patched tree.
RUN rm -f /tmp/frappe/.git \
    && git config --global --add safe.directory /tmp/frappe \
    && git init /tmp/frappe \
    && git -C /tmp/frappe add -A \
    && git -C /tmp/frappe -c user.email=x -c user.name=x commit -qm base \
    && chmod +x /tmp/scripts/apply-patches.sh \
    && if [ "$APPLY_PATCHES" = "true" ]; then \
         /tmp/scripts/apply-patches.sh \
         && git -C /tmp/frappe add -A \
         && git -C /tmp/frappe -c user.email=x -c user.name=x commit -qm patched; \
       else \
         echo "APPLY_PATCHES=$APPLY_PATCHES => unpatched base variant; NOT applying ./patches."; \
       fi

RUN su - frappe -c 'git config --global --add safe.directory "*"' \
    && su - frappe -c 'export PATH=/home/frappe/.nvm/versions/node/v24.13.0/bin:$PATH && bench init \
      --frappe-path=/tmp/frappe \
      --no-procfile \
      --no-backups \
      --skip-redis-config-generation \
      --verbose \
      /home/frappe/frappe-bench' \
    && rm -rf /tmp/frappe /tmp/patches /tmp/scripts \
    && cd /home/frappe/frappe-bench \
    && echo "{}" > sites/common_site_config.json \
    && find apps -mindepth 1 -path "*/.git" -exec rm -rf {} +

# opentelemetry packages into the bench virtualenv created by bench init.
# Separate layer: only re-runs when the bench init layer above changes.
RUN su - frappe -c '/home/frappe/frappe-bench/env/bin/pip install \
      opentelemetry-sdk \
      opentelemetry-api \
      opentelemetry-exporter-otlp-proto-http \
      opentelemetry-instrumentation-wsgi'

# Overlay the OTEL emitter files onto the bench tree. bench init git-clones the
# app, so uncommitted files would otherwise never reach the image and gunicorn
# would crash-loop on the missing gunicorn-otel-conf.py. COPY from the build
# context wins over the git-cloned copies. These overlay files are vendored in
# ./runtime (not part of the pristine upstream submodule).
COPY --chown=frappe:frappe runtime/otel.py /home/frappe/frappe-bench/apps/frappe/frappe/otel.py
COPY --chown=frappe:frappe runtime/otel_wsgi.py /home/frappe/frappe-bench/apps/frappe/frappe/otel_wsgi.py
COPY --chown=frappe:frappe runtime/test_otel.py /home/frappe/frappe-bench/apps/frappe/frappe/tests/test_otel.py
COPY --chown=frappe:frappe resources/gunicorn-otel-conf.py /home/frappe/frappe-bench/apps/frappe/resources/gunicorn-otel-conf.py

# =============================================================================
# Final stages — runtime only, no build deps. Both funnel the shared builder
# output through identical runtime wiring; they differ only in the variant labels
# and the APPLY_PATCHES ARG that selects which bench the builder produced.
# =============================================================================
FROM base AS deploy

USER frappe
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench/sites/assets/assets.json /opt/defaults/assets.json

# =============================================================================
# Target frappe-base : variant=base (unpatched reference image).
# =============================================================================
FROM deploy AS frappe-base
LABEL org.opencontainers.image.variant=base \
      org.opencontainers.image.patches-applied=false
VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
]
COPY --chmod=0755 resources/init.sh /usr/local/bin/init.sh
COPY --chmod=0755 resources/fix-db-users.sh /scripts/fix-db-users.sh

# =============================================================================
# Target frappe (DEFAULT) : variant=latest (patched, production image).
# =============================================================================
FROM deploy AS frappe
LABEL org.opencontainers.image.variant=latest \
      org.opencontainers.image.patches-applied=true
WORKDIR /home/frappe/frappe-bench
RUN echo "echo \"Commands restricted in production container, Read FAQ before you proceed: https://frappe.io/ctr-faq\"" >> ~/.bashrc
VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
]
COPY --chmod=0755 resources/init.sh /usr/local/bin/init.sh
COPY --chmod=0755 resources/fix-db-users.sh /scripts/fix-db-users.sh