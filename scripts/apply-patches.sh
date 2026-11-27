#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="$(realpath -m "${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}")"
SRC_PARENT="$(realpath -m "${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}")"
SRC_DIR="$(realpath -m "${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}")"
STAMP_FILE="${SRC_DIR}/.opentina-patches-applied"
LOCK_FILE="${SRC_DIR}/.opentina-patch.lock"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: Chromium source tree not found at ${SRC_DIR}" >&2
  exit 1
fi

exec 9>"${LOCK_FILE}"
flock 9

PATCH_FILES=()
while IFS= read -r patch_name || [[ -n "${patch_name}" ]]; do
  [[ -z "${patch_name}" || "${patch_name}" =~ ^# ]] && continue
  PATCH_FILES+=("${REPO_ROOT}/patches/${patch_name}")
done < "${REPO_ROOT}/patches/series"

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

if [[ "${#PATCH_FILES[@]}" -gt 0 ]]; then
  # Validate all patches in a temporary copy of touched files first so a later
  # hunk failure never leaves earlier files half-patched on disk.
  TMP_CHECK="$(mktemp -d)"
  trap 'rm -rf "${TMP_CHECK}"' EXIT
  echo "Validating OpenTina patch series atomically..."
  for patch_file in "${PATCH_FILES[@]}"; do
    while IFS= read -r rel_path; do
      [[ -z "${rel_path}" ]] && continue
      if [[ -f "${SRC_DIR}/${rel_path}" && ! -f "${TMP_CHECK}/${rel_path}" ]]; then
        mkdir -p "${TMP_CHECK}/$(dirname "${rel_path}")"
        cp -a "${SRC_DIR}/${rel_path}" "${TMP_CHECK}/${rel_path}"
      fi
    done < <(sed -n 's|^--- a/||p; s|^+++ b/||p' "${patch_file}" | grep -v '^/dev/null$' | sort -u)
    patch -d "${TMP_CHECK}" -p1 --forward --silent < "${patch_file}"
  done
  rm -rf "${TMP_CHECK}"
  trap - EXIT

  echo "Applying OpenTina patches from ${REPO_ROOT}/patches/series..."
  for patch_file in "${PATCH_FILES[@]}"; do
    echo "  -> $(basename "${patch_file}")"
    patch -d "${SRC_DIR}" -p1 --forward < "${patch_file}"
  done
fi

echo "${EXPECTED_DIGEST}" > "${STAMP_FILE}"
echo "All patches applied cleanly (digest ${EXPECTED_DIGEST})."
