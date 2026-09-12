#!/usr/bin/env bash
# matrix-variant-test.sh -- run the SAME common compose/OTEL/CRUD contract against
# ONE loaded local image variant, then add variant-specific identity/lineage checks.
#
# Usage: matrix-variant-test.sh <base|latest|latest-granian>
#
# The image under test is already loaded into the local daemon (from the
# tested-images artifact) BEFORE this script is invoked; the matrix job never
# rebuilds or pulls. This script only maps the variant to:
#   * the local image tag (FRAPPE_TEST_IMAGE, used by compose.variant-ci.yml)
#   * whether the Granian serving override (+ command swap) applies
# then runs the SAME contract for every entry.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

VARIANT="${1:?usage: matrix-variant-test.sh <base|latest|latest-granian>}"
case "$VARIANT" in
  base)
    FRAPPE_TEST_IMAGE="frappe:base"
    EXTRA_FILES="resources/compose.variant-ci.yml"
    HTTP_PORT=18085
    ;;
  latest)
    FRAPPE_TEST_IMAGE="frappe:latest"
    EXTRA_FILES="resources/compose.variant-ci.yml"
    HTTP_PORT=18085
    ;;
  latest-granian)
    FRAPPE_TEST_IMAGE="frappe-granian:latest"
    EXTRA_FILES="resources/compose.variant-ci.yml resources/compose.granian-ci.yml"
    HTTP_PORT=18086
    ;;
  *)
    echo "::error::unknown variant '$VARIANT'"
    exit 2
    ;;
esac
export FRAPPE_TEST_IMAGE
export EXTRA_FILES
export HTTP_PORT

CI_PROJECT="ci-${VARIANT}"
export CI_PROJECT

# The common contract validates OTEL span continuity, so the exporter endpoints
# are ON for every variant during the compose lifecycle (matching the existing
# integration job's "Vanilla start stack" step). Only the gunicorn-served
# variants then re-run with OTLP empty to verify the gate-off path.
OTEL_EXPORTER_OTLP_ENDPOINT="http://otel-collector:4318"
NGINX_OTEL_ENDPOINT="otel-collector:4317"
export OTEL_EXPORTER_OTLP_ENDPOINT
export NGINX_OTEL_ENDPOINT

# Granian needs more time to become ready on a shared runner.
CI_WAIT_ROUNDS=60
[ "$VARIANT" = "latest-granian" ] && CI_WAIT_ROUNDS=120
export CI_WAIT_ROUNDS

echo "============================================================"
echo "matrix-variant-test: VARIANT=$VARIANT  IMAGE=$FRAPPE_TEST_IMAGE"
echo "  CI_PROJECT=$CI_PROJECT  HTTP_PORT=$HTTP_PORT  EXTRA_FILES=$EXTRA_FILES"
echo "============================================================"

# =============================================================================
# 1. Variant identity / lineage assertions (ADDITIVE, never a substitute for the
#    common contract below).
#
# Marker: patch 0001 adds frappe/integrations/trace_context.py.
#   base           -> marker ABSENT  (genuinely unpatched)
#   latest         -> marker PRESENT (patched)
#   latest-granian -> marker PRESENT (layered on patched latest)
# =============================================================================
MARKER="/home/frappe/frappe-bench/apps/frappe/frappe/integrations/trace_context.py"
echo "==> [$VARIANT] patch-marker check"
case "$VARIANT" in
  base)
    if docker run --rm "$FRAPPE_TEST_IMAGE" sh -c '[ ! -f "$1" ]' sh "$MARKER"; then
      echo "   OK base unpatched (trace_context.py absent)"
    else
      echo "::error::base contains patch marker; base is not unpatched"; exit 1
    fi
    # Positive runtime signal for the unpatched reference image.
    docker run --rm --entrypoint /bin/bash "$FRAPPE_TEST_IMAGE" -lc \
      'cd /home/frappe/frappe-bench/sites && ../env/bin/python -c "import frappe; print(\"frappe %s, base smoke OK\" % frappe.__version__)"'
    ;;
  latest|latest-granian)
    if docker run --rm "$FRAPPE_TEST_IMAGE" sh -c '[ -f "$1" ]' sh "$MARKER"; then
      echo "   OK $VARIANT patched (trace_context.py present)"
    else
      echo "::error::$VARIANT missing patch marker"; exit 1
    fi
    ;;
esac

# Prove the tested image tag is a distinct local artifact with the intended label.
echo "==> [$VARIANT] image identity"
docker inspect --format 'tags={{.RepoTags}} variant={{index .Config.Labels "org.opencontainers.image.variant"}} patched={{index .Config.Labels "org.opencontainers.image.patches-applied"}}' "$FRAPPE_TEST_IMAGE"

if [ "$VARIANT" = "latest-granian" ]; then
  echo "==> [$VARIANT] granian runtime check"
  docker run --rm "$FRAPPE_TEST_IMAGE" bash -c \
    "./env/bin/granian --version"
fi

# =============================================================================
# 2. COMMON CONTRACT — identical for base, latest, latest-granian.
#    Full compose lifecycle + OTEL span continuity + CRUD, then teardown.
# =============================================================================
echo "==> [$VARIANT] common contract start"
compose-cleanup() { bash scripts/ci/compose-cleanup.sh -v; }
run_step() {
  local name="$1"; shift
  echo "--- [$VARIANT] $name ---"
  bash "scripts/ci/$name.sh"
}

ERR_CODE=0
finish() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "::error::[$VARIANT] failed at step, rc=$rc"
    bash scripts/ci/compose-diag.sh || true
  fi
  bash scripts/ci/compose-teardown.sh || true
  exit "$rc"
}
trap finish EXIT

compose-cleanup
run_step compose-start-deps
run_step compose-init
run_step compose-start-stack
run_step compose-wait-web

# Readiness through nginx for every variant.
echo "--- [$VARIANT] ping via nginx ---"
body=$(compose exec -T nginx curl -s -H "Host: crm.localhost" http://127.0.0.1:8080/api/method/ping || true)
echo "ping response: $body"
echo "$body" | grep -q '"message":"pong"' || { echo "::error::[$VARIANT] expected pong"; exit 1; }

run_step compose-otel-spans
run_step granian-crud
# gate-off only applies to the gunicorn-served variants (latest, base): restart
# with OTLP endpoints EMPTY and assert no spans leak.
if [ "$VARIANT" != "latest-granian" ]; then
  OTEL_EXPORTER_OTLP_ENDPOINT=""
  NGINX_OTEL_ENDPOINT=""
  export OTEL_EXPORTER_OTLP_ENDPOINT
  export NGINX_OTEL_ENDPOINT
  run_step compose-gate-off
fi

# Granian-specific serving assertion (additive, only for latest-granian).
if [ "$VARIANT" = "latest-granian" ]; then
  echo "--- [$VARIANT] granian serving process ---"
  bash scripts/ci/granian-verify-serving.sh
fi

echo "==> [$VARIANT] OK: all common + variant-specific checks passed"