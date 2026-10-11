#!/usr/bin/env bash

# Installs audio support for the ReSpeaker 4-Mic Pi HAT (AC108 codec) on
# Raspberry Pi hardware.
#
# The AC108 has no mainline kernel driver, so this installer uses the
# out-of-tree seeed-voicecard driver, cross-compiled on the ko-server
# against the exact running kernel version and downloaded as a .ko:
#   1. Detects the HAT on i2c bus 1 (AC108 at 0x3b).
#   2. Fetches the prebuilt .ko for $(uname -r) from the ko-server.
#   3. Installs the .ko into /lib/modules/$(uname -r)/extra/seeed-voicecard/.
#   4. Installs the seeed-4mic-voicecard overlay (compiled locally with dtc).
#   5. Registers the modules and the overlay in config.txt / /etc/modules.
#   6. Installs /etc/voicecard/asound_4mic.conf and the ALSA card config.
#   7. Loads the driver and tries to bring the card up without a reboot.
#
# Coexistence with the ReSpeaker 2-Mic HAT: the 2-mic installer owns
# /etc/asound.conf; this installer never touches it. LVA must select the
# 4-mic card by name (seeed4micvoicec), not by "default", when both are
# present.
#
# Requires: i2c-tools, device-tree-compiler, curl (installed below).
# Must be run with sudo.

set -eo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run with sudo."
  exit 1
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
overlay_dts="${script_dir}/seeed-4mic-voicecard-overlay.dts"
overlay_name="seeed-4mic-voicecard"
card_id="seeed4micvoicec"
i2c_addr="0x3b"

ko_server="${KO_SERVER_URL:-http://192.168.2.225:8000}"
allow_local_build=0

usage() {
  cat <<EOF
Usage: sudo ${0##*/} [--uninstall] [options]

  (no args)    Detect the 4-Mic HAT on i2c (0x3b) and install the
               seeed-voicecard driver + overlay.
  --uninstall  Remove the driver, overlay, ALSA config and every config
               change this installer made.
  --ko-server URL  Base URL of the ko-server (default: ${ko_server})
  --allow-local-build
               If the ko-server has no .ko for the running kernel,
               build it locally instead of failing. Source locations are
               auto-detected or overridable via SEEED_SRC and KERNEL_SRC
               env vars (needs a prepared kernel tree + aarch64 toolchain).
  -h, --help   Show this help.
EOF
}

mode="install"
while [ $# -gt 0 ]; do
  case "$1" in
    "") shift ;;
    --uninstall) mode="uninstall"; shift ;;
    --ko-server)
      [ $# -ge 2 ] || { echo "error: --ko-server requires a URL" >&2; exit 1; }
      ko_server="$2"; shift 2 ;;
    --allow-local-build) allow_local_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Locate the boot partition (bookworm moved config/overlays to /boot/firmware)
if [ -d /boot/firmware/overlays ]; then
  boot_dir=/boot/firmware
else
  boot_dir=/boot
fi
config="${boot_dir}/config.txt"
overlays_dir="${boot_dir}/overlays"
modules_dir="/lib/modules/$(uname -r)"
driver_dir="${modules_dir}/extra/seeed-voicecard"

# --- uninstall ----------------------------------------------------------------

do_uninstall() {
  removed=0

  # Load-order: unload the platform (which pulls the codec) first.
  modprobe -r snd-soc-seeed-voicecard 2>/dev/null || true
  modprobe -r snd-soc-ac108 2>/dev/null || true

  if [ -d "${driver_dir}" ]; then
    rm -rf "${driver_dir}"
    echo "Removed ${driver_dir}"
    removed=1
  fi

  # Remove ONLY the 4-mic dtoverlay. Do NOT touch dtparam=i2c_arm=on,
  # dtparam=i2s=on or dtoverlay=i2s-mmap: they are shared and owned by the
  # 2-mic installer (the mainline simple-card overlay needs i2s=on and
  # i2s-mmap), so removing them here would break a concurrently installed
  # ReSpeaker 2-Mic HAT. The 2-mic --uninstall removes them.
  if [ -f "${config}" ]; then
    sed -i -e '/^dtoverlay=seeed-4mic-voicecard/d' "${config}"
  fi

  if [ -f "${overlays_dir}/${overlay_name}.dtbo" ]; then
    rm -f "${overlays_dir}/${overlay_name}.dtbo"
    echo "Removed ${overlays_dir}/${overlay_name}.dtbo"
    removed=1
  fi

  if command -v dtoverlay >/dev/null 2>&1; then
    dtoverlay -r "${overlay_name}" 2>/dev/null || true
  fi

  sed -i -e '/^snd-soc-ac108$/d' -e '/^snd-soc-seeed-voicecard$/d' /etc/modules 2>/dev/null || true

  # Keep the 2-mic ALSA config intact: only remove our file, and the dir too
  # only if nothing else uses it. If this installer owns the default-card
  # symlink (no 2-mic present), drop the now-dangling link.
  if [ -f /etc/voicecard/asound_4mic.conf ]; then
    rm -f /etc/voicecard/asound_4mic.conf
    echo "Removed 4-mic ALSA config."
    removed=1
  fi
  if [ -L /etc/asound.conf ] && \
     [ "$(readlink /etc/asound.conf)" = "/etc/voicecard/asound_4mic.conf" ]; then
    rm -f /etc/asound.conf
    echo "Removed /etc/asound.conf symlink."
    removed=1
  fi
  rmdir /etc/voicecard 2>/dev/null || true

  depmod -a 2>/dev/null || true

  echo
  if [ "${removed}" -eq 0 ]; then
    echo "Nothing to uninstall: no 4-Mic HAT driver state found."
  else
    echo "Done. ReSpeaker 4-Mic HAT driver removed. Reboot to finish."
  fi
}

if [ "${mode}" = "uninstall" ]; then
  do_uninstall
  exit 0
fi

# --- sanity checks -----------------------------------------------------------

if [ ! -f "${overlay_dts}" ]; then
  echo "ERROR: ${overlay_dts} not found next to this script."
  exit 1
fi

uname_r="$(uname -r)"

# --- enable i2c and probe the HAT --------------------------------------------

echo "Checking for the 4-Mic HAT on i2c bus 1..."
apt-get install --no-install-recommends --yes i2c-tools device-tree-compiler curl alsa-utils

# Enable the bus for THIS session too (a fresh image has i2c off): config.txt
# entry for the next boot, live dtparam, i2c-dev for /dev/i2c-*.
touch "${config}"
grep -q "^dtparam=i2c_arm=on" "${config}" || echo "dtparam=i2c_arm=on" >> "${config}"
grep -qx "i2c-dev" /etc/modules 2>/dev/null || echo "i2c-dev" >> /etc/modules
modprobe i2c-dev 2>/dev/null || true
if command -v dtparam >/dev/null 2>&1; then
  [ -e /dev/i2c-1 ] || dtparam i2c_arm=on 2>/dev/null || true
  dtparam i2s=on 2>/dev/null || true
fi
if [ ! -e /dev/i2c-1 ]; then
  echo "ERROR: no I2C bus (/dev/i2c-1 missing). dtparam=i2c_arm=on was added"
  echo "       to ${config}; reboot and re-run, and check the HAT is seated."
  exit 1
fi

if ! i2cdetect -y -r 1 "${i2c_addr}" "${i2c_addr}" 2>/dev/null | grep -qE "(^|[[:space:]])(3b|UU)"; then
  echo "ERROR: no AC108 codec at ${i2c_addr} on i2c bus 1."
  echo "       Is the ReSpeaker 4-Mic HAT seated on the 40-pin header?"
  exit 1
fi
echo "HAT detected: ReSpeaker 4-Mics Pi HAT (AC108 at ${i2c_addr})."

# --- fetch the prebuilt module ------------------------------------------------

echo "Requesting seeed-voicecard module for kernel ${uname_r} from ${ko_server}..."
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

downloaded=0
if curl -fsSL "${ko_server}/modules/${uname_r}.ko" -o "${tmp_dir}/seeed-voicecard.ko" 2>/dev/null; then
  downloaded=1
fi

if [ "${downloaded}" -eq 0 ]; then
  if [ "${allow_local_build}" -eq 1 ]; then
    echo "ko-server has no module for ${uname_r}; building locally..."
    seeed_src="${SEEED_SRC:-$(ls -d /opt/seed-v614 /opt/seeed-voicecard 2>/dev/null | head -1)}"
    if [ -z "${seeed_src}" ] || [ ! -f "${seeed_src}/Makefile" ]; then
      echo "ERROR: seeed-voicecard source not found for local build."
      echo "       Set SEEED_SRC to the source directory (e.g. /opt/seed-v614)."
      exit 1
    fi
    local_kdir="${KERNEL_SRC:-$(ls -d /opt/rpi-linux-* /opt/kern* /opt/linux-* 2>/dev/null | head -1)}"
    if [ -z "${local_kdir}" ] || [ ! -f "${local_kdir}/Makefile" ]; then
      echo "ERROR: no prepared kernel source tree found for local build."
      echo "       Set KERNEL_SRC to a prepared RPi kernel tree (e.g. /opt/kern618)."
      exit 1
    fi
    [ -f "${local_kdir}/.config" ] || {
      echo "ERROR: ${local_kdir}/.config missing (tree not prepared)."
      exit 1
    }
    [ -f "${local_kdir}/Module.symvers" ] || {
      echo "ERROR: ${local_kdir}/Module.symvers missing (tree not prepared)."
      exit 1
    }
    # Preserve the tree's Module.symvers across the module build.
    cp "${local_kdir}/Module.symvers" "${local_kdir}/Module.symvers.prebuild"
    make -C "${local_kdir}" ARCH=arm64 M="${seeed_src}" -j"$(nproc)" modules || {
      echo "ERROR: local build failed against ${local_kdir}."
      mv -f "${local_kdir}/Module.symvers.prebuild" "${local_kdir}/Module.symvers" 2>/dev/null || true
      exit 1
    }
    mv -f "${local_kdir}/Module.symvers.prebuild" "${local_kdir}/Module.symvers" 2>/dev/null || true
    cp "${seeed_src}/snd-soc-ac108.ko" "${tmp_dir}/snd-soc-ac108.ko"
    cp "${seeed_src}/snd-soc-seeed-voicecard.ko" "${tmp_dir}/seeed-voicecard.ko"
  else
    echo "ERROR: ko-server has no module for kernel ${uname_r}."
    echo "       Trigger a build:  curl -X POST ${ko_server}/build \\"
    echo "         -H 'Content-Type: application/json' \\"
    echo "         -d '{\"kernel_version\": \"${uname_r}\"}'"
    echo "       or re-run with --allow-local-build (SEEED_SRC/KERNEL_SRC)."
    exit 1
  fi
fi

# The ko-server serves the .ko of the main card driver; the ac108 codec
# module is fetched alongside when present.
ac108_ok=0
curl -fsSL "${ko_server}/modules/${uname_r}/snd-soc-ac108.ko" \
  -o "${tmp_dir}/snd-soc-ac108.ko" 2>/dev/null && ac108_ok=1

if [ "${ac108_ok}" -eq 0 ] && [ "${downloaded}" -eq 1 ]; then
  echo "ERROR: got the card driver but not the ac108 codec module."
  echo "       Rebuild on the server for kernel ${uname_r}."
  exit 1
fi

# --- install the modules -------------------------------------------------------

echo "Installing kernel modules into ${driver_dir}..."
mkdir -p "${driver_dir}"
cp "${tmp_dir}/seeed-voicecard.ko" "${driver_dir}/"
cp "${tmp_dir}/snd-soc-ac108.ko" "${driver_dir}/"
depmod -a

echo "Registering modules in /etc/modules..."
grep -qx "snd-soc-ac108" /etc/modules || echo "snd-soc-ac108" >> /etc/modules
grep -qx "snd-soc-seeed-voicecard" /etc/modules || echo "snd-soc-seeed-voicecard" >> /etc/modules

# --- build and install the overlay --------------------------------------------

echo "Compiling device tree overlay..."
dtc -@ -I dts -O dtb \
  -o "${tmp_dir}/${overlay_name}.dtbo" \
  "${overlay_dts}"

mkdir -p "${overlays_dir}"
cp "${tmp_dir}/${overlay_name}.dtbo" "${overlays_dir}/"

# --- boot configuration --------------------------------------------------------

echo "Updating ${config}..."
touch "${config}"
grep -q "^dtparam=i2s=on" "${config}" || echo "dtparam=i2s=on" >> "${config}"
grep -q "^dtoverlay=i2s-mmap" "${config}" || echo "dtoverlay=i2s-mmap" >> "${config}"
grep -q "^dtoverlay=${overlay_name}" "${config}" || echo "dtoverlay=${overlay_name}" >> "${config}"

# --- ALSA configuration --------------------------------------------------------

echo "Installing ALSA configuration..."
mkdir -p /etc/voicecard
cp "${script_dir}/asound_4mic.conf" /etc/voicecard/asound_4mic.conf

# Coexistence: only own /etc/asound.conf when no 2-mic install is present.
if [ -L /etc/asound.conf ] && [ "$(readlink /etc/asound.conf)" = "/etc/voicecard/asound_2mic.conf" ]; then
  echo "2-Mic HAT also present: leaving /etc/asound.conf on the 2-mic card."
  echo "Configure LVA to use the 4-mic card by name: ${card_id}"
else
  ln -sfn /etc/voicecard/asound_4mic.conf /etc/asound.conf
fi

# --- try to bring the card up without a reboot ---------------------------------

modprobe snd-soc-ac108 2>/dev/null || true
modprobe snd-soc-seeed-voicecard 2>/dev/null || true

if command -v dtoverlay >/dev/null 2>&1; then
  dtoverlay -d "${overlays_dir}" "${overlay_name}" 2>/dev/null || true
  sleep 2
fi

# The 4-Mic HAT is capture-only: verify with arecord, not aplay.
if arecord -l 2>/dev/null | grep -q "${card_id}"; then
  echo
  echo "Done. The HAT is available as capture card '${card_id}'."
  echo "Verify with:"
  echo "  arecord -D plughw:CARD=${card_id} -f S16_LE -r 48000 -c 4 -d 5 /tmp/t4mic.wav && aplay /tmp/t4mic.wav"
else
  echo
  echo "Done. Please reboot the system to activate the HAT."
  echo "After reboot, verify with:"
  echo "  arecord -l | grep ${card_id}"
fi
