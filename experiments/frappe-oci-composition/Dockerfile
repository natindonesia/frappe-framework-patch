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
# Only dependency METADATA is pulled from the app artifacts at build time.
#
# The app list below must mirror the app list in compose.yaml.
# Add/remove an app: edit both files' lists.
# =============================================================================

# Dependency metadata sources — one stage per selected app.
FROM ghcr.io/natindonesia/erpnext:latest-standalone AS src-erpnext
FROM ghcr.io/natindonesia/hrms:latest-standalone AS src-hrms
FROM ghcr.io/natindonesia/fayolex_extension:latest-standalone AS src-fayolex_extension
FROM ghcr.io/natindonesia/eps:latest-standalone AS src-eps
FROM ghcr.io/natindonesia/indonesia_payroll:latest-standalone AS src-indonesia_payroll
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
FROM scratch AS artifact-indonesia_payroll
COPY --from=src-indonesia_payroll /opt/frappe/apps/indonesia_payroll/ /
FROM scratch AS artifact-fayolex_ds
COPY --from=src-fayolex_ds /opt/frappe/apps/fayolex_decision_science_tools/ /

FROM ghcr.io/natindonesia/frappe:latest-granian

USER root

# uv replaces pip for installing the composition's dependencies.
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/

COPY --from=src-erpnext /opt/frappe/apps/erpnext/pyproject.toml /deps/erpnext/pyproject.toml
COPY --from=src-hrms /opt/frappe/apps/hrms/pyproject.toml /deps/hrms/pyproject.toml
COPY --from=src-fayolex_extension /opt/frappe/apps/fayolex_extension/pyproject.toml /deps/fayolex_extension/pyproject.toml
COPY --from=src-eps /opt/frappe/apps/eps/pyproject.toml /deps/eps/pyproject.toml
COPY --from=src-indonesia_payroll /opt/frappe/apps/indonesia_payroll/pyproject.toml /deps/indonesia_payroll/pyproject.toml
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
        /home/frappe/frappe-bench/apps/indonesia_payroll \
        /home/frappe/frappe-bench/apps/fayolex_decision_science_tools \
        > /home/frappe/frappe-bench/env/lib/python3.14/site-packages/composed-apps.pth

RUN mkdir -p /home/frappe/frappe-bench/logs /home/frappe/logs \
    && chown frappe:frappe /home/frappe/frappe-bench/logs /home/frappe/logs

USER frappe
WORKDIR /home/frappe/frappe-bench
