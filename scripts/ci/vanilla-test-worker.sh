#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

docker run --rm frappe:latest bash -c '
  cd sites
  ../env/bin/python -m frappe.utils.bench_helper frappe worker --help >/dev/null
  ../env/bin/python -c "import frappe.utils.background_jobs; import frappe.utils.bench_helper; print(\"patched worker modules import OK\")"
'