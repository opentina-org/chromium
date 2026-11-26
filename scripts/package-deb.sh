#!/usr/bin/env bash
set -euo pipefail
umask 022

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../VERSION
source "${REPO_ROOT}/VERSION"

CACHE_DIR="${CHROMIUM_CACHE_DIR:-${REPO_ROOT}/build/cache}"
SRC_PARENT="${CHROMIUM_SRC_PARENT:-${CACHE_DIR}}"
SRC_DIR="${CHROMIUM_SRC_DIR:-${SRC_PARENT}/chromium-${CHROMIUM_VERSION}}"
OUT_DIR="${CHROMIUM_OUT_DIR:-${SRC_DIR}/out/Release-arm64}"
DIST_DIR="${CHROMIUM_DIST_DIR:-${REPO_ROOT}/dist}"
PKG_VER="${CHROMIUM_VERSION}-${DEB_REVISION}"
PKG_NAME="chromium_${PKG_VER}_arm64"
STAGE_DIR="${DIST_DIR}/${PKG_NAME}"

STRIP_BIN="${SRC_DIR}/third_party/llvm-build/Release+Asserts/bin/llvm-strip"
if [[ ! -x "${STRIP_BIN}" ]]; then
  STRIP_BIN="aarch64-linux-gnu-strip"
fi

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

found_v8_snapshot=0
for snap in v8_context_snapshot.bin snapshot_blob.bin; do
  if [[ -f "${OUT_DIR}/${snap}" ]]; then
    cp -a "${OUT_DIR}/${snap}" "${STAGE_DIR}/usr/lib/chromium/"
    found_v8_snapshot=1
  fi
done
if [[ "${found_v8_snapshot}" -eq 0 ]]; then
  echo "Error: Missing V8 snapshot binary (v8_context_snapshot.bin / snapshot_blob.bin) in ${OUT_DIR}" >&2
  exit 1
fi

cp -a "${OUT_DIR}/icudtl.dat" "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}"/chrome_*.pak "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}/resources.pak" "${STAGE_DIR}/usr/lib/chromium/"
cp -a "${OUT_DIR}/locales"/*.pak "${STAGE_DIR}/usr/lib/chromium/locales/"

if [[ -d "${OUT_DIR}/MEIPreload" ]]; then
  cp -a "${OUT_DIR}/MEIPreload" "${STAGE_DIR}/usr/lib/chromium/"
fi

echo "[2/4] Stripping ELF binaries and setting default sandbox permissions..."
"${STRIP_BIN}" --strip-unneeded \
  "${STAGE_DIR}/usr/lib/chromium/chromium" \
  "${STAGE_DIR}/usr/lib/chromium/chrome-sandbox" \
  "${STAGE_DIR}/usr/lib/chromium/chrome_crashpad_handler"
for sofile in "${STAGE_DIR}/usr/lib/chromium"/*.so*; do
  if [[ -f "${sofile}" && ! -L "${sofile}" ]]; then
    "${STRIP_BIN}" --strip-unneeded "${sofile}"
  fi
done
# Set 4755 in package payload (owned by root:root via dpkg-deb --root-owner-group)
# so dpkg preserves local dpkg-statoverride settings across upgrades.
chmod 4755 "${STAGE_DIR}/usr/lib/chromium/chrome-sandbox"

install -m 0755 "${REPO_ROOT}/packaging/chromium-launcher.sh" "${STAGE_DIR}/usr/bin/chromium"
ln -sf chromium "${STAGE_DIR}/usr/bin/chromium-browser"
install -m 0644 "${REPO_ROOT}/packaging/etc-chromium.d/10-opentina-gpu" "${STAGE_DIR}/etc/chromium.d/10-opentina-gpu"
install -m 0644 "${REPO_ROOT}/packaging/chromium.desktop" "${STAGE_DIR}/usr/share/applications/chromium.desktop"

if [[ -f "${SRC_DIR}/chrome/app/theme/chromium/product_logo_256.png" ]]; then
  install -m 0644 "${SRC_DIR}/chrome/app/theme/chromium/product_logo_256.png" \
    "${STAGE_DIR}/usr/share/icons/hicolor/256x256/apps/chromium.png"
fi

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
Depends: libc6 (>= 2.31), libglib2.0-0t64 | libglib2.0-0, libnss3, libnspr4, libdbus-1-3, libatk1.0-0t64 | libatk1.0-0, libatk-bridge2.0-0t64 | libatk-bridge2.0-0, libatspi2.0-0t64 | libatspi2.0-0, libcups2t64 | libcups2, libdrm2, libgbm1, libexpat1, libxcb1, libxkbcommon0, libx11-6, libxcomposite1, libxdamage1, libxext6, libxfixes3, libxrandr2, libpango-1.0-0, libcairo2, libasound2t64 | libasound2, libudev1, ca-certificates, fonts-liberation | fonts-dejavu-core
Recommends: libegl1, libgles2, mesa-vulkan-drivers
Provides: chromium-browser, chromium-common, chromium-sandbox, www-browser
Conflicts: chromium-common, chromium-sandbox, chromium-l10n, chromium-browser-sunxi
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

echo "[4/4] Building ${DIST_DIR}/${PKG_NAME}.deb..."
mkdir -p "${DIST_DIR}"
dpkg-deb --root-owner-group -Zxz -z6 --build "${STAGE_DIR}" "${DIST_DIR}/${PKG_NAME}.deb"
(cd "${DIST_DIR}" && sha256sum "${PKG_NAME}.deb" > "${PKG_NAME}.deb.sha256")

echo "Verify DT_NEEDED of /usr/lib/chromium/chromium:"
aarch64-linux-gnu-readelf -d "${STAGE_DIR}/usr/lib/chromium/chromium" | grep NEEDED || true
ls -lh "${DIST_DIR}/${PKG_NAME}.deb"
cat "${DIST_DIR}/${PKG_NAME}.deb.sha256"
