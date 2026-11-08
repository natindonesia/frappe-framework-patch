#!/usr/bin/env bash
# install-syft.sh -- install a pinned syft release binary for CI.
#
# Replaces the syft installer bundled with anchore/sbom-action: that installer
# resolves the version by scraping the GitHub release page, which answers 5xx
# during the same release-CDN incidents that break the tarball downloads.
# Here the asset is fetched through the shared retry + GitHub-CLI fallback and
# verified against the published checksums.
#
# Usage: SYFT_VERSION=v1.52.0 bash scripts/ci/install-syft.sh
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=security-lib.sh
source scripts/ci/security-lib.sh

version="${SYFT_VERSION:?set SYFT_VERSION (e.g. v1.52.0)}"
[[ "$version" == v* ]] || version="v${version}"
number="${version#v}"

case "$(uname -m)" in
  x86_64|amd64) arch="amd64" ;;
  aarch64|arm64) arch="arm64" ;;
  *) echo "Unsupported arch for syft install: $(uname -m)" >&2; exit 1 ;;
esac

asset="syft_${number}_linux_${arch}.tar.gz"
checksums="syft_${number}_checksums.txt"
dest="${RUNNER_TEMP:-/tmp}/syft-bin"
mkdir -p "$dest"
base="https://github.com/anchore/syft/releases/download/${version}"

echo "Installing syft ${version} (${asset})"
download_release_asset "${base}/${asset}" "$dest/$asset" "$version" anchore/syft \
  || { echo "could not download ${asset}" >&2; exit 1; }
download_release_asset "${base}/${checksums}" "$dest/$checksums" "$version" anchore/syft \
  || { echo "could not download ${checksums}" >&2; exit 1; }

( cd "$dest" \
    && grep -E "^[0-9a-f]{64}  ${asset}$" "$checksums" > "${asset}.sha256" \
    && sha256sum -c "${asset}.sha256" )
tar -xzf "$dest/$asset" -C "$dest" syft
chmod +x "$dest/syft"
echo "$dest" >> "${GITHUB_PATH:-/dev/null}" 2>/dev/null || true
export PATH="$dest:$PATH"
echo "Installed: $(syft version | awk '/^Version:/ {print $2}')"
