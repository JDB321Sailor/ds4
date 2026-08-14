#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ─────────────────────────────────────────────
# Step 1 — Optionally update Limine boot params
# ─────────────────────────────────────────────
echo ""
echo "Step 1: Limine boot parameters for maximum VRAM / GTT aperture."
echo "  Adds: amd_iommu=off amdgpu.gttsize=126976 ttm.pages_limit=32505856 ttm.page_pool_size=32505856"
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

# ──────────────────────────────────────────────────────────
# Step 2 — Install AMD HIP/ROCm (most recent stable version)
# ──────────────────────────────────────────────────────────
echo ""
echo "Step 2: Installing AMD HIP/ROCm stack …"
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

# ───────────────────────────────────────────────────────────
# Step 3 — Detect and install Nvidia drivers via cachyos chwd
# ───────────────────────────────────────────────────────────
echo ""
echo "Step 3: Detecting and installing Nvidia drivers via chwd …"
sudo chwd -a

# ──────────────────────────────────────────────────────
# Step 4 — Install CUDA build packages for llama.cpp
# ──────────────────────────────────────────────────────
echo ""
echo "Step 4: Installing CUDA build packages …"
sudo pacman -Syu --needed --noconfirm \
    cuda \
    cuda-tools \
    cudnn

# ─────────────────────────────────────────────────────────────────────────────
# Step 5 — Display visible GPUs (AMD iGPU + eGPU, Nvidia eGPU) with model names
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 5: Visible GPUs ─────────────────────────────────────────────────────"

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
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,uuid \
        --format=csv,noheader \
        | awk -F', ' '{printf "  GPU %s: %s\n", $1, $2}'
else
    echo "  nvidia-smi not available — Nvidia driver may not be installed yet."
fi

echo ""
echo "── Nvidia PCIe (lspci) ──"
lspci -nn | grep -iE 'VGA|Display|3D|NVIDIA' || echo "  (none found)"
echo "──────────────────────────────────────────────────────────────────────────"

# ─────────────────────────────────────────────────────────────────────────────
# Step 6 — Install build dependencies for llama.cpp and ds4
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 6: Installing build dependencies for llama.cpp and ds4 …"
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
# Step 7 — Build llama.cpp-cuda
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 7: Building llama.cpp-cuda …"
cd "${SCRIPT_DIR}/arch-ai-strix-halo/llama.cpp-cuda"
makepkg -s --noconfirm

# ─────────────────────────────────────────────────────────────────────────────
# Step 8 — Build llama.cpp-rocm
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 8: Building llama.cpp-rocm …"
cd "${SCRIPT_DIR}/arch-ai-strix-halo/llama.cpp-rocm"
makepkg -s --noconfirm

# ─────────────────────────────────────────────────────────────────────────────
# Step 9 — Ask which backend to install
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 9: Which llama.cpp backend should be installed?"
echo "  1) ROCm  (AMD iGPU / dGPU)"
echo "  2) CUDA  (Nvidia eGPU)"
read -rp "  Enter 1 or 2: " _backend_choice

case "${_backend_choice}" in
    1)
        echo "  Installing llama.cpp-rocm …"
        cd "${SCRIPT_DIR}/arch-ai-strix-halo/llama.cpp-rocm"
        sudo pacman -U --noconfirm llama.cpp-rocm-*.pkg.tar.zst
        _installed_backend="llama.cpp-rocm"
        ;;
    2)
        echo "  Installing llama.cpp-cuda …"
        cd "${SCRIPT_DIR}/arch-ai-strix-halo/llama.cpp-cuda"
        sudo pacman -U --noconfirm llama.cpp-cuda-*.pkg.tar.zst
        _installed_backend="llama.cpp-cuda"
        ;;
    *)
        echo "  Invalid choice — skipping llama.cpp install."
        _installed_backend="(none)"
        ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
# Step 10 — Change to ds4 arch folder
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 10: Changing to ds4 arch folder …"
cd "${SCRIPT_DIR}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 11 — Build dwarfstar4 (ds4 with ROCm backend)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 11: Building dwarfstar4 (ds4 ROCm) …"
makepkg -s --noconfirm

# ─────────────────────────────────────────────────────────────────────────────
# Step 12 — Install dwarfstar4
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 12: Installing dwarfstar4 …"
sudo pacman -U --noconfirm dwarfstar4-*.pkg.tar.zst

# ─────────────────────────────────────────────────────────────────────────────
# Step 13 — System check
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Step 13: System check ────────────────────────────────────────────────────"
_all_ok=true

echo ""
echo "── Installed package versions ──"
for _pkg in "${_installed_backend}" dwarfstar4; do
    if [[ "$_pkg" == "(none)" ]]; then
        echo "  llama.cpp: not installed (skipped in step 9)"
        _all_ok=false
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
for _bin in ds4 ds4-server ds4-bench ds4-eval ds4-agent; do
    if command -v "$_bin" >/dev/null 2>&1; then
        echo "  ${_bin}: $(command -v $_bin)"
    else
        echo "  ${_bin}: NOT found in PATH"
        _all_ok=false
    fi
done

echo ""
echo "── llama-cli binary check ──"
if command -v llama-cli >/dev/null 2>&1; then
    echo "  llama-cli: $(command -v llama-cli)"
    llama-cli --version 2>&1 | head -1 | sed 's/^/  version: /'
else
    echo "  llama-cli: NOT found in PATH"
    _all_ok=false
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
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name --format=csv,noheader | sed 's/^/  /'
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
    echo "  All checks passed."
    echo "  Models are ready to be deployed with ds4 and ${_installed_backend}."
    echo ""
else
    echo ""
    echo "  One or more checks failed — review the output above."
    echo ""
fi
