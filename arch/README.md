# `dwarfstar4` — Arch / CachyOS package for DS4

This directory contains the `PKGBUILD` for the `dwarfstar4` package, an
Arch Linux / CachyOS native packaging of
[`antirez/ds4`](https://github.com/antirez/ds4) built for the ROCm /
Strix Halo (`gfx1151`) backend.

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
- Runs `make strix-halo -j"$(nproc)"` which uses `hipcc`, `gfx1151`, and
  links against `hipblas` / `hipblaslt` / `rocblas` / `rocwmma`.
- Overrides `NATIVE_CPU_FLAG` to `-march=x86-64-v3` so the resulting
  package is portable across Zen 4 / Zen 5 boxes rather than locked to the
  exact build host.
- Installs five binaries with `install -Dm755`, plus license and Markdown
  docs.

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
| `ROCM_ARCH`        | `gfx1151`                | GPU offload arch. Set to `gfx1100` for an RX 7900 XTX build, etc. |
| `NATIVE_CPU_FLAG`  | `-march=x86-64-v3`       | CPU baseline. Use `-march=native` for a host-locked binary. |

Example: build for the discrete RX 7900 XTX in the same box:

```sh
ROCM_ARCH=gfx1100 makepkg -s -f
```

(If you need both targets installed in parallel, fork this PKGBUILD into
`dwarfstar4-gfx1100` with the appropriate `pkgname` / `conflicts` /
`provides` adjustments.)

## Why a separate `dwarfstar4` name?

The upstream binaries are `ds4*`, but `ds4` is an extremely short and
collision-prone package name. `dwarfstar4` (DwarfStar 4 = "DS4") is the
package identity that pacman tracks, while the installed commands keep
their upstream names so existing scripts and the upstream README continue
to work verbatim. The PKGBUILD declares `provides=(ds4 ...)` and
`conflicts=(ds4 ...)` so an AUR `ds4` package, if one ever appears,
won't co-install.
