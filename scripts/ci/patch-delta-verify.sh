#!/usr/bin/env bash
# patch-delta-verify.sh
#
# Proves the patched `latest` and unpatched `base` images are genuinely
# DIFFERENT: every patch under patches/ must have a visible marker effect in
# frappe:latest and the opposite effect in frappe:base.
#
# Marker contract (keep in sync with tests/test_frappe_framework_patch.py):
#   0001-otel-trace-context-propagation.patch   ADDS    frappe/integrations/trace_context.py
#                                               -> base ABSENT,  latest PRESENT
#   0002-remove-frappe-build-comment.patch      REMOVES "Built on Frappe" from templates/base.html
#   0003-desktop-remove-frappe-support-link.patch REMOVES "Frappe Support" from desk/page/desktop/desktop.js
#   0004-desktop-remove-about-link.patch        REMOVES "frappe.ui.toolbar.show_about" from desk/page/desktop/desktop.js
#   0005-sidebar-remove-crm-banner.patch        REMOVES "Switch to CRM" from public/js/frappe/ui/sidebar/sidebar.js
#                                               -> base PRESENT, latest ABSENT
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Frappe package root inside the images: bench app dir is
# /home/frappe/frappe-bench/apps/frappe, and the package itself lives directly
# under it (matching the marker path used by base-verify.sh).
PKG="/home/frappe/frappe-bench/apps/frappe"

# check <image> <expect-present: yes|no> <relpath> <fixed-marker> <patch-label>
check() {
  local image="$1" expect="$2" rel="$3" marker="$4" label="$5"
  local path="${PKG}/${rel}"
  if [ "$expect" = yes ]; then
    if docker run --rm "$image" sh -c 'test -f "$1" && grep -Fq -- "$2" "$1"' sh "$path" "$marker"; then
      echo "   OK   $image contains marker [$label] $rel :: $marker"
    else
      echo "::error::$label: $image must contain marker ($rel): $marker"; exit 1
    fi
  else
    # For "must be absent", a missing file also satisfies the check (patch 0001).
    if docker run --rm "$image" sh -c 'if [ -f "$1" ]; then ! grep -Fq -- "$2" "$1"; fi' sh "$path" "$marker"; then
      echo "   OK   $image free of marker  [$label] $rel :: $marker"
    else
      echo "::error::$label: $image must NOT contain marker ($rel): $marker"; exit 1
    fi
  fi
}

fail() { echo "::error::$1"; exit 1; }

echo "==> patch-delta: frappe:latest (patched) vs frappe:base (unpatched)"

# 0001-otel-trace-context-propagation.patch (adds trace_context.py)
check frappe:base   no  frappe/integrations/trace_context.py "def get_trace_context" 0001-otel-trace-context-propagation.patch
check frappe:latest yes frappe/integrations/trace_context.py "def get_trace_context" 0001-otel-trace-context-propagation.patch

# 0002-remove-frappe-build-comment.patch
check frappe:base   yes frappe/templates/base.html "Built on Frappe" 0002-remove-frappe-build-comment.patch
check frappe:latest no  frappe/templates/base.html "Built on Frappe" 0002-remove-frappe-build-comment.patch

# 0003-desktop-remove-frappe-support-link.patch
check frappe:base   yes frappe/desk/page/desktop/desktop.js "Frappe Support" 0003-desktop-remove-frappe-support-link.patch
check frappe:latest no  frappe/desk/page/desktop/desktop.js "Frappe Support" 0003-desktop-remove-frappe-support-link.patch

# 0004-desktop-remove-about-link.patch
check frappe:base   yes frappe/desk/page/desktop/desktop.js "frappe.ui.toolbar.show_about" 0004-desktop-remove-about-link.patch
check frappe:latest no  frappe/desk/page/desktop/desktop.js "frappe.ui.toolbar.show_about" 0004-desktop-remove-about-link.patch

# 0005-sidebar-remove-crm-banner.patch
check frappe:base   yes frappe/public/js/frappe/ui/sidebar/sidebar.js "Switch to CRM" 0005-sidebar-remove-crm-banner.patch
check frappe:latest no  frappe/public/js/frappe/ui/sidebar/sidebar.js "Switch to CRM" 0005-sidebar-remove-crm-banner.patch

# Guard against empty-marker accidents: every removal marker MUST really exist
# in the pristine base (checked above via "yes") and every added marker MUST
# really exist in latest (checked via "yes"); nothing else to do here.
echo "==> patch-delta OK: latest is patched, base is unpatched, and they differ"
