#!/usr/bin/env bash
# Shared helpers for the security-scanning CI steps (Trivy + Semgrep).
# Source this (`source scripts/ci/security-lib.sh`), don't execute it.
#
# Provides:
#   * `install_trivy`    -- install a pinned, checksum-verified Trivy binary into
#                           $RUNNER_TEMP (or /tmp locally) and put it on PATH.
#   * `install_semgrep`  -- install Semgrep into an isolated virtualenv.
#   * `sarif_dir`        -- print/create the directory SARIF reports are written to.
#
# All tools are version-pinned via env vars (with sane defaults) so CI runs are
# reproducible and upgrades are explicit:
#   TRIVY_VERSION   (default 0.74.0)
#   SEMGREP_VERSION (default: empty -> latest release)
# The only network access is the tool download performed HERE; the scans
# themselves consume already-built local images and the checked-out source.
set -euo pipefail

SECURITY_SARIF_DIR="${SECURITY_SARIF_DIR:-security-results}"

sarif_dir() {
  mkdir -p "$SECURITY_SARIF_DIR"
  printf '%s' "$SECURITY_SARIF_DIR"
}

# download_release_asset <url> <dest> <tag> <repo> -- download a GitHub release
# asset with bounded retries, then fall back to the GitHub CLI (which resolves
# assets through the API rather than the release CDN). GitHub's release CDN
# intermittently answers 5xx for minutes at a time, which must not fail a scan
# before it even starts.
download_release_asset() {
  local url="$1" dest="$2" tag="$3" repo="$4" attempt file tmp
  file="$(basename "$dest")"

  for attempt in 1 2 3; do
    if curl -fsSL --connect-timeout 20 --max-time 600 \
        --retry 2 --retry-delay 2 --retry-all-errors \
        "$url" -o "$dest"; then
      return 0
    fi
    echo "download failed (attempt ${attempt}/3): ${file}" >&2
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3)) || true
  done

  command -v gh >/dev/null 2>&1 || return 1
  echo "retrying ${file} via 'gh release download ${tag}'" >&2
  tmp="$(mktemp -d)"
  if gh release download "$tag" --repo "$repo" --pattern "$file" --dir "$tmp" >&2; then
    mv "$tmp/$file" "$dest"
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  return 1
}

# install_trivy -- downloads the pinned Trivy release tarball, verifies it
# against the published SHA-256 checksum, and installs the binary.
install_trivy() {
  if command -v trivy >/dev/null 2>&1; then
    echo "Trivy already present: $(trivy --version | head -n1)"
    return 0
  fi

  local version="${TRIVY_VERSION:-0.74.0}"
  local dest="${RUNNER_TEMP:-/tmp}/trivy-bin"
  local os arch asset base checksums
  os="$(uname -s)"; arch="$(uname -m)"
  case "$os" in
    Linux)  os="Linux" ;;
    Darwin) os="macOS" ;;
    *) echo "Unsupported OS for Trivy install: $os" >&2; exit 1 ;;
  esac
  case "$arch" in
    x86_64|amd64) arch="64bit" ;;
    aarch64|arm64) arch="ARM64" ;;
    *) echo "Unsupported arch for Trivy install: $arch" >&2; exit 1 ;;
  esac

  asset="trivy_${version}_${os}-${arch}.tar.gz"
  base="https://github.com/aquasecurity/trivy/releases/download/v${version}"
  checksums="trivy_${version}_checksums.txt"

  mkdir -p "$dest"
  echo "Installing Trivy ${version} (${asset})"
  download_release_asset "${base}/${asset}" "$dest/$asset" "v${version}" aquasecurity/trivy \
    || { echo "could not download ${asset}" >&2; return 1; }
  download_release_asset "${base}/${checksums}" "$dest/$checksums" "v${version}" aquasecurity/trivy \
    || { echo "could not download ${checksums}" >&2; return 1; }
  ( cd "$dest" && grep -F "$asset" "$checksums" > "${asset}.sha256" \
      && sha256sum -c "${asset}.sha256" )
  tar -xzf "$dest/$asset" -C "$dest" trivy
  chmod +x "$dest/trivy"
  echo "$dest" >> "${GITHUB_PATH:-/dev/null}" 2>/dev/null || true
  export PATH="$dest:$PATH"
  echo "Installed: $(trivy --version | head -n1)"
}

# install_semgrep -- installs Semgrep into a throwaway virtualenv so the scan
# never pollutes the Docker build environment or the checked-out tree.
install_semgrep() {
  if command -v semgrep >/dev/null 2>&1; then
    echo "Semgrep already present: $(semgrep --version)"
    return 0
  fi

  local venv="${RUNNER_TEMP:-/tmp}/semgrep-venv"
  local spec="semgrep"
  [ -n "${SEMGREP_VERSION:-}" ] && spec="semgrep==${SEMGREP_VERSION}"

  echo "Installing ${spec} into ${venv}"
  python3 -m venv "$venv"
  "$venv/bin/pip" install --quiet --upgrade pip
  "$venv/bin/pip" install --quiet "$spec"
  echo "$venv/bin" >> "${GITHUB_PATH:-/dev/null}" 2>/dev/null || true
  export PATH="$venv/bin:$PATH"
  echo "Installed: $(semgrep --version)"
}
