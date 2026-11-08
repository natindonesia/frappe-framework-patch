#!/usr/bin/env bash
# install-cosign.sh -- install a pinned cosign release binary for CI.
#
# Replaces sigstore/cosign-installer so the download goes through the shared
# retry + GitHub-CLI fallback path: GitHub's release CDN intermittently answers
# 5xx, and an installer failure there aborts attestation before it starts.
#
# Usage: COSIGN_VERSION=v3.1.3 bash scripts/ci/install-cosign.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=security-lib.sh
source scripts/ci/security-lib.sh

version="${COSIGN_VERSION:?set COSIGN_VERSION (e.g. v3.1.3)}"
[[ "$version" == v* ]] || version="v${version}"

case "$(uname -m)" in
  x86_64|amd64) asset="cosign-linux-amd64" ;;
  aarch64|arm64) asset="cosign-linux-arm64" ;;
  *) echo "Unsupported arch for cosign install: $(uname -m)" >&2; exit 1 ;;
esac

dest="${RUNNER_TEMP:-/tmp}/cosign-bin"
mkdir -p "$dest"
base="https://github.com/sigstore/cosign/releases/download/${version}"

echo "Installing cosign ${version} (${asset})"
download_release_asset "${base}/${asset}" "$dest/$asset" "$version" sigstore/cosign \
  || { echo "could not download ${asset}" >&2; exit 1; }
download_release_asset "${base}/cosign_checksums.txt" "$dest/cosign_checksums.txt" \
  "$version" sigstore/cosign \
  || { echo "could not download cosign checksums" >&2; exit 1; }

( cd "$dest" \
    && grep -E "^[0-9a-f]{64}  ${asset}$" cosign_checksums.txt > "${asset}.sha256" \
    && sha256sum -c "${asset}.sha256" )
mv "$dest/$asset" "$dest/cosign"
chmod +x "$dest/cosign"
echo "$dest" >> "${GITHUB_PATH:-/dev/null}" 2>/dev/null || true
export PATH="$dest:$PATH"
echo "Installed: $(cosign version 2>/dev/null | awk '/GitVersion/ {print $2}')"
