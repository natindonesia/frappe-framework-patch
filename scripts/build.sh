#!/usr/bin/env bash
# build.sh -- build the patched-Frappe base image locally.
#
# It computes the involved SHAs safely and bakes them into OCI labels / build args,
# then tags the image with the immutable tag policy:
#
#     <registry>/natindonesia/frappe:<upstream-short>-<patch-short>
#
# By default it only BUILDS and TAGS locally (with the registry-qualified tag, so a
# later explicit push is ready(i>. NO PUSH happens unless you pass --push.)
#
# Usage:
#   ./scripts/build.sh                      # build + tag immutable + latest (no push)
#   ./scripts/build.sh --push               # build then docker push both tags
#   ./scripts/build.sh --no-latest          # skip the floating "latest" tag
#   ./scripts/build.sh --pull               # docker build --pull (refresh base images)
#
# Requires a Docker daemon and the pinned submodule to be initialized
# (`git submodule update --init --recursive`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

REGISTRY="${REGISTRY:-registry.digitalocean.com/natindonesia/frappe}"
IMAGE_NAME="frappe-framework-patch"

PUSH=0
LATEST=1
PULL=0

for opt in "$@"; do
  case "$opt" in
    --push) PUSH=1 ;;
    --no-latest) LATEST=0 ;;
    --pull) PULL=1 ;;
    --help|-h)
      echo "Usage: $0 [--push] [--no-latest] [--pull]"
      echo "  Builds docker image ${REGISTRY}:<up-short>-<patch-short> (no push unless --push)."
      exit 0 ;;
    *) echo "Unknown option: $opt"; exit 2 ;;
  esac
done

# --- verify the submodule is an initialized, git-backed checkout ---
if ! git -C "$REPO_ROOT/frappe" rev-parse --git-dir >/dev/null 2>&1;then
  echo "ERROR: ./frappe submodule is not an initialized git checkout."
  echo "       Run: git submodule update --init --recursive"
  exit 1
fi

# --- compute SHAs safely ---
UPSTREAM_SHA="$(git -C "$REPO_ROOT/frappe" rev-parse --short=12 HEAD)"
PATCH_REPO_SHA="$(git -C "$REPO_ROOT" rev-parse --short=12 HEAD)"

[[ -n "$UPSTREAM_SHA" && -n "$PATCH_REPO_SHA" ]] || { echo "ERROR: could not resolve SHAs"; exit 1; }

TAG="${UPSTREAM_SHA}-${PATCH_REPO_SHA}"
FULL_TAG="${REGISTRY}:${TAG}"

echo "==> frappe-framework-patch build"
echo "    upstream frappe  : $UPSTREAM_SHA  (origin/version-16)"
echo "    patch repo head    : $PATCH_REPO_SHA"
echo "    immutable tag      : $TAG"
echo "    full image tag     : $FULL_TAG"

ARGS=(--build-arg "UPSTREAM_SHA=${UPSTREAM_SHA}" --build-arg "PATCH_REPO_SHA=${PATCH_REPO_SHA}")
if [[ "$PULL" -eq 1 ]]; then
  ARGS+=(--pull)
fi

echo "==> docker build ..."
docker build "${ARGS[@]}" -t "$FULL_TAG" .
if [[ "$LATEST" -eq 1 ]]; then
  docker tag "$FULL_TAG" "${REGISTRY}:latest"
fi

echo "==> built: $FULL_TAG ($TAG) + ${REGISTRY}:latest"

if [[ "$PUSH" -eq 1 ]];then
  echo "==> docker push ..."
  docker push "$FULL_TAG"
  if [[ "$LATEST" -eq 1 ]];then
      docker push "${REGISTRY}:latest"
  fi
else
  echo "==> (not pushed -- pass --push to push ${REGISTRY}.* tags)."
fi