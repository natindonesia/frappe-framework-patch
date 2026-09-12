#!/usr/bin/env bash
# base-verify.sh
#
# Proves the `base` variant is genuinely UNPATCHED while `latest` is patched,
# and that runtime smoke surface shared by both still works.
#
# Marker: patch 0001 adds `frappe/integrations/trace_context.py` (a NEW file).
#   - latest MUST contain it  (patches applied).
#   - base   MUST NOT contain it, plus a positive runtime signal (python import).
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

MARKER="/home/frappe/frappe-bench/apps/frappe/frappe/integrations/trace_context.py"

echo "==> frappe:latest patch marker presence"
if docker run --rm frappe:latest sh -c '[ -f "$1" ]' sh "$MARKER"; then
  echo "   OK :latest patched  (trace_context.py present)"
else
  echo "   FAIL :latest missing patch marker"; exit 1
fi

echo "==> frappe:base patch marker absence (must be unpatched)"
if docker run --rm frappe:base sh -c '[ ! -f "$1" ]' sh "$MARKER"; then
  echo "   OK :base unpatched (trace_context.py absent)"
else
  echo "   FAIL :base contains patch marker - base is not unpatched"; exit 1
fi

echo "==> frappe:base runtime smoke (python + frappe import)"
docker run --rm --entrypoint /bin/bash frappe:base -lc \
  'cd /home/frappe/frappe-bench/sites && ../env/bin/python -c "import frappe; print(\"frappe %s, base smoke OK\" % frappe.__version__)"'

echo "==> base-verify done"