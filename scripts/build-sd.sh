#!/usr/bin/env bash
# build-sd.sh — assemble a raw SD image from a fetched Kobo firmware version.
#
# Usage:
#   build-sd.sh <version> [--out PATH]
#
# Layout (512-byte sectors, DOS MBR):
#   gap   sector 0..2047      zeroed (sector 1024 is the Kobo HW CONFIG slot;
#                             left zeroed, so rcS falls back to PLATFORM=freescale)
#   p1    2048..1050623      ext4 rootfs (KoboRoot.tgz + boot/ kernels)
#   p3    1050624..1312767   FAT16 "ONBOARD" (empty onboard partition)
#
# Outputs (default under build/):
#   build/kobo-sd-<version>.img   raw SD image for qemu -drive/-sd
#   build/zImage-<version>        uImage header stripped (for qemu -kernel)
set -euo pipefail

readonly P1_START=2048
readonly P1_SECTORS=1048576 # 512 MiB
readonly P1_BLOCKS_4K=131072
readonly P3_START=1050624
readonly P3_SECTORS=262144 # 128 MiB
readonly P3_TRACKS=256
readonly P3_HEADS=32
readonly P3_SPT=32

die() {
  echo "build-sd: error: $*" >&2
  exit 1
}

print_usage() {
  cat <<'USAGE'
Usage: build-sd.sh <version> [--out PATH]

  <version>   Firmware version already fetched into firmware/<version>/
  --out PATH  SD image path (default: build/kobo-sd-<version>.img)
USAGE
}

main() {
  [[ $# -ge 1 ]] || { print_usage; die "missing <version> argument"; }
  local version="$1"
  shift
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "malformed version '$version' (want MAJOR.MINOR.BUILD)"

  local out_image="build/kobo-sd-$version.img"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out_image="${2:?build-sd: error: --out needs a value}"; shift 2 ;;
      --help|-h) print_usage; exit 0 ;;
      --*) die "unknown flag: $1 (see --help)" ;;
      *) die "unexpected extra argument: $1" ;;
    esac
  done

  local version_dir="firmware/$version"
  local root_tgz="$version_dir/KoboRoot.tgz"
  local uboot_ntx="$version_dir/upgrade/mx50-ntx/u-boot.bin"
  local uimage_ntx="$version_dir/upgrade/mx50-ntx/uImage"
  local uimage_ref="$version_dir/upgrade/freescale/uImage"

  [[ -f "$root_tgz" ]] || die "missing $root_tgz — run fetch-firmware.sh $version first"
  [[ -f "$uimage_ntx" ]] || die "missing $uimage_ntx — re-run fetch-firmware.sh $version"
  [[ -f "$uimage_ref" ]] || die "missing $uimage_ref — re-run fetch-firmware.sh $version"
  command -v mke2fs >/dev/null || die "mke2fs not in PATH (enter 'nix develop')"
  command -v mformat >/dev/null || die "mformat not in PATH (enter 'nix develop')"
  command -v sfdisk >/dev/null || die "sfdisk not in PATH (enter 'nix develop')"

  mkdir -p build

  # 1. Unpack the rootfs boundary-fresh (build/ is gitignored scratch).
  local stage="build/rootfs-$version"
  echo "build-sd: unpacking $root_tgz -> $stage/"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf "$root_tgz" -C "$stage"

  # 2. Stage the boot-chain copies inside the image for provenance.
  mkdir -p "$stage/boot"
  cp "$uimage_ntx" "$stage/boot/uImage-mx50-ntx"
  cp "$uimage_ref" "$stage/boot/uImage-freescale"
  [[ -f "$uboot_ntx" ]] && cp "$uboot_ntx" "$stage/boot/u-boot-mx50-ntx.bin"

  # 3. Strip the 64-byte uImage header -> raw zImage for qemu -kernel.
  local zimage="build/zImage-$version"
  dd if="$uimage_ntx" of="$zimage" bs=64 skip=1 status=none
  [[ -s "$zimage" ]] || die "zImage came out empty ($zimage)"
  echo "build-sd: zImage: $(file -b "$zimage" | cut -c1-80)"

  # 4. Populate an ext4 p1 directly from the stage dir (no loop mounts).
  local p1="build/p1-$version.ext4"
  rm -f "$p1"
  echo "build-sd: mke2fs p1 ($P1_SECTORS sectors) ..."
  mke2fs -q -t ext4 -b 4096 -L KOBO_ROOTFS -d "$stage" "$p1" "$P1_BLOCKS_4K"

  # 5. Format an empty FAT16 p3 ("ONBOARD"). This mtools build requires
  #    drive-letter syntax, so map a temp drive via MTOOLSRC.
  local p3="build/p3-$version.fat"
  local mtoolsrc="build/mtoolsrc-$version"
  rm -f "$p3"
  printf 'drive p: file="%s/%s"\n' "$PWD" "$p3" > "$mtoolsrc"
  echo "build-sd: mformat p3 ($P3_SECTORS sectors) ..."
  MTOOLSRC="$mtoolsrc" mformat -C -t "$P3_TRACKS" -h "$P3_HEADS" -n "$P3_SPT" -v ONBOARD p:

  # 6. Assemble the raw disk: zero, partition, inject p1 + p3.
  # Total is exactly 1 GiB: cubieboard's SD slot rejects non-power-of-2 sizes.
  rm -f "$out_image"
  echo "build-sd: assembling $out_image ..."
  dd if=/dev/zero of="$out_image" bs=1M count=1024 status=none
  sfdisk -q "$out_image" <<LAYOUT
label: dos
unit: sectors
sector-size: 512
start=$P1_START, size=$P1_SECTORS, type=83
start=$P3_START, size=$P3_SECTORS, type=0e
LAYOUT
  dd if="$p1" of="$out_image" bs=512 seek="$P1_START" conv=notrunc status=none
  dd if="$p3" of="$out_image" bs=512 seek="$P3_START" conv=notrunc status=none

  echo "build-sd: partition table:"
  sfdisk -d "$out_image"
  echo "build-sd: done:"
  ls -la "$out_image" "$zimage"
}

main "$@"
