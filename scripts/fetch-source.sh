#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}"
SRC_PARENT="${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}"
SRC_DIR="${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}"
EXTRACT_PARENT="$(dirname "${SRC_DIR}")"
EXTRACT_STAMP="${SRC_DIR}/.opentina-extracted"
TARBALL_NAME="chromium-${CHROMIUM_VERSION}-${TARBALL_VARIANT}.tar.xz"
TARBALL_PATH="${CACHE_DIR}/${TARBALL_NAME}"
TARBALL_PART="${TARBALL_PATH}.part"
TARBALL_URL="https://commondatastorage.googleapis.com/chromium-browser-official/${TARBALL_NAME}"

mkdir -p "${CACHE_DIR}" "${EXTRACT_PARENT}"

echo "[1/4] Verifying or downloading ${TARBALL_NAME}..."
if [[ ! -f "${TARBALL_PATH}" ]] || ! echo "${TARBALL_SHA256}  ${TARBALL_PATH}" | sha256sum -c - >/dev/null 2>&1; then
  rm -f "${TARBALL_PATH}"
  for attempt in $(seq 1 10); do
    if curl -fL -C - --connect-timeout 15 --speed-time 20 --speed-limit 10000 \
         -o "${TARBALL_PART}" "${TARBALL_URL}"; then
      break
    fi
    echo "Download interrupted (attempt ${attempt}/10), retrying..."
    sleep 2
  done
  if ! echo "${TARBALL_SHA256}  ${TARBALL_PART}" | sha256sum -c -; then
    echo "Checksum mismatch on ${TARBALL_PART}; removing corrupted partial file." >&2
    rm -f "${TARBALL_PART}"
    exit 1
  fi
  mv -f "${TARBALL_PART}" "${TARBALL_PATH}"
fi

echo "[2/4] Extracting source tree to ${SRC_DIR}..."
if [[ ! -f "${EXTRACT_STAMP}" ]]; then
  rm -rf "${SRC_DIR}"
  tar -I "xz -T4" -xf "${TARBALL_PATH}" -C "${EXTRACT_PARENT}"
  if [[ ! -d "${SRC_DIR}" ]]; then
    echo "Error: Archive did not extract expected directory ${SRC_DIR}" >&2
    exit 1
  fi
  echo "${TARBALL_SHA256}" > "${EXTRACT_STAMP}"
fi

echo "[3/4] Installing matched Debian Bullseye amd64 + arm64 sysroots..."
cd "${SRC_DIR}"
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=arm64

echo "[4/4] Installing matched Clang, Rust, Node (${NODE_VERSION}), and Go (${GO_VERSION}) toolchains..."
python3 tools/clang/scripts/update.py
python3 tools/rust/update_rust.py

if [[ ! -x "third_party/node/linux/node-linux-x64/bin/node" ]]; then
  mkdir -p third_party/node/linux
  curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJf - -C third_party/node/linux
  rm -rf third_party/node/linux/node-linux-x64
  mv "third_party/node/linux/node-${NODE_VERSION}-linux-x64" third_party/node/linux/node-linux-x64
fi

if [[ ! -x "third_party/dawn/tools/golang/linux-amd64/bin/go" ]]; then
  mkdir -p third_party/dawn/tools/golang
  rm -rf third_party/dawn/tools/golang/go third_party/dawn/tools/golang/linux-amd64
  curl -fsSL "https://dl.google.com/go/go${GO_VERSION}.linux-amd64.tar.gz" \
    | tar -xzf - -C third_party/dawn/tools/golang
  mv third_party/dawn/tools/golang/go third_party/dawn/tools/golang/linux-amd64
fi

echo "Source and toolchains ready at: ${SRC_DIR}"
