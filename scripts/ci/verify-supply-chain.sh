#!/usr/bin/env bash
# Hard-fail supply-chain gate. For every published variant, verify the keyless
# image signature AND both attestations (SLSA build provenance + SPDX SBOM)
# against the exact GHCR digest. The certificate identity is pinned to THIS
# repository's build-images.yml workflow, so a signature produced by any other
# workflow, repository, or issuer fails the gate.
set -euo pipefail
# shellcheck source=scripts/ci/common.sh
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

SECONDARY="$(secondary_registry)"
: "${SECONDARY:?secondary registry (GHCR) required for supply-chain verification}"
: "${DIGESTS_JSON:?DIGESTS_JSON required (from the publish job outputs)}"

ISSUER="https://token.actions.githubusercontent.com"
REPO="$(lower "${GITHUB_REPOSITORY:-natindonesia/frappe-framework-patch}")"
IDENTITY_REGEXP="^https://github\.com/${REPO}/\.github/workflows/build-images\.yml@"
# Exact predicate type URIs emitted by actions/attest (SLSA v1 provenance and
# the SPDX SBOM document). cosign's short aliases (slsaprovenance/spdxjson)
# resolve to DIFFERENT URIs and would not match.
SLSA_PREDICATE_TYPE="https://slsa.dev/provenance/v1"
SPDX_PREDICATE_TYPE="https://spdx.dev/Document/v2.3"

verify_variant() {
  local variant="$1" digest ref
  digest="$(printf '%s' "$DIGESTS_JSON" | jq -r --arg v "$variant" '.[$v]')"
  [ -n "$digest" ] && [ "$digest" != "null" ] || { echo "no digest for ${variant}"; exit 1; }
  ref="${SECONDARY}/frappe@${digest}"
  echo "== verify ${variant}: ${ref}"
  cosign verify \
    --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    "$ref"
  # verify-attestation prints the FULL attestation payload to stdout. The SPDX
  # SBOM for this image is ~18 MB on ONE line; streaming that through the
  # GitHub Actions log can stall the runner indefinitely. Verification
  # diagnostics/errors go to stderr and the exit code is authoritative, so
  # discard stdout.
  cosign verify-attestation --type "$SLSA_PREDICATE_TYPE" \
    --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    "$ref" >/dev/null
  cosign verify-attestation --type "$SPDX_PREDICATE_TYPE" \
    --certificate-oidc-issuer "$ISSUER" \
    --certificate-identity-regexp "$IDENTITY_REGEXP" \
    "$ref" >/dev/null
  echo "   OK ${variant}: signature + SLSA provenance + SPDX SBOM verified"
}

for variant in base latest latest-granian; do
  verify_variant "$variant"
done
echo "OK: all variants signed and attested (provenance + SPDX SBOM)"
