#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}"
SRC_PARENT="${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}"
SRC_DIR="${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}"
STAMP_FILE="${SRC_DIR}/.opentina-patches-applied"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: Chromium source tree not found at ${SRC_DIR}" >&2
  exit 1
fi

EXPECTED_DIGEST="$(
  cd "${REPO_ROOT}"
  {
    cat patches/series
    while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
      [[ -z "${patch_name}" || "${patch_name}" =~ ^# ]] && continue
      sha256sum "patches/${patch_name}"
    done < patches/series
  } | sha256sum | awk '{print $1}'
)"

if [[ -f "${STAMP_FILE}" ]]; then
  APPLIED_DIGEST="$(cat "${STAMP_FILE}")"
  if [[ "${APPLIED_DIGEST}" == "${EXPECTED_DIGEST}" ]]; then
    echo "Patches already applied (digest ${EXPECTED_DIGEST})."
    exit 0
  fi
  echo "Error: Patch series digest changed (applied=${APPLIED_DIGEST}, current=${EXPECTED_DIGEST})." >&2
  echo "Remove ${SRC_DIR} and re-run scripts/fetch-source.sh to apply updated patches cleanly." >&2
  exit 1
fi

echo "Applying OpenTina patches from ${REPO_ROOT}/patches/series..."
while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
  [[ -z "${patch_name}" || "${patch_name}" =~ ^# ]] && continue
  patch_file="${REPO_ROOT}/patches/${patch_name}"
  echo "  -> ${patch_name}"
  patch -d "${SRC_DIR}" -p1 --forward < "${patch_file}"
done < "${REPO_ROOT}/patches/series"

echo "${EXPECTED_DIGEST}" > "${STAMP_FILE}"
echo "All patches applied cleanly (digest ${EXPECTED_DIGEST})."
