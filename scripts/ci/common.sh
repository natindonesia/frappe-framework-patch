#!/usr/bin/env bash
# Shared bootstrap/helpers for CI steps. Source this (`source scripts/ci/common.sh`),
# don't execute it. Always cd's to the repository root first.
#
# Provides:
#   * `compose()` runs `docker compose` against the repository's standard CI
#     stack (project + docker-compose.yml + resources/compose.ci.yml, plus any
#     extra override files).
#   * `secondary_registry()` / `publish_secondary()` mirror a tested image to the
#     optional second registry (ghcr.io).
#   * `build_cache_ref()` prints the buildx registry-cache reference shared by
#     every image build (default ghcr.io — no Actions-cache 10 GB LRU to fight).
#   * `push_with_retry()` pushes an image with bounded retries for transient
#     registry errors (GHCR "unknown blob").
#   * `set_image_metadata_args()` fills IMAGE_METADATA_ARGS with the
#     `--build-arg` flags for the org.opencontainers.image LABEL metadata.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# compose() -- run docker compose for a CI stack.
# Required env : CI_PROJECT (e.g. ci-otel / ci-granian)
# Optional env : EXTRA_FILES (extra space-separated `-f <file>` overrides),
#                HTTP_PORT (default 18085; pass-through to compose.ci.yml)
compose() {
  : "${CI_PROJECT:?set CI_PROJECT (e.g. ci-otel / ci-granian)}"
  local flags=(-p "${CI_PROJECT}" -f docker-compose.yml -f resources/compose.ci.yml)
  local f
  for f in ${EXTRA_FILES:-}; do
    [ -n "$f" ] && flags+=(-f "$f")
  done
  docker compose "${flags[@]}" "$@"
}

# lower() -- lowercase a string. Registry image names (GHCR included) MUST be
# lowercase, while GitHub expressions have no lowercase function.
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# push_with_retry <remote-ref> -- docker push with bounded retries and backoff.
# Registries (GHCR especially) intermittently reject a completed upload with
# "unknown blob"; a retry re-checks and re-uploads only the missing layers, so a
# fresh attempt normally succeeds. Override attempts via PUSH_MAX_ATTEMPTS.
push_with_retry() {
  local ref="$1" attempt max="${PUSH_MAX_ATTEMPTS:-5}"
  for ((attempt = 1; attempt <= max; attempt++)); do
    if docker push "$ref"; then
      return 0
    fi
    echo "docker push ${ref} failed (attempt ${attempt}/${max})" >&2
    [ "$attempt" -lt "$max" ] || return 1
    sleep $((attempt * 5))
  done
}

# set_image_metadata_args() -- populate the global IMAGE_METADATA_ARGS array
# with `--build-arg` flags for the org.opencontainers.image metadata baked into
# the image LABELs. Values come from the environment (the workflow metadata
# step), falling back to the local checkout so plain local builds still carry a
# sensible revision/version.
set_image_metadata_args() {
  local revision="${IMAGE_REVISION:-$(git rev-parse HEAD 2>/dev/null || echo unknown)}"
  local version="${IMAGE_VERSION:-$(git describe --tags --always --dirty 2>/dev/null || echo dev)}"
  local source="${IMAGE_SOURCE:-https://github.com/natindonesia/frappe-framework-patch}"
  local created="${IMAGE_CREATED:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  local frappe_sha="${FRAPPE_SHA:-$(git -C frappe rev-parse HEAD 2>/dev/null || echo unknown)}"
  IMAGE_METADATA_ARGS=(
    --build-arg "IMAGE_VERSION=${version}"
    --build-arg "IMAGE_REVISION=${revision}"
    --build-arg "IMAGE_SOURCE=${source}"
    --build-arg "IMAGE_CREATED=${created}"
    --build-arg "FRAPPE_SHA=${frappe_sha}"
  )
}

# build_cache_ref() -- print the single buildx registry-cache reference shared
# by ALL image variants (base / latest / granian builds read and write it).
# GHCR by default: registry cache blobs are not subject to the 10 GB
# Actions-cache LRU eviction that made cold `bench init` rebuilds chronic.
# Overrides: BUILD_CACHE_REGISTRY / BUILD_CACHE_NAMESPACE / BUILD_CACHE_TAG.
# NOTE: changing BUILD_CACHE_REGISTRY to a non-GHCR registry requires adding a
# matching docker/login-action step for it in the workflow.
build_cache_ref() {
  local reg="${BUILD_CACHE_REGISTRY:-ghcr.io}"
  local ns="${BUILD_CACHE_NAMESPACE:-${SECONDARY_REGISTRY_NAMESPACE:-${GITHUB_REPOSITORY_OWNER:-natindonesia}}}"
  printf '%s/%s/frappe-buildcache:%s' "$(lower "$reg")" "$(lower "$ns")" "${BUILD_CACHE_TAG:-main}"
}

# secondary_registry() -- print "<registry>/<namespace>" for the OPTIONAL second
# registry (e.g. ghcr.io alongside registry.digitalocean.com), or nothing when
# SECONDARY_REGISTRY_URL is empty. Generic hook: the workflow decides the value.
secondary_registry() {
  [ -n "${SECONDARY_REGISTRY_URL:-}" ] || return 0
  : "${SECONDARY_REGISTRY_NAMESPACE:?SECONDARY_REGISTRY_NAMESPACE required when SECONDARY_REGISTRY_URL is set}"
  printf '%s/%s' "$(lower "$SECONDARY_REGISTRY_URL")" "$(lower "$SECONDARY_REGISTRY_NAMESPACE")"
}

# publish_secondary <local-image> <remote-repo:tag> -- push the EXACT tested
# local image to the secondary registry (docker tag + docker push, no rebuild).
# No-op with a clear message when the secondary registry is not configured.
publish_secondary() {
  local local_image="$1" remote="$2" target
  target="$(secondary_registry)"
  if [ -z "$target" ]; then
    echo "Secondary registry not configured — skipping ${remote}"
    return 0
  fi
  echo "Publishing tested ${local_image} -> ${target}/${remote}"
  docker tag "$local_image" "${target}/${remote}"
  push_with_retry "${target}/${remote}"
}