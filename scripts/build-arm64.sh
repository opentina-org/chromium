#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="$(realpath -m "${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}")"
SRC_PARENT="$(realpath -m "${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}")"
SRC_DIR="$(realpath -m "${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}")"
OUT_DIR="$(realpath -m "${CHROMIUM_OUT_DIR:-${SRC_DIR}/out/Release-arm64}")"
JOBS="${NINJA_JOBS:-8}"

if [[ ! -d "${SRC_DIR}" ]]; then
  echo "Error: Source directory not found at ${SRC_DIR}. Run scripts/fetch-source.sh first." >&2
  exit 1
fi

"${REPO_ROOT}/scripts/apply-patches.sh"

mkdir -p "${OUT_DIR}"
OUT_LOCK_FILE="${OUT_DIR}/.opentina-build.lock"
exec 9>"${OUT_LOCK_FILE}"
flock 9

cp "${REPO_ROOT}/config/args.arm64.gn" "${OUT_DIR}/args.gn"

cd "${SRC_DIR}"
echo "[1/2] Generating Ninja build files in ${OUT_DIR}..."
./buildtools/linux64/gn gen "${OUT_DIR}"

echo "[2/2] Building Chromium arm64 targets (-j${JOBS})..."
ninja -C "${OUT_DIR}" -j"${JOBS}" \
  chrome \
  chrome_sandbox \
  chrome_crashpad_handler

echo "Build complete: ${OUT_DIR}/chrome"
