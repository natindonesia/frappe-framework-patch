#!/usr/bin/env bash
# Shared bootstrap/helpers for CI steps. Source this (`source scripts/ci/common.sh`),
# don't execute it. Always cd's to the repository root first.
#
# Provides:
#   * `compose()` runs `docker compose` against the repository's standard CI
#     stack (project + docker-compose.yml + resources/compose.ci.yml, plus any
#     extra override files).
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
  docker push "${target}/${remote}"
}