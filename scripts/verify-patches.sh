#!/usr/bin/env bash
# verify-patches.sh
#
# Read-only verification that the ./frappe submodule is clean AND the patches in
# ./patches apply cleanly to a disposable pristine copy (including expected files).
# This intentionally does NOT modify the submodule.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$REPO_ROOT/frappe"
PATCHES_DIR="$REPO_ROOT/patches"

EXPECTED_FILES=("frappe/integrations/trace_context.py" "frappe/utils/background_jobs.py")

main() {
  [[ -d "$PATCHES_DIR" ]] || { echo "ERROR: missing $PATCHES_DIR"; exit 1; }
  if ! git -C "$SUBMODULE" rev-parse --git-dir >/dev/null 2>&1; then
    echo "ERROR: missing submodule at $SUBMODULE"; exit 1;
  fi

  echo "=> submodule dirty check"
  local dirty
  dirty="$(cd "$SUBMODULE" && git status --porcelain)"
  if [[ -n "$dirty" ]]; then
    echo "ERROR: submodule is NOT clean (uncommitted changes present):" >&2
    echo "$dirty"
    exit 1
  else
    echo "   clean."
  fi

  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  git -C "$SUBMODULE" archive HEAD | tar -x -C "$temp_dir"

  echo "=> patch applicability"
  local patch
  for patch in "$PATCHES_DIR"/*.patch; do
    ( cd "$temp_dir" && git apply --check "$patch" )
    ( cd "$temp_dir" && git apply "$patch" )
    echo "   OK  $(basename "$patch") applies cleanly"
  done

  echo "=> expected patched files present after apply"
  for rel in "${EXPECTED_FILES[@]}"; do
    if [[ -e "$temp_dir/$rel" ]]; then
      echo "   PRESENT $rel"
    else
      echo "   ERROR   $rel" >&2
      exit 1
    fi
  done
  rm -rf "$temp_dir"
  trap - EXIT
  echo "==> verify done (read-only; no modifications made)."
}

main "$@"