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
COPY --from=src /opt/frappe/apps/${APP}/ /opt/frappe/apps/${APP}/

FROM scratch AS payload
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
ENV VIRTUAL_ENV=/home/frappe/frappe-bench/env
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

# Asset stitching (issue #3): the composition never builds assets. The app
# artifact ships its own prebuilt assets/ plus an asset-map snapshot
# (assets.json); here we merge that snapshot on top of the frappe base map
# baked in the runtime image at /opt/defaults/assets.json. Requires the
# artifact to carry assets.json (true for every app that builds assets).
COPY --from=src /opt/frappe/apps/${APP}/assets.json /tmp/manifests/${APP}.json

RUN python3 - <<'EOF'
import glob, json
merged = json.load(open("/opt/defaults/assets.json"))
for path in sorted(glob.glob("/tmp/manifests/*.json")):
    merged.update(json.load(open(path)))
json.dump(merged, open("/opt/defaults/assets.json", "w"), indent=1)

# The frappe base manifest can drift from the dist tree actually baked in the
# runtime image (rebuilt bundles change their content hash while the baked
# snapshot keeps the old one). Reconcile: any frappe entry whose target file
# is missing is re-pointed at the real hashed file of the same bundle in the
# image's dist tree. App snapshots are authoritative and left untouched.
import glob, json, os
merged = json.load(open("/opt/defaults/assets.json"))
frappe_root = "/home/frappe/frappe-bench/apps/frappe/frappe/public/dist"
changed = 0
for key, val in list(merged.items()):
    if not val.startswith("/assets/frappe/dist/"):
        continue
    rel = val[len("/assets/frappe/"):]
    if os.path.exists(f"/home/frappe/frappe-bench/apps/frappe/frappe/public/{rel}"):
        continue
    stem, ext = key.rsplit(".", 1)
    candidates = [
        p for p in glob.glob(f"{frappe_root}/{ext}/{stem}.*.{ext}")
        if not p.endswith(".map")
    ]
    if len(candidates) == 1:
        merged[key] = "/assets/frappe/dist/%s/%s" % (
            ext, os.path.basename(candidates[0]))
        changed += 1
    elif not candidates:
        raise SystemExit(f"bundle {key}: no built file in dist, refusing to ship")
    else:
        raise SystemExit(f"bundle {key}: ambiguous dist candidates {candidates}")
json.dump(merged, open("/opt/defaults/assets.json", "w"), indent=1)
print(f"reconciled {changed} stale frappe bundle hashes")
EOF

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
# FILES are copied into the sites volume once at first boot by the init
# service (from each app image mount's assets/ or, for unbuilt apps, the
# package's public/ directory).
# =============================================================================
COPY --from=src-erpnext /opt/frappe/apps/erpnext/assets.json /tmp/manifests/erpnext.json
COPY --from=src-hrms /opt/frappe/apps/hrms/assets.json /tmp/manifests/hrms.json
COPY --from=src-eps /opt/frappe/apps/eps/assets.json /tmp/manifests/eps.json

# Merge every app snapshot over the frappe base manifest. The fayolex apps
# are unbuilt (no bundles), ship no snapshot and contribute nothing.
RUN python3 - <<'EOF'
import glob, json
merged = json.load(open("/opt/defaults/assets.json"))
for path in sorted(glob.glob("/tmp/manifests/*.json")):
    merged.update(json.load(open(path)))
json.dump(merged, open("/opt/defaults/assets.json", "w"), indent=1)

# The frappe base manifest can drift from the dist tree actually baked in the
# runtime image (rebuilt bundles change their content hash while the baked
# snapshot keeps the old one). Reconcile: any frappe entry whose target file
# is missing is re-pointed at the real hashed file of the same bundle in the
# image's dist tree. App snapshots are authoritative and left untouched.
import glob, json, os
merged = json.load(open("/opt/defaults/assets.json"))
frappe_root = "/home/frappe/frappe-bench/apps/frappe/frappe/public/dist"
changed = 0
for key, val in list(merged.items()):
    if not val.startswith("/assets/frappe/dist/"):
        continue
    rel = val[len("/assets/frappe/"):]
    if os.path.exists(f"/home/frappe/frappe-bench/apps/frappe/frappe/public/{rel}"):
        continue
    stem, ext = key.rsplit(".", 1)
    candidates = [
        p for p in glob.glob(f"{frappe_root}/{ext}/{stem}.*.{ext}")
        if not p.endswith(".map")
    ]
    if len(candidates) == 1:
        merged[key] = "/assets/frappe/dist/%s/%s" % (
            ext, os.path.basename(candidates[0]))
        changed += 1
    elif not candidates:
        raise SystemExit(f"bundle {key}: no built file in dist, refusing to ship")
    else:
        raise SystemExit(f"bundle {key}: ambiguous dist candidates {candidates}")
json.dump(merged, open("/opt/defaults/assets.json", "w"), indent=1)
print(f"reconciled {changed} stale frappe bundle hashes")
EOF

USER frappe
WORKDIR /home/frappe/frappe-bench
