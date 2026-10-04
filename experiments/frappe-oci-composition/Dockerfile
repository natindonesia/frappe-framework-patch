# syntax=docker/dockerfile:1
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
FROM ghcr.io/natindonesia/erpnext:latest-standalone AS src-erpnext
FROM ghcr.io/natindonesia/hrms:latest-standalone AS src-hrms
FROM ghcr.io/natindonesia/fayolex_extension:latest-standalone AS src-fayolex_extension
FROM ghcr.io/natindonesia/eps:latest-standalone AS src-eps
FROM ghcr.io/natindonesia/fayolex_decision_science_tools:latest-standalone AS src-fayolex_ds

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

# Asset-only artifacts: each carries exactly one app's prebuilt site asset
# tree at its rootfs root so compose can image-mount it directly at
# sites/assets/<app>, shadowing any stale copy in the shared sites volume.
FROM scratch AS asset-fayolex_ds
COPY --from=src-fayolex_ds /opt/frappe/apps/fayolex_decision_science_tools/assets/ /

# Prep stages: normalize each app's optional asset payload. Backend-only
# apps (no prebuilt assets/ or assets.json in their artifact) produce an
# empty asset tree and an empty manifest instead of failing the build.
FROM src-erpnext AS prep-erpnext
RUN mkdir -p /out/assets /manifests \
    && if [ -f /opt/frappe/apps/erpnext/assets.json ]; then cp /opt/frappe/apps/erpnext/assets.json /manifests/; fi \
    && if [ -d /opt/frappe/apps/erpnext/assets ]; then cp -a /opt/frappe/apps/erpnext/assets/. /out/assets/; fi
FROM src-hrms AS prep-hrms
RUN mkdir -p /out/assets /manifests \
    && if [ -f /opt/frappe/apps/hrms/assets.json ]; then cp /opt/frappe/apps/hrms/assets.json /manifests/; fi \
    && if [ -d /opt/frappe/apps/hrms/assets ]; then cp -a /opt/frappe/apps/hrms/assets/. /out/assets/; fi
FROM src-fayolex_extension AS prep-fayolex_extension
RUN mkdir -p /out/assets /manifests \
    && if [ -f /opt/frappe/apps/fayolex_extension/assets.json ]; then cp /opt/frappe/apps/fayolex_extension/assets.json /manifests/; fi \
    && if [ -d /opt/frappe/apps/fayolex_extension/assets ]; then cp -a /opt/frappe/apps/fayolex_extension/assets/. /out/assets/; fi
FROM src-eps AS prep-eps
RUN mkdir -p /out/assets /manifests \
    && if [ -f /opt/frappe/apps/eps/assets.json ]; then cp /opt/frappe/apps/eps/assets.json /manifests/; fi \
    && if [ -d /opt/frappe/apps/eps/assets ]; then cp -a /opt/frappe/apps/eps/assets/. /out/assets/; fi
FROM src-fayolex_ds AS prep-fayolex_ds
RUN mkdir -p /out/assets /manifests \
    && if [ -f /opt/frappe/apps/fayolex_decision_science_tools/assets.json ]; then cp /opt/frappe/apps/fayolex_decision_science_tools/assets.json /manifests/; fi \
    && if [ -d /opt/frappe/apps/fayolex_decision_science_tools/assets ]; then cp -a /opt/frappe/apps/fayolex_decision_science_tools/assets/. /out/assets/; fi

# Asset-only artifacts: each carries exactly one app's prebuilt site asset
# tree at its rootfs root so compose can image-mount it directly at
# sites/assets/<app>, shadowing any stale copy in the shared sites volume.
FROM scratch AS asset-erpnext
COPY --from=prep-erpnext /out/assets/ /
FROM scratch AS asset-hrms
COPY --from=prep-hrms /out/assets/ /
FROM scratch AS asset-fayolex_extension
COPY --from=prep-fayolex_extension /out/assets/ /
FROM scratch AS asset-eps
COPY --from=prep-eps /out/assets/ /
FROM scratch AS asset-fayolex_ds
COPY --from=prep-fayolex_ds /out/assets/ /

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
ENV VIRTUAL_ENV=/home/frappe/frappe-bench/env
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
# Asset stitching (issue #3): the composition never builds assets. Each app
# artifact ships its own prebuilt assets/ plus an asset-map snapshot
# (apps/<app>/assets.json); here we compose the bench asset map by merging
# every app snapshot on top of the frappe base map baked in the runtime image
# at /opt/defaults/assets.json. init.sh copies this manifest to the sites
# volume on every boot (so stale volumes get refreshed), while the asset
# FILES are shipped as dedicated asset-only artifacts (see the asset-*
# stages below) that compose image-mounts directly into the nginx
# container's sites/assets/<app> — no copying of asset files at deploy time
# and no nginx configuration changes.
# =============================================================================
COPY --from=prep-erpnext /manifests/ /tmp/manifests/erpnext/
COPY --from=prep-hrms /manifests/ /tmp/manifests/hrms/
COPY --from=prep-fayolex_extension /manifests/ /tmp/manifests/fayolex_extension/
COPY --from=prep-eps /manifests/ /tmp/manifests/eps/
COPY --from=prep-fayolex_ds /manifests/ /tmp/manifests/fayolex_decision_science_tools/

# Merge every app snapshot over the frappe base manifest. Backend-only apps
# contribute an empty manifest, which is a no-op on merge.
RUN python3 - <<'EOF'
import glob, json
merged = json.load(open("/opt/defaults/assets.json"))
for path in sorted(glob.glob("/tmp/manifests/*.json")):
    merged.update(json.load(open(path)))
json.dump(merged, open("/opt/defaults/assets.json", "w"), indent=1)
EOF

USER frappe
WORKDIR /home/frappe/frappe-bench
