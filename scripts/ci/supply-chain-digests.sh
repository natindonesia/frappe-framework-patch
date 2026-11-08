#!/usr/bin/env bash
# Resolve the IMMUTABLE digest of each variant published by THIS run. The tags
# differ between a default-branch run (moving tags) and a release re-publish
# (immutable <version> tags), so the tag comes from `published_tag`. Attestations
# and signatures are bound to a digest (not a mutable tag), so the attest/sign/
# verify jobs must address the exact bytes that were published. Writes a
# `digests_json` output (variant -> "sha256:...") to $GITHUB_OUTPUT.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SECONDARY="$(secondary_registry)"
: "${SECONDARY:?secondary registry (GHCR) required for supply-chain attestation}"

# Release re-publishes address immutable <version> tags, which need the version.
# The moving-tag family (default-branch runs) does not.
if [ "${PUBLISH_MOVING_TAGS:-1}" != "1" ]; then
  frappe_release_version_for_run >/dev/null
fi

json=""
for variant in base latest latest-granian; do
  tag="$(published_tag "$variant")"
  ref="${SECONDARY}/frappe:${tag}"
  digest="$(imagetools_digest "$ref")"
  [ -n "$digest" ] || { echo "empty digest for ${ref}" >&2; exit 1; }
  echo "${variant} -> ${ref}@${digest}"
  json+="\"${variant}\":\"${digest}\","
done
json="{${json%,}}"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "digests_json=${json}" >> "$GITHUB_OUTPUT"
else
  echo "$json"
fi
