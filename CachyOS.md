# DS4 on CachyOS (Strix Halo, Limine, pacman package)

This is a CachyOS-native installation guide for [DS4](https://github.com/antirez/ds4)
on an AMD Strix Halo machine (Ryzen AI MAX / Radeon 8060S, `gfx1151`) with
128 GB of unified memory.

It targets a default **CachyOS** install:

- **Bootloader:** Limine (default)
- **Limine config management:** `/etc/default/limine` → `/boot/limine.conf`
  via the `limine-mkinitcpio-hook` (auto-regenerates `limine.conf` on every
  kernel / initramfs update so your kernel parameters stick)
- **Snapshots:** `limine-snapper-sync` (default; nothing extra needed here,
  but kernel-parameter changes will be reflected in newly created snapshot
  entries automatically the next time they are synced)
- **Package manager:** `pacman`
- **GPU stack:** ROCm 7.x from the CachyOS / Arch `extra` repo

DS4 is built as a proper Arch package (`dwarfstar4`) from the
[`arch/PKGBUILD`](arch/PKGBUILD) shipped in this repository, so it is
installed, upgraded and removed like any other CachyOS package via `pacman`.

A short GRUB alternative is provided at the end for users who switched away
from Limine. The body of the guide assumes the CachyOS defaults.

---

## 1. Install ROCm from the official repo

CachyOS inherits ROCm packages from Arch `extra`. Install the runtime,
compiler, and the libraries the Strix Halo backend links against:

```sh
sudo pacman -Syu
sudo pacman -S --needed \
  rocm-hip-sdk \
  rocm-hip-runtime \
  rocm-llvm \
  rocminfo \
  rocm-smi-lib \
  rocblas \
  hipblas \
  hipblaslt \
  rocwmma
```

Notes:

- `rocm-hip-sdk` is the metapackage that pulls in `hipcc`, the HIP headers
  and `hip-runtime-amd`. It is the Arch equivalent of Ubuntu's
  `hipcc` + `libamdhip64-dev` + `libhip*-dev` combination.
- `rocwmma` on Arch installs the **complete** rocWMMA header tree under
  `/usr/include/rocwmma/` (including `rocwmma/internal/`). You do **not**
  need the manual `git clone` workaround that the Ubuntu guide describes.
- On Arch / CachyOS, ROCm installs into `/opt/rocm` natively (`hipcc` is at
  `/opt/rocm/bin/hipcc`). The Ubuntu `/usr` ↔ `/opt/rocm` symlink shim from
  `STRIXHALO.md` is **not** needed.

Looking at your installed set you already have most of this (`rocm-hip-sdk`,
`rocm-hip-runtime`, `rocminfo`, `rocblas`, `hipblas`, `rocm-llvm`, ...).
Only confirm that `hipblaslt` and `rocwmma` are present:

```sh
pacman -Qi hipblaslt rocwmma
```

If either is missing, install it with `sudo pacman -S hipblaslt rocwmma`.

---

## 2. Enable ROCm access for your user

The user running DS4 must be able to open `/dev/kfd` and the DRM render
node:

```sh
sudo usermod -aG render,video "$USER"
```

Log out and back in (or reboot). Verify:

```sh
groups | tr ' ' '\n' | grep -E '^(render|video)$'
rocminfo | grep -A80 'Name:                    gfx1151'
```

You should see your gfx1151 agent listed. If DS4 later reports
`no ROCm-capable device is detected`, this is almost always a missing
`render` group on the running user.

---

## 3. Increase GPU-visible memory (Limine, CachyOS default)

A 128 GB Strix Halo system initially exposes only ~62 GB of GPU-visible
memory through the default GTT aperture. The 80.76 GiB DS4 model needs the
larger aperture plus runtime buffers, so we extend it via kernel
parameters.

The parameters we need are the same ones from `STRIXHALO.md`:

```text
amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856
```

### 3.1. Edit `/etc/default/limine`

On CachyOS, `/etc/default/limine` is the source of truth for kernel
parameters. The `limine-mkinitcpio-hook` regenerates `/boot/limine.conf`
(and refreshes snapshot entries via `limine-snapper-sync`) every time a
kernel or initramfs is updated, so anything you put in this file becomes
permanent and survives kernel upgrades and snapshot creation.

Back up first:

```sh
sudo cp /etc/default/limine /etc/default/limine.bak
```

Then open the file:

```sh
sudoedit /etc/default/limine
```

Find the `KERNEL_CMDLINE` block. It is a Bash associative array. The
default profile is `default` (this is what CachyOS uses for `linux-cachyos`
and friends). Append the Strix Halo parameters to it. If the file already
contains a `KERNEL_CMDLINE[default]=...` line, append to that line; if it
uses `+=` form, add a new `+=` line. Both work.

Recommended form — add a clearly marked block at the bottom of the file so
you can easily see / revert it:

```bash
# --- DS4 / Strix Halo (gfx1151) GPU-visible memory tuning ---
# Required to expose the full ~127 GiB GTT aperture to ROCm.
# Reverting: delete this block and run `sudo limine-mkinitcpio`.
KERNEL_CMDLINE[default]+=" amd_iommu=off"
KERNEL_CMDLINE[default]+=" amdgpu.gttsize=126976"
KERNEL_CMDLINE[default]+=" ttm.pages_limit=32505856"
KERNEL_CMDLINE[default]+=" ttm.page_pool_size=32505856"
```

Note the **leading space** inside each quoted value — `+=` on a Bash
string concatenates without adding a separator, and the kernel expects
parameters to be space-separated.

If you maintain extra named profiles (for example a fallback or a
debugging profile), repeat the block for each profile key you care
about, e.g. `KERNEL_CMDLINE[fallback]+=" ..."`.

> **Heads up about `amd_iommu=off`:** this disables the AMD IOMMU
> system-wide. On a single-GPU compute box this is the path of least
> resistance for the Strix Halo backend, but if you depend on IOMMU
> (PCIe passthrough to a VM, certain virtualization features), use
> `iommu=pt amd_iommu=on` instead and accept the smaller aperture, or
> reserve the IOMMU-off configuration for a dedicated boot profile.

### 3.2. Regenerate `/boot/limine.conf`

Trigger the hook explicitly so you don't have to wait for the next kernel
update:

```sh
sudo limine-mkinitcpio
```

(Equivalent: `sudo mkinitcpio -P`, which re-runs the same hook for every
installed kernel preset.)

If you also want existing Limine **snapshot** entries to pick up the new
cmdline immediately, refresh the snapper-sync state:

```sh
sudo limine-snapper-sync
```

New snapshots created from this point on already inherit the new cmdline,
so this step is only needed if you want to update entries that already
existed before the change.

Sanity-check the generated config before rebooting:

```sh
sudo grep -E 'CMDLINE|cmdline' /boot/limine.conf
```

You should see your four new tokens appended to the line for the
`default` entry.

### 3.3. Reboot and verify

```sh
sudo reboot
```

After reboot:

```sh
cat /proc/cmdline
sudo dmesg | grep -Ei 'GTT|gttsize|TTM|VRAM|amdgpu'
rocminfo | grep -A80 'Name:                    gfx1151'
```

Expected signs (same as the Ubuntu guide):

```text
amdgpu:  126976M of GTT memory ready
rocminfo gfx1151 pool: 130023424 KB
```

If `/proc/cmdline` does **not** contain your new parameters, the most
likely cause is that you edited a profile name that is not the active one
for your installed kernel. Check what Limine actually booted:

```sh
sudo cat /boot/limine.conf | less
```

…and confirm the entry that was selected references `KERNEL_CMDLINE[default]`.
If it references a different key (e.g. `linux-cachyos-lts`), add the same
block for that key as well.

---

## 4. Build and install DS4 as an Arch package

This repository ships an Arch `PKGBUILD` under [`arch/`](arch/) that:

- Pulls the upstream source from
  [`antirez/ds4`](https://github.com/antirez/ds4) (not from your fork) at a
  pinned commit.
- Builds the `strix-halo` (ROCm) Makefile target with `hipcc` and the
  correct `gfx1151` offload arch.
- Installs the five DS4 binaries (`ds4`, `ds4-server`, `ds4-bench`,
  `ds4-eval`, `ds4-agent`) to `/usr/bin/` and the docs to
  `/usr/share/doc/dwarfstar4/`.

The package name is `dwarfstar4` (DwarfStar 4 = "DS4"). The provided
binaries keep their upstream names so existing scripts keep working.

### 4.1. Get the PKGBUILD

Clone this fork (or download just the `arch/` directory). The PKGBUILD
itself does **not** need this repo to be the build source — it fetches
upstream `antirez/ds4` independently — but the PKGBUILD file lives here.

```sh
git clone https://github.com/JDB321Sailor/ds4.git
cd ds4/arch
```

If you only want the PKGBUILD without the whole repo:

```sh
mkdir -p ~/build/dwarfstar4 && cd ~/build/dwarfstar4
curl -LO https://raw.githubusercontent.com/JDB321Sailor/ds4/main/arch/PKGBUILD
```

### 4.2. Build the package

`makepkg` is the standard Arch tool. It runs as your normal (non-root)
user, builds the package in a clean subdirectory, and emits a
`.pkg.tar.zst` file you then install with `pacman`.

```sh
# Run inside the directory that contains the PKGBUILD.
makepkg -s
```

Flags used:

- `-s` — install missing build dependencies via `sudo pacman -S` before
  building. (Build-only dependencies declared in `makedepends` are not
  removed afterwards; use `makepkg -rs` if you want them auto-removed.)

The build runs `make strix-halo -j$(nproc)`. On a 32-thread Ryzen AI MAX+
395 this should complete in a few minutes. Output lands as:

```text
dwarfstar4-<version>-1-x86_64.pkg.tar.zst
```

### 4.3. Install with pacman

```sh
sudo pacman -U dwarfstar4-*-x86_64.pkg.tar.zst
```

Verify:

```sh
pacman -Qi dwarfstar4
pacman -Ql dwarfstar4 | head
which ds4 ds4-server ds4-bench ds4-eval ds4-agent
```

From this point on `dwarfstar4` is a normal pacman-managed package:

- `pacman -Qi dwarfstar4` — show metadata.
- `pacman -Ql dwarfstar4` — list installed files.
- `pacman -Qo $(which ds4)` — confirm `/usr/bin/ds4` is owned by it.
- `sudo pacman -R dwarfstar4` — clean uninstall.
- To upgrade to a newer upstream commit: bump `pkgver` / `_commit` in the
  PKGBUILD, re-run `makepkg -s`, then `sudo pacman -U` the new
  `.pkg.tar.zst`.

> **Tip:** if you maintain this for yourself, drop the `PKGBUILD` into a
> personal `pacman` local repo (`repo-add`) so that `pacman -Syu` will
> pick up your upgrades automatically. That is optional — `pacman -U`
> is fine for a single machine.

---

## 5. Get the model and run DS4

Use the standard IQ2XXS/Q2K/Q8 imatrix GGUF — the same recommendation as
`STRIXHALO.md`:

```text
DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf
```

The upstream `download_model.sh` helper still works (it is just a shell
script). Either grab it once from upstream:

```sh
curl -LO https://raw.githubusercontent.com/antirez/ds4/main/download_model.sh
chmod +x download_model.sh
mkdir -p ~/ds4-models/gguf
cd ~/ds4-models
./download_model.sh
```

…or fetch the GGUF manually via your normal channel and place it under
`~/ds4-models/gguf/`.

Avoid the mixed IQ2/IQ4 or IQ2/Q4 GGUFs on this box for now: they put more
memory pressure on the ROCm path and can trigger a system OOM instead of a
clean DS4 failure.

Run it (binaries are on `$PATH` because they are installed in
`/usr/bin/`):

```sh
cd ~/ds4-models
ds4 -m gguf/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix.gguf
```

The ROCm build uses the Strix Halo backend automatically. On first run,
glance at `rocm-smi` in another terminal to confirm the GPU is being used:

```sh
watch -n 1 rocm-smi
```

---

## Appendix A — GRUB alternative

If you replaced Limine with GRUB on your CachyOS install, do this instead
of section 3.1 / 3.2:

```sh
sudo cp /etc/default/grub /etc/default/grub.bak
sudoedit /etc/default/grub
```

Append the Strix Halo parameters to `GRUB_CMDLINE_LINUX_DEFAULT`, for
example:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856"
```

Then regenerate `grub.cfg`:

```sh
sudo grub-mkconfig -o /boot/grub/grub.cfg
sudo reboot
```

Everything else in this guide (ROCm install, `render`/`video` group,
building and installing the `dwarfstar4` pacman package, running DS4) is
identical. Only the bootloader-configuration step changes.

---

## Appendix B — Where you are now (per your pasted system info)

Based on the system snapshot you shared (CachyOS x86_64, kernel
`7.1.1-2-cachyos`, Ryzen AI MAX+ 395, Radeon 8060S, 125 GiB RAM, ROCm 7.2.4
packages already installed), this is your concrete status against the
guide:

| Step | Status on your box |
| ---- | ------------------ |
| 1. ROCm packages | **Mostly done.** You already have `rocm-hip-sdk`, `rocm-hip-runtime`, `rocm-hip-libraries`, `rocblas`, `hipblas`, `rocm-llvm`, `rocminfo`, `rocm-smi-lib`. Verify `hipblaslt` and `rocwmma`: `pacman -Qi hipblaslt rocwmma`. Install whichever is missing. |
| 2. `render`/`video` group | Verify with `groups`. If missing, run the `usermod -aG` command and re-login. |
| 3. Kernel parameters via `/etc/default/limine` | **To do.** This is where you should start. Add the four-line `KERNEL_CMDLINE[default]+=` block from §3.1, then `sudo limine-mkinitcpio`, then reboot, then check `cat /proc/cmdline` and `dmesg \| grep amdgpu`. |
| 4. Build & install `dwarfstar4` | **To do.** Clone this fork, `cd arch && makepkg -s`, then `sudo pacman -U dwarfstar4-*.pkg.tar.zst`. |
| 5. Model + run | **To do.** Place the IQ2XXS GGUF under `~/ds4-models/gguf/` and run `ds4 -m gguf/...`. |

Recommended order for you specifically:

1. `pacman -Qi hipblaslt rocwmma` and install anything missing.
2. Edit `/etc/default/limine`, run `sudo limine-mkinitcpio`, reboot,
   verify `amdgpu: 126976M of GTT memory ready` in `dmesg`.
3. Clone this fork, `cd arch && makepkg -s && sudo pacman -U dwarfstar4-*.pkg.tar.zst`.
4. Download the GGUF and run `ds4 -m ...`.

You should be one reboot and one `makepkg` away from a working
ROCm-on-Strix-Halo DS4 install that is fully managed by pacman.
