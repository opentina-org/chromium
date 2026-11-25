#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}"
SRC_DIR="${CHROMIUM_SRC_DIR:-${CACHE_DIR}/chromium-${CHROMIUM_VERSION}}"
STAMP_FILE="${SRC_DIR}/.opentina-patches-applied"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: Chromium source tree not found at ${SRC_DIR}" >&2
  exit 1
fi

if [[ -f "${STAMP_FILE}" ]]; then
  echo "Patches already applied (${STAMP_FILE})."
  exit 0
fi

echo "Applying OpenTina patches from ${REPO_ROOT}/patches/series..."
while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
  [[ -z "${patch_name}" || "${patch_name}" =~ ^# ]] && continue
  patch_file="${REPO_ROOT}/patches/${patch_name}"
  echo "  -> ${patch_name}"
  patch -d "${SRC_DIR}" -p1 --forward < "${patch_file}"
done < "${REPO_ROOT}/patches/series"

date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STAMP_FILE}"
echo "All patches applied cleanly."
