#!/usr/bin/env bash
# run_tests.sh -- run the frappe-framework-patch test suite.
#
# Creates a throwaway virtualenv, installs OpenTelemetry packages so the functional
# W3C trace-context tests actually run, then runs the unit tests with `unittest`.
# If the otel install fails (e.g. offline environment), we warn and fall back to the
# interpreter WITHOUT otel -- the optional functional tests then SKIP cleanly while
# the structural/static tests (patch applicability, py_compile) still run.
#
# Usage:  tests/run_tests.sh [--no-otel]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PYTHON="${PYTHON:-python3}"
command -v "$PYTHON" >/dev/null 2>&1 || { echo "ERROR: '$PYTHON' not found"; exit 1; }

WANT_OTEL=1
if [[ "${1:-}" == "--no-otel" ]]; then WANT_OTEL=0; fi

echo "==> using interpreter: $($PYTHON --version 2>&1)"

VENV_DIR="$(mktemp -d)"
trap 'rm -rf "$VENV_DIR"' EXIT

echo "==> creating throwaway venv at $VENV_DIR"
"$PYTHON" -m venv "$VENV_DIR/venv"
# shellcheck disable=SC1091
source "$VENV_DIR/venv/bin/activate"

if [[ "$WANT_OTEL" -eq 1 ]]; then
  echo "==> installing opentelemetry packages (functional tests)"
  if pip install --quiet \
      opentelemetry-api \
      opentelemetry-sdk \
      opentelemetry-exporter-otlp; then
    echo "   otel installed OK"
  else
    echo "   WARN: could not install opentelemetry; functional OTel tests will SKIP (structural tests still run)."
  fi
else
  echo "==> --no-otel requested; OTel functional tests will skip"
fi

echo "==> running unittest suite"
python -m unittest discover -s tests -p 'test_*.py' -t . -v