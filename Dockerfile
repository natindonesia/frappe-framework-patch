# syntax=docker/dockerfile:1.4
ARG PYTHON_VERSION=3.14.2
ARG DEBIAN_BASE=bookworm

# =============================================================================
# Two published variants are now genuinely LAYERED, not sibling forks:
#
#   builder-base   : bench init on the PRISTINE pinned ./frappe source.
#                    -> frappe:base (unpatched reference image)
#   builder-patched: FROM builder-base. Applies ./patches into the bench's
#                    apps/frappe and rebuilds ONLY the frappe app assets.
#                    -> frappe:latest (patched, production default)
#   frappe-granian : FROM frappe:latest (see Dockerfile.granian)
#
# Because the patch set is applied AFTER bench init, the expensive
# pip/yarn/bootstrap work runs exactly ONCE and is shared by both variants;
# a patch or helper-script edit only invalidates the cheap patch/asset-rebuild
# layers. Constraint: no patch may change Python dependency declarations
# (pyproject.toml / setup.py / requirements) — deps are installed pre-patch.
#
# Select a variant with `--target`:
#   docker build --target frappe      (latest / patched)  -- DEFAULT target
#   docker build --target frappe-base (base / unpatched)
# =============================================================================

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
    && apt-get upgrade -y \
    && apt-get install --no-install-recommends -y \
        curl \
        git \
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
ARG NODE_VERSION=24.15.0
ENV NVM_DIR=/home/frappe/.nvm
ENV PATH=${NVM_DIR}/versions/node/v${NODE_VERSION}/bin/:${PATH}

RUN mkdir -p ${NVM_DIR} \
    && curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.5/install.sh | bash \
    && . ${NVM_DIR}/nvm.sh \
    && nvm install ${NODE_VERSION} \
    && nvm use v${NODE_VERSION} \
    && npm install -g npm@latest \
    && npm install -g yarn \
    && corepack enable pnpm \
    && nvm alias default v${NODE_VERSION} \
    && rm -rf ${NVM_DIR}/.cache \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >> /home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm' >> /home/frappe/.bashrc \
    && echo '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion' >> /home/frappe/.bashrc \
    && echo 'export NVM_DIR="/home/frappe/.nvm"' >> /home/frappe/.profile \
    && echo 'export PATH="/home/frappe/.nvm/versions/node/v'${NODE_VERSION}'/bin:${PATH}"' >> /home/frappe/.profile

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
# RUM telemetry bundle (built from resources/rum/rum-src.js with esbuild);
# nginx serves it at /__rum.js and injects the script tag when the deployment
# sets RUM_SCRIPT_TAG. Absent here, the location 404s silently.
COPY resources/rum/rum.js /opt/rum/rum.js

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
# builder-base — pristine bench tree. Both variants build ON TOP of this stage.
# Split into cache-bounded sub-layers so the expensive `bench init` (pip + yarn
# over the whole app tree) re-runs ONLY when the committed Frappe source itself
# changes, not when patches/ or scripts/ churn (those are applied in
# builder-patched, layered on top of this stage).
# =============================================================================
FROM build AS builder-base

# --- Sub-layer 1: pristine source snapshot. --------------------------------
# Copy ONLY the pinned ./frappe tree and commit it. Isolating the frappe COPY
# here is what makes the expensive bench init below cacheable across patch/
# helper-script edits: bench init only reads /tmp/frappe, so its cache keys
# track this tree, never the patch or script inputs.
#
# bench init (frappe-bench) requires --frappe-path to be a Git repository, but
# the submodule .git is unusable inside the image. Remove it, then re-initialise
# a fresh repo with a single pristine commit so bench init's `git clone` of
# --frappe-path succeeds. builder-patched applies ./patches directly into the
# CLONED app (apps/frappe), so no `patched` commit dance is needed here.
COPY --chown=frappe:frappe frappe/ /tmp/frappe/
RUN rm -f /tmp/frappe/.git \
    && git config --global --add safe.directory /tmp/frappe \
    && git init /tmp/frappe \
    && git -C /tmp/frappe add -A \
    && git -C /tmp/frappe -c user.email=x -c user.name=x commit -qm base

# --- Sub-layer 2: bench init (expensive). -----------------------------------
# Reads the committed /tmp/frappe tree only. The cloned apps/frappe KEEPS its
# .git so builder-patched can run the strict git-backed patch preflight; the
# .git dirs are stripped in the deploy stages so neither final image ships
# repo metadata.
RUN su - frappe -c 'git config --global --add safe.directory "*"' \
    && su - frappe -c 'bench init \
      --frappe-path=/tmp/frappe \
      --no-procfile \
      --no-backups \
      --skip-redis-config-generation \
      --verbose \
      /home/frappe/frappe-bench' \
    && rm -rf /tmp/frappe \
    && cd /home/frappe/frappe-bench \
    && echo "{}" > sites/common_site_config.json

# opentelemetry packages into the bench virtualenv created by bench init.
# Separate layer: only re-runs when the bench init layer above changes.
RUN su - frappe -c '/home/frappe/frappe-bench/env/bin/pip install \
      opentelemetry-sdk \
      opentelemetry-api \
      opentelemetry-exporter-otlp-proto-http \
      opentelemetry-instrumentation-wsgi \
      opentelemetry-instrumentation-redis \
      pyinstrument \
    && /home/frappe/frappe-bench/env/bin/pip install --upgrade \
      "pypdf>=6.19.0" \
      "pyjwt>=2.14.0" \
      "urllib3>=2.8.0" \
      "setuptools>=78.1.1" \
      "msgpack>=1.2.1"'

# Overlay the OTEL emitter files onto the bench tree. bench init git-clones the
# app, so uncommitted files would otherwise never reach the image and gunicorn
# would crash-loop on the missing gunicorn-otel-conf.py. COPY from the build
# context wins over the git-cloned copies. These overlay files are vendored in
# ./runtime (not part of the pristine upstream submodule).
COPY --chown=frappe:frappe runtime/otel.py /home/frappe/frappe-bench/apps/frappe/frappe/otel.py
COPY --chown=frappe:frappe runtime/otel_wsgi.py /home/frappe/frappe-bench/apps/frappe/frappe/otel_wsgi.py
COPY --chown=frappe:frappe runtime/pyinstrument_middleware.py /home/frappe/frappe-bench/apps/frappe/frappe/pyinstrument_middleware.py
COPY --chown=frappe:frappe runtime/test_otel.py /home/frappe/frappe-bench/apps/frappe/frappe/tests/test_otel.py
COPY --chown=frappe:frappe resources/gunicorn-otel-conf.py /home/frappe/frappe-bench/apps/frappe/resources/gunicorn-otel-conf.py

# Commit the overlays in the bench clone's git. The app clone keeps its .git so
# builder-patched can run apply-patches.sh in git-backed mode, whose strict
# clean check refuses ANY uncommitted change — including these untracked
# overlays. Committing them (they ship in BOTH variants, so they belong to the
# pristine tree semantics) keeps `git status --porcelain` empty; the overlay
# files are ignored by the frappe repo's .gitignore rules, so `git add -A` only
# picks up the vendored files.
RUN su - frappe -c 'cd /home/frappe/frappe-bench/apps/frappe \
      && git add -A \
      && git -c user.email=x -c user.name=x commit -qm "otel runtime overlays"'

# =============================================================================
# builder-patched — the `latest` variant, LAYERED on builder-base. Applies the
# patch set into the bench's apps/frappe (git-backed mode: strict clean check +
# `git apply --check --3way` preflight) and rebuilds ONLY the frappe app's
# assets, because the patches touch bundled desk JS (desktop.js, sidebar.js).
# Python deps were installed pre-patch — a patch must never add a dependency.
# =============================================================================
FROM builder-base AS builder-patched

COPY --chown=frappe:frappe patches/ /tmp/patches/
COPY --chown=frappe:frappe scripts/ /tmp/scripts/

RUN su - frappe -c 'export SUBMODULE=/home/frappe/frappe-bench/apps/frappe \
      && export PATCHES_DIR=/tmp/patches \
      && /tmp/scripts/apply-patches.sh' \
    && su - frappe -c 'cd /home/frappe/frappe-bench && bench build --app frappe' \
    && rm -rf /tmp/patches /tmp/scripts

# =============================================================================
# Final stages — runtime only, no build deps. Each variant deploys from its own
# builder output (deploy-base <- builder-base, deploy-latest <- builder-patched)
# through identical runtime wiring. The apps' .git metadata (kept through the
# builder stages for the patch preflight) is stripped here so neither final
# image ships repo metadata.
# =============================================================================
FROM base AS deploy-base

USER frappe
RUN mkdir -p /home/frappe/logs /home/frappe/frappe-bench/logs
COPY --from=builder-base --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
RUN find /home/frappe/frappe-bench/apps -mindepth 1 -path "*/.git" -exec rm -rf {} +
COPY --from=builder-base --chown=frappe:frappe /home/frappe/frappe-bench/sites/assets/assets.json /opt/defaults/assets.json

FROM base AS deploy-latest

USER frappe
RUN mkdir -p /home/frappe/logs /home/frappe/frappe-bench/logs
COPY --from=builder-patched --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
RUN find /home/frappe/frappe-bench/apps -mindepth 1 -path "*/.git" -exec rm -rf {} +
COPY --from=builder-patched --chown=frappe:frappe /home/frappe/frappe-bench/sites/assets/assets.json /opt/defaults/assets.json

# =============================================================================
# Target frappe-base : variant=base (unpatched reference image).
# =============================================================================
FROM deploy-base AS frappe-base
ARG IMAGE_VERSION
ARG IMAGE_REVISION
ARG IMAGE_SOURCE=https://github.com/natindonesia/frappe-framework-patch
ARG IMAGE_CREATED
ARG FRAPPE_SHA
LABEL org.opencontainers.image.title="Frappe Framework backend (unpatched base)" \
      org.opencontainers.image.description="Unpatched reference build of Frappe/ERPNext (pinned submodule, no local patches applied)." \
      org.opencontainers.image.url="https://github.com/natindonesia/frappe-framework-patch" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.frappe-sha="${FRAPPE_SHA}" \
      org.opencontainers.image.variant=base \
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
FROM deploy-latest AS frappe
ARG IMAGE_VERSION
ARG IMAGE_REVISION
ARG IMAGE_SOURCE=https://github.com/natindonesia/frappe-framework-patch
ARG IMAGE_CREATED
ARG FRAPPE_SHA
LABEL org.opencontainers.image.title="Frappe Framework backend (patched)" \
      org.opencontainers.image.description="Patched production build of Frappe/ERPNext (pinned submodule plus local patch set)." \
      org.opencontainers.image.url="https://github.com/natindonesia/frappe-framework-patch" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.frappe-sha="${FRAPPE_SHA}" \
      org.opencontainers.image.variant=latest \
      org.opencontainers.image.patches-applied=true
WORKDIR /home/frappe/frappe-bench
RUN echo "echo \"Commands restricted in production container, Read FAQ before you proceed: https://frappe.io/ctr-faq\"" >> ~/.bashrc
VOLUME [ \
  "/home/frappe/frappe-bench/sites", \
  "/home/frappe/frappe-bench/logs" \
]
COPY --chmod=0755 resources/init.sh /usr/local/bin/init.sh
COPY --chmod=0755 resources/fix-db-users.sh /scripts/fix-db-users.sh