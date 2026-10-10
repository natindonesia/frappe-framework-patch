# Frappe OCI Composition: New App Integration Guide

This guide documents the architecture of `experiments/frappe-oci-composition` and provides step-by-step instructions for onboarding a new Frappe app into the composable runtime model (both Docker Compose and Kubernetes).

---

## 1. Architecture Overview

Under the **Frappe OCI Composition Model**:
1. **Shared Runtime Image (`composed-frappe-granian`)**:
   - Contains Frappe core, the Python virtual environment (`/home/frappe/frappe-bench/env`), Granian WSGI/ASGI server, and Nginx.
   - At build time, it extracts `pyproject.toml` from each selected app's artifact and compiles the union of all app dependencies into a single venv via `uv pip install`.
   - App import paths are registered into Python via `/home/frappe/frappe-bench/env/lib/python3.14/site-packages/composed-apps.pth`.
   - Manifest snapshots (`assets.json`) from apps that build assets are merged into `/opt/defaults/assets.json`.
2. **Independent App Artifacts (`ghcr.io/natindonesia/<app>:latest-standalone`)**:
   - Immutable, standalone OCI images containing only the app payload rooted at `/opt/frappe/apps/<app>`.
   - Built and tested in their own repositories.
   - No runtime, Python interpreter, or mutable state is baked inside.
3. **OCI Image Volume Mounts (Zero Copy)**:
   - At container runtime, app code is mounted read-only directly from the OCI artifact to `/home/frappe/frappe-bench/apps/<app>`.
   - For Nginx, the app's unified `assets/` directory is mounted read-only at `/home/frappe/frappe-bench/sites/assets/<app>` using `subpath: assets`.

---

## 2. Standardized Standalone App Contract

Every app published for this composition **must** conform to the standalone artifact contract.

### Required Artifact Filesystem Layout
Inside the published image (`ghcr.io/natindonesia/<app>:latest-standalone`):
```text
/opt/frappe/apps/<app>/
├── <app>/                       # Python package source code
├── pyproject.toml               # Python project & dependencies declaration
├── assets/                      # UNIFIED static & compiled assets
│   ├── dist/                    # Compiled JS/CSS bundles (if app builds frontend)
│   └── <static files...>        # All public static files (icons, images, svgs)
├── assets.json                  # Optional: bundle hash map (if app builds assets)
└── apps.txt                     # Bench app identifier ("<app>\n")
```

> [!IMPORTANT]
> **Unified `assets/` directory**: Upstream Frappe puts compiled bundles in `sites/assets/<app>/dist` and static files in `<app>/public`. The standalone artifact MUST unify both into `/opt/frappe/apps/<app>/assets` so that Nginx serving via `subpath: assets` will never 404 on static files (like desktop SVG icons or images).

---

## 3. Step-by-Step: Onboarding a New App

### Step 3.1: Build the Conforming Artifact in the App Repo

In your app repository (`<app>/Dockerfile` or `Dockerfile.app`):

```dockerfile
# 1. Build stage: compile assets on top of Frappe runtime
FROM ghcr.io/natindonesia/frappe:latest-granian AS build

USER root
RUN chown -R frappe:frappe /home/frappe
USER frappe

# Copy source into bench
COPY --chown=frappe:frappe <app> /home/frappe/frappe-bench/apps/<app>
RUN cd /home/frappe/frappe-bench && \
    bench pip install -e apps/<app> && \
    printf '<app>\n' > /tmp/apps.txt

# (Optional) If app has frontend assets to compile:
# RUN cd /home/frappe/frappe-bench/apps/<app> && yarn install --frozen-lockfile
# RUN cd /home/frappe/frappe-bench && bench build --app <app>

# Unify static public files and compiled dist/ into sites/assets/<app>
RUN mkdir -p /home/frappe/frappe-bench/sites/assets/<app> && \
    if [ -d /home/frappe/frappe-bench/apps/<app>/<app>/public ]; then \
        cp -a /home/frappe/frappe-bench/apps/<app>/<app>/public/. /home/frappe/frappe-bench/sites/assets/<app>/; \
    fi && \
    if [ -d /home/frappe/frappe-bench/sites/assets/<app>/dist ]; then \
        cp -a /home/frappe/frappe-bench/sites/assets/<app>/dist /home/frappe/frappe-bench/apps/<app>/<app>/public/; \
    fi

# Clean up build-only node_modules
RUN find /home/frappe/frappe-bench/apps/<app> /home/frappe/frappe-bench/sites/assets/<app> -name node_modules -prune -exec rm -rf {} +

# 2. Artifact stage: minimal scratch payload under /opt/frappe/apps/<app>
FROM scratch AS artifact
COPY --from=build /home/frappe/frappe-bench/apps/<app> /opt/frappe/apps/<app>
COPY --from=build /home/frappe/frappe-bench/sites/assets/<app> /opt/frappe/apps/<app>/assets
COPY --from=build /home/frappe/frappe-bench/sites/assets/assets.json /opt/frappe/apps/<app>/assets.json
COPY --from=build /tmp/apps.txt /opt/frappe/apps/<app>/apps.txt
```

### Step 3.2: Verify Contract in the App CI

In the app's `.github/workflows/build-artifact.yml`:

```yaml
      - name: Checkout Frappe Framework Patch (validator script)
        uses: actions/checkout@v4
        with:
          repository: natindonesia/frappe-framework-patch
          ref: main
          path: .frappe-framework-patch

      - name: Validate artifact payload (enforce standalone image contract)
        run: |
          chmod +x .frappe-framework-patch/scripts/ci/validate-app-artifact.sh
          .frappe-framework-patch/scripts/ci/validate-app-artifact.sh \
            "${ARTIFACT_IMAGE}" \
            "<app>" \
            --require-dist \ # omit if unbuilt app
            --check-file "images/logo.svg"
```

---

## 4. Registering the New App into the Composition

Once the app artifact is published to GHCR as `ghcr.io/natindonesia/<app>:latest-standalone`, register it in `frappe-framework-patch/experiments/frappe-oci-composition`:

### 4.1 Update `docker-compose/Dockerfile`

1. **Add Build ARG and Source Stage**:
   ```dockerfile
   ARG <APP>_ARTIFACT=ghcr.io/natindonesia/<app>:latest-standalone
   FROM ${<APP>_ARTIFACT} AS src-<app>
   ```

2. **Add Rootfs Artifact Stage**:
   ```dockerfile
   FROM scratch AS artifact-<app>
   COPY --from=src-<app> /opt/frappe/apps/<app>/ /
   ```

3. **Extract `pyproject.toml` for Dependency Union**:
   ```dockerfile
   COPY --from=src-<app> /opt/frappe/apps/<app>/pyproject.toml /deps/<app>/pyproject.toml
   ```

4. **Register in `composed-apps.pth`**:
   Add `/home/frappe/frappe-bench/apps/<app>` to `composed-apps.pth`.

5. **(If Built) Merge `assets.json` Manifest**:
   ```dockerfile
   COPY --from=src-<app> /opt/frappe/apps/<app>/assets.json /tmp/manifests/<app>.json
   ```

### 4.2 Update `docker-compose/compose.yaml`

1. **Define Build Service**:
   ```yaml
     artifact-<app>:
       image: composed/<app>:latest
       build: { <<: *artifact-build, target: artifact-<app> }
       profiles: ["build"]
   ```

2. **Add Volume Mount to `x-frappe-volumes-runtime`**:
   ```yaml
     - type: image
       source: composed/<app>:latest
       target: /home/frappe/frappe-bench/apps/<app>
       read_only: true
   ```

3. **Add Subpath Nginx Mount**:
   ```yaml
     - type: image
       source: composed/<app>:latest
       target: /home/frappe/frappe-bench/sites/assets/<app>
       read_only: true
       image:
         subpath: assets
   ```

### 4.3 Update Kubernetes Manifests (`k8s/`)

1. **`k8s/40-runtime.yaml` (web, workers, schedule, socketio)**:
   Add volume and volumeMount:
   ```yaml
   volumeMounts:
     - name: apps-<app>
       mountPath: /home/frappe/frappe-bench/apps/<app>
       readOnly: true
   volumes:
     - name: apps-<app>
       image:
         reference: composed/<app>:latest
         pullPolicy: Never
   ```

2. **`k8s/50-nginx.yaml`**:
   Add the app mount so symlinks resolve to the app payload assets.

3. **`k8s/31-init-job.yaml`**:
   Add volume and volumeMount for `apps-<app>` so `init.sh` and `bench install-app <app>` can access the app files during bootstrap.

---

## 5. Composition Smoke Testing

To test the composition locally with the new app:

```bash
cd experiments/frappe-oci-composition/docker-compose

# 1. Build runtime and all app artifacts
docker compose --profile build build

# 2. Boot dependencies and run initialization
docker compose up -d mariadb redis
docker compose run --rm init

# 3. Boot full stack
docker compose up -d

# 4. Verify live serving
curl -I http://localhost:8085/api/method/ping
curl -I http://localhost:8085/assets/<app>/<static-file-or-bundle>
```
