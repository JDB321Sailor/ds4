# `dwarfstar4` — Arch / CachyOS package for DS4

This directory contains the `PKGBUILD` for the `dwarfstar4` package, an
Arch Linux / CachyOS native packaging of
[`antirez/ds4`](https://github.com/antirez/ds4) built for the ROCm
backend as a multi-arch fat binary.

For the full system setup (ROCm install, Limine kernel parameters for the
GTT aperture, etc.), see [`../CachyOS.md`](../CachyOS.md).

## TL;DR

```sh
# From the root of this repo:
cd arch
makepkg -s
sudo pacman -U dwarfstar4-*-x86_64.pkg.tar.zst
```

After install you get:

| Binary        | Path              |
| ------------- | ----------------- |
| `ds4`         | `/usr/bin/ds4`         |
| `ds4-server`  | `/usr/bin/ds4-server`  |
| `ds4-bench`   | `/usr/bin/ds4-bench`   |
| `ds4-eval`    | `/usr/bin/ds4-eval`    |
| `ds4-agent`   | `/usr/bin/ds4-agent`   |

Docs land under `/usr/share/doc/dwarfstar4/` and the license under
`/usr/share/licenses/dwarfstar4/LICENSE`.

## What the PKGBUILD does

- Fetches upstream `antirez/ds4` at a **pinned commit** (`_commit=` in the
  PKGBUILD) — even though the PKGBUILD lives in
  [`JDB321Sailor/ds4`](https://github.com/JDB321Sailor/ds4), the **source
  it builds** is always upstream. That keeps the package reproducible and
  decoupled from any fork-only changes.
- Runs `make strix-halo -j"$(nproc)"` which uses `hipcc`, ROCm offload
  arch flags, and links against `hipblas` / `hipblaslt` / `rocblas` /
  `rocwmma`.
- Builds ROCm offload code for `gfx1100 gfx1151` by default (RX 7900 XTX +
  Strix Halo). ROCm does not JIT-translate missing arch code objects at
  runtime, so the target arch must be present in the binary.
- Overrides `NATIVE_CPU_FLAG` to `-march=x86-64-v3` so the resulting
  package is portable across Zen 4 / Zen 5 boxes rather than locked to the
  exact build host.
- Installs five binaries with `install -Dm755`, plus license and Markdown
  docs.
- Installs model helpers:
  - `/usr/share/dwarfstar4/download_model.sh` (upstream downloader)
  - `/usr/bin/dwarfstar4-download-model` (package wrapper)

## Upgrading

1. Find the upstream commit you want:
   <https://github.com/antirez/ds4/commits/main>
2. Bump in `PKGBUILD`:
   - `_commit=<full 40-char SHA>`
   - `pkgver=0.r<7-char SHA>` (or let `pkgver()` recompute it on rebuild;
     the manual value is a fallback for offline builds)
   - `pkgrel=1` (reset to 1 on a `pkgver` bump; bump only `pkgrel` when
     you change packaging without changing upstream).
3. Rebuild and reinstall:
   ```sh
   makepkg -s -f
   sudo pacman -U dwarfstar4-*-x86_64.pkg.tar.zst
   ```

`makepkg -f` forces a rebuild over a previously built `.pkg.tar.zst`.

## Customizing the build

The PKGBUILD honors a few environment variables if you `export` them
before running `makepkg`:

| Variable           | Default                  | Purpose |
| ------------------ | ------------------------ | ------- |
| `HIPCC`            | `/opt/rocm/bin/hipcc`    | Path to the HIP compiler. |
| `ROCM_ARCH`        | `gfx1100 gfx1151`        | GPU offload arch list. Accepts space- or comma-separated values. |
| `NATIVE_CPU_FLAG`  | `-march=x86-64-v3`       | CPU baseline. Use `-march=native` for a host-locked binary. |

Examples:

```sh
ROCM_ARCH=gfx1100 makepkg -s -f
ROCM_ARCH='gfx1100 gfx1151' makepkg -s -f
```

`build()` logs the final ROCm arch list before compiling. If `rocminfo`
cannot run during build (common in clean chroots), the PKGBUILD warns and
falls back to `gfx1100 gfx1151`.

## Runtime prerequisites and model setup

ROCm access on Arch/CachyOS typically requires your user to be in both
`render` and `video` groups:

```sh
sudo usermod -aG render,video "$USER"
```

Then log out/in (or reboot), and verify:

```sh
rocminfo | grep -m1 gfx
groups | grep -E 'render|video'
```

If your APU/GPU needs an override, try:

```sh
HSA_OVERRIDE_GFX_VERSION=11.0.0 ds4 -m ~/.local/share/models/ds4flash.gguf
```

If you have both an iGPU and dGPU, select a specific runtime device with
`HIP_VISIBLE_DEVICES` or `ROCR_VISIBLE_DEVICES`.

### Model directory (`~/.local/share/models`)

The package wrapper stores GGUF files in:

`~/.local/share/models` (or `${XDG_DATA_HOME}/models` when `XDG_DATA_HOME`
is set), so models from multiple projects can share one location.

Recommended model download for Strix Halo + RX 7900 XTX:

```sh
dwarfstar4-download-model q2-imatrix
```

If the requested GGUF already exists in that folder, the wrapper prints an
"already present, skipping" message and avoids re-downloading.

The wrapper refreshes:

`~/.local/share/models/ds4flash.gguf -> <selected model>`

Run with an explicit path:

```sh
ds4 -m ~/.local/share/models/ds4flash.gguf
```

Or run from the model directory so DS4's default relative path resolves:

```sh
cd ~/.local/share/models
ds4
```

## Why a separate `dwarfstar4` name?

The upstream binaries are `ds4*`, but `ds4` is an extremely short and
collision-prone package name. `dwarfstar4` (DwarfStar 4 = "DS4") is the
package identity that pacman tracks, while the installed commands keep
their upstream names so existing scripts and the upstream README continue
to work verbatim. The PKGBUILD declares `provides=(ds4 ...)` and
`conflicts=(ds4 ...)` so an AUR `ds4` package, if one ever appears,
won't co-install.
