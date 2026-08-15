#!/usr/bin/env bash
#
# build-kernel.sh — compile and install your modified kernel.
# After it finishes, all you do is:  sudo reboot
#
# Usage: run from the ROOT of your kernel source tree:
#     chmod +x build-kernel.sh
#     ./build-kernel.sh
#
set -euo pipefail

# Optional: a version suffix so your last working kernel stays bootable
# as a fallback (recommended). Keep it in sync with the static-th value you
# built, e.g. "-th0" when you ran make-static-th.sh 0.
LOCALVERSION="-acc-fix"          # e.g. "-th0"
cd ~/Natalia_SS2026/Linux-6-16-Tiers/linux-6.16.1

# --- sanity checks -------------------------------------------------------
[[ -f Makefile && -f .config ]] || {
    echo "error: run this from the kernel source root (Makefile + .config needed)" >&2
    exit 1
}

EXTRA=()
[[ -n "${LOCALVERSION}" ]] && EXTRA+=("LOCALVERSION=${LOCALVERSION}")
JOBS="$(nproc)"

echo ">>> Building with -j${JOBS} ${LOCALVERSION:+(LOCALVERSION=${LOCALVERSION})}..."
time make -j"${JOBS}" "${EXTRA[@]}"

echo ">>> Installing modules (needs sudo)..."
sudo make "${EXTRA[@]}" modules_install

echo ">>> Installing kernel image + updating bootloader (needs sudo)..."
sudo make "${EXTRA[@]}" install

echo
echo ">>> Done. Built kernel: $(make -s "${EXTRA[@]}" kernelrelease)"
echo ">>> Reboot to use it:   sudo reboot"
