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

  # Track A fixup: the shipped rootfs has a dangling loader chain
  # (lib/ld-linux-armhf.so.3 -> ld-linux.so.3, target missing) while
  # bin/busybox's PT_INTERP needs /lib/ld-linux-armhf.so.3 and only
  # lib/ld-2.11.1.so exists (ELF magic + e_machine EM_ARM + ET_DYN,
  # verified via header). Supply the missing hop so the chain resolves.
  [[ -f "$stage/lib/ld-2.11.1.so" ]] \
    || die "missing $stage/lib/ld-2.11.1.so — cannot repair loader chain"
  if [[ ! -e "$stage/lib/ld-linux.so.3" ]]; then
    ln -s ld-2.11.1.so "$stage/lib/ld-linux.so.3"
  fi

  # Track A soname fixups (mirror of run-usermode.sh loader fixups):
  # KoboRoot.tgz ships versioned libs (libm-2.11.1.so, libdbus-1.so.3.4.0,
  # ...) but omits the soname symlinks on-device ldconfig would own, so
  # /sbin/init (busybox: NEEDED libc.so.6, libm.so.6, libresolv.so.2 per
  # strings) dies with "libm.so.6: cannot open shared object file". Recreate
  # them here: relativize absolute symlinks (same 38 as run-usermode.sh),
  # repair broken soname links by sibling prefix, create missing sonames
  # (explicit glibc map + generic libfoo.so.MAJOR derivation covering
  # libdbus-1.so.3, libiconv.so.2, libjpeg.so.62, libudev.so.0, libz.so.1,
  # libstdc++.so.6, libxml2.so.2, libattr.so.1, libfreetype.so.6), then the
  # libpng/libcrypto compat links. Idempotent.
  command -v python3 >/dev/null || die "python3 not in PATH (enter 'nix develop')"
  python3 - "$stage" <<'PYEOF'
import os
import re
import sys

stage = sys.argv[1]
relativized = repaired = created = compat = 0

for dirpath, _dirnames, filenames in os.walk(stage):
    for name in filenames:
        link = os.path.join(dirpath, name)
        if not os.path.islink(link):
            continue
        target = os.readlink(link)
        if os.path.isabs(target) and os.path.exists(stage + target):
            os.remove(link)
            os.symlink(os.path.relpath(stage + target, dirpath), link)
            relativized += 1

for rel_link, rel_target in (
    ("lib/libpng.so", "libpng12.so.0.43.0"),
    ("usr/lib/libcrypto.so", "libcrypto.so.0.9.8"),
):
    link = os.path.join(stage, rel_link)
    want = os.path.join(os.path.dirname(link), rel_target)
    if os.path.exists(want) and not os.path.exists(link):
        if os.path.islink(link):
            os.remove(link)
        os.symlink(rel_target, link)
        compat += 1
        print("build-sd: compat %s -> %s" % (rel_link, rel_target))

for libdir in ("lib", "usr/lib"):
    full = os.path.join(stage, libdir)
    if not os.path.isdir(full):
        continue
    for name in sorted(os.listdir(full)):
        link = os.path.join(full, name)
        if not os.path.islink(link) or os.path.exists(link):
            continue
        siblings = sorted(
            f for f in os.listdir(full)
            if f.startswith(name) and f != name
            and os.path.exists(os.path.join(full, f))
        )
        if not siblings:
            continue
        os.remove(link)
        os.symlink(siblings[-1], link)
        repaired += 1
        print("build-sd: soname %s/%s -> %s" % (libdir, name, siblings[-1]))

for libdir, soname, target in (
    ("lib", "libc.so.6", "libc-2.11.1.so"),
    ("lib", "libm.so.6", "libm-2.11.1.so"),
    ("lib", "libpthread.so.0", "libpthread-2.11.1.so"),
    ("lib", "libdl.so.2", "libdl-2.11.1.so"),
    ("lib", "librt.so.1", "librt-2.11.1.so"),
    ("lib", "libresolv.so.2", "libresolv-2.11.1.so"),
    ("lib", "libnsl.so.1", "libnsl-2.11.1.so"),
    ("lib", "libutil.so.1", "libutil-2.11.1.so"),
    ("lib", "libcrypt.so.1", "libcrypt-2.11.1.so"),
    ("lib", "libanl.so.1", "libanl-2.11.1.so"),
    # Track A dbus-late: glibc NSS shims dlopen libnss_<svc>.so.2 at
    # runtime (getpwuid/getpwnam for dbus-daemon's user="root" policy).
    # The dash-versioned libs ship without those sonames and the generic
    # derivation above cannot guess them (no ".so.N" substring), so without
    # these links every user lookup fails ("User ??? unknown") even with a
    # correct /etc/passwd. Same idempotent shape as the glibc map above.
    ("lib", "libnss_compat.so.2", "libnss_compat-2.11.1.so"),
    ("lib", "libnss_dns.so.2", "libnss_dns-2.11.1.so"),
    ("lib", "libnss_files.so.2", "libnss_files-2.11.1.so"),
    ("lib", "libnss_hesiod.so.2", "libnss_hesiod-2.11.1.so"),
    ("lib", "libnss_nis.so.2", "libnss_nis-2.11.1.so"),
    ("lib", "libnss_nisplus.so.2", "libnss_nisplus-2.11.1.so"),
):
    link = os.path.join(stage, libdir, soname)
    want = os.path.join(stage, libdir, target)
    if os.path.exists(want) and not os.path.exists(link):
        if os.path.islink(link):
            os.remove(link)
        os.symlink(target, link)
        created += 1
        print("build-sd: soname %s/%s -> %s" % (libdir, soname, target))

soname_re = re.compile(r"(.+\.so\.\d+).*")
for libdir in ("lib", "usr/lib"):
    full = os.path.join(stage, libdir)
    if not os.path.isdir(full):
        continue
    for name in sorted(os.listdir(full)):
        match = soname_re.fullmatch(name)
        if not match:
            continue
        soname = match.group(1)
        if soname == name:
            continue
        link = os.path.join(full, soname)
        if os.path.exists(link):
            continue
        if os.path.islink(link):
            os.remove(link)
        os.symlink(name, link)
        created += 1
        print("build-sd: soname %s/%s -> %s" % (libdir, soname, name))

print("build-sd: loader fixups: relativized=%d repaired=%d created=%d compat=%d"
      % (relativized, repaired, created, compat))
PYEOF

  # Track A rcS fixup: stock rcS assumes on-device udev + a factory eMMC
  # layout, neither of which exists in the emu image, so guest init
  # reboots forever (see logs/trackA-dctl-late/late.log):
  #   * KoboRoot.tgz ships no /sbin/udevd or /sbin/udevadm (only helper
  #     scripts under /usr/local/Kobo/udev), so after rcS mounts tmpfs
  #     over /dev every mmc open fails ("can't open '/dev/mmcblk0'",
  #     "can't open '/dev/null'").
  #   * dosfsck then fails 4x on the missing onboard node, setting
  #     FS_CORRUPT=1, which selects the factory-reset branch whose
  #     `reboot` loops forever ("Requesting system reboot" +
  #     "Kernel---System reset ---").
  #   * The emu SD lays the FAT second (MBR slot 2 = mmcblk0p2) while
  #     stock rcS expects onboard at mmcblk0p3, so p3 is aliased to p2.
  # Patch the STAGED rcS copy (the tarball is untouched): create the
  # minimum static nodes right after the tmpfs /dev mount (a staged
  # /dev would be wiped by that mount, and unprivileged builds cannot
  # mknod into the image anyway), skip the udevadm dance when the
  # binaries are absent, and turn the factory-reset `reboot; exit`
  # into a diagnostic so boot falls through toward Nickel. The EPDC
  # fw block already gates on [ ! -s ] and is left alone (no fake fw).
  python3 - "$stage" <<'PYEOF'
import sys

stage = sys.argv[1]
path = stage + "/etc/init.d/rcS"
with open(path, "r", encoding="utf-8") as handle:
    rcs = handle.read()


def replace_once(old, new, label):
    global rcs
    found = rcs.count(old)
    if found != 1:
        print("build-sd: rcS patch %s: anchor found %d times, want 1" % (label, found))
        sys.exit(1)
    rcs = rcs.replace(old, new, 1)
    print("build-sd: rcS patch applied: %s" % label)


replace_once(
    "/bin/mount -t tmpfs none /dev\n",
    "/bin/mount -t tmpfs none /dev\n"
    "# Track A emu: no udevd ships in KoboRoot, so populate the fresh\n"
    "# tmpfs /dev with the minimum static nodes rcS needs (guest is root).\n"
    "mknod /dev/null c 1 3\n"
    "mknod /dev/zero c 1 5\n"
    "mknod /dev/console c 5 1\n"
    "mknod /dev/tty c 5 0\n"
    "mknod /dev/mmcblk0 b 179 0\n"
    "mknod /dev/mmcblk0p1 b 179 1\n"
    "mknod /dev/mmcblk0p2 b 179 2\n"
    "ln -sf mmcblk0p2 /dev/mmcblk0p3 # emu FAT is MBR slot 2; stock rcS wants p3\n"
    "mknod /dev/fb0 c 29 0 # EPDC framebuffer, if the driver registered it\n"
    "# Track A emu nickel-late: hwclock wants /dev/misc/rtc and Nickel /\n"
    "# hindenburg probe /dev/input/event*; udev is absent so create them here.\n"
    "mkdir -p /dev/input /dev/misc\n"
    "mknod /dev/misc/rtc c 10 135 # pmic_rtc compat (hwclock -s -u)\n"
    "mknod /dev/rtc c 10 135 # rtc compat symlink target\n"
    "mknod /dev/rtc0 c 254 0 # rtc core (registered as rtc0 in boot log)\n"
    "mknod /dev/input/event0 c 13 64 # mxckpd / zForce-ir-touch evdev\n"
    "mknod /dev/input/event1 c 13 65\n"
    "mknod /dev/input/event2 c 13 66\n"
    "mknod /dev/input/mice c 13 63 # evdev mice compat\n"
    "chmod 666 /dev/null /dev/zero\n",
    "static-dev-nodes",
)

replace_once(
    "/sbin/udevd -d\n",
    "[ -x /sbin/udevd ] && /sbin/udevd -d || true # Track A emu: udevd not shipped\n",
    "udevd-guard",
)

replace_once(
    "if [ $PLATFORM == freescale ] || [ ! -e /etc/udev.tgz ]; then\n",
    "if [ -x /sbin/udevadm ] && { [ $PLATFORM == freescale ] || [ ! -e /etc/udev.tgz ]; }; then\n",
    "udevadm-guard",
)

replace_once(
    "\twrite_uboot_env $PLATFORM $UBOOT_RECOVERY\n\treboot\n\texit\n",
    "\twrite_uboot_env $PLATFORM $UBOOT_RECOVERY\n"
    "\t# Track A emu: never reboot out of rcS; fall through toward Nickel.\n"
    "\techo \"rcS-emu: factory-reset reboot stubbed; continuing to Nickel\" > /dev/console\n",
    "factory-reset-reboot-stub",
)

replace_once(
    "handle_passwd $PRODUCT_BASE_NAME\n",
    "handle_passwd $PRODUCT_BASE_NAME\n"
    "# Track A emu dbus-late: HW CONFIG is absent here (sector 1024 zeroed,\n"
    "# no mmcblk0p6 node), so kobo_config.sh/ntx_hwconfig cannot resolve a\n"
    "# product name and handle_passwd() can leave /etc/passwd without root\n"
    "# (the tarball ships no /etc/passwd, only /etc/passwds/ +\n"
    "# /etc/passwd_update). dbus-uuidgen/daemon then fail getpwuid(0)\n"
    "# ('User ??? unknown') and the config's user=\"root\" lookup ('Unknown\n"
    "# username root'), so no system bus exists for Nickel. Re-assert the\n"
    "# two daemon-critical entries with the exact /etc/passwd_update lines\n"
    "# if the call above missed them (idempotent; no-op when intact).\n"
    "grep -q '^root:' /etc/passwd 2>/dev/null || echo 'root:H0AaAeTNN06O6:0:0:root:/:/bin/sh' >> /etc/passwd\n"
    "grep -q '^messagebus:' /etc/passwd 2>/dev/null || echo 'messagebus:*:30:30:messagebus::/bin/false' >> /etc/passwd\n",
    "passwd-restore",
)

replace_once(
    "/bin/dbus-uuidgen > /var/lib/dbus/machine-id\n",
    "# Track A emu dbus-late preflight: one line to serial before dbus starts;\n"
    "# if dbus fails this shows whether /etc/passwd lost root/messagebus.\n"
    "(id; cat /etc/passwd) > /dev/console 2>&1\n"
    "/bin/dbus-uuidgen > /var/lib/dbus/machine-id\n",
    "dbus-preflight",
)

with open(path, "w", encoding="utf-8") as handle:
    handle.write(rcs)
print("build-sd: rcS fixup complete: %s" % path)
PYEOF

  # Track A nickel-late fixup: KoboRoot.tgz ships only /etc/dbus-1/system.d/
  # (dhcpcd-dbus.conf) — no system.conf/session.conf anywhere in the tarball
  # (verified via tar tzf grep) — so rcS's tail fails verbatim:
  #   /bin/dbus-daemon --system &                                   -> "Failed
  #     to open //etc/dbus-1/system.conf: No such file or directory"
  #   DBUS_SESSION_BUS_ADDRESS=$(/bin/dbus-daemon --session ...)    -> "Failed
  #     to open //etc/dbus-1/session.conf: No such file or directory"
  # (see logs/trackA-rcsfix/late.log) and Nickel/hindenburg start with no
  # bus. dbus-daemon 1.6.30 defaults to //etc/dbus-1/{system,session}.conf
  # (strings on the staged bin confirms), so stage minimal emu-permissive
  # confs. Paths match what rcS already prepares (/var/run/dbus pid+socket
  # dir, /var/lib/dbus machine-id) and the servicedirs the tarball does
  # ship (/usr/share/dbus-1/services, .../system-services). Permissive
  # policy is intentional: the stock restrictive policy files are absent,
  # and nothing here should gate Nickel input/paint bring-up.
  cat > "$stage/etc/dbus-1/system.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <listen>unix:path=/var/run/dbus/system_bus_socket</listen>
  <pidfile>/var/run/dbus/pid</pidfile>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow user="*"/>
    <allow own="*"/>
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow send_type="method_call"/>
    <allow send_type="method_return"/>
    <allow send_type="error"/>
    <allow send_type="signal"/>
  </policy>
  <includedir>/etc/dbus-1/system.d</includedir>
  <servicedir>/usr/share/dbus-1/system-services</servicedir>
</busconfig>
EOF
  cat > "$stage/etc/dbus-1/session.conf" <<'EOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN"
 "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>session</type>
  <listen>unix:tmpdir=/tmp</listen>
  <auth>EXTERNAL</auth>
  <policy context="default">
    <allow send_destination="*" eavesdrop="true"/>
    <allow eavesdrop="true"/>
    <allow own="*"/>
  </policy>
  <servicedir>/usr/share/dbus-1/services</servicedir>
</busconfig>
EOF
  echo "build-sd: dbus confs staged: $stage/etc/dbus-1/system.conf + session.conf"

  # Track A dbus-late: KoboRoot.tgz ships no /etc/nsswitch.conf, and the
  # glibc default can route passwd/group through compat/nis shims that have
  # no backing in the emu image. Pin files-only lookups so getpwuid(0) and
  # getpwnam("root") resolve straight from the restored /etc/passwd.
  cat > "$stage/etc/nsswitch.conf" <<'EOF'
passwd: files
shadow: files
group: files
hosts: files dns
EOF
  echo "build-sd: nsswitch staged: $stage/etc/nsswitch.conf"

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
  # 2.6.35-era kernel compat: disable modern optional features the old
  # EXT4 driver rejects (64bit/flex_bg/metadata_csum/orphan_file/etc.);
  # 128-byte inodes match the era default. has_journal/extents stay on.
  mke2fs -q -t ext4 -O ^64bit,^huge_file,^flex_bg,^metadata_csum,^orphan_file,^extra_isize -I 128 -b 4096 -L KOBO_ROOTFS -d "$stage" "$p1" "$P1_BLOCKS_4K"

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
