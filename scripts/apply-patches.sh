#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="$(realpath -m "${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}")"
SRC_PARENT="$(realpath -m "${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}")"
SRC_DIR="$(realpath -m "${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}")"
STAMP_FILE="${SRC_DIR}/.opentina-patches-applied"
BACKUP_DIR="${SRC_DIR}/.opentina-patch-backup"
LOCK_FILE="${SRC_DIR}/.opentina-patch.lock"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: Chromium source tree not found at ${SRC_DIR}" >&2
  exit 1
fi

if [[ "${OPENTINA_PATCH_LOCK_HELD:-0}" != "1" ]]; then
  exec 9>"${LOCK_FILE}"
  flock 9
fi

restore_from_backup() {
  echo "Restoring pristine source files from ${BACKUP_DIR}..."
  if [[ -d "${BACKUP_DIR}/orig" ]]; then
    (
      cd "${BACKUP_DIR}/orig"
      find . -type f -print0 | while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        mkdir -p "${SRC_DIR}/$(dirname "${rel}")"
        cp -f "${BACKUP_DIR}/orig/${rel}" "${SRC_DIR}/${rel}"
        # Refresh mtime so Ninja rebuilds objects for files no longer patched.
        touch "${SRC_DIR}/${rel}"
      done
    )
  fi
  if [[ -f "${BACKUP_DIR}/created" ]]; then
    while IFS= read -r rel || [[ -n "${rel}" ]]; do
      [[ -z "${rel}" ]] && continue
      rm -f "${SRC_DIR}/${rel}"
    done < "${BACKUP_DIR}/created"
  fi
  rm -f "${STAMP_FILE}"
  rm -rf "${BACKUP_DIR}"
}

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
  if [[ -f "${BACKUP_DIR}/ready" ]]; then
    echo "Patch series digest changed (${APPLIED_DIGEST} -> ${EXPECTED_DIGEST}); rolling back before re-applying."
    restore_from_backup
  else
    echo "Error: Patch series digest changed (applied=${APPLIED_DIGEST}, current=${EXPECTED_DIGEST})." >&2
    echo "Remove ${SRC_DIR} and re-run scripts/fetch-source.sh to apply updated patches cleanly." >&2
    exit 1
  fi
elif [[ -d "${BACKUP_DIR}" ]]; then
  if [[ -f "${BACKUP_DIR}/ready" ]]; then
    echo "Detected interrupted patch application; restoring backup before retrying."
    restore_from_backup
  else
    rm -rf "${BACKUP_DIR}"
  fi
fi

TOUCHED_PATHS=()
if [[ "${#PATCH_FILES[@]}" -gt 0 ]]; then
  while IFS= read -r rel_path; do
    [[ -z "${rel_path}" ]] && continue
    TOUCHED_PATHS+=("${rel_path}")
  done < <(
    for patch_file in "${PATCH_FILES[@]}"; do
      sed -n 's|^--- a/||p; s|^+++ b/||p' "${patch_file}"
    done | grep -v '^/dev/null$' | sort -u
  )

  # Populate a temporary copy of all touched paths once, then validate the
  # entire patch series in order (including delete-then-recreate sequences).
  TMP_CHECK="$(mktemp -d)"
  trap 'rm -rf "${TMP_CHECK}"' EXIT
  echo "Validating OpenTina patch series atomically..."
  for rel_path in "${TOUCHED_PATHS[@]}"; do
    if [[ -f "${SRC_DIR}/${rel_path}" ]]; then
      mkdir -p "${TMP_CHECK}/$(dirname "${rel_path}")"
      cp -a "${SRC_DIR}/${rel_path}" "${TMP_CHECK}/${rel_path}"
    fi
  done
  for patch_file in "${PATCH_FILES[@]}"; do
    patch -d "${TMP_CHECK}" -p1 --forward --silent < "${patch_file}"
  done
  rm -rf "${TMP_CHECK}"
  trap - EXIT
fi

# Always initialize backup/ready (even for an empty patch series) so subsequent
# additions or modifications to patches/series can roll back and re-apply cleanly.
rm -rf "${BACKUP_DIR}"
mkdir -p "${BACKUP_DIR}/orig"
: > "${BACKUP_DIR}/created"
for rel_path in "${TOUCHED_PATHS[@]}"; do
  if [[ -f "${SRC_DIR}/${rel_path}" ]]; then
    mkdir -p "${BACKUP_DIR}/orig/$(dirname "${rel_path}")"
    cp -a "${SRC_DIR}/${rel_path}" "${BACKUP_DIR}/orig/${rel_path}"
  else
    echo "${rel_path}" >> "${BACKUP_DIR}/created"
  fi
done
touch "${BACKUP_DIR}/ready"

if [[ "${#PATCH_FILES[@]}" -gt 0 ]]; then
  echo "Applying OpenTina patches from ${REPO_ROOT}/patches/series..."
  for patch_file in "${PATCH_FILES[@]}"; do
    echo "  -> $(basename "${patch_file}")"
    patch -d "${SRC_DIR}" -p1 --forward < "${patch_file}"
  done
fi

echo "${EXPECTED_DIGEST}" > "${STAMP_FILE}.tmp"
mv -f "${STAMP_FILE}.tmp" "${STAMP_FILE}"
echo "All patches applied cleanly (digest ${EXPECTED_DIGEST})."
