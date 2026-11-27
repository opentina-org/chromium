#!/usr/bin/env bash
set -euo pipefail
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="$(realpath -m "${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}")"
SRC_PARENT="$(realpath -m "${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}")"
SRC_DIR="$(realpath -m "${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}")"
OUT_DIR="$(realpath -m "${CHROMIUM_OUT_DIR:-${SRC_DIR}/out/Release-arm64}")"
DIST_DIR="$(realpath -m "${CHROMIUM_DIST_DIR:-${REPO_ROOT}/dist}")"
PKG_VER="${CHROMIUM_VERSION}-${DEB_REVISION}"
PKG_NAME="chromium_${PKG_VER}_arm64"
STAGE_DIR="${DIST_DIR}/${PKG_NAME}"

STRIP_BIN="${SRC_DIR}/third_party/llvm-build/Release+Asserts/bin/llvm-strip"
if [[ ! -x "${STRIP_BIN}" ]]; then
  STRIP_BIN="aarch64-linux-gnu-strip"
fi

if [[ ! -d "${OUT_DIR}" ]]; then
  echo "Error: Build output directory not found at ${OUT_DIR}" >&2
  exit 1
fi

mkdir -p "${DIST_DIR}"
LOCK_FILE="${DIST_DIR}/.${PKG_NAME}.lock"
exec 9>"${LOCK_FILE}"
flock 9

# Hold a shared lock on OUT_DIR while verifying and copying build outputs so an
# incremental build cannot overwrite binaries/resources mid-staging.
OUT_LOCK_FILE="${OUT_DIR}/.opentina-build.lock"
exec 8>"${OUT_LOCK_FILE}"
flock -s 8

if [[ ! -x "${OUT_DIR}/chrome" ]]; then
  echo "Error: Built binary not found at ${OUT_DIR}/chrome" >&2
  exit 1
fi

rm -rf "${STAGE_DIR}"
mkdir -p \
  "${STAGE_DIR}/DEBIAN" \
  "${STAGE_DIR}/usr/bin" \
  "${STAGE_DIR}/usr/lib/chromium/locales" \
  "${STAGE_DIR}/etc/chromium.d" \
  "${STAGE_DIR}/usr/share/applications" \
  "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps"

echo "[1/4] Staging binaries and resources..."
install -m 0755 "${OUT_DIR}/chrome" "${STAGE_DIR}/usr/lib/chromium/chromium"
install -m 0755 "${OUT_DIR}/chrome_sandbox" "${STAGE_DIR}/usr/lib/chromium/chrome-sandbox"
install -m 0755 "${OUT_DIR}/chrome_crashpad_handler" "${STAGE_DIR}/usr/lib/chromium/chrome_crashpad_handler"

for shlib in libEGL.so libGLESv2.so libvk_swiftshader.so libvulkan.so.1; do
  if [[ -f "${OUT_DIR}/${shlib}" ]]; then
    cp -a "${OUT_DIR}/${shlib}" "${STAGE_DIR}/usr/lib/chromium/"
  fi
done
[[ -f "${OUT_DIR}/vk_swiftshader_icd.json" ]] && cp -a "${OUT_DIR}/vk_swiftshader_icd.json" "${STAGE_DIR}/usr/lib/chromium/"

V8_BUILDFLAGS_HEADER="${OUT_DIR}/gen/tools/v8_context_snapshot/buildflags.h"
require_ctx_snap=1
require_blob_snap=0
ctx_snap_name="v8_context_snapshot.bin"
if [[ -f "${V8_BUILDFLAGS_HEADER}" ]]; then
  if grep -q 'BUILDFLAG_INTERNAL_USE_V8_CONTEXT_SNAPSHOT() (0)' "${V8_BUILDFLAGS_HEADER}"; then
    require_ctx_snap=0
    require_blob_snap=1
  fi
  if grep -q 'BUILDFLAG_INTERNAL_INCLUDE_BOTH_V8_SNAPSHOTS() (1)' "${V8_BUILDFLAGS_HEADER}"; then
    require_blob_snap=1
  fi
  parsed_snap_name="$(sed -n 's/.*BUILDFLAG_INTERNAL_V8_CONTEXT_SNAPSHOT_FILENAME() ("\([^"]*\)").*/\1/p' "${V8_BUILDFLAGS_HEADER}")"
  if [[ -n "${parsed_snap_name}" ]]; then
    ctx_snap_name="${parsed_snap_name}"
  fi
fi

if [[ "${require_ctx_snap}" -eq 1 ]]; then
  if [[ ! -f "${OUT_DIR}/${ctx_snap_name}" ]]; then
    echo "Error: Required V8 context snapshot ${OUT_DIR}/${ctx_snap_name} is missing." >&2
    exit 1
  fi
  cp -a "${OUT_DIR}/${ctx_snap_name}" "${STAGE_DIR}/usr/lib/chromium/"
fi
if [[ "${require_blob_snap}" -eq 1 ]]; then
  if [[ ! -f "${OUT_DIR}/snapshot_blob.bin" ]]; then
    echo "Error: Required V8 snapshot ${OUT_DIR}/snapshot_blob.bin is missing." >&2
    exit 1
  fi
  cp -a "${OUT_DIR}/snapshot_blob.bin" "${STAGE_DIR}/usr/lib/chromium/"
elif [[ -f "${OUT_DIR}/snapshot_blob.bin" ]]; then
  cp -a "${OUT_DIR}/snapshot_blob.bin" "${STAGE_DIR}/usr/lib/chromium/"
fi

cp -a "${OUT_DIR}/icudtl.dat" "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}"/chrome_*.pak "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}/resources.pak" "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}/locales"/*.pak "${STAGE_DIR}/usr/lib/chromium/locales/"

if [[ -d "${OUT_DIR}/MEIPreload" ]]; then
  cp -a "${OUT_DIR}/MEIPreload" "${STAGE_DIR}/usr/lib/chromium/"
fi

# Staging from OUT_DIR is complete; release shared build lock.
exec 8>&-

echo "[2/4] Stripping ELF binaries and normalizing payload permissions..."
"${STRIP_BIN}" --strip-unneeded \
  "${STAGE_DIR}/usr/lib/chromium/chromium" \
  "${STAGE_DIR}/usr/lib/chromium/chrome-sandbox" \
  "${STAGE_DIR}/usr/lib/chromium/chrome_crashpad_handler"
for sofile in "${STAGE_DIR}/usr/lib/chromium"/*.so*; do
  if [[ -f "${sofile}" && ! -L "${sofile}" ]]; then
    "${STRIP_BIN}" --strip-unneeded "${sofile}"
  fi
done

install -m 0755 "${REPO_ROOT}/packaging/chromium-launcher.sh" "${STAGE_DIR}/usr/bin/chromium"
ln -sf chromium "${STAGE_DIR}/usr/bin/chromium-browser"
install -m 0644 "${REPO_ROOT}/packaging/etc-chromium.d/10-opentina-gpu" "${STAGE_DIR}/etc/chromium.d/10-opentina-gpu"
install -m 0644 "${REPO_ROOT}/packaging/chromium.desktop" "${STAGE_DIR}/usr/share/applications/chromium.desktop"

if [[ -f "${SRC_DIR}/chrome/app/theme/chromium/product_logo_256.png" ]]; then
  install -m 0644 "${SRC_DIR}/chrome/app/theme/chromium/product_logo_256.png" \
    "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/chromium.png"
fi

# Explicitly normalize all directory/file modes so restrictive build umasks
# (such as 077) never produce root-only .pak / .bin resources.
find "${STAGE_DIR}" -type d -exec chmod 0755 {} +
find "${STAGE_DIR}/usr/lib/chromium" -type f -exec chmod 0644 {} +
chmod 0755 \
  "${STAGE_DIR}/usr/bin/chromium" \
  "${STAGE_DIR}/usr/lib/chromium/chromium" \
  "${STAGE_DIR}/usr/lib/chromium/chrome_crashpad_handler"
for sofile in "${STAGE_DIR}/usr/lib/chromium"/*.so*; do
  if [[ -f "${sofile}" && ! -L "${sofile}" ]]; then
    chmod 0755 "${sofile}"
  fi
done
# Set 4755 in package payload (owned by root:root via dpkg-deb --root-owner-group)
# so dpkg preserves local dpkg-statoverride settings across upgrades.
chmod 4755 "${STAGE_DIR}/usr/lib/chromium/chrome-sandbox"

echo "[3/4] Writing Debian/Ubuntu cross-distro control metadata..."
INSTALLED_KB="$(du -sk "${STAGE_DIR}/usr" "${STAGE_DIR}/etc" | awk '{sum+=$1} END {print sum}')"

cat > "${STAGE_DIR}/DEBIAN/control" <<EOF
Package: chromium
Version: ${PKG_VER}
Section: web
Priority: optional
Architecture: arm64
Installed-Size: ${INSTALLED_KB}
Maintainer: OpenTina Maintainers <maintainers@opentina.org>
Depends: libc6 (>= 2.31), libglib2.0-0t64 | libglib2.0-0, libgtk-3-0t64 | libgtk-3-0 | libgtk-4-1, libnss3, libnspr4, libdbus-1-3, libatk1.0-0t64 | libatk1.0-0, libatk-bridge2.0-0t64 | libatk-bridge2.0-0, libatspi2.0-0t64 | libatspi2.0-0, libcups2t64 | libcups2, libdrm2, libgbm1, libexpat1, libxcb1, libxkbcommon0, libx11-6, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxrandr2, libpango-1.0-0, libcairo2, libasound2t64 | libasound2, libudev1, xdg-utils (>= 1.0.2), ca-certificates, fonts-liberation | fonts-dejavu-core
Recommends: libegl1, libgles2, mesa-vulkan-drivers
Provides: chromium-browser, chromium-common, chromium-sandbox, www-browser
Conflicts: chromium-common, chromium-sandbox, chromium-l10n, chromium-browser, chromium-browser-sunxi
Replaces: chromium-common, chromium-sandbox, chromium-l10n, chromium-browser, chromium-browser-sunxi
Description: Chromium web browser for OpenTina ARM64 (with GLES2 fallback support)
 Universal ARM64 Chromium build linked against bundled third_party libraries
 and baseline glibc >= 2.31 for compatibility across Debian 12/13 and
 Ubuntu 22.04/24.04. Includes OpenTina EGL OpenGL ES 3.0 -> 2.0 fallback
 restoration so hardware GPU compositing and WebGL1 work over Mesa Zink on
 OpenGL ES 2.0 drivers (such as PowerVR Rogue/BXM).
EOF

cat > "${STAGE_DIR}/DEBIAN/conffiles" <<EOF
/etc/chromium.d/10-opentina-gpu
EOF
chmod 0644 "${STAGE_DIR}/DEBIAN/control" "${STAGE_DIR}/DEBIAN/conffiles"

echo "[4/4] Building ${DIST_DIR}/${PKG_NAME}.deb atomically..."
TMP_DEB="${DIST_DIR}/.${PKG_NAME}.deb.tmp"
TMP_SHA="${DIST_DIR}/.${PKG_NAME}.deb.sha256.tmp"
rm -f "${TMP_DEB}" "${TMP_SHA}"
trap 'rm -f "${TMP_DEB}" "${TMP_SHA}"' EXIT
DPKG_DEB_THREADS_MAX="${DPKG_DEB_THREADS_MAX:-8}" dpkg-deb --root-owner-group -Zxz -z6 --build "${STAGE_DIR}" "${TMP_DEB}"
DEB_SHA256="$(sha256sum "${TMP_DEB}" | awk '{print $1}')"
printf '%s  %s.deb\n' "${DEB_SHA256}" "${PKG_NAME}" > "${TMP_SHA}"
mv -f "${TMP_DEB}" "${DIST_DIR}/${PKG_NAME}.deb"
mv -f "${TMP_SHA}" "${DIST_DIR}/${PKG_NAME}.deb.sha256"
trap - EXIT

echo "Verify DT_NEEDED of /usr/lib/chromium/chromium:"
aarch64-linux-gnu-readelf -d "${STAGE_DIR}/usr/lib/chromium/chromium" | grep NEEDED || true
ls -lh "${DIST_DIR}/${PKG_NAME}.deb"
cat "${DIST_DIR}/${PKG_NAME}.deb.sha256"
