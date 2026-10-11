#!/usr/bin/env bash
# Cross-builds the seeed-voicecard modules (ac108, seeed-voicecard, wm8960)
# against a prepared Raspberry Pi kernel tree.
#
# Usage: build_module.sh <kernel_version> <kernel_src> <seeed_src> <output_dir>
#
# The kernel tree must already be prepared (idempotent check here):
#   - .config configured for arm64 (rpi-v8 flavor)
#   - Module.symvers present (extracted from the distro headers package)
#   - scripts/ generated (make prepare)
# Only the out-of-tree modules are built; the kernel itself is never rebuilt.
set -euo pipefail

kver="${1:?kernel_version}"
kernel_src="${2:?kernel_src}"
seeed_src="${3:?seeed_src}"
out_dir="${4:?output_dir}"

arch="${ARCH:-arm64}"
cross="${CROSS_COMPILE:-aarch64-linux-gnu-}"
jobs="${JOBS:-$(nproc)}"

[ -d "${kernel_src}" ] || { echo "ERROR: kernel tree ${kernel_src} not found" >&2; exit 1; }
[ -f "${kernel_src}/.config" ] || { echo "ERROR: ${kernel_src}/.config missing (tree not prepared)" >&2; exit 1; }
[ -f "${kernel_src}/Module.symvers" ] || { echo "ERROR: ${kernel_src}/Module.symvers missing (tree not prepared)" >&2; exit 1; }
[ -f "${seeed_src}/Makefile" ] || { echo "ERROR: ${seeed_src}/Makefile not found" >&2; exit 1; }

# The tree's own release string must match the requested kernel version.
tree_release="$(make -s -C "${kernel_src}" ARCH="${arch}" CROSS_COMPILE="${cross}" kernelrelease 2>/dev/null || true)"
if [ -n "${tree_release}" ] && [ "${tree_release}" != "${kver}" ]; then
    echo "ERROR: kernel tree release '${tree_release}' != requested '${kver}'" >&2
    echo "       (a different prepared tree is needed for ${kver})" >&2
    exit 1
fi

# Build tools (modpost, module.lds) without touching the config.
make -C "${kernel_src}" ARCH="${arch}" CROSS_COMPILE="${cross}" -j"${jobs}" scripts

# The module build rewrites Module.symvers in the module dir from the tree's;
# keep the tree's copy so subsequent builds stay consistent.
cp "${kernel_src}/Module.symvers" "${kernel_src}/Module.symvers.prebuild"
trap 'rm -f "${kernel_src}/Module.symvers.prebuild"' EXIT

# Clean stale objects so nothing is skipped after a config change.
make -C "${kernel_src}" ARCH="${arch}" CROSS_COMPILE="${cross}" \
    M="${seeed_src}" clean >/dev/null 2>&1 || true

make -C "${kernel_src}" ARCH="${arch}" CROSS_COMPILE="${cross}" \
    M="${seeed_src}" -j"${jobs}" modules

mv -f "${kernel_src}/Module.symvers.prebuild" "${kernel_src}/Module.symvers" 2>/dev/null || true

mods="snd-soc-ac108 snd-soc-seeed-voicecard snd-soc-wm8960"
mkdir -p "${out_dir}/${kver}"
for m in ${mods}; do
    ko="${seeed_src}/${m}.ko"
    if [ -f "${ko}" ]; then
        cp "${ko}" "${out_dir}/${kver}/"
        sha256sum "${out_dir}/${kver}/${m}.ko"
    else
        echo "ERROR: ${m}.ko was not produced" >&2
        exit 1
    fi
done
echo "OK ${kver}"
