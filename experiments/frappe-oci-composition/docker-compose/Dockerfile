# syntax=docker/dockerfile:1
# ARGs here so they are in scope for FROM expansion (mid-file ARGs are not).
# The defaults keep the multi-app targets parseable; generic single-app
# stages only get built when explicitly targeted.
ARG APP
ARG APP_ARTIFACT=ghcr.io/natindonesia/erpnext:latest-standalone
# Per-app artifact sources for the multi-app composition. Overridable so a
# CI run can inject its own ref's artifact via a local image tag (docker
# build resolves FROM against the local daemon before pulling).
ARG ERPNEXT_ARTIFACT=ghcr.io/natindonesia/erpnext:latest-standalone
ARG HRMS_ARTIFACT=ghcr.io/natindonesia/hrms:latest-standalone
ARG FAYOLEX_EXTENSION_ARTIFACT=ghcr.io/natindonesia/fayolex_extension:latest-standalone
ARG EPS_ARTIFACT=ghcr.io/natindonesia/eps:latest-standalone
ARG FAYOLEX_DS_ARTIFACT=ghcr.io/natindonesia/fayolex_decision_science_tools:latest-standalone
# =============================================================================
# Composed Frappe runtime (issue #3 model).
#
# Base: the patched Granian runtime image (full bench, frappe app, node,
# nginx, granian in the bench venv). On top of it, the Python dependencies of
# every app selected by the composition are resolved and installed ONCE into
# the bench venv, so there is exactly one shared Python environment for the
# deployment (issue #3 sections 3 and 4).
#
# App CODE is NOT baked in — each app payload is image-mounted read-only at
# runtime from its own immutable artifact (compose.yaml, issue #3 section 5).
# Dependency METADATA is pulled from the app artifacts at build time; assets
# are stitched into the sites volume at init time. Nothing is built here.
#
# The app list below must mirror the app list in compose.yaml.
# Add/remove an app: edit both files' lists.
# =============================================================================

# Dependency metadata sources — one stage per selected app. Each artifact
# carries the app payload plus its OWN prebuilt assets (assets/, assets.json,
# apps.txt), built once in the app's own repo and baked into the artifact.
# No asset building happens here — this image only stitches.
FROM ${ERPNEXT_ARTIFACT} AS src-erpnext
FROM ${HRMS_ARTIFACT} AS src-hrms
FROM ${FAYOLEX_EXTENSION_ARTIFACT} AS src-fayolex_extension
FROM ${EPS_ARTIFACT} AS src-eps
FROM ${FAYOLEX_DS_ARTIFACT} AS src-fayolex_ds

# =============================================================================
# Conforming app payload artifacts (issue #3 section 1): payload at the image
# rootfs root so the artifact can be image-mounted directly at
# /home/frappe/frappe-bench/apps/<app>. Built and tagged by the profile-"build"
# services in compose.yaml; NOT part of the runtime image.
# =============================================================================
FROM scratch AS artifact-erpnext
COPY --from=src-erpnext /opt/frappe/apps/erpnext/ /
FROM scratch AS artifact-hrms
COPY --from=src-hrms /opt/frappe/apps/hrms/ /
FROM scratch AS artifact-fayolex_extension
COPY --from=src-fayolex_extension /opt/frappe/apps/fayolex_extension/ /
FROM scratch AS artifact-eps
COPY --from=src-eps /opt/frappe/apps/eps/ /
FROM scratch AS artifact-fayolex_ds
COPY --from=src-fayolex_ds /opt/frappe/apps/fayolex_decision_science_tools/ /

# =============================================================================
# Generic single-app variant (ARG-driven, reusable by app repositories).
# Builds the same stages as above for ONE app passed via build args:
#   APP           app name, e.g. erpnext
#   APP_ARTIFACT  artifact image ref carrying /opt/frappe/apps/<app>/
#                 (e.g. ghcr.io/natindonesia/erpnext:latest-standalone)
# Stages: src -> artifact (/opt layout) / payload (rootfs) / runtime-single.
# The multi-app stages above and the default target below are untouched, so
# the full composition keeps building exactly as before.
# =============================================================================
ARG APP
ARG APP_ARTIFACT=ghcr.io/natindonesia/erpnext:latest-standalone

FROM ${APP_ARTIFACT} AS src
ARG APP

FROM scratch AS artifact
ARG APP
COPY --from=src /opt/frappe/apps/${APP}/ /opt/frappe/apps/${APP}/

FROM scratch AS payload
ARG APP
COPY --from=src /opt/frappe/apps/${APP}/ /

FROM ghcr.io/natindonesia/frappe:latest-granian AS runtime-single
ARG APP

USER root

# uv replaces pip for installing the composition's dependencies.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/

COPY --from=src /opt/frappe/apps/${APP}/pyproject.toml /deps/${APP}/pyproject.toml

# Union of every selected app's [project].dependencies -> one uv resolution
# into the bench venv (frappe's own dependencies are already satisfied there).
RUN python3 - <<'EOF'
import glob, tomllib
with open("/deps/requirements.txt", "w") as out:
    for path in sorted(glob.glob("/deps/*/pyproject.toml")):
        for dep in tomllib.load(open(path, "rb"))["project"].get("dependencies", []):
            out.write(dep + "\n")
EOF

# Install the union into the bench venv (uv only adds what is missing,
# keeping the base runtime's own resolution intact).
ARG FRAPPE_BUILD_VERSION=
ENV VIRTUAL_ENV=/home/frappe/frappe-bench/env
ENV FRAPPE_BUILD_VERSION=${FRAPPE_BUILD_VERSION}
RUN uv pip install --no-cache-dir -r /deps/requirements.txt

# Expose the image-mounted apps to the interpreter, derived from the /deps
# tree (one entry per selected app — no hardcoded app list here).
RUN python3 - <<'EOF'
import glob
paths = sorted(glob.glob("/deps/*/pyproject.toml"))
with open("/home/frappe/frappe-bench/env/lib/python3.14/site-packages/composed-apps.pth", "w") as out:
    for path in paths:
        out.write("/home/frappe/frappe-bench/apps/" + path.split("/")[2] + "\n")
EOF

RUN mkdir -p /home/frappe/frappe-bench/logs /home/frappe/logs \
    && chown frappe:frappe /home/frappe/frappe-bench/logs /home/frappe/logs

# No asset manifest is stitched or reconciled here. Bundle filenames are
# hashed (frappe esbuild entryNames "[dir]/[name].[hash]", see
# patches/0007-drop-assets-json-manifest.patch), but no assets.json ships:
# frappe derives the logical name -> hashed path map from the dist trees at
# runtime, so a key can only resolve to a file really present in the app asset
# mounts. Nothing to merge or reconcile at build time. Cache-busting is the
# release version bundled below.

USER frappe
WORKDIR /home/frappe/frappe-bench

FROM ghcr.io/natindonesia/frappe:latest-granian

USER root

# uv replaces pip for installing the composition's dependencies.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/

COPY --from=src-erpnext /opt/frappe/apps/erpnext/pyproject.toml /deps/erpnext/pyproject.toml
COPY --from=src-hrms /opt/frappe/apps/hrms/pyproject.toml /deps/hrms/pyproject.toml
COPY --from=src-fayolex_extension /opt/frappe/apps/fayolex_extension/pyproject.toml /deps/fayolex_extension/pyproject.toml
COPY --from=src-eps /opt/frappe/apps/eps/pyproject.toml /deps/eps/pyproject.toml
COPY --from=src-fayolex_ds /opt/frappe/apps/fayolex_decision_science_tools/pyproject.toml /deps/fayolex_decision_science_tools/pyproject.toml

# Union of every selected app's [project].dependencies -> one uv resolution
# into the bench venv (frappe's own dependencies are already satisfied there).
RUN python3 - <<'EOF'
import glob, tomllib
with open("/deps/requirements.txt", "w") as out:
    for path in sorted(glob.glob("/deps/*/pyproject.toml")):
        for dep in tomllib.load(open(path, "rb"))["project"].get("dependencies", []):
            out.write(dep + "\n")
EOF

# Install the union into the bench venv (uv only adds what is missing,
# keeping the base runtime's own resolution intact).
ARG FRAPPE_BUILD_VERSION=
ENV VIRTUAL_ENV=/home/frappe/frappe-bench/env
ENV FRAPPE_BUILD_VERSION=${FRAPPE_BUILD_VERSION}
RUN uv pip install --no-cache-dir -r /deps/requirements.txt

# Expose the image-mounted apps to the interpreter. The base venv resolves
# apps via editable-install hooks baked at bench-init time; the composed apps
# are image-mounted at runtime, so a .pth file does that job instead
# (read-only mounts must never be written).
RUN printf '%s\n' \
        /home/frappe/frappe-bench/apps/erpnext \
        /home/frappe/frappe-bench/apps/hrms \
        /home/frappe/frappe-bench/apps/fayolex_extension \
        /home/frappe/frappe-bench/apps/eps \
        /home/frappe/frappe-bench/apps/fayolex_decision_science_tools \
        > /home/frappe/frappe-bench/env/lib/python3.14/site-packages/composed-apps.pth

RUN mkdir -p /home/frappe/frappe-bench/logs /home/frappe/logs \
    && chown frappe:frappe /home/frappe/frappe-bench/logs /home/frappe/logs

USER root

# =============================================================================
# No asset manifest is stitched or reconciled here. Bundle filenames are
# hashed (frappe esbuild entryNames "[dir]/[name].[hash]", see
# patches/0007-drop-assets-json-manifest.patch), but no assets.json ships:
# frappe derives the logical name -> hashed path map from the dist trees at
# runtime, so /assets/<app>/... links resolve only to files really present in
# the per-app asset mounts (and the sites volume for frappe). There is
# nothing to merge at build time and no content hash to reconcile, and init.sh
# no longer seeds any manifest.
#
# The asset FILES themselves are still copied into the sites volume on first
# boot by the init service (from each app image mount's assets/ dir, or the
# package's public/ tree for unbuilt apps).
# =============================================================================

USER frappe
WORKDIR /home/frappe/frappe-bench
