#!/usr/bin/env bash
# boot-kobo.sh — boot a Kobo SD image under QEMU (TCG).
#
# Usage:
#   boot-kobo.sh [--version V] [--machine M] [--timeout S] [--display MODE]
#
#   --version V    firmware version (default: $KOBO_VERSION or 4.38.23684)
#   --machine M    QEMU machine (default: $QEMU_MACHINE or cubieboard;
#                  stock QEMU has no i.MX50 — see README for why cubieboard)
#   --timeout S    kill QEMU after S seconds, 0 = no timeout
#                  (default: $KOBO_BOOT_TIMEOUT or 300)
#   --display MODE none | sdl | vnc  (default: $KOBO_DISPLAY or none)
#
# Needs build/kobo-sd-<version>.img + build/zImage-<version> first;
# build them with scripts/build-sd.sh <version>.
set -euo pipefail

readonly DEFAULT_VERSION="${KOBO_VERSION:-4.38.23684}"
readonly DEFAULT_MACHINE="${QEMU_MACHINE:-cubieboard}"
readonly DEFAULT_TIMEOUT="${KOBO_BOOT_TIMEOUT:-300}"
readonly DEFAULT_DISPLAY="${KOBO_DISPLAY:-none}"
readonly WANT_CPU="cortex-a8"
# cubieboard rejects 256M ("only 512MiB or 1GiB"); the real N905 has 256M,
# so any cubieboard run is a documented deviation, not a 1:1 memory map.
# KOBO_MEM_MB overrides per-machine defaults when set.
readonly MEM_MB_OVERRIDE="${KOBO_MEM_MB:-}"
# Stock intent: the i.MX50 kernel's console is an MXC UART. No stock QEMU
# board wires one, so serial output is best-effort (expect silence).
readonly GUEST_CMDLINE="console=ttymxc0,115200n8 root=/dev/mmcblk0p1 rw rootwait rootfstype=ext4"

die() {
  echo "kobo-emu: error: $*" >&2
  exit 1
}

print_usage() {
  cat <<'USAGE'
Usage: boot-kobo.sh [--version V] [--machine M] [--timeout S] [--display MODE]
USAGE
}

qemu_machine_is_available() {
  qemu-system-arm -M help | grep -q "^$1[[:space:]]"
}

# Parse, don't validate: exactly one memory size per machine, KOBO_MEM_MB wins.
resolve_mem_mb() {
  if [[ -n "$MEM_MB_OVERRIDE" ]]; then
    printf '%s' "$MEM_MB_OVERRIDE"
    return
  fi
  case "$1" in
    cubieboard) printf '512' ;;
    *) printf '256' ;;
  esac
}

list_cortex_a8_boards() {
  echo "kobo-emu: Cortex-A8 boards in this QEMU:"
  qemu-system-arm -M help | grep -i 'cortex-a8' || true
  echo "kobo-emu: i.MX boards in this QEMU:"
  qemu-system-arm -M help | grep -i 'imx' || true
}

main() {
  local version="$DEFAULT_VERSION"
  local machine="$DEFAULT_MACHINE"
  local timeout_s="$DEFAULT_TIMEOUT"
  local display="$DEFAULT_DISPLAY"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) version="${2:?kobo-emu: error: --version needs a value}"; shift 2 ;;
      --machine) machine="${2:?kobo-emu: error: --machine needs a value}"; shift 2 ;;
      --timeout) timeout_s="${2:?kobo-emu: error: --timeout needs a value}"; shift 2 ;;
      --display) display="${2:?kobo-emu: error: --display needs a value}"; shift 2 ;;
      --help|-h) print_usage; exit 0 ;;
      --*) die "unknown flag: $1 (see --help)" ;;
      *) die "unexpected extra argument: $1" ;;
    esac
  done

  [[ "$timeout_s" =~ ^[0-9]+$ ]] || die "--timeout must be a non-negative integer (got '$timeout_s')"
  case "$display" in
    none|sdl|vnc) ;;
    *) die "--display must be none, sdl, or vnc (got '$display')" ;;
  esac

  command -v qemu-system-arm >/dev/null \
    || die "qemu-system-arm not in PATH (enter 'nix develop' or run via 'nix run')"
  command -v timeout >/dev/null \
    || die "timeout(1) not in PATH (coreutils missing from runtime closure)"

  if ! qemu_machine_is_available "$machine"; then
    list_cortex_a8_boards
    die "machine '$machine' not in this QEMU (stock QEMU 9.2.4 has no i.MX50)"
  fi

  local mem_mb
  mem_mb="$(resolve_mem_mb "$machine")"
  [[ "$mem_mb" =~ ^[0-9]+$ ]] || die "resolved memory '$mem_mb' is not numeric"

  local sd_image="build/kobo-sd-$version.img"
  local zimage="build/zImage-$version"
  [[ -f "$sd_image" ]] \
    || die "missing $sd_image — build it with: scripts/build-sd.sh $version"
  [[ -f "$zimage" ]] \
    || die "missing $zimage — build it with: scripts/build-sd.sh $version"

  mkdir -p logs
  local log="logs/boot-$version-$machine.log"
  : > "$log" || die "cannot write log $log"

  local -a display_flags=(-display none)
  case "$display" in
    sdl) display_flags=(-display sdl) ;;
    vnc) display_flags=(-display none -vnc :1) ;;
  esac

  local -a qemu_cmd=(
    qemu-system-arm
    -M "$machine" -cpu "$WANT_CPU" -m "${mem_mb}M"
    -kernel "$zimage"
    -append "$GUEST_CMDLINE"
    -drive "file=$sd_image,format=raw,if=sd"
    -serial "file:$log"
    -no-reboot
    "${display_flags[@]}"
  )

  echo "kobo-emu: target=Kobo Touch N905 (i.MX508, $WANT_CPU, ${mem_mb}MB)"
  echo "kobo-emu: version=$version machine=$machine display=$display timeout=${timeout_s}s"
  echo "kobo-emu: qemu=$(qemu-system-arm --version | head -1)"
  echo "kobo-emu: sd=$sd_image kernel=$zimage"
  echo "kobo-emu: log=$log"

  if [[ "$timeout_s" -gt 0 ]]; then
    local rc=0
    timeout --signal=KILL "$timeout_s" "${qemu_cmd[@]}" || rc=$?
    echo "kobo-emu: qemu exited (rc=$rc); serial tail:"
  else
    exec "${qemu_cmd[@]}"
  fi
  tail -20 "$log" || true
}

main "$@"
