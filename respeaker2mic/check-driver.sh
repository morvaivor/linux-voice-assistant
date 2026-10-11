#!/usr/bin/env bash
# Health-check for the ReSpeaker 2-Mic and 4-Mic HAT drivers.
#
# Reports, without side effects, whether each HAT's driver stack is
# present and the ALSA card is up. Exit code is 0 when every HAT that is
# physically attached is healthy, 1 otherwise (or 0 with --quiet when
# nothing is attached).
#
# Usage:
#   respeaker2mic/check-driver.sh [--quiet] [--json]
#
# --quiet   Exit silently; use only the exit code (for systemd/cron).
# --json    Emit a single JSON object instead of human text.
#
# This is safe to call from update_lva after an update: it never loads
# or unloads modules, it only inspects.

set -uo pipefail

quiet=0
json=0
for arg in "$@"; do
  case "$arg" in
    --quiet) quiet=1 ;;
    --json) json=1 ;;
    -h|--help) grep '^#' "$0" | sed -n '2,12p'; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

overall=0

check_2mic() {
  local codec_addr codec_name
  codec_name="seeed2micvoicec"
  local present=0 healthy=1

  # Is a 2-mic HAT attached? Either a card is registered, or the i2c
  # address answers. We only flag a problem when a card is expected.
  if aplay -l 2>/dev/null | grep -q "${codec_name}"; then
    present=1
  elif command -v i2cdetect >/dev/null 2>&1 && [ -e /dev/i2c-1 ]; then
    if i2cdetect -y -r 1 0x1a 0x1a 2>/dev/null | grep -qE "(^|[[:space:]])1a"; then
      present=1
    elif i2cdetect -y -r 1 0x18 0x18 2>/dev/null | grep -qE "(^|[[:space:]])18"; then
      present=1
    fi
  fi

  if [ "${present}" -eq 1 ]; then
    if ! aplay -l 2>/dev/null | grep -q "${codec_name}"; then
      healthy=0
    fi
  fi

  echo "2mic present=${present} healthy=${healthy}"
  [ "${healthy}" -eq 1 ] || overall=1
}

check_4mic() {
  local card_name="seeed4micvoicec"
  local present=0 healthy=1

  # The 4-Mic HAT is a capture-only card: it shows up in `arecord -l`,
  # never in `aplay -l`.
  if arecord -l 2>/dev/null | grep -q "${card_name}"; then
    present=1
  elif [ -e /dev/i2c-1 ]; then
    if i2cdetect -y -r 1 0x3b 0x3b 2>/dev/null | grep -qE "(^|[[:space:]])3b"; then
      present=1
    fi
  fi

  if [ "${present}" -eq 1 ]; then
    if ! arecord -l 2>/dev/null | grep -q "${card_name}"; then
      healthy=0
    fi
  fi

  echo "4mic present=${present} healthy=${healthy}"
  [ "${healthy}" -eq 1 ] || overall=1
}

# Collect results into variables for JSON output.
r2=$(check_2mic)
r4=$(check_4mic)
p2=$(echo "${r2}" | sed -n 's/.*present=\([01]\).*/\1/p')
h2=$(echo "${r2}" | sed -n 's/.*healthy=\([01]\).*/\1/p')
p4=$(echo "${r4}" | sed -n 's/.*present=\([01]\).*/\1/p')
h4=$(echo "${r4}" | sed -n 's/.*healthy=\([01]\).*/\1/p')

if [ "${json}" -eq 1 ]; then
  cat <<EOF
{"two_mic":{"present":${p2},"healthy":${h2}},"four_mic":{"present":${p4},"healthy":${h4}},"ok":$([ ${overall} -eq 0 ] && echo true || echo false)}
EOF
  exit "${overall}"
fi

if [ "${quiet}" -eq 1 ]; then
  exit "${overall}"
fi

echo "ReSpeaker driver health:"
echo "  2-Mic HAT : present=${p2} healthy=${h2}"
echo "  4-Mic HAT : present=${p4} healthy=${h4}"

if [ "${overall}" -eq 0 ]; then
  echo "OK: all attached HATs are healthy."
else
  echo "PROBLEM: an attached HAT is not producing a working ALSA card."
  echo "  - Check the HAT is seated and the correct dtoverlay is in config.txt"
  echo "  - For the 4-Mic HAT the out-of-tree seeed-voicecard module must be"
  echo "    loaded for the running kernel (see install-4mic-drivers.sh)."
fi
exit "${overall}"
