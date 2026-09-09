#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Verify Granian is installed and the otel_wsgi entrypoint imports.
docker run --rm frappe-granian:latest bash -c "
  mkdir -p /home/frappe/logs &&
  ./env/bin/granian --version &&
  ./env/bin/python -c 'import frappe; from frappe.otel_wsgi import application; print(f\"Frappe {frappe.__version__} granian entrypoint loads\")'
"

# Image size report.
docker images frappe:latest frappe-granian:latest --format "Image: {{.Repository}}:{{.Tag}}  Size: {{.Size}}"