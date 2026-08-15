#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

# Print a section header.
_header() { echo ""; echo "── $* ──"; }

# Ask a yes/no question; echoes "y" or "n".
_ask_yn() {
    local _prompt="$1" _default="${2:-n}" _ans
    read -rp "  ${_prompt} [y/N] " _ans
    echo "${_ans,,:-$_default}"
}

# Return the pkgver string a PKGBUILD directory will produce by running
# makepkg --printsrcinfo is slow; instead call pkgver() directly via sourcing.
# We only need the pkgname here (for glob matching).
_pkgname_of() {
    local _dir="$1"
    grep '^pkgname=' "${_dir}/PKGBUILD" | head -1 | cut -d= -f2
}

# List existing built packages (*.pkg.tar.zst) in a directory.
_existing_pkgs() {
    local _dir="$1"
    find "${_dir}" -maxdepth 1 -name '*.pkg.tar.zst' 2>/dev/null | sort
}

# Show OLD vs NEW package comparison and offer to delete OLD ones.
# $1 = build dir, $2 = new pkgname prefix (e.g. "llama.cpp-rocm")
_offer_cleanup() {
    local _dir="$1" _pkgname="$2"
    local _old_pkgs _new_pkgs _all_old _ans

    # Collect files that exist BEFORE the build (already there = old).
    # We mark them by timestamp — anything older than 10 s is "old".
    _old_pkgs="$(find "${_dir}" -maxdepth 1 -name "${_pkgname}-*.pkg.tar.zst" \
                     ! -newer "${_dir}/PKGBUILD" 2>/dev/null | sort || true)"
    _new_pkgs="$(find "${_dir}" -maxdepth 1 -name "${_pkgname}-*.pkg.tar.zst" \
                       -newer "${_dir}/PKGBUILD" 2>/dev/null | sort || true)"

    [[ -z "$_old_pkgs" ]] && return 0

    echo ""
    echo "  Old and new built packages found in: ${_dir}"
    echo ""
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && printf "    OLD  %s\n" "$(basename "$_f")"
    done <<< "$_old_pkgs"
    while IFS= read -r _f; do
        [[ -n "$_f" ]] && printf "    NEW  %s\n" "$(basename "$_f")"
    done <<< "$_new_pkgs"

    read -rp "  Delete the OLD package file(s) listed above? [y/N] " _ans
    if [[ "${_ans,,}" == "y" ]]; then
        while IFS= read -r _f; do
            [[ -z "$_f" ]] && continue
            echo "  Removing: $(basename "$_f")"
            rm -f "$_f"
        done <<< "$_old_pkgs"
    fi
}

# Build one llama.cpp variant.  Handles rerun detection.
# $1 = label (e.g. "llama.cpp-rocm"), $2 = build dir
_build_llama() {
    local _label="$1" _dir="$2"
    echo ""
    echo "Building ${_label} …"

    local _existing
    _existing="$(_existing_pkgs "${_dir}")"

    if [[ -n "$_existing" ]]; then
        echo ""
        echo "  Existing built package(s) found for ${_label}:"
        while IFS= read -r _f; do
            [[ -n "$_f" ]] && printf "    %s\n" "$(basename "$_f")"
        done <<< "$_existing"
        read -rp "  Rebuild ${_label}? [y/N] " _rebuild_ans
        if [[ "${_rebuild_ans,,}" != "y" ]]; then
            echo "  Skipping rebuild of ${_label}."
            return 0
        fi
    fi

    # Touch PKGBUILD so we can distinguish old vs new artifacts afterward.
    touch "${_dir}/PKGBUILD"

    pushd "${_dir}" > /dev/null
    makepkg -s --noconfirm
    popd > /dev/null

    _offer_cleanup "${_dir}" "${_label}"
}

# Install one llama.cpp package from its build dir.
# $1 = build dir, $2 = package name (used for pacman -U glob)
_install_pkg() {
    local _dir="$1" _pkgname="$2"
    local _pkg
    _pkg="$(find "${_dir}" -maxdepth 1 -name "${_pkgname}-*.pkg.tar.zst" | sort | tail -1)"
    if [[ -z "$_pkg" ]]; then
        echo "  ERROR: No built package found for ${_pkgname} in ${_dir}" >&2
        return 1
    fi
    echo "  Installing: $(basename "$_pkg")"
    sudo pacman -U --noconfirm "$_pkg"
}

# ─────────────────────────────────────────────────────────────────────────────
# Detect whether this is a rerun (any llama.cpp-* already installed).
# ─────────────────────────────────────────────────────────────────────────────
_currently_installed_llama=""
for _lp in llama.cpp-rocm llama.cpp-cuda llama.cpp-vulkan; do
    if pacman -Qi "$_lp" &>/dev/null; then
        _currently_installed_llama="$_lp"
        break
    fi
done

_rerun=false
[[ -n "$_currently_installed_llama" ]] && _rerun=true

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — Optionally update Limine boot params
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 1: Limine boot parameters for maximum VRAM / GTT aperture"
echo "  Adds: amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856"

_limine_already=false
grep -q 'amdgpu.gttsize=126976' /proc/cmdline 2>/dev/null && _limine_already=true || true

if ${_limine_already}; then
    echo "  Limine GTT parameters already active in /proc/cmdline — skipping."
else
    read -rp "  Update Limine boot parameters now? [y/N] " _limine_ans
    if [[ "${_limine_ans,,}" == "y" ]]; then
        echo "  Backing up /etc/default/limine …"
        sudo cp /etc/default/limine /etc/default/limine.bak
        echo "  Appending kernel parameters to /etc/default/limine …"
        sudo tee -a /etc/default/limine > /dev/null <<'EOF'

# Added by setup.sh — maximum GTT aperture for LLM/ROCm usage on Strix Halo.
KERNEL_CMDLINE[default]+=" amd_iommu=off"
KERNEL_CMDLINE[default]+=" amdgpu.gttsize=126976"
KERNEL_CMDLINE[default]+=" ttm.pages_limit=32505856"
KERNEL_CMDLINE[default]+=" ttm.page_pool_size=32505856"
EOF
        echo "  Regenerating /boot/limine.conf …"
        sudo limine-mkinitcpio
        echo "  Rebooting in 5 seconds — press Ctrl-C to cancel."
        sleep 5
        sudo reboot
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — Install AMD HIP/ROCm
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 2: Installing AMD HIP/ROCm stack"
sudo pacman -Syu --needed --noconfirm \
    rocm-hip-sdk \
    rocm-hip-runtime \
    rocm-llvm \
    rocminfo \
    rocm-smi-lib \
    rocblas \
    hipblas \
    hipblaslt \
    rocwmma

# ─────────────────────────────────────────────────────────────────────────────
# Step 3 — Detect and install Nvidia drivers via cachyos chwd
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 3: Detecting and installing Nvidia drivers via chwd"

_has_nvidia=false
if command -v lspci >/dev/null 2>&1 \
    && LC_ALL=C lspci -Dn 2>/dev/null \
        | grep -qE '[[:space:]](0300|0302|0380):[[:space:]]+10de:'; then
    _has_nvidia=true
fi

if ${_has_nvidia}; then
    echo "  Nvidia GPU detected — installing the recommended CachyOS driver profile."
    sudo chwd -a
else
    echo "  No Nvidia GPU detected — skipping Nvidia driver installation."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4 — Install CUDA and Vulkan build packages
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 4: Installing CUDA and Vulkan build packages"

_gpu_build_packages=(
    vulkan-headers
    vulkan-icd-loader
    shaderc
)
if ${_has_nvidia}; then
    _gpu_build_packages=(
        cuda
        cudnn
        "${_gpu_build_packages[@]}"
    )
else
    echo "  No Nvidia GPU detected — skipping CUDA packages."
fi

sudo pacman -Syu --needed --noconfirm "${_gpu_build_packages[@]}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — Display visible GPUs
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 5: Visible GPUs"

echo ""
echo "── AMD / ROCm (rocminfo) ──"
if command -v rocminfo >/dev/null 2>&1; then
    rocminfo | awk '
        /^[[:space:]]*Agent[[:space:]]+[0-9]+/ { agent=$0 }
        /^[[:space:]]*Name:/ && !/gfx/ { name=$0; sub(/^[[:space:]]*Name:[[:space:]]*/,"",name) }
        /^[[:space:]]*Name:[[:space:]]*gfx/ { arch=$0; sub(/^[[:space:]]*Name:[[:space:]]*/,"",arch) }
        /^[[:space:]]*Marketing Name:/ {
            mkt=$0; sub(/^[[:space:]]*Marketing Name:[[:space:]]*/,"",mkt)
            printf "  %s  arch: %s  (%s)\n", name, arch, mkt
        }
    '
else
    echo "  rocminfo not found — skipping AMD GPU listing."
fi

echo ""
echo "── AMD PCIe (lspci) ──"
lspci -nn | grep -iE 'VGA|Display|3D|AMD' || echo "  (none found)"

echo ""
echo "── Nvidia (nvidia-smi) ──"
if ! ${_has_nvidia}; then
    echo "  No Nvidia GPU detected."
elif command -v nvidia-smi >/dev/null 2>&1; then
    if ! nvidia-smi --query-gpu=index,name,uuid \
        --format=csv,noheader \
        | awk -F', ' '{printf "  GPU %s: %s\n", $1, $2}'; then
        echo "  nvidia-smi could not query the detected Nvidia GPU."
    fi
else
    echo "  nvidia-smi not available — Nvidia driver may not be installed yet."
fi

echo ""
echo "── Nvidia PCIe (lspci) ──"
lspci -nn | grep -iE 'VGA|Display|3D|NVIDIA' || echo "  (none found)"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — Install build dependencies for llama.cpp and ds4
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 6: Installing build dependencies for llama.cpp and ds4"
sudo pacman -Syu --needed --noconfirm \
    base-devel \
    git \
    cmake \
    ninja \
    make \
    gcc \
    clang \
    pkgconf

# ─────────────────────────────────────────────────────────────────────────────
# Step 7 — Build available llama.cpp backends
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 7: Building llama.cpp packages"

# On a rerun, offer to switch vs. build new.
_do_build_llama=true
if ${_rerun}; then
    echo ""
    echo "  A llama.cpp backend is already installed: ${_currently_installed_llama}"
    echo "  What would you like to do?"
    echo "    new    — build fresh packages (all three backends)"
    echo "    switch — only choose a different backend to install (skip rebuild)"
    read -rp "  Enter 'new' or 'switch': " _rerun_mode
    if [[ "${_rerun_mode,,}" == "switch" ]]; then
        _do_build_llama=false
    fi
fi

LLAMA_BUILD_DIR="${SCRIPT_DIR}/arch-ai-strix-halo"

if ${_do_build_llama}; then
    if ${_has_nvidia}; then
        echo ""
        echo "  Step 7a: llama.cpp-cuda"
        _build_llama "llama.cpp-cuda" "${LLAMA_BUILD_DIR}/llama.cpp-cuda"
    else
        echo ""
        echo "  Step 7a: llama.cpp-cuda — skipped (no Nvidia GPU detected)"
    fi

    echo ""
    echo "  Step 7b: llama.cpp-rocm"
    _build_llama "llama.cpp-rocm"   "${LLAMA_BUILD_DIR}/llama.cpp-rocm"

    echo ""
    echo "  Step 7c: llama.cpp-vulkan"
    _build_llama "llama.cpp-vulkan" "${LLAMA_BUILD_DIR}/llama.cpp-vulkan"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 8 — Choose and install a llama.cpp backend
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 8: llama.cpp backend selection"
echo ""
echo "  Which llama.cpp backend would you like to install?"
echo "    1) ROCm   — AMD iGPU / dGPU (llama.cpp-rocm)"
if ${_has_nvidia}; then
    echo "    2) CUDA   — Nvidia eGPU     (llama.cpp-cuda)"
else
    echo "    2) CUDA   — unavailable (no Nvidia GPU detected)"
fi
echo "    3) Vulkan — any Vulkan GPU  (llama.cpp-vulkan)"
echo "    4) None   — skip installation"
read -rp "  Enter 1, 2, 3, or 4: " _backend_choice

_installed_backend="(none)"
case "${_backend_choice}" in
    1)
        _install_pkg "${LLAMA_BUILD_DIR}/llama.cpp-rocm"   "llama.cpp-rocm"
        _installed_backend="llama.cpp-rocm"
        ;;
    2)
        if ${_has_nvidia}; then
            _install_pkg "${LLAMA_BUILD_DIR}/llama.cpp-cuda" "llama.cpp-cuda"
            _installed_backend="llama.cpp-cuda"
        else
            echo "  CUDA backend unavailable — no Nvidia GPU was detected."
        fi
        ;;
    3)
        _install_pkg "${LLAMA_BUILD_DIR}/llama.cpp-vulkan" "llama.cpp-vulkan"
        _installed_backend="llama.cpp-vulkan"
        ;;
    4)
        echo "  Skipping llama.cpp installation."
        ;;
    *)
        echo "  Invalid choice — skipping llama.cpp installation."
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Step 9 — Build dwarfstar4 (ds4 ROCm package)
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 9: Building dwarfstar4 (ds4 ROCm)"
echo ""

_dw4_existing="$(_existing_pkgs "${SCRIPT_DIR}")"
_do_build_dw4=true
if [[ -n "$_dw4_existing" ]]; then
    echo "  Existing built package(s) found for dwarfstar4:"
    while IFS= read -r _f; do
        [[ -z "$_f" ]] && continue
        printf "    %s\n" "$(basename "$_f")"
    done <<< "$_dw4_existing"
    read -rp "  Rebuild dwarfstar4? [y/N] " _rebuild_dw4
    [[ "${_rebuild_dw4,,}" != "y" ]] && _do_build_dw4=false
fi

if ${_do_build_dw4}; then
    touch "${SCRIPT_DIR}/PKGBUILD"
    pushd "${SCRIPT_DIR}" > /dev/null
    makepkg -s --noconfirm
    popd > /dev/null
    _offer_cleanup "${SCRIPT_DIR}" "dwarfstar4"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 10 — Optionally install dwarfstar4
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 10: Install dwarfstar4?"
echo ""
read -rp "  Install dwarfstar4 now? [y/N] " _install_dw4_ans
_dw4_installed=false
if [[ "${_install_dw4_ans,,}" == "y" ]]; then
    _install_pkg "${SCRIPT_DIR}" "dwarfstar4"
    _dw4_installed=true
else
    echo "  Skipping dwarfstar4 installation."
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 11 — System check
# ─────────────────────────────────────────────────────────────────────────────
_header "Step 11: System check"
_all_ok=true

echo ""
echo "── Installed package versions ──"
for _pkg in "${_installed_backend}" dwarfstar4; do
    if [[ "$_pkg" == "(none)" ]]; then
        echo "  llama.cpp: not installed (skipped)"
        continue
    fi
    if pacman -Qi "$_pkg" &>/dev/null; then
        _ver="$(pacman -Q "$_pkg" | awk '{print $2}')"
        echo "  ${_pkg}: ${_ver}"
    else
        echo "  ${_pkg}: NOT found in pacman database"
        _all_ok=false
    fi
done

echo ""
echo "── ds4 binary check ──"
if ${_dw4_installed}; then
    for _bin in ds4 ds4-server ds4-bench ds4-eval ds4-agent; do
        if command -v "$_bin" >/dev/null 2>&1; then
            echo "  ${_bin}: $(command -v "$_bin")"
        else
            echo "  ${_bin}: NOT found in PATH"
            _all_ok=false
        fi
    done
else
    echo "  dwarfstar4 not installed — skipping binary check."
fi

echo ""
echo "── llama-cli binary check ──"
if [[ "${_installed_backend}" != "(none)" ]]; then
    if command -v llama-cli >/dev/null 2>&1; then
        echo "  llama-cli: $(command -v llama-cli)"
        llama-cli --version 2>&1 | head -1 | sed 's/^/  version: /'
    else
        echo "  llama-cli: NOT found in PATH"
        _all_ok=false
    fi
else
    echo "  llama.cpp not installed — skipping llama-cli check."
fi

echo ""
echo "── ROCm device visibility ──"
if command -v rocminfo >/dev/null 2>&1; then
    rocminfo 2>/dev/null | grep -E 'Name:|Marketing Name:' | sed 's/^/  /' || echo "  (no output)"
else
    echo "  rocminfo not available"
fi

echo ""
echo "── Nvidia device visibility ──"
if ! ${_has_nvidia}; then
    echo "  No Nvidia GPU detected."
elif command -v nvidia-smi >/dev/null 2>&1; then
    if ! nvidia-smi --query-gpu=name --format=csv,noheader | sed 's/^/  /'; then
        echo "  nvidia-smi could not query the detected Nvidia GPU."
    fi
else
    echo "  nvidia-smi not available"
fi

echo ""
echo "── Active kernel parameters ──"
grep -oE '(amd_iommu|amdgpu\.gttsize|ttm\.pages_limit)[^ ]+' /proc/cmdline \
    | sed 's/^/  /' || echo "  (no GTT parameters detected)"

echo ""
echo "──────────────────────────────────────────────────────────────────────────"
if ${_all_ok}; then
    echo ""
    if [[ "${_installed_backend}" != "(none)" ]] && ${_dw4_installed}; then
        echo "  All checks passed."
        echo "  Models are ready to be deployed with ds4 and ${_installed_backend}."
    else
        echo "  All checks passed."
        echo "  Note: some packages were not installed — see above."
    fi
else
    echo ""
    echo "  One or more checks failed — review the output above."
fi
echo ""
