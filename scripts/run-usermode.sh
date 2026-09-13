#!/usr/bin/env bash
# run-usermode.sh — run Kobo ARM userspace under qemu-arm with fb/touch shims.
#
# Usage:
#   run-usermode.sh [--version V] [--mode test|nickel|koreader] [--timeout S]
#                   [--artifacts DIR]
#
# Modes:
#   test    build the ARM shims, seed synthetic touch, run the fb-test guest
#           program under qemu-arm + LD_PRELOAD shim, dump the virtual
#           framebuffer to artifacts/fb-test-<V>.png
#   nickel  same staging, then run the real Nickel binary headless under the
#           shim and capture its log (expected: runs into init, no paint yet)
#   koreader  stage the KOReader Kobo bundle at onboard/.kobo/koreader and run
#           its luajit frontend directly under qemu-arm + shim (no wifi gate;
#           expected: paints /dev/fb0)
#
# All scratch lives under build/ and artifacts/ (both gitignored).
set -euo pipefail

VERSION="4.38.23684"
MODE="test"
TIMEOUT=""
ARTIFACTS="artifacts"

print_usage() {
  cat <<'USAGE'
  Usage: run-usermode.sh [--version V] [--mode test|nickel|koreader] [--timeout S] [--artifacts DIR]
USAGE
}

need() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "run-usermode: error: '$1' not in PATH (enter 'nix develop')" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version) VERSION="${2:?run-usermode: error: --version needs a value}"; shift 2 ;;
    --mode) MODE="${2:?run-usermode: error: --mode needs a value}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?run-usermode: error: --timeout needs a value}"; shift 2 ;;
    --artifacts) ARTIFACTS="${2:?run-usermode: error: --artifacts needs a value}"; shift 2 ;;
    --help|-h) print_usage; exit 0 ;;
    --*) echo "run-usermode: error: unknown flag: $1" >&2; exit 1 ;;
    *) echo "run-usermode: error: unexpected argument: $1" >&2; exit 1 ;;
  esac
done

[[ "$MODE" == "test" || "$MODE" == "nickel" || "$MODE" == "koreader" ]] \
  || { echo "run-usermode: error: --mode must be test|nickel|koreader" >&2; exit 1; }
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
  || { echo "run-usermode: error: malformed version '$VERSION'" >&2; exit 1; }
if [[ -z "$TIMEOUT" ]]; then
  [[ "$MODE" == "test" ]] && TIMEOUT=30 || TIMEOUT=45
  [[ "$MODE" == "koreader" ]] && TIMEOUT=60
fi

need qemu-arm
need zig
need python3
need timeout
need unzip

ROOT="build/rootfs-$VERSION"
FIRMWARE_TGZ="firmware/$VERSION/KoboRoot.tgz"

# 1. Rootfs: unpack from the firmware tarball when the scratch dir is absent.
if [[ ! -d "$ROOT" ]]; then
  [[ -f "$FIRMWARE_TGZ" ]] \
    || { echo "run-usermode: error: missing $FIRMWARE_TGZ" >&2; exit 1; }
  echo "run-usermode: unpacking $FIRMWARE_TGZ -> $ROOT/"
  mkdir -p "$ROOT"
  tar -xzf "$FIRMWARE_TGZ" -C "$ROOT"
fi

# 2. Loader fixups (idempotent): relativize absolute symlinks (qemu-arm does
#    not resolve them under -L) and recreate the soname symlinks KoboRoot.tgz
#    omits (on-device ldconfig would own these).
echo "run-usermode: applying loader fixups under $ROOT/"
python3 - "$ROOT" <<'PYEOF'
import os, sys

root = sys.argv[1]
relativized, sonames, compat = 0, 0, 0

for dirpath, _dirnames, filenames in os.walk(root):
    for name in filenames:
        link = os.path.join(dirpath, name)
        if not os.path.islink(link):
            continue
        target = os.readlink(link)
        if os.path.isabs(target) and os.path.exists(root + target):
            os.remove(link)
            os.symlink(os.path.relpath(root + target, dirpath), link)
            relativized += 1

COMPAT = {
    "lib/libpng.so": "libpng12.so.0.43.0",
    "usr/lib/libcrypto.so": "libcrypto.so.0.9.8",
}
for rel_link, rel_target in COMPAT.items():
    link = os.path.join(root, rel_link)
    want = os.path.join(os.path.dirname(link), rel_target)
    if os.path.exists(want) and not os.path.exists(link):
        if os.path.islink(link):
            os.remove(link)
        os.symlink(rel_target, link)
        compat += 1
        print("run-usermode: compat %s -> %s" % (rel_link, rel_target))

for libdir in ("lib", "usr/lib"):
    full = os.path.join(root, libdir)
    if not os.path.isdir(full):
        continue
    for name in sorted(os.listdir(full)):
        link = os.path.join(full, name)
        if not os.path.islink(link) or os.path.exists(link):
            continue
        siblings = sorted(f for f in os.listdir(full)
                          if f.startswith(name) and f != name
                          and os.path.exists(os.path.join(full, f)))
        if not siblings:
            continue
        os.remove(link)
        os.symlink(siblings[-1], link)
        sonames += 1
        print("run-usermode: soname %s/%s -> %s" % (libdir, name, siblings[-1]))

print("run-usermode: fixups: relativized=%d sonames=%d compat=%d"
      % (relativized, sonames, compat))
PYEOF

# 3. Device placeholders: the tarball ships no /dev (devtmpfs at runtime);
#    empty regular files satisfy access()/stat() probes while open() still
#    routes through the shim.
mkdir -p "$ROOT/dev/input" "$ROOT/tmp" "$ROOT/kobo-emu"
touch "$ROOT/dev/fb0" "$ROOT/dev/input/event0" "$ROOT/dev/input/event1" "$ROOT/dev/mmcblk0"

# 4. Build the ARM shims with zig (pinned glibc 2.11 baseline, lazy binding:
#    the guest loader predates BIND_NOW-era assumptions and chokes otherwise).
echo "run-usermode: building ARM shims"
mkdir -p build/shims
ZIG_FLAGS="-target arm-linux-gnueabihf.2.11 -O2 -Wl,-z,lazy"
# shellcheck disable=SC2086
zig cc $ZIG_FLAGS -shared -fPIC shims/kobo-fb-shim.c -o build/shims/libkobofb.so
# shellcheck disable=SC2086
zig cc -target arm-linux-gnueabihf.2.11 -O2 -Wl,-z,lazy \
  shims/fb-test.c -o build/shims/fb-test
zig cc -target arm-linux-musleabihf -static -O2 \
  shims/hello.c -o build/shims/hello
cp build/shims/libkobofb.so build/shims/fb-test "$ROOT/kobo-emu/"

# 5. Backing files must pre-exist under the sysroot: qemu-arm falls back to
#    the host path when a -L-prefixed open hits ENOENT (even with O_CREAT).
#    The touch transport is mode-specific, and each evdev node gets its own
#    backing (the shim routes event1/touch to kobo-touch0.bin, every other
#    eventN to kobo-button0.bin — sharing one FIFO lets the button poll
#    steal the touch stream):
#    - test: regular files with the proven 6-event tap (fb-test drains
#      event0 exactly to EOF; byte-identical seed keeps checksum=244284764).
#    - nickel: FIFOs, EMPTY (same readiness rationale as koreader: a
#      regular file is always poll-ready, so Qt's notifier refires instantly
#      and hot-spins ~2000:1 empty:data reads instead of poll-waiting.
#      Mid-run taps come live via scripts/kobo-tap.sh --fifo).
#    - koreader: FIFOs, EMPTY (a regular file is always poll-ready, which
#      breaks KOReader's gesture timers; pre-seeded taps would arrive as
#      one stale burst — mid-run taps come live via scripts/kobo-tap.sh).
python3 - "$ROOT" "$MODE" <<'PYEOF'
import errno, os, struct, sys

root, mode = sys.argv[1], sys.argv[2]
tmp = os.path.join(root, "tmp")

fb = os.path.join(tmp, "kobo-fb0.bin")
with open(fb, "wb") as handle:
    handle.truncate(800 * 600 * 2)

open(os.path.join(tmp, "kobo-shim.log"), "w").close()

touch = os.path.join(tmp, "kobo-touch0.bin")
button = os.path.join(tmp, "kobo-button0.bin")
for staged in (touch, button):
    try:
        os.remove(staged)
    except OSError:
        pass

event = struct.Struct("iiHHI")
tap = [(3, 0, 400), (3, 1, 300), (1, 0x14A, 1), (0, 0, 0),
       (1, 0x14A, 0), (0, 0, 0)]

if mode in ("koreader", "nickel"):
    os.mkfifo(touch, 0o644)
    os.mkfifo(button, 0o644)
    print("run-usermode: staged fb backing + empty touch/button FIFOs in %s/" % tmp)
else:
    for seeded in (touch, button):
        with open(seeded, "wb") as handle:
            for index, (kind, code, value) in enumerate(tap):
                handle.write(event.pack(index, 1000 * index, kind, code, value))
    print("run-usermode: staged fb backing + 6-event synthetic tap in %s/" % tmp)
PYEOF

# 6. OOBE-bypass staging where Nickel actually reads it: strace shows the
#    only config lookup is /mnt/onboard/.kobo/Kobo/Kobo eReader.conf (plus a
#    Qt-xdg fallback that never exists). N3FSSyncManager::sync() takes an
#    unsigned-device early exit to finished() unless the boot-warmed global
#    Settings cache holds SideloadedMode=true under the section it queries;
#    a single [Application] entry is NOT enough (gate still fires). Stage the
#    key bare (top-level) plus under [Application], [ApplicationPreferences],
#    and [General] — the exact set that reached FSSyncManager::sync on the
#    manual-staging run. Any KoboReader.sqlite there is removed.
ONBOARD_KOBO="$ROOT/mnt/onboard/.kobo"
mkdir -p "$ONBOARD_KOBO/Kobo"
rm -f "$ONBOARD_KOBO/KoboReader.sqlite" "$ONBOARD_KOBO/Kobo/KoboReader.sqlite"
cat > "$ONBOARD_KOBO/Kobo/Kobo eReader.conf" <<'EOF'
SideloadedMode=true
[Application]
SideloadedMode=true
SkipWifiSetupDialog=true

[ApplicationPreferences]
SideloadedMode=true
WifiEnabled=false
AirplaneMode=true

[General]
SideloadedMode=true
EOF
echo "run-usermode: OOBE bypass staged in $ONBOARD_KOBO/Kobo/"

# 6a. Pre-create files Nickel must open with O_CREAT. qemu-arm translates
#    opens of EXISTING files under -L but creates MISSING files on the host
#    (verified: guest touch lands in host /tmp), so any database/config
#    Nickel creates itself dies with ENOENT. Pre-creating empties under the
#    sysroot turns those into ordinary O_RDWR opens: SQLite treats a 0-byte
#    file as a fresh database and initializes its schema on first write.
#    (QSettings O_EXCL temp files like Analytics.conf.<pid> cannot be
#    pre-created by construction; Qt tolerates their absence.)
for precreated in "$ONBOARD_KOBO/KoboReader.sqlite" \
    "$ONBOARD_KOBO/BookReader.sqlite" \
    "$ONBOARD_KOBO/KoboReader.sqlite-journal" \
    "$ONBOARD_KOBO/KoboReader.sqlite-wal" \
    "$ONBOARD_KOBO/BookReader.sqlite-journal" \
    "$ONBOARD_KOBO/BookReader.sqlite-wal" \
    "$ONBOARD_KOBO/version"; do
  rm -f "$precreated"
  : > "$precreated"
done
mkdir -p "$ROOT/mnt/onboard/.adobe-digital-editions"
: > "$ROOT/mnt/onboard/.adobe-digital-editions/device.xml"
echo "run-usermode: pre-created Nickel databases + Adobe device.xml"

# 6b. NickelMenu (homebrew launcher) staging. The genuine KoboRoot.tgz
#    (fetch documented in README §B.4) is staged where rcS picks it up at
#    boot (onboard/.kobo/KoboRoot.tgz) and pre-extracted to its post-boot
#    locations so a painting Nickel sees it immediately. The hello-world
#    binary + menu entry give it something to spawn; menu pickup itself
#    needs a Nickel that reaches its home screen (see painting status).
NM_TGZ="firmware/nickelmenu/KoboRoot.tgz"
mkdir -p "$ROOT/mnt/onboard/.adds/nm"
if [[ -f "$NM_TGZ" ]]; then
  cp "$NM_TGZ" "$ONBOARD_KOBO/KoboRoot.tgz"
  tar -xzf "$NM_TGZ" -C "$ROOT"
  cp build/shims/hello "$ROOT/mnt/onboard/.adds/hello"
  chmod +x "$ROOT/mnt/onboard/.adds/hello"
  cat > "$ROOT/mnt/onboard/.adds/nm/config" <<'EOF'
# NickelMenu config (full format in .adds/nm/doc from the tarball).
menu_item:main:Hello:cmd_spawn:quiet:/mnt/onboard/.adds/hello
menu_item:main:Rescan:nickel_misc:rescan_books
EOF
  echo "run-usermode: NickelMenu staged + hello-world menu entry"
else
  echo "run-usermode: warning: $NM_TGZ absent, NickelMenu skipped" >&2
fi
# /sys is translated under -L (verified: the dvfs enable knob below opens
# and takes a write), so stage a full battery: Nickel polls
# pmic_battery.1/mc13892_bat at boot, and missing capacity/status reads risk
# a 0% reading that ends boot in sync+poweroff instead of the home screen.
BAT_DIR="$ROOT/sys/devices/platform/pmic_battery.1/power_supply/mc13892_bat"
mkdir -p "$BAT_DIR" \
  "$ROOT/sys/devices/platform/pmic_light.1" \
  "$ROOT/sys/devices/platform/mxc_dvfs_core.0"
printf '100\n' > "$BAT_DIR/capacity"
printf 'Full\n' > "$BAT_DIR/status"
printf '0\n' > "$BAT_DIR/time_to_full_now"
for sysknob in "$ROOT/sys/devices/platform/pmic_light.1/lit" \
    "$ROOT/sys/devices/platform/mxc_dvfs_core.0/enable"; do
  [[ -e "$sysknob" ]] || : > "$sysknob"
done
echo "run-usermode: staged full battery (mc13892_bat) + light/DVFS knobs"

# 6c. Wifi-env staging. Nickel's helpers (wpa_supplicant/dhcpcd/ifconfig/...)
#    spawn as HOST processes under qemu-arm (execve passthrough, verified by
#    tracing a marker file to host /tmp), so scripts/fakebin/ provides
#    host-runnable stand-ins (each logs to $FAKEBIN_LOG). The guest side gets
#    the dirs/files rcS would own: the wpa control dir and a minimal client
#    config so Nickel's stat/open probes succeed.
[[ -d scripts/fakebin ]] \
  || { echo "run-usermode: error: scripts/fakebin/ missing (run from the flake root)" >&2; exit 1; }
mkdir -p "$ROOT/var/run/wpa_supplicant" "$ROOT/etc/wpa_supplicant"
cat > "$ROOT/etc/wpa_supplicant/wpa_supplicant.conf" <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
update_config=1
EOF
echo "run-usermode: wifi-env staged (fakebin/ + guest wpa_supplicant.conf)"

# 6d. KOReader staging (first-pixels path; provenance + glibc analysis in
#    README §B.7 and firmware/koreader/fetch-info.txt). The bundle lives at
#    onboard/.kobo/koreader, its on-device home. Skip the re-copy when the
#    marker matches so repeat runs stay fast; KOReader's own runtime files
#    (crash.log, settings) persist across runs, as on device.
KOREADER_ZIP="firmware/koreader/koreader-kobo-v2022.01.zip"
KOREADER_STAGE="$ROOT/mnt/onboard/.kobo/koreader"
KOREADER_MARKER="$KOREADER_STAGE/.staged-v2022.01"
if [[ -f "$KOREADER_ZIP" ]]; then
  if [[ ! -f "$KOREADER_MARKER" ]]; then
    echo "run-usermode: staging KOReader v2022.01 -> $KOREADER_STAGE/"
    rm -rf "$KOREADER_STAGE"
    mkdir -p "$KOREADER_STAGE"
    unzip -q "$KOREADER_ZIP" -d "$KOREADER_STAGE"
    if [[ -f "$KOREADER_STAGE/koreader/reader.lua" && ! -f "$KOREADER_STAGE/reader.lua" ]]; then
      # Flatten the zip's single top-level koreader/ dir.
      mv "$KOREADER_STAGE/koreader/"* "$KOREADER_STAGE/"
      rmdir "$KOREADER_STAGE/koreader"
    fi
    [[ -f "$KOREADER_STAGE/reader.lua" && -x "$KOREADER_STAGE/luajit" ]] \
      || { echo "run-usermode: error: KOReader stage incomplete after unzip" >&2; exit 1; }
    touch "$KOREADER_MARKER"
  else
    echo "run-usermode: KOReader v2022.01 already staged"
  fi
else
  echo "run-usermode: warning: $KOREADER_ZIP absent, koreader mode unavailable" >&2
fi

# 7. Launch under a sanitized host env (host LD_LIBRARY_PATH would leak into
#    the guest loader); the guest gets an rcS-like PATH plus C locale (the
#    guest glibc 2.11 aborts on the host's locale data). rcS-derived exports
#    (mx50-ntx branch: N905 "trilogy" defaults) so Nickel's `ifconfig %1`
#    templates render a real interface name instead of the empty string that
#    previously doomed every wifi helper call. The launch host PATH puts
#    scripts/fakebin/ first so Nickel's host-executed children find the
#    stand-ins instead of failing with 127.
mkdir -p "$ARTIFACTS"
LOG="$ARTIFACTS/usermode-$VERSION-$MODE.log"
case "$ARTIFACTS" in
  /*) FAKEBIN_LOG="$ARTIFACTS/fakebin-$VERSION-$MODE.log" ;;
  *) FAKEBIN_LOG="$PWD/$ARTIFACTS/fakebin-$VERSION-$MODE.log" ;;
esac
: > "$FAKEBIN_LOG"
QEMU_ARM="$(command -v qemu-arm)"
# Nickel's children execute on the HOST (qemu-user execve passthrough) with
# Nickel's own environ, so the host-absolute fakebin dir rides along in the
# guest PATH: guest-side lookups resolve to the real Kobo binaries first
# (fakebin is last), while host-side lookups fall through /bin:/sbin/... to
# the stand-ins. Fail fast when the dir is absent so helpers can never
# silently miss.
GUEST_ENV=(
  -E "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/Kobo:$PWD/scripts/fakebin"
  -E "FAKEBIN_DIR=$PWD/scripts/fakebin"
  -E "FAKEBIN_LOG_PATH=$FAKEBIN_LOG"
  -E "KOBO_SYSROOT=$PWD/$ROOT"
  -E LC_ALL=C -E LANG=C
  -E LD_LIBRARY_PATH=/usr/local/Kobo:/usr/local/Qt-5.2.1-arm/lib
  -E LD_PRELOAD=/kobo-emu/libkobofb.so
  -E KOBO_SHIM_LOG=/tmp/kobo-shim.log
  -E PLATFORM=mx50-ntx -E CPU=mx50 -E PRODUCT=trilogy
  -E INTERFACE=eth0 -E WIFI_MODULE=dhd
  -E NICKEL_HOME=/mnt/onboard/.kobo
)
# test mode drains the seeded tap to EOF, so it alone gets the bounded-grace
# EOF policy; nickel/koreader block on empty queues like real evdev nodes.
# FIFO touch transport (nickel + koreader): a regular backing file is always
# poll-ready, so Qt's notifier / KOReader's gesture timers never wait —
# Nickel hot-spun ~2000:1 empty:data reads. FIFOs are natively blocking +
# poll-gated, so readers sleep until kobo-tap.sh --fifo injects live taps.
[[ "$MODE" == "test" ]] && GUEST_ENV+=(-E KOBO_TOUCH_EOF=1)
[[ "$MODE" == "nickel" || "$MODE" == "koreader" ]] && GUEST_ENV+=(-E KOBO_TOUCH_FIFO=1)
echo "run-usermode: launching mode=$MODE timeout=${TIMEOUT}s log=$LOG"
rc=0
if [[ "$MODE" == "test" ]]; then
  env -i PATH=/usr/bin:/bin timeout "$TIMEOUT" "$QEMU_ARM" -L "$ROOT" \
    "${GUEST_ENV[@]}" "$ROOT/kobo-emu/fb-test" >"$LOG" 2>&1 || rc=$?
elif [[ "$MODE" == "nickel" ]]; then
  env -i "PATH=$PWD/scripts/fakebin:/usr/bin:/bin" "FAKEBIN_LOG=$FAKEBIN_LOG" \
    timeout "$TIMEOUT" "$QEMU_ARM" -L "$ROOT" \
    "${GUEST_ENV[@]}" "$ROOT/usr/local/Kobo/nickel" \
    -platform kobo -skipFontLoad >"$LOG" 2>&1 || rc=$?
else
  # koreader: invoke luajit directly (koreader.sh's shell Preliminaries —
  # cpufreq, fbdepth, update check, nickel-kill — assume real hardware and
  # would run on the HOST under qemu-arm's execve passthrough, so they are
  # bypassed; the env it would export is replicated below). reader.lua uses
  # cwd-relative package.path/data dirs, so launch from the stage dir inside
  # a subshell with absolute host paths.
  [[ -f "$KOREADER_MARKER" ]] \
    || { echo "run-usermode: error: KOReader not staged ($KOREADER_ZIP missing?)" >&2; exit 1; }
  if [[ ! -s "$ONBOARD_KOBO/version" ]]; then
    # KOReader splits this CSV line (field 3 = fw rev, tail = product id);
    # an empty file nil-crashes its Lua parser.
    printf '%s\n' '00000000-0000-0000-0000-000000000000,6.18.33.2,4.38.23684,000' \
      > "$ONBOARD_KOBO/version"
    echo "run-usermode: seeded onboard version line for KOReader device probe"
  fi
  ROOT_ABS="$PWD/$ROOT"
  case "$LOG" in
    /*) LOG_ABS="$LOG" ;;
    *) LOG_ABS="$PWD/$LOG" ;;
  esac
  STAGE_ABS="$PWD/$KOREADER_STAGE"
  KOREADER_ENV=(
    -E "PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/Kobo"
    -E LC_ALL=C -E LANG=C
    -E LD_LIBRARY_PATH=/mnt/onboard/.kobo/koreader/libs:/usr/local/Kobo:/usr/local/Qt-5.2.1-arm/lib
    -E LD_PRELOAD=/kobo-emu/libkobofb.so
    -E KOBO_SHIM_LOG=/tmp/kobo-shim.log
    # Sysroot for the shim's unlink redirect: qemu-arm -L lets unlink of a
    # sysroot file fall through to the host, so the shim re-attempts ENOENT
    # unlinks against this host-absolute prefix (fail-open when unset).
    -E "KOBO_SYSROOT=$ROOT_ABS"
    # Portrait panel: KOReader enforces portrait 600x800 and would otherwise
    # BB-rotate it sideways into our landscape backing (see README §B.8).
    # FIFO touch transport: KOReader's gesture timers need a pollable input
    # node (a regular file is always poll-ready, so timers never fire).
    -E KOBO_FB_PORTRAIT=1
    -E KOBO_TOUCH_FIFO=1
    # Opt-in per-event touch logging ($KOBO_SHIM_TOUCH_DEBUG=1 on the host
    # enables it in the guest); off by default to keep the shim log small.
    -E "KOBO_SHIM_TOUCH_DEBUG=${KOBO_SHIM_TOUCH_DEBUG:-0}"
    -E KOREADER_DIR=/mnt/onboard/.kobo/koreader
    -E PLATFORM=mx50-ntx -E CPU=mx50 -E PRODUCT=trilogy
    -E INTERFACE=eth0 -E WIFI_MODULE=dhd
    -E NICKEL_HOME=/mnt/onboard/.kobo
  )
  (
    cd "$STAGE_ABS" || exit 1
    env -i PATH=/usr/bin:/bin timeout "$TIMEOUT" "$QEMU_ARM" -L "$ROOT_ABS" \
      "${KOREADER_ENV[@]}" "$STAGE_ABS/luajit" reader.lua >"$LOG_ABS" 2>&1
  ) || rc=$?
fi

# 8. Dump whatever the virtual panel holds (portrait dims in koreader mode).
PNG="$ARTIFACTS/fb-$VERSION-$MODE.png"
if [[ "$MODE" == "koreader" ]]; then
  python3 shims/fb-dump.py "$ROOT/tmp/kobo-fb0.bin" "$PNG" --width 600 --height 800
else
  python3 shims/fb-dump.py "$ROOT/tmp/kobo-fb0.bin" "$PNG"
fi

echo "run-usermode: done mode=$MODE rc=$rc (124 = still running at timeout)"
echo "run-usermode: guest log : $LOG"
echo "run-usermode: helper log: $FAKEBIN_LOG"
echo "run-usermode: shim log  : $ROOT/tmp/kobo-shim.log"
echo "run-usermode: framebuffer: $PNG"
if [[ "$rc" == "124" && "$MODE" != "test" ]]; then
  # 124 = still running at timeout, not a crash (nickel idles post-wifi,
  # koreader runs its event loop indefinitely). test mode must finish fast,
  # so its timeouts keep failing loudly below.
  echo "run-usermode: $MODE survived startup (timeout, not a crash)"
  exit 0
fi
exit "$rc"
