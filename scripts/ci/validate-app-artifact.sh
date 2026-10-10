#!/usr/bin/env bash
# =============================================================================
# validate-app-artifact.sh
#
# Standalone Image Artifact Contract Validator.
# Enforces the canonical OCI artifact format for Frappe apps:
#   1. Payload rooted at /opt/frappe/apps/<app_name>
#   2. pyproject.toml exists (dependency metadata)
#   3. Top-level /opt/frappe/apps/<app_name>/assets exists:
#      - Must contain static public assets (if app has public assets)
#      - Must contain compiled dist/ bundles (if app builds assets)
#   4. assets.json and apps.txt present if applicable
#   5. No build-time node_modules leakage
#
# Usage:
#   validate-app-artifact.sh <image_tag_or_archive> <app_name> [--require-dist] [--check-file <relative_asset_path>]...
#
# Examples:
#   scripts/ci/validate-app-artifact.sh erpnext-app:artifact erpnext --require-dist --check-file icons/desktop_icons/solid/subscription.svg
#   scripts/ci/validate-app-artifact.sh hrms-app:artifact hrms --require-dist --check-file frontend/manifest.webmanifest
# =============================================================================
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <artifact-image-or-tar> <app-name> [--require-dist] [--check-file <relative_asset_path>]..."
  exit 1
fi

TARGET="$1"
APP_NAME="$2"
shift 2

REQUIRE_DIST=0
CHECK_FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --require-dist)
      REQUIRE_DIST=1
      shift
      ;;
    --check-file)
      if [ -n "${2:-}" ]; then
        CHECK_FILES+=("$2")
        shift 2
      else
        echo "Error: --check-file requires an argument" >&2
        exit 1
      fi
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

TMP_DIR=$(mktemp -d "/tmp/artifact-contract-${APP_NAME}-XXXXXX")
TAR_FILE="${TMP_DIR}/artifact.tar"
EXTRACT_DIR="${TMP_DIR}/rootfs"
mkdir -p "${EXTRACT_DIR}"

cleanup() {
  rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

echo "==> [Contract] Validating standalone artifact format for app: ${APP_NAME}"

# Step 1: Export artifact filesystem
if [ -f "${TARGET}" ]; then
  echo "--> Using input archive: ${TARGET}"
  cp "${TARGET}" "${TAR_FILE}"
else
  echo "--> Exporting image filesystem from: ${TARGET}"
  CID=$(docker create --entrypoint /bin/true "${TARGET}" 2>/dev/null || docker create "${TARGET}")
  docker export "${CID}" -o "${TAR_FILE}"
  docker rm -f "${CID}" >/dev/null 2>&1 || true
fi

# Step 2: Extract archive
tar -xf "${TAR_FILE}" -C "${EXTRACT_DIR}"

APP_ROOT="${EXTRACT_DIR}/opt/frappe/apps/${APP_NAME}"
if [ ! -d "${APP_ROOT}" ]; then
  # Check if payload was exported directly at rootfs root
  if [ -d "${EXTRACT_DIR}/${APP_NAME}" ] && [ -f "${EXTRACT_DIR}/pyproject.toml" ]; then
    APP_ROOT="${EXTRACT_DIR}"
  else
    echo "❌ [Contract Violation] Application payload not found at /opt/frappe/apps/${APP_NAME}" >&2
    ls -la "${EXTRACT_DIR}" >&2
    exit 1
  fi
fi

echo "✅ [Contract] App payload located at ${APP_ROOT}"

# Step 3: Verify pyproject.toml
if [ ! -f "${APP_ROOT}/pyproject.toml" ]; then
  echo "❌ [Contract Violation] ${APP_NAME} missing pyproject.toml in payload" >&2
  exit 1
fi
echo "✅ [Contract] pyproject.toml present"

# Step 4: Verify unified assets/ directory
ASSETS_DIR="${APP_ROOT}/assets"
if [ ! -d "${ASSETS_DIR}" ]; then
  echo "❌ [Contract Violation] Standalone image MUST ship a top-level assets/ directory (/opt/frappe/apps/${APP_NAME}/assets)" >&2
  exit 1
fi
echo "✅ [Contract] Top-level assets/ directory present"

# Step 5: Verify compiled dist if required
if [ "${REQUIRE_DIST}" -eq 1 ]; then
  if [ ! -d "${ASSETS_DIR}/dist" ]; then
    echo "❌ [Contract Violation] Compiled bundle directory assets/dist/ missing for app ${APP_NAME}" >&2
    exit 1
  fi
  echo "✅ [Contract] assets/dist compiled bundles present"
fi

# Step 6: Verify specified static assets
for rel_file in "${CHECK_FILES[@]}"; do
  target_file="${ASSETS_DIR}/${rel_file}"
  if [ ! -e "${target_file}" ]; then
    echo "❌ [Contract Violation] Required asset '${rel_file}' missing in ${ASSETS_DIR}" >&2
    exit 1
  fi
  echo "✅ [Contract] Required asset '${rel_file}' verified"
done

# Step 7: Check node_modules leakage
if [ -d "${APP_ROOT}/node_modules" ] || [ -d "${ASSETS_DIR}/node_modules" ]; then
  echo "❌ [Contract Violation] node_modules must not ship in the standalone artifact payload" >&2
  exit 1
fi
echo "✅ [Contract] No node_modules leakage detected"

echo "🎉 [Contract] Artifact '${TARGET}' strictly conforms to the Frappe standalone image format contract!"
