#!/usr/bin/env bash
# apply-patches.sh
#
# Apply the Frappe framework patches (in ./patches) to the ./frappe submodule.

# Works in two contexts:
#   1. git-backed checkout (local dev / CI):- the submodule MUST be a clean
#      checkout of the SHA recorded in the parent repo. We verify cleanliness and
#      pre-flight check applicability (git apply --check --3way) before touching
#      anything, so a patch that no longer applies fails loudly WOTHOUT modifying.

#   2. plain copy (Docker build context):- no .git is present. We then apply
#      patches plainly ((git apply --3way falls back to patch -p1 when no git repo)
#      with no clean/check gates (the source tree is assumed pristine because it was
#      produced by `git submodule update` + `COPY` in a fresh build context.)
#
# Repeated local runs are safe: if the submodule is clean and the patches are
# already applied, `git apply --check` fails clearly (patch already applied)and we
# exit non-zero -- run `git submodule update --force` to reset first.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBMODULE="$REPO_ROOT/frappe"
PATCHES_DIR="$REPO_ROOT/patches"

# Files that MUST exist after applying all patches (relative to the submodule root).
EXPECTED_FILES=(
  "frappe/integrations/trace_context.py"
)

GIT_MODE=0
if git -C "$SUBMODULE" rev-parse --git-dir >/dev/null 2>&1;then
  GIT_MODE=1
fi

main() {
  echo "=> [1/5] checking paths"
  check_paths
  if [[ "$GIT_MODE" -eq 1 ]]; then
    echo "=> [2/5] git-backed source tree"
    echo "   git repo present -- enforcing clean check + pre-flight"
    check_submodule_clean
    preflight_check
  else
    echo "=> [2/5] plain-copy source tree (e.g. Docker build context)"
  fi
  echo "=> [3/5] applying patches"
  apply_all
  echo "=> [4/5] verifying expected files"
  verify_expected_files
  echo "==> DONE: all patches applied and verified."
}

check_paths() {
  [[ -d "$PATCHES_DIR" ]] || { echo "ERROR: missing $PATCHES_DIR"; exit 1; }
  [[ -d "$SUBMODULE" ]] || { echo "ERROR: missing submodule at $SUBMODULE"; exit 1; }
  if [[ "$GIT_MODE" -eq 0 ]];then
    # plain copy: ensure the framework top-level package is actually present
    [[ -d "$SUBMODULE/frappe" ]] || { echo "ERROR: $SUBMODULE/frappe not found -- is the submodule a valid checkout?"; exit 1; }
  fi
}

check_submodule_clean() {
  local dirty
  dirty="$(cd "$SUBMODULE" && git status --porcelain)"
  if [[ -n "$dirty" ]];then
    echo "ERROR: submodule $SUBMODULE is not clean. Refusing to apply over uncommitted changes."
    echo "$dirty"
    echo "Reset with: git -C \"$SUBMODULE\" clean -fd && git -C \"$SUBMODULE\" checkout -- ."
    exit 1
  fi
}

preflight_check() {
  local patches
  mapfile -t patches < <(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null || true)
  if [[ ${#patches[@]} -eq 0 ]];then
    echo "ERROR: no *.patch files found in $PATCHES_DIR"
    exit 1
  fi
  for patch in "${patches[@]}"; do
    local rel
    rel="$(basename "$patch")"
    echo "  - check: $rel"
    ( cd "$SUBMODULE" && git apply --check --3way "$patch" )
  done
}

apply_all() {
  local patches
  mapfile -t patches < <(ls -1 "$PATCHES_DIR"/*.patch 2>/dev/null || true)
  if [[ ${#patches[@]} -eq 0 ]]; then
    echo "ERROR: no *.patch files found in $PATCHES_DIR"
    exit 1
  fi
  for patch in "${patches[@]}"; do
    local rel
    rel="$(basename "$patch")"
    echo "     + apply: $rel"
    if [[ "$GIT_MODE" -eq 1 ]]; then
      ( cd "$SUBMODULE" && git apply --3way "$patch" )
    else
      # no git repo (Docker build context): plain git apply strips a/ b/ prefixes directly
      ( cd "$SUBMODULE" && git apply "$patch" )
    fi
  done
}

verify_expected_files() {
  local missing=()
  for rel in "${EXPECTED_FILES[@]}"; do
    if [[ ! -e "$SUBMODULE/$rel" ]]; then
      missing+=("$rel")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: expected files missing after applying:" >&2
    printf '   %s\n' "${missing[@]}" >&2
    exit 1
  fi
}

main "$@"