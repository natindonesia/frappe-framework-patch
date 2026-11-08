#!/usr/bin/env bash
# Verify the published tags in EVERY configured registry and that the three
# variants resolve to DISTINCT digests, so each variant is genuinely its own
# artifact:
#   - <version>-base / base                    (unpatched reference image)
#   - <version>      / latest                  (patched production image)
#   - <version>-granian / latest-granian       (Granian layered on latest)
# Immutable release tags are verified on every run; the moving tags only when
# this run is allowed to advance them. When both are published they must resolve
# to the SAME digest, and when two registries are configured each tag must match
# across them — proof the same tested image reached every registry.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

require_registry
PRIMARY="$(primary_registry)"
SECONDARY="$(secondary_registry)"
# The publishes above read the version from the image they pushed, so resolve it
# the same way here when the release tag family is in play.
FRAPPE_VERSION="$(frappe_release_version_for_run)"
PUBLISH_MOVING_TAGS="${PUBLISH_MOVING_TAGS:-1}"

# digest_set <registry> <label> <base-tag> <latest-tag> <granian-tag>
# Sets VERIFIED_BASE / VERIFIED_LATEST / VERIFIED_GRANIAN.
digest_set() {
  local registry="$1" label="$2" b_tag="$3" v_tag="$4" g_tag="$5" b v g
  b="$(imagetools_digest "${registry}/frappe:${b_tag}")"
  v="$(imagetools_digest "${registry}/frappe:${v_tag}")"
  g="$(imagetools_digest "${registry}/frappe:${g_tag}")"
  echo "[${label}] base           :${b_tag} -> $b"
  echo "[${label}] patched        :${v_tag} -> $v"
  echo "[${label}] granian        :${g_tag} -> $g"
  [ -n "$b" ] || { echo "  ${label} ${b_tag} digest empty"; exit 1; }
  [ -n "$v" ] || { echo "  ${label} ${v_tag} digest empty"; exit 1; }
  [ -n "$g" ] || { echo "  ${label} ${g_tag} digest empty"; exit 1; }
  [ "$b" != "$v" ] || { echo "  ${label} base and latest resolved to the SAME digest — check Dockerfile patch wiring"; exit 1; }
  [ "$v" != "$g" ] || { echo "  ${label} latest and granian resolved to the SAME digest — check BASE_IMAGE wiring"; exit 1; }
  [ "$b" != "$g" ] || { echo "  ${label} base and granian resolved to the SAME digest — unexpected"; exit 1; }
  VERIFIED_BASE="$b"; VERIFIED_LATEST="$v"; VERIFIED_GRANIAN="$g"
}

verify_one_registry() {
  local registry="$1" label="$2"
  local v_base="${FRAPPE_VERSION}-base" v_latest="${FRAPPE_VERSION}" v_granian="${FRAPPE_VERSION}-granian"
  local pv_base vv_base pv_latest vv_latest pv_granian vv_granian

  digest_set "$registry" "${label}/release" "$v_base" "$v_latest" "$v_granian"
  pv_base="$VERIFIED_BASE"; pv_latest="$VERIFIED_LATEST"; pv_granian="$VERIFIED_GRANIAN"

  [ "$PUBLISH_MOVING_TAGS" = "1" ] || return 0

  digest_set "$registry" "${label}/moving" base latest latest-granian
  vv_base="$VERIFIED_BASE"; vv_latest="$VERIFIED_LATEST"; vv_granian="$VERIFIED_GRANIAN"

  [ "$vv_base" = "$pv_base" ] || { echo "  ${label} :base differs from :${v_base} — moving tag moved independently"; exit 1; }
  [ "$vv_latest" = "$pv_latest" ] || { echo "  ${label} :latest differs from :${v_latest} — moving tag moved independently"; exit 1; }
  [ "$vv_granian" = "$pv_granian" ] || { echo "  ${label} :latest-granian differs from :${v_granian} — moving tag moved independently"; exit 1; }

  # Report the moving digests upward for the cross-registry comparison.
  VERIFIED_BASE="$vv_base"; VERIFIED_LATEST="$vv_latest"; VERIFIED_GRANIAN="$vv_granian"
}

P_BASE=""; P_LATEST=""; P_GRANIAN=""
if [ -n "$PRIMARY" ]; then
  verify_one_registry "$PRIMARY" primary
  P_BASE="$VERIFIED_BASE"; P_LATEST="$VERIFIED_LATEST"; P_GRANIAN="$VERIFIED_GRANIAN"
else
  echo "Primary registry not configured — verifying the secondary only"
fi

if [ -n "$SECONDARY" ]; then
  verify_one_registry "$SECONDARY" secondary
  if [ -n "$PRIMARY" ]; then
    [ "$VERIFIED_BASE" = "$P_BASE" ] || { echo "  secondary base digest differs from primary — not the same tested image"; exit 1; }
    [ "$VERIFIED_LATEST" = "$P_LATEST" ] || { echo "  secondary latest digest differs from primary — not the same tested image"; exit 1; }
    [ "$VERIFIED_GRANIAN" = "$P_GRANIAN" ] || { echo "  secondary granian digest differs from primary — not the same tested image"; exit 1; }
    echo "OK: ${PRIMARY} and ${SECONDARY} hold the same three distinct images"
  else
    echo "OK: ${SECONDARY} holds three distinct images"
  fi
else
  echo "Secondary registry not configured — verified ${PRIMARY} only"
fi
echo "OK: base, latest, and latest-granian variants are three distinct published images (Frappe ${FRAPPE_VERSION})"
