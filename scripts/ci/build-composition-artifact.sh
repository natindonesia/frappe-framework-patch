#!/usr/bin/env bash
# =============================================================================
# build-composition-artifact.sh
#
# Build and publish the whole composition as one OCI artifact:
#
#     ghcr.io/natindonesia/frappe-oci-composition:<runtime-digest>
#   ├── <runtime-digest>          the composed runtime image (what every runtime
#   │                             service in compose.published.yaml uses)
#   └── <runtime-digest>-payload  the standalone payload: every composed app's
#                                 code under /opt/frappe/apps/<app> (Dockerfile.app
#                                 `artifact` target, validated against the
#                                 standalone app contract)
#
# The runtime stays the base of the payload, so pulling the payload tag gives
# the app code and the runtime tag gives the runtime — both are published from
# one run, and the digest tag names exactly the runtime inside them.
#
# Steps:
#   1. resolve the exact runtime digest to build on,
#   2. build the composed app images (`docker compose --profile build build`,
#      HOST daemon — see Dockerfile.app's "bake" section),
#   3. build the payload on that runtime (Dockerfile.app `artifact` target),
#   4. validate the standalone contract,
#   5. push the payload, then the runtime, tagged by the runtime digest,
#   6. move the `runtime` tag (only with --push), after both exist.
#
# Usage: build-composition-artifact.sh [--tag <tag>] [--push] [--skip-apps]
# Env  : REGISTRY_URL (ghcr.io), REGISTRY_NAMESPACE (natindonesia),
#        COMPOSED_RUNTIME_IMAGE, RUNTIME_DIGEST, RUNTIME_IMAGE,
#        BASE_RUNTIME_IMAGE, BAKED_RUN_ID, PUSH_MAX_ATTEMPTS
# =============================================================================
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

: "${REGISTRY_URL:?REGISTRY_URL required}"
: "${REGISTRY_NAMESPACE:?REGISTRY_NAMESPACE required}"
REGISTRY="$(lower "${REGISTRY_URL}/${REGISTRY_NAMESPACE}")"

COMPOSE_DIR="experiments/frappe-oci-composition/docker-compose"
COMPOSITION_IMAGE_NAME="frappe-oci-composition"
PAYLOAD_IMAGE="${COMPOSITION_IMAGE_NAME}:artifact"
# The local runtime build of the plain Dockerfile (see compose.yaml).
LOCAL_RUNTIME_IMAGE="${BASE_RUNTIME_IMAGE:-frappe-granian:latest}"

APPS=(erpnext hrms fayolex_extension eps fayolex_decision_science_tools)

TAG=""
PUSH=0
SKIP_APPS=0
for opt in "$@"; do
  case "$opt" in
    --tag=*) TAG="${opt#--tag=}" ;;
    --tag) shift; TAG="${1:?--tag needs a value}" ;;
    --push) PUSH=1 ;;
    --skip-apps) SKIP_APPS=1 ;;
    --help|-h)
      echo "Usage: $0 [--tag <tag>] [--push] [--skip-apps]"
      exit 0 ;;
    *) echo "Unknown option: $opt" >&2; exit 2 ;;
  esac
done

# The composed runtime ref, i.e. the image every runtime service in compose.yaml
# and compose.published.yaml names. Baked and published must agree.
COMPOSED_RUNTIME="${COMPOSED_RUNTIME_IMAGE:-$(sed -n 's/^ *image: *\(ghcr\.io\/natindonesia\/frappe-oci-composition:.*\)$/\1/p' "$COMPOSE_DIR/compose.yaml" | head -n1)}"
[ -n "$COMPOSED_RUNTIME" ] || { echo "compose.yaml names no ghcr.io/natindonesia/frappe-oci-composition runtime image" >&2; exit 1; }

login_ghcr() {
  [ -n "${GHCR_TOKEN:-}" ] || return 0
  printf '%s' "$GHCR_TOKEN" | docker login "${REGISTRY_URL}" \
    --username "${GHCR_USER:-${GITHUB_ACTOR:-github-actions}}" --password-stdin
}

# -- 1. resolve the exact runtime digest to build on -------------------------
# 1. RUNTIME_IMAGE (an explicit local/registry ref, as the workflow passes the
#    stack just smoke-tested) or RUNTIME_DIGEST when set, 2. the published
#    <ns>/frappe:latest-granian, 3. the local frappe-granian:latest.
# The registry ref is only used for the digest when the image is a published
# base; a local tag (no slash) is baked directly from the daemon.
BASE_REF="${RUNTIME_IMAGE:-${REGISTRY}/${LOCAL_RUNTIME_IMAGE%:*}:${LOCAL_RUNTIME_IMAGE##*:}}"
RUNTIME_FROM_REGISTRY=0
if [ -n "${RUNTIME_DIGEST:-}" ]; then
  RUNTIME_FROM_REGISTRY=1
  echo "==> runtime pinned by RUNTIME_DIGEST: ${RUNTIME_DIGEST} (${BASE_REF})"
elif [ -n "${RUNTIME_IMAGE:-}" ] && ! printf '%s' "$RUNTIME_IMAGE" | grep -q '/'; then
  # A local image tag (e.g. frappe-granian:latest): the exact bytes the stack
  # just ran. Build on it directly, never on a registry copy.
  docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1 || {
    echo "RUNTIME_IMAGE ${RUNTIME_IMAGE} is not in the local daemon" >&2
    exit 1
  }
  LOCAL_RUNTIME_IMAGE="$RUNTIME_IMAGE"
  RUNTIME_DIGEST="$(docker image inspect --format '{{.Id}}' "$RUNTIME_IMAGE")"
  echo "==> local runtime ${RUNTIME_IMAGE} (${RUNTIME_DIGEST})"
elif published_digest="$(docker buildx imagetools inspect "$BASE_REF" --format '{{.Manifest.Digest}}' 2>/dev/null)"; then
  RUNTIME_DIGEST="${published_digest##*@}"
  RUNTIME_DIGEST="sha256:${RUNTIME_DIGEST##*:}"
  RUNTIME_FROM_REGISTRY=1
  echo "==> published runtime ${BASE_REF} -> ${RUNTIME_DIGEST}"
else
  docker image inspect "$LOCAL_RUNTIME_IMAGE" >/dev/null 2>&1 || {
    echo "No published ${BASE_REF} and no local ${LOCAL_RUNTIME_IMAGE} to bake" >&2
    exit 1
  }
  RUNTIME_DIGEST="$(docker image inspect --format '{{.Id}}' "$LOCAL_RUNTIME_IMAGE")"
  echo "==> no published ${BASE_REF}; baking the local build ${LOCAL_RUNTIME_IMAGE} (${RUNTIME_DIGEST})"
fi
[ -n "$RUNTIME_DIGEST" ] || { echo "could not resolve the runtime digest" >&2; exit 1; }
# A tag cannot contain ':', so the digest becomes sha256-<hex>.
TAG="${TAG:-sha256-${RUNTIME_DIGEST#sha256:}}"
PUBLISH_REF="${REGISTRY}/${COMPOSITION_IMAGE_NAME}"
PAYLOAD_REF="${PUBLISH_REF}:${TAG}-payload"

# -- 2. build the composed app images on the host daemon --------------------
if [ "$SKIP_APPS" -eq 0 ]; then
  echo "==> building composed app images (${APPS[*]})"
  docker compose -f "$COMPOSE_DIR/compose.yaml" --profile build build
fi
for app in "${APPS[@]}"; do
  docker image inspect "composed/${app}:latest" >/dev/null 2>&1 || {
    echo "composed/${app}:latest missing; run without --skip-apps" >&2
    exit 1
  }
done

# -- 3. build the payload ------------------------------------------------
login_ghcr
build_args=(
  --build-arg "BAKED_RUNTIME=${RUNTIME_DIGEST}"
  --build-arg "BAKED_RUN_ID=${BAKED_RUN_ID:-${GITHUB_RUN_ID:-local}}"
)
# Pin the runtime by digest: a tag that moved between resolution and build
# must not silently change what the artifact claims to carry. A local image
# only has its ID, so it is referenced by ID.
if [ "$RUNTIME_FROM_REGISTRY" -eq 1 ]; then
  build_args+=(--build-arg "BASE_RUNTIME_IMAGE=${BASE_REF}@${RUNTIME_DIGEST}")
  echo "==> building payload on ${BASE_REF}@${RUNTIME_DIGEST}"
else
  build_args+=(--build-arg "BASE_RUNTIME_IMAGE=${LOCAL_RUNTIME_IMAGE}")
  echo "==> building payload on the local runtime ${LOCAL_RUNTIME_IMAGE}"
fi
docker buildx build \
  -f "$COMPOSE_DIR/Dockerfile.app" \
  --target artifact \
  "${build_args[@]}" \
  --load \
  -t "$PAYLOAD_IMAGE" \
  "$COMPOSE_DIR"

# -- 4. validate the standalone contract -------------------------------------
echo "==> validating standalone payload contract"
bash "$(dirname "${BASH_SOURCE[0]}")/validate-app-artifact.sh" \
  "$PAYLOAD_IMAGE" "$COMPOSITION_IMAGE_NAME"

# -- 5. push payload, then runtime ------------------------------------------
# Payload first: nothing references the payload tag unless the runtime it
# embeds exists.
echo "==> pushing payload ${PAYLOAD_REF}"
docker tag "$PAYLOAD_IMAGE" "$PAYLOAD_REF"
push_with_retry "$PAYLOAD_REF"

if [ "$RUNTIME_FROM_REGISTRY" -eq 1 ]; then
  RUNTIME_SRC="${BASE_REF}@${RUNTIME_DIGEST}"
else
  RUNTIME_SRC="$LOCAL_RUNTIME_IMAGE"
fi
# The runtime under the published name. `crane`/`docker` only create the tag;
# the runtime bytes are pushed once and only when they are not there yet.
echo "==> publishing runtime ${PUBLISH_REF}:${TAG} (from ${RUNTIME_SRC})"
if [ "$RUNTIME_FROM_REGISTRY" -eq 1 ]; then
  docker buildx imagetools create -t "${PUBLISH_REF}:${TAG}" "${BASE_REF}@${RUNTIME_DIGEST}"
else
  docker tag "$RUNTIME_SRC" "${PUBLISH_REF}:${TAG}"
  push_with_retry "${PUBLISH_REF}:${TAG}"
fi

# -- 6. move the moving tag last --------------------------------------------
if [ "$PUSH" -eq 1 ]; then
  docker buildx imagetools create -t "${PUBLISH_REF}:runtime" "${PUBLISH_REF}:${TAG}"
fi

{
  echo "## 📦 Published composition artifact"
  echo ""
  echo "| Item | Ref |"
  echo "| :--- | :--- |"
  echo "| Runtime | \`${PUBLISH_REF}:${TAG}\` |"
  echo "| Runtime (moving tag) | \`${PUBLISH_REF}:runtime\` |"
  echo "| Payload | \`${PAYLOAD_REF}\` |"
  echo "| Baked runtime digest | \`${RUNTIME_DIGEST}\` |"
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

echo "OK: ${PUBLISH_REF}:${TAG} (+ ${PAYLOAD_REF})"
