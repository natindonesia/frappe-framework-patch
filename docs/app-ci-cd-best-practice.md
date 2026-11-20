# CI/CD Best Practice — Backend-Only Frappe App

Normative guide for shipping a Frappe app that has **no frontend build**: Python
package, DocTypes, optional `public/` statics. No Node stage, no `dist/`, no
`assets.json` merge.

- Artifact contract: [`experiments/frappe-oci-composition/README.md`](../experiments/frappe-oci-composition/README.md) §2
- Contract validator: [`scripts/ci/validate-app-artifact.sh`](../scripts/ci/validate-app-artifact.sh)
- Runtime/scan/supply-chain helpers: `scripts/ci/`

Parts of this pipeline are already implemented in this repository's own CI, and
can be read as a reference:

| Workflow | Take from it |
| :--- | :--- |
| `build-images.yml` | matrix test contract, Trivy/Semgrep gates, attest + cosign + hard-fail verify |
| `scripts/ci/validate-app-artifact.sh` | the contract check every app should call instead of hand-rolled assertions |
| `scripts/ci/install-*.sh`, `verify-supply-chain.sh` | pinned, retrying installer pattern and the identity-pinned verification gate |

---

## 1. Non-negotiables

1. **Artifact ≠ runtime.** Publish a `scratch` payload; compose it onto a pinned
   runtime image at deploy. Never bake a venv or mutable state into the payload.
2. **Build once.** Test the image you publish. No downstream rebuild.
3. **Publish on the default branch only.** PR builds need no registry credentials.
4. **Every image is referenced by digest** downstream (`image@sha256:…`). Tags
   are for humans.
5. **A gate that cannot fail is not a gate.**
6. **The verifier must not be part of the change.** Workflows that judge a PR
   come from the base branch.

---

## 2. Artifact contract

```text
/opt/frappe/apps/<app>/
├── <app>/            # importable Python package
├── pyproject.toml    # dependency source of truth
├── assets/           # UNIFIED static tree — MUST exist, even when empty
└── apps.txt          # "<app>\n"
```

Rules the validator enforces, plus the ones it implies:

- `assets/` must exist at the payload root. For a backend-only app it is often
  just the contents of `<app>/public`. Create it unconditionally
  (`mkdir -p sites/assets/<app>`) — a `COPY` from a directory that was never
  created fails the build with a confusing error.
- `apps.txt` is written outside the build context (`/tmp/apps.txt`) and copied in.
  Writing it into `sites/` inside the build stage leaks site state.
- Strip `node_modules`, `.git`, `.gitkeep`, `__pycache__`, `*.pyc` before the
  `artifact` stage. A leaked `node_modules` in a payload is a 100× size
  regression and the validator rejects it.
- Never pass `--require-dist`. There is no `dist/` in a backend-only app.

### `Dockerfile.app`

Two targets. `build` is for tests, `artifact` is what gets published.

```dockerfile
# syntax=docker/dockerfile:1.7
# Pin the runtime: a rebuild of `latest-granian` must not change your payload
# without a commit in this repository. Bump the digest deliberately.
ARG BASE_IMAGE=<registry>/<org>/frappe:<tag>@sha256:<digest>

FROM ${BASE_IMAGE} AS build

USER root
RUN mkdir -p /home/frappe/frappe-bench/apps/<app> \
    && chown -R frappe:frappe /home/frappe/frappe-bench/apps/<app>

COPY --chown=frappe:frappe . /home/frappe/frappe-bench/apps/<app>

USER frappe
ENV PATH="/home/frappe/frappe-bench/env/bin:${PATH}"

# -e: no wheel is built, so no build backend is needed. --no-deps: the runtime
# image already has the resolved environment.
RUN cd /home/frappe/frappe-bench \
    && bench pip install -e apps/<app> \
    && python3 -m compileall -q apps/<app> \
    && printf '<app>\n' > /tmp/apps.txt

# Unify the public tree. Unconditional mkdir: the artifact stage copies this
# path whether or not the app ships static files.
RUN mkdir -p /home/frappe/frappe-bench/sites/assets/<app> \
    && if [ -d /home/frappe/frappe-bench/apps/<app>/<app>/public ]; then \
         cp -a /home/frappe/frappe-bench/apps/<app>/<app>/public/. \
               /home/frappe/frappe-bench/sites/assets/<app>/; \
       fi \
    && find /home/frappe/frappe-bench/apps/<app> \
            /home/frappe/frappe-bench/sites/assets/<app> \
            \( -name node_modules -o -name __pycache__ \) -prune -exec rm -rf {} + \
    && find /home/frappe/frappe-bench/apps/<app> -name '*.pyc' -delete \
    && find /home/frappe/frappe-bench/apps/<app> -name .gitkeep -delete

FROM scratch AS artifact
COPY --from=build /home/frappe/frappe-bench/apps/<app> /opt/frappe/apps/<app>
COPY --from=build /home/frappe/frappe-bench/sites/assets/<app> /opt/frappe/apps/<app>/assets
COPY --from=build /tmp/apps.txt /opt/frappe/apps/<app>/apps.txt
```

### Contract validation

Call the shared validator; do not hand-roll path assertions.

```bash
- name: Checkout contract validator
  uses: actions/checkout@<sha>
  with:
    repository: <org>/frappe-framework-patch
    ref: main
    path: .frappe-framework-patch

- name: Validate artifact payload
  run: |
    .frappe-framework-patch/scripts/ci/validate-app-artifact.sh \
      "${ARTIFACT_IMAGE}" "${APP_NAME}" \
      --check-file images/logo.svg \
      --check-file images/favicon.png
```

`--check-file` is the part everyone skips and later regrets: it proves the
unified `assets/` tree actually contains the statics the app references.

---

## 3. Pipeline shape

Four workflows, four gates. Gate _N+1_ never runs unless _N_ is green.

| # | Workflow | Trigger | Gate |
| :-- | :--- | :--- | :--- |
| 1 | `ci.yml` | PR, push, `workflow_call` | lint, DocType JSON, bench test suite |
| 2 | `build-artifact.yml` | PR, push `main`, dispatch | import smoke, contract, Trivy image |
| 3 | `build-artifact.yml#publish` | `main` only | semver tag, 3 tags, digest |
| 4 | `security-scan.yml` | PR, `main`, weekly cron | ruff, Bandit → SARIF, Trivy fs/config |

```
ci.yml ──► build-and-test ──► publish (main) ──► deploy (digest dispatch)
                    │
                    └──► attest + sign ──► verify supply chain (main)
```

### Gate 1 — `ci.yml`

Reusable so the artifact pipeline can gate on it:

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
  workflow_call:

jobs:
  tests:
    runs-on: [self-hosted, linux]   # or ubuntu-latest; see §5
    timeout-minutes: 90
    services:
      mariadb:
        image: mariadb:10.8
        env: { MARIADB_ROOT_PASSWORD: root }
        ports: ["3306:3306"]
        options: >-
          --health-cmd="mariadb-admin ping -uroot -proot"
          --health-interval=5s --health-timeout=2s --health-retries=20
      redis-cache:
        image: redis:7-alpine
        ports: ["13000:6379"]
      redis-queue:
        image: redis:7-alpine
        ports: ["11000:6379"]
    steps:
      - uses: actions/checkout@<sha>
      - name: Lint (blocking)
        run: ruff check <app>
      - name: Compile
        run: python3 -m compileall -q <app>
      - name: Validate DocType schemas
        run: python3 scripts/ci/validate_doctypes.py   # app-local script; checks doctype/name/module
      - name: Install and test
        run: |
          bench new-site test-site --force \
            --mariadb-root-username root --mariadb-root-password root \
            --admin-password admin --mariadb-user-host-login-scope='%'
          bench --site test-site install-app <app>
          bench --site test-site set-config allow_tests true
          bench --site test-site run-tests --app <app>
```

Rules:

- **`ruff` must fail the job.** `set +e` plus printing the exit code is a
  report, not a gate. If a rule is noisy, fix it or add it to
  `[tool.ruff.lint] ignore` with a comment.
- **DocType JSON validation must check the real module list**, read from
  `<app>/modules.txt` — a hardcoded list goes stale the first time a module is
  renamed and then rejects valid schemas.
- **`run-tests --app` is not optional.** "install-app succeeded" proves the
  schema parses; it proves nothing about behaviour.
- **`bench migrate` twice.** The second run must be a no-op. This catches
  non-idempotent `after_migrate` hooks, and it is cheap.
- **Upgrade path, if the app ever removed a module or DocType**: seed a site with
  the stale `Module Def` rows plus a stale `app_modules` cache entry, then
  `bench migrate` and assert the rows are healed. That scenario is what makes
  `migrate` die with `ModuleNotFoundError` in production and it is invisible to
  a fresh-install test.

### Gate 2 — `build-artifact.yml`

```yaml
env:
  APP_NAME: <app>
  ARTIFACT_IMAGE: <app>-app:artifact

concurrency:
  group: build-artifact-${{ github.ref }}
  # Shared self-hosted daemon: overlapping runs fight over local tags and
  # cache dirs. Never cancel-in-progress here.
  cancel-in-progress: false

jobs:
  build-test-publish:
    needs: [ci-tests]        # once ci.yml is green; see below
    runs-on: [self-hosted, linux]
    timeout-minutes: 60
    steps:
      - uses: actions/checkout@<sha>

      - name: Build app payload (build stage)
        run: docker buildx build -f Dockerfile.app --target build --load -t ${APP_NAME}-app:build .

      - name: Import smoke test against the Frappe runtime
        run: |
          docker run --rm ${APP_NAME}-app:build \
            /home/frappe/frappe-bench/env/bin/python -c "
          import frappe, ${APP_NAME}
          frappe.local.flags = frappe._dict(in_install=True)
          print('ping:', frappe.get_attr('frappe.ping')())
          print('version:', ${APP_NAME}.__version__)"

      - name: Build final artifact
        run: docker buildx build -f Dockerfile.app --target artifact --load -t ${ARTIFACT_IMAGE} .

      - name: Validate standalone contract
        run: scripts/ci/validate-app-artifact.sh "${ARTIFACT_IMAGE}" "${APP_NAME}" --check-file …

      - name: Scan the payload
        run: scripts/ci/security-scan-images.sh "${ARTIFACT_IMAGE}"

      - name: Publish (main only)
        if: github.ref == 'refs/heads/main'
        run: |
          for tag in latest-standalone "${VERSION}" "v${VERSION}"; do
            docker tag "${ARTIFACT_IMAGE}" "${IMAGE}:${tag}"
            docker push "${IMAGE}:${tag}"
          done
          DIGEST="sha256:$(docker buildx imagetools inspect --raw "${IMAGE}:latest-standalone" | sha256sum | awk '{print $1}')"
          echo "digest=${DIGEST}" >> "$GITHUB_OUTPUT"
```

`needs: [ci-tests]` is the goal. While a suite is red, ship with `needs: []` and
a comment saying exactly why — leaving an unexplained ungated publish is worse
than an explicit one.

Trivy scan of the **payload** is a pre-push gate: it runs on a scratch image of
a few MB, costs seconds, and stops a leaked secret or a vendored CVE from ever
reaching the registry. Scan the published digest again afterwards only if you
also want to catch registry-side drift.

### Gate 3 — versioning and publish

```bash
# Conventional commits → semver. feat → minor, fix/chore → patch,
# `<type>!:` or BREAKING CHANGE: → major.
VERSION=1.4.2
TAG=v${VERSION}
```

Order matters and it is not symmetric:

1. compute version
2. **create and push the git tag** (`git tag -a`), if absent
3. **then push the image** under `latest-standalone`, `${VERSION}`, `${TAG}`
4. **emit the digest**: `docker buildx imagetools inspect --raw … | sha256sum`

Consequences to design for:

- "tag exists" ≠ "image exists". A consumer that resolves the newest tag must be
  prepared to fall back to an older one; try the few newest candidates in turn
  and say in the report when the baseline is approximate.
- Version numbers are **global**: refuse to move an existing tag, even one on an
  unmerged branch. Renumber instead.
- Stamping the version into `pyproject.toml` / `<app>/__init__.py` at build time
  is fine, but then **assert the stamped value inside the artifact** — otherwise
  a failed `sed` publishes an app that reports the old version forever.
- Deploy dispatch must carry the **digest**, never a floating tag.

### Gate 4 — supply chain

Only publish what you can prove came from this workflow.

```bash
scripts/ci/install-syft.sh          # pinned, checksum-verified, no release-page scraping
scripts/ci/install-cosign.sh
syft dir:/tmp/sbom-src -o spdx-json=sbom.spdx.json
actions/attest@<sha>  # SLSA provenance + SPDX SBOM, push-to-registry
cosign sign --yes "$IMAGE@$DIGEST"
scripts/ci/verify-supply-chain.sh   # hard-fail gate, runs after publish
```

`verify-supply-chain.sh` pins the certificate identity to **this repository's
workflow file**, so a signature minted by another workflow or repository fails:

```
IDENTITY_REGEXP="^https://github\.com/${REPO}/\.github/workflows/build-artifact\.yml@"
```

Use the exact predicate URIs (`https://slsa.dev/provenance/v1`,
`https://spdx.dev/Document/v2.3`); cosign's aliases (`slsaprovenance`,
`spdxjson`) resolve differently and silently never match.

For a backend-only app the SBOM input is the Python dependency metadata, not a
lockfile you don't have:

```bash
mkdir -p /tmp/sbom-src && cp pyproject.toml /tmp/sbom-src/
syft dir:/tmp/sbom-src -o spdx-json=sbom.spdx.json
```

---

## 4. Anti-patterns

Each row cost a real run somewhere; all of them are avoidable.

| Anti-pattern | Failure it causes |
| :--- | :--- |
| Downloading a scanner (Trivy/syft/cosign) from GitHub releases in the critical path | Release CDN answers 5xx; the gate fails for reasons unrelated to the app. Use `scripts/ci/install-*.sh` (retry + `gh` fallback + checksum), or extract from a pinned Docker image |
| Copying `assets/` with `COPY --from` when the directory may not exist | Build dies in the `artifact` stage. `mkdir -p` first, unconditionally |
| `cancel-in-progress: true` on a shared self-hosted daemon | Overlapping runs overwrite local tags and cache dirs |
| Using `/tmp/.buildx-cache` on an ephemeral runner | Cache is gone next run; builds take the full time every time. Use the builder's own sticky cache |
| `FROM` another job's locally-tagged image on an ephemeral builder | The builder resolves `FROM` against the registry, not the daemon. Reference an in-file stage (`--build-arg WEB_IMAGE=web-artifact`) or a published digest |
| Floating `latest`-style tag as the app's base image | Your payload changes without a commit; reproducibility is gone. Digest-pin and bump deliberately |
| Unpinned action tags (`@v1`, `@main`) on publish/sign paths | Upstream retag changes what runs with your publish token. SHA-pin |
| `upload-sarif` when Code Security is disabled | The step errors and takes the job down. Either enable it or `continue-on-error: true` with a comment |
| Publish gate keyed on a git tag | Race: tag exists before the image does. Consumers must tolerate a missing image |
| Test gate = "install-app succeeded" | Schema parses; behaviour is untested |
| `--require-dist` on an app with no frontend | Validator hard-fails on `assets/dist/` |
| Hardcoded DocType module list in CI | Rejects valid schemas after the first module rename |

---

## 5. Runner selection

| Runner | Consequences |
| :--- | :--- |
| `[self-hosted, linux]` persistent daemon | Local tags and `/tmp/.buildx-cache` survive between runs; must set `cancel-in-progress: false`; inherits the host's network egress, which may proxy or reject GitHub release downloads (see §4) |
| Ephemeral hosted runners | No local state; must use builder-native cache and in-file stage references; but no host network oddities, which removes an entire class of gate failures |

A backend-only app has no SPA build, so it fits `ubuntu-latest` comfortably. If
the org already publishes a pinned runtime image, moving CI to hosted runners is
the cheapest reliability win available.

---

## 6. Onboarding checklist

New backend-only app, in order:

- [ ] `Dockerfile.app` with digest-pinned `BASE_IMAGE` and `build` + `artifact` targets
- [ ] `assets/` created unconditionally; `node_modules`/`__pycache__`/`.gitkeep` stripped
- [ ] version stamped into `pyproject.toml` and `<app>/__init__.py`, then asserted in the payload
- [ ] `.github/workflows/ci.yml`: blocking lint, DocType JSON against `modules.txt`, `run-tests --app`, `migrate` twice
- [ ] `.github/workflows/build-artifact.yml`: import smoke → contract validator (`--check-file` per static) → Trivy image → publish on `main`
- [ ] conventional-commit semver; tag before image; `latest-standalone`, `X.Y.Z`, `vX.Y.Z`; digest output
- [ ] `.github/workflows/security-scan.yml`: ruff, Bandit → SARIF, Trivy fs + config, weekly cron
- [ ] syft SBOM + `actions/attest` + `cosign sign` + `verify-supply-chain.sh` hard-fail gate
- [ ] every action SHA-pinned; every consumer pins `image@sha256:…`
- [ ] register in `experiments/frappe-oci-composition` (§4 of the contract README): Dockerfile stage, compose build service, runtime image volume, nginx `subpath: assets` mount, k8s volumes in `40-runtime.yaml`, `50-nginx.yaml`, `31-init-job.yaml`
- [ ] composition smoke test: `docker compose --profile build build`, `run --rm init`, `up -d`, then `curl /api/method/ping` and one `/assets/<app>/…` URL
