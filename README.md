# OpenTina Chromium (`arm64`)

Lightweight Chromium build, GPU patch queue, and cross-distro `arm64.deb` packaging repository for OpenTina platforms (such as Allwinner A733 / PowerVR BXM-4-64 MC1).

## Why This Repository Exists

On mainline open-source GPU stacks (`imagination` Vulkan + Mesa `zink` `26.1.x`), system EGL currently exposes **OpenGL ES 2.0** without `EGL_OPENGL_ES3_BIT_KHR`. Upstream Chromium 130+ disabled OpenGL ES `3.0 -> 2.0` context fallback inside `gpu_info_collector::InitializeGLContext()`, causing startup GPU info collection to abort when `eglCreateContext(3.0)` returns `EGL_BAD_ATTRIBUTE` and forcing the entire browser back to CPU software compositing (which also disables hardware WebGL1).

This repository maintains:

1. **Standalone Patch Queue (`patches/`)** — Restores `ES 3.0 -> ES 2.0` context fallback for GPU info collection and compositor contexts while keeping WebGL2 context requests strict (`getContext('webgl2')` cleanly returns `null` until Mesa/Zink exposes ES 3.0, while hardware GPU compositing and WebGL1 work immediately). Patches follow standard `-p1` quilt format so they can also be added directly to Yocto `meta-chromium` `SRC_URI`.
2. **Cross-Distro `arm64.deb` Packaging (`config/`, `packaging/`, `scripts/`)** — Cross-compiles Chromium with bundled `third_party` libraries against the baseline Debian Bullseye `arm64` sysroot (`glibc >= 2.31`), producing a **single `chromium_<ver>_arm64.deb`** that installs cleanly on **both Debian 12/13 and Ubuntu 22.04/24.04** without library SONAME conflicts or Snap shims.
3. **Default GPU Flags (`/etc/chromium.d/10-opentina-gpu`)** — Auto-selects `--ozone-platform=wayland` in Wayland sessions (and maps legacy `--ozone-platform-hint=x11|wayland` flags) while defaulting ANGLE to `--use-angle=gles-egl` unless overridden on the command line.

## Repository Layout

- `VERSION` — Pinned upstream Chromium version and source tarball SHA-256.
- `config/args.arm64.gn` — Release `arm64` GN configuration (`symbol_level=0`, `use_thin_lto=false`, `concurrent_links=1` to fit comfortably under 20 GiB RAM without swap).
- `patches/` — Quilt/BitBake-compatible patch series (`patches/series`).
- `packaging/` — `/usr/bin/chromium` wrapper, `/etc/chromium.d/10-opentina-gpu`, and desktop entry.
- `scripts/` — End-to-end fetch, patch, build, and `.deb` packaging scripts.

## Building Locally (x86_64 Linux Host -> arm64)

> **Note:** Full Chromium compilation requires ~45–65 CPU-hours and ~50 GB disk space, exceeding standard free GitHub-hosted runner limits (4 vCPU / 6h timeout). Build on an `x86_64` workstation or self-hosted runner and upload the resulting `.deb` to **GitHub Releases**.

```bash
# 1. Download & verify source tarball, sysroots, Clang, Rust, and Node
./scripts/fetch-source.sh

# 2. Cross-compile under bounded CPU/RAM scope (8 cores, 20 GiB RAM max)
systemd-run --user --scope -p MemoryMax=20G -p MemorySwapMax=0 -p CPUQuota=800% \
  env NINJA_JOBS=8 ./scripts/build-arm64.sh

# 3. Package universal arm64 .deb into dist/
./scripts/package-deb.sh
```

## Integrating into OpenTina Rootfs Builds

Place the released `chromium_<ver>_arm64.deb` into `$OPENTINA_OEM_DIR/packages/` when building `opentina-org/debian` or `opentina-org/ubuntu` desktop images, or install directly on target:

```bash
sudo apt-get install ./chromium_156.0.8078.79-1+opentina1_arm64.deb
```
