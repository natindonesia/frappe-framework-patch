#!/usr/bin/env bash
# Delete stale GHCR package versions while protecting everything the CURRENT
# release tags resolve to, regardless of age:
#   * the manifest each keep-tag points at (frappe:latest/base/latest-granian)
#   * that manifest's cosign signature (.sig) and attestation (.att) manifests
# Everything else older than CLEANUP_MAX_AGE_DAYS (default 7) is deleted —
# including the sha256-<digest> versions GHCR auto-lists for retired
# signatures/attestations (the package-page noise).
#
# Deletions are irreversible. Run with --dry-run first.
#
# Usage: ghcr-cleanup.sh [--dry-run] <namespace> <package> <keep-tag>...
#   e.g. ghcr-cleanup.sh natindonesia frappe latest base latest-granian
# Requires: gh CLI authenticated with read:packages (list) and delete:packages
# (delete) for the owning account/org, plus docker buildx for digest resolution.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

[ $# -ge 2 ] || { echo "usage: ghcr-cleanup.sh [--dry-run] <namespace> <package> <keep-tag>..." >&2; exit 2; }
NAMESPACE="$1"; shift
PACKAGE="$1"; shift
[ $# -ge 1 ] || { echo "at least one keep-tag required" >&2; exit 2; }

REGISTRY="${SECONDARY_REGISTRY_URL:-ghcr.io}"
IMAGE="$(lower "$REGISTRY")/$(lower "$NAMESPACE")/$PACKAGE"
MAX_AGE_DAYS="${CLEANUP_MAX_AGE_DAYS:-7}"

# --- Resolve currently-protected manifest digests ---------------------------
# hex digest (no "sha256:" prefix) of each keep-tag, plus the cosign/attest
# sidecar manifests referenced via sha256-<hex>.sig / .att / referrer tags.
protected_hexes=""
collect_digest() {
  local digest
  digest="$(docker buildx imagetools inspect "$1" 2>/dev/null | awk '/^Digest:/ {print $2; exit}')" || return 0
  [ -n "$digest" ] || return 0
  protected_hexes+=" ${digest#sha256:}"
}

for tag in "$@"; do
  collect_digest "${IMAGE}:${tag}"
done
# Sidecars of the FIRST keep-tag's image(s): cosign signature + attestation,
# and GitHub attest referrers tagged sha256-<hex>. Check for every keep-tag.
for tag in "$@"; do
  subj="$(docker buildx imagetools inspect "${IMAGE}:${tag}" 2>/dev/null | awk '/^Digest:/ {print $2; exit}')" || continue
  [ -n "$subj" ] || continue
  hex="${subj#sha256:}"
  collect_digest "${IMAGE}:sha256-${hex}.sig"
  collect_digest "${IMAGE}:sha256-${hex}.att"
  collect_digest "${IMAGE}:sha256-${hex}"
done
[ -n "$protected_hexes" ] || echo "warn: no digests resolvable for ${IMAGE} (package missing yet?)" >&2
echo "Protected manifest digests (${#protected_hexes}):$(for h in $protected_hexes; do printf ' sha256:%s' "$h"; done)"

# --- List all package versions ----------------------------------------------
# Package is repo-linked; it lives under the org when the owner is an org.
api_base="/user/packages"
if gh api "orgs/$(lower "$NAMESPACE")" >/dev/null 2>&1; then
  api_base="/orgs/$(lower "$NAMESPACE")/packages"
fi
versions_url="${api_base}/container/${PACKAGE}/versions?per_page=100"

# Fail fast on auth/permission problems before the silent process-substitution loop.
gh api "${api_base}/container/${PACKAGE}/versions?per_page=1" --jq 'length' >/dev/null

cutoff_epoch="$(date -u -d "${MAX_AGE_DAYS} days ago" +%s)"
now_epoch="$(date -u +%s)"
deleted=0
kept=0

# Keep-tag names that must never age out (user policy: regardless of days).
keep_tags="$*"
# Sidecar tag suffixes for protected subjects, e.g. sha256-<hex>(.sig|.att)?
# Build one extended regex of protected hexes for tag matching.
hex_alt="$(printf '%s|' $protected_hexes)"; hex_alt="${hex_alt%|}"

mapfile -t version_lines < <(
  gh api --paginate "$versions_url" \
    --jq '.[] | [.id, .name, .created_at, ([.metadata.container.tags // [] | join(",")])] | @tsv' 2>/dev/null
)

for line in "${version_lines[@]}"; do
  IFS=$'\t' read -r id name created_at tags_json <<<"$line"
  [ -n "$id" ] || continue
  hex="${name#sha256:}"
  protected=0
  if printf ' %s ' "$protected_hexes" | grep -q " ${hex} "; then
    protected=1
  fi
  if [ "$protected" -eq 0 ] && [ -n "$tags_json" ]; then
    # Any tag that is a keep-tag, or a sha256- sidecar of a protected digest.
    if printf '%s' "$tags_json" | jq -re --arg kt "$keep_tags" --arg hx "$hex_alt" '
        .[] | select(
             (index($kt | split(" ") | .[]) != null)
          or (test("^sha256-(" + $hx + ")(\\.(sig|att))?$"))
        )' >/dev/null 2>&1; then
      protected=1
    fi
  fi
  if [ "$protected" -eq 1 ]; then
    kept=$((kept + 1))
    continue
  fi
  created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null || echo 0)"
  if [ "$created_epoch" -ge "$cutoff_epoch" ]; then
    kept=$((kept + 1))
    continue
  fi
  age_days=$(( (now_epoch - created_epoch) / 86400 ))
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY-RUN would delete version ${id} (${name}, ${age_days}d old, tags: ${tags_json})"
  else
    echo "Deleting version ${id} (${name}, ${age_days}d old, tags: ${tags_json})"
    gh api -X DELETE "${api_base}/container/${PACKAGE}/versions/${id}" >/dev/null
  fi
  deleted=$((deleted + 1))
done

echo "done: ${deleted} deleted, ${kept} kept (package=${PACKAGE}, max_age=${MAX_AGE_DAYS}d)"
