#!/usr/bin/env bash
# Resolve the IMMUTABLE digest of each published GHCR variant tag. Attestations
# and signatures are bound to a digest (not a mutable tag), so the attest/sign/
# verify jobs must address the exact bytes that were published. Writes a
# `digests_json` output (variant -> "sha256:...") to $GITHUB_OUTPUT.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SECONDARY="$(secondary_registry)"
: "${SECONDARY:?secondary registry (GHCR) required for supply-chain attestation}"

digest_of() {
  docker buildx imagetools inspect "$1" | awk '/^Digest:/ {print $2; exit}'
}

json=""
for variant in base latest latest-granian; do
  ref="${SECONDARY}/frappe:${variant}"
  digest="$(digest_of "$ref")"
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
