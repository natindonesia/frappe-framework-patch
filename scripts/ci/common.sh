#!/usr/bin/env bash
# Shared bootstrap/helpers for CI steps. Source this (`source scripts/ci/common.sh`),
# don't execute it. Always cd's to the repository root first.
#
# Provides:
#   * `compose()` runs `docker compose` against the repository's standard CI
#     stack (project + docker-compose.yml + resources/compose.ci.yml, plus any
#     extra override files).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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