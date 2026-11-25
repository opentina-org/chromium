#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}"
SRC_PARENT="${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}"
SRC_DIR="${SRC_PARENT}/chromium-${CHROMIUM_VERSION}"
TARBALL_NAME="chromium-${CHROMIUM_VERSION}-${TARBALL_VARIANT}.tar.xz"
TARBALL_PATH="${CACHE_DIR}/${TARBALL_NAME}"
TARBALL_URL="https://commondatastorage.googleapis.com/chromium-browser-official/${TARBALL_NAME}"

mkdir -p "${CACHE_DIR}" "${SRC_PARENT}"

echo "[1/4] Verifying or downloading ${TARBALL_NAME}..."
if [[ ! -f "${TARBALL_PATH}" ]] || ! echo "${TARBALL_SHA256}  ${TARBALL_PATH}" | sha256sum -c - >/dev/null 2>&1; then
  for attempt in $(seq 1 10); do
    if curl -fL -C - --connect-timeout 15 --speed-time 20 --speed-limit 10000 \
         -o "${TARBALL_PATH}" "${TARBALL_URL}"; then
      break
    fi
    echo "Download interrupted (attempt ${attempt}/10), retrying..."
    sleep 2
  done
  echo "${TARBALL_SHA256}  ${TARBALL_PATH}" | sha256sum -c -
fi

echo "[2/4] Extracting source tree to ${SRC_DIR}..."
if [[ ! -f "${SRC_DIR}/chrome/VERSION" ]]; then
  tar -I "xz -T4" -xf "${TARBALL_PATH}" -C "${SRC_PARENT}"
fi

echo "[3/4] Installing matched Debian Bullseye amd64 + arm64 sysroots..."
cd "${SRC_DIR}"
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=arm64

echo "[4/4] Installing matched Clang, Rust, and Node (${NODE_VERSION}) toolchains..."
python3 tools/clang/scripts/update.py
python3 tools/rust/update_rust.py

if [[ ! -x "third_party/node/linux/node-linux-x64/bin/node" ]]; then
  mkdir -p third_party/node/linux
  curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJf - -C third_party/node/linux
  rm -rf third_party/node/linux/node-linux-x64
  mv "third_party/node/linux/node-${NODE_VERSION}-linux-x64" third_party/node/linux/node-linux-x64
fi

echo "Source and toolchains ready at: ${SRC_DIR}"
