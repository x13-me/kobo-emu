# kobo-emu — Kobo Touch N905 emulator (QEMU + Nix)

Goal: boot stock N905 firmware in QEMU, packaged as a Nix flake.
Deadline: 0900 UK 2026-09-07 — **passed**. Track B milestones below
were achieved 2026-09-07 (HANDOVER.md).

## Status (2026-09-09)

| Track | State | Evidence |
|---|---|---|
| **Track B — user-mode** | **Functional** | `--mode test` → rc=0, checksum 244284764; `--mode nickel` → rc=124 survival, **first paint landed**: backing 919302/960000 nonzero (md5 db859e20), `artifacts/fb-4.38.23684-nickel.png` md5 05e2d992 showing library/charging screen (book-cover grid, battery glyph, footer bar); `--mode koreader` → paints calibration PNG 950562/960000 bytes; **book render COMPLETE** (`artifacts/koreader-render-proof.png`: "Render Proof Book" fully legible, 5 KOBOEMU RENDER PROOF LINE paragraphs, footer 0/1, backing 933401/960000 nonzero); **sync() trigger VERIFIED** 2026-09-12 (FIFO → `invokeMethod(singleton,"sync",QueuedConnection)` → +492 repaints, zero regression) |
| **Touch → UI** | **Partial** | Footer tap (400,550) → full repaint +7764 nonzero; 3 other taps ignored; DBs 0B; no OOBE/Menu/cmd_spawn. Cover taps pending; zero-DB hypothesis under investigation (see [Handover §2.1](#what-doesnt-work) and `.remember/now.md`) |
| **Track A — full-system** | **Blocked** | 0-byte serial on all runs; 2.6.35 mach-mx50 zImage fails ATAG machine-ID on non-i.MX50 boards |
| **Flake/lint** | **Clean** | `nix flake check` passes; `shellcheck -S warning` clean on all scripts |

**Evidence**: probe/ directory holds pixel-proof, pixel-transfer, wifi-gate, input-wedge, and qt-flush logs + README.

**Firmware**: 4.38.23684 (primary, kobo3/Apr2026) + 4.31.19086 (fallback, kobo3/Jan2022). Full hashes in `firmware/*/fetch-info.txt`.

**Reproduce** (from repo root) — see [HANDOVER §3](#3-exact-reproduction-commands-run-from-repo-root) for the full command matrix:
```
nix run .#kobo-usermode -- --mode test      # rc=0, checksum 244284764
nix run .#kobo-usermode -- --mode nickel    # rc=124 survival
nix run .#kobo-usermode -- --mode koreader  # calibration PNG
```

**Handover rule**: refresh README AND HANDOVER.md after every phase (see [HANDOVER §7](#7-phases--refresh-rule)). A phase is not done until both are current.

## Target device

| Item | Value |
|---|---|
| Device | Kobo Touch N905 (2011) |
| SoC | Freescale i.MX508 (Cortex-A8) |
| RAM | 256 MB |
| Display | 800x600 e-ink |
| Touch | zForce (USB) |
| Firmware hw group | `kobo3` (device id 310 in pgaskin KoboStuff db) |

## QEMU approach

- Machine: `imx50-kobotouch` if the e-ink-emulator fork provides it, else closest
  i.MX50 board; `-cpu cortex-a8 -m 256M`.
- TCG only (no `/dev/kvm` on x86_64 WSL2 host).
- Display SDL/VNC; touch via usb-tablet + tablet_send (pragmatic).
- Host has binfmt `armv7l` enabled; no qemu in PATH, so the flake provides it.

## Layout

```
flake.nix                  inputs: nixpkgs; outputs: apps/packages/devShell
scripts/fetch-firmware.sh  parameterized downloader: fetch-firmware.sh <version> [--hw kobo3] [--url URL] [--out DIR] [--mirror]
scripts/build-sd.sh        assemble build/kobo-sd-<version>.img (1 GiB) + build/zImage-<version> from firmware/<version>/
scripts/boot-kobo.sh       boot the SD image under QEMU: boot-kobo.sh [--version V] [--machine M] [--timeout S] [--display MODE]
scripts/run-usermode.sh    Track B: qemu-arm + fb/touch shims: run-usermode.sh [--version V] [--mode test|nickel|koreader] [--timeout S]
scripts/fakebin/           host-runnable stand-ins for Nickel's wifi helpers (pidof/killall/ifconfig/wpa_supplicant/wpa_cli/dhcpcd/syslogd/wlarm_le/cp)
shims/kobo-fb-shim.c       ARM LD_PRELOAD shim: virtual 800x600 RGB565 /dev/fb0 + synthetic /dev/input/event*
shims/hello.c              ARM homebrew hello-world (NickelMenu cmd_spawn target)
firmware/nickelmenu/       genuine NickelMenu KoboRoot.tgz (see §B.4)
shims/fb-test.c            ARM guest prover: geometry print + test pattern + touch drain
shims/fb-dump.py           host: RGB565 backing -> PNG (stdlib only)
firmware/<version>/        per-version: zip + KoboRoot.tgz + manifest.md5sum + upgrade/ + fetch-info.txt + zip-contents.txt
build/  logs/  artifacts/  gitignored scratch: unpacked rootfs, p1/p3 parts, SD images, zImages, boot logs, shims, PNGs, guest logs
```

## Flake outputs

- `nix run .#kobo-emu -- [--version V] [--machine M] [--timeout S] [--display MODE]` — boot script
- `nix run .#fetch-firmware -- <version>` — firmware downloader
- `nix run .#build-sd -- <version>` — SD image builder
- `nix run .#kobo-usermode -- [--version V] [--mode test|nickel|koreader] [--timeout S]` — user-mode track (this README)
- `nix build .#kobo-emu` / `.#fetch-firmware` / `.#build-sd` / `.#kobo-usermode` — built scripts
- `nix develop` — shell with qemu, gdb, dtc, e2fsprogs, mtools, ubootTools, curl, unzip, zig, strace, shellcheck, …

## Firmware (fetched 2026-09-06, hardware `kobo3`)

| Version | URL | Bytes | SHA-256 |
|---|---|---|---|
| 4.38.23684 (primary) | `https://cdn.kobo.com/downloads/firmwares/kobo3/Apr2026/kobo-update-4.38.23684.zip` | 107569899 | `155d3f3b…473ca34` |
| 4.31.19086 (fallback, N905 max official) | `https://cdn.kobo.com/downloads/firmwares/kobo3/Jan2022/kobo-update-4.31.19086.zip` | 95260246 | `69d869c4…2448425` |

Full hashes in `firmware/<version>/fetch-info.txt`.

Source notes: URLs follow the pgaskin KoboStuff pattern
(`kfw.db.js`: N905 Touch = hw `kobo3`, dev `310`; 4.31.19086 md5
`f1392974…` matches the `kfw.storage.pgaskin.net` MD5SUMS mirror and the CDN
ETag — authentic). The mirror lagged on 4.38.23684 (404), but the Kobo CDN
serves it (HTTP 200, 107569899 bytes, last-modified 2026-04-13).

Each zip extracts to 10 entries:

```
KoboRoot.tgz  manifest.md5sum  upgrade/  upgrade/freescale/{u-boot.bin,uImage}
upgrade/mx50-ntx/{u-boot.bin,uImage,uImage-E60610}
```

Notable: `upgrade/` bootloader+kernel md5s are **identical** across 4.31.19086
and 4.38.23684 (e.g. freescale u-boot.bin `b0d0d58e…`, uImage `a2f4d024…`,
mx50-ntx uImage `2383a870…` = uImage-E60610) — Kobo reuses the kobo3 boot
chain; only KoboRoot.tgz differs.

## Machine choice (Phase 2 decision)

Stock QEMU 9.2.4 (nixpkgs 25.05) has **no i.MX50 machine** — verified via
`qemu-system-arm -M help` (only imx25/imx6ul/imx7; see `docs/` log excerpts).
Fork evaluation (timeboxed): no fetchable `imx50-kobotouch` machine exists —
GitHub repo search for `qemu imx50` returns nothing; the known e-ink QEMU
projects sidestep it (Quill-OS/emu uses `vexpress-a9`, qemu-kindle uses
LD_PRELOAD shims on `virt`). Packaging a fork would mean a full QEMU rebuild
for an unvetted patch set, so per the timebox rule we fell back to stock.

- **Primary: `cubieboard`** — the only in-tree board with a real Cortex-A8
  SoC (Allwinner A10) *and* an SD slot, which the Kobo userspace requires
  (`rcS` addresses `/dev/mmcblk0*` directly). Deviations from N905 hardware:
  512 MB RAM (cubieboard rejects `-m 256M`), no i.MX50 UART/EPDC/zForce.
- **Secondary probe: `realview-pb-a8`** — generic Cortex-A8 dev board, no SD
  slot. Probed once for completeness.

`scripts/boot-kobo.sh` defaults to cubieboard/512M (`KOBO_MEM_MB` overrides).

## Kernel images (2.2: `file` + `mkimage -l`)

| File | Version string | Load | Entry | Date |
|---|---|---|---|---|
| `upgrade/mx50-ntx/uImage` | Linux-2.6.35.3-850-gbc67621+, ARM, uncompressed | `0x70008000` | `0x70008000` | 2016-12-22 |
| `upgrade/freescale/uImage` | Linux-2.6.35.3-568-g4cf53cf-gb54, ARM, uncompressed | `0x70008000` | `0x70008000` | 2015-03-04 |

DRAM base `0x70000000` matches the kobo3 board files (256 MB). The mx50-ntx
uImage is **bit-identical** between 4.38.23684 and 4.31.19086
(md5 `2383a870…6ec9dd`) — only `KoboRoot.tgz` differs per version.

## Rootfs findings (2.3: unpacked to `build/rootfs-<version>/`)

- Init: BusyBox (`/sbin/init -> ../bin/busybox`), `/etc/inittab` runs
  `/etc/init.d/rcS` as sysinit. No systemd, no `/dev` in the tarball
  (devtmpfs/udev at runtime).
- `rcS` is hardware-bound: reads the HW CONFIG block at mmcblk0 sector 1024
  (`ntx_hwconfig`) to select `PLATFORM` (`mx50-ntx` on real HW), remounts
  `/dev/mmcblk0p1` as `/`, `dosfsck`s `/dev/mmcblk0p3` (onboard), extracts the
  EPDC waveform fw from mmcblk0 offset 5 MiB, then launches
  `LIBC_FATAL_STDERR_=1 /usr/local/Kobo/nickel -platform kobo -skipFontLoad &`.
  With a zeroed HW CONFIG slot it degrades to `PLATFORM=freescale`.
- Drivers shipped as modules under `/drivers/ntx508/` (`lowmem`,
  `sdio_wifi_pwr`, USB gadget); EPDC framebuffer (`/dev/fb0`) is in-kernel.
- Nickel: `/usr/local/Kobo/nickel`, ELF32 ARM EABI5 **hard-float**, Qt-based.

## SD image build (2.4: `scripts/build-sd.sh <version>`)

`build/kobo-sd-<version>.img` (exactly 1 GiB raw — cubieboard's SD slot
rejects non-power-of-2 sizes), DOS MBR:

| Part | Start | Size | Type | Content |
|---|---|---|---|---|
| p1 | sector 2048 | 512 MiB | ext4 (`Linux`) | KoboRoot + `boot/{uImage-mx50-ntx,uImage-freescale,u-boot-mx50-ntx.bin}` |
| p3 | sector 1050624 | 128 MiB | FAT16 (`0e`, label `ONBOARD`) | empty onboard |

Built without loop mounts: `mke2fs -d <stage>` for p1, `mformat` (via a temp
`MTOOLSRC` drive-letter mapping — this mtools build requires it) for p3,
`sfdisk` + `dd conv=notrunc` assembly. HW CONFIG sector 1024 stays zeroed
(`freescale` fallback). Also emits `build/zImage-<version>` (uImage header
stripped) for `qemu -kernel`. Owners inside p1 map to the build uid
(cosmetic; `mke2fs -d` has no fakeroot here).

`scripts/boot-kobo.sh [--version V] [--machine M] [--timeout S] [--display none|sdl|vnc]`
replaces the Phase-1 placeholder: `-cpu cortex-a8`, per-machine RAM,
`-drive file=…,format=raw,if=sd`, `-kernel zImage` with
`console=ttymxc0,115200n8 root=/dev/mmcblk0p1 rw rootwait rootfstype=ext4`,
`-serial file:logs/boot-<version>-<machine>.log`, `-no-reboot`, timeout-kill
with rc reporting.

## Boot results (2.5–2.7)

| Run | Timeout | Serial bytes | Outcome |
|---|---|---|---|
| 4.38.23684 / cubieboard | 180 s | **0** | silent hang, killed (rc=137) |
| 4.31.19086 / cubieboard | 120 s | **0** | silent hang, killed (rc=137) |
| 4.38.23684 / realview-pb-a8 | 60 s | **0** | silent hang, killed (rc=137) |

No userspace (no kernel output at all): the 2.6.35 mach-mx50 zImage fails the
ATAG machine-ID check on any non-i.MX50 board, and its low-level debug UART
writes hit unmapped i.MX50 physical addresses — hence zero serial bytes, the
classic unsupported-hardware signature. Not a boot-loop; QEMU itself is
healthy (earlier fail-fast probes: bad `-m`, non-pow2 SD).

Fallback justification (2.6–2.7): the 4.31.19086 attempt was run as specified
and shows the identical signature — expected, since its kernel is
bit-identical to 4.38's. The fallback therefore cannot unblock boot; it stays
valuable as the older-Nickel rootfs for later user-mode or proper-board work.
Primary remains 4.38.23684.

- Screenshots: none — no framebuffer exists without EPDC emulation.
- Display/touch: blocked on the machine, not the image. Next step (Phase 3):
  either (a) package a QEMU fork carrying an i.MX50 machine (revisit with a
  bigger timebox), or (b) pivot to `qemu-arm` user-mode for Nickel against
  fb/touch shims (qemu-kindle pattern), which needs no machine model.

## Build / run status (Phase 2)

- [x] 2.1 machine probe + fork evaluation → cubieboard (this README)
- [x] 2.2 uImage headers recorded (table above)
- [x] 2.3 KoboRoot unpacked + inspected (busybox/rcS/Nickel/EPDC)
- [x] 2.4 `scripts/build-sd.sh` builds 1 GiB SD + zImage; `boot-kobo.sh` wired
- [x] 2.5 headless TCG attempts → 0-byte serial logs in `logs/`
- [x] 2.6–2.7 fallback 4.31.19086 attempted, justification recorded
- [x] Phase-1 self-review: `boot-kobo.sh` real boot path; flake gains
      `coreutils/gnugrep/util-linux` (scripts broke under `nix run`'s hermetic
      PATH without them) + `.#build-sd` package/app; `build/`+`logs/` gitignored
- [x] `nix flake check` passes; `shellcheck -S warning` clean on all scripts

## Track B: user-mode Kobo userspace under qemu-arm (the pragmatic path)

Full-system boot (Track A) is blocked on the machine model (0-byte serial,
§Boot results). Track B sidesteps it: run the stock ARM userspace directly
under `qemu-arm` (QEMU 9.2.4, TCG) with an `LD_PRELOAD` shim standing in for
the i.MX50 EPDC framebuffer and zForce touch controller (qemu-kindle pattern).
No machine model, no kernel, no SD image needed — only `build/rootfs-<V>/`.

Entry point: `nix run .#kobo-usermode -- [--mode test|nickel|koreader]` (see
`scripts/run-usermode.sh`). Toolchain: `zig` 0.14.1 via nixpkgs-25.05
(`nixpkgs#zig` registry is 0.16.0; both verified for the shim build flags).
(`scripts/usermode-demo.sh` + `scripts/fb-proof.py` are the earlier host-side
concept demo — host draws the test card; the shim pipeline below supersedes
it with guest-side mmap/ioctl through a real `LD_PRELOAD` interposer.)

### B.1 Kobo binaries run under qemu-arm (proven)

```
$ qemu-arm -L build/rootfs-4.38.23684 build/rootfs-4.38.23684/bin/busybox uname -a
Linux wsl 6.18.33.2-microsoft-standard-WSL2 #1 SMP PREEMPT_DYNAMIC ... armv7l GNU/Linux
$ qemu-arm -L build/rootfs-4.38.23684 build/rootfs-4.38.23684/bin/busybox echo hello-from-kobo-busybox
hello-from-kobo-busybox
```

(The kernel is the host's; `armv7l` proves guest code executes.)

### B.2 Nickel inspection

`file`: ELF 32-bit LSB executable, ARM EABI5, dynamically linked,
interpreter `/lib/ld-linux-armhf.so.3`, for GNU/Linux 2.6.31, stripped.

`readelf -d` NEEDED (42 libs): `libssl/crypto.so.1.0.0`, QtSolutions_IOCompressor,
`libxml2/xslt/exslt`, `libzip`, `libkmod/udev/sunpinyin/nickel/rmsdk`,
`libQt5{WebKitWidgets,PrintSupport,Svg,WebKit,Widgets,DBus,Concurrent,Sensors,Script,Xml,Network,Sql,Gui,Core}.so.5`,
`libpng16/jpeg/icu/iconv/dbus-1/dl/rt/z/pthread/stdc++/m/gcc_s/c`.
RPATH: `/chroot/lib:/chroot/usr/lib:/usr/local/Qt-5.2.1-arm/lib`.

Platform plugin present: `usr/local/Kobo/platforms/libkobo.so` (the
`-platform kobo` plugin), `plugins/gfxdrivers/libimxepd.so`,
`plugins/mousedrivers/libtouchscreen.so`. Qt libs live in
`usr/local/Qt-5.2.1-arm/lib/` as `libQt5*.so.5{,.2} -> libQt5*.so.5.2.1`
symlinks into `/usr/local/Trolltech/QtEmbedded-4.6.2-arm/lib/libQt*.so.4.6.2`
(Kobo's Qt5-names-on-Qt4-ABI layout).

Loader fixups (applied idempotently by `run-usermode.sh` into the
`build/` scratch rootfs — on-device `ldconfig` would own these):
- 38 absolute symlinks rewritten relative — **qemu-arm does not resolve
  absolute symlinks under `-L`** (observed: `libQt5WebKitWidgets.so.5`
  ENOENT despite existing, fixed by relativizing).
- Soname links missing from `KoboRoot.tgz` recreated from versioned
  siblings: `libdbus-1.so.3`, `libiconv.so.2`, `libjpeg.so.62`,
  `libudev.so.0`, `libz.so.1`, `libstdc++.so.6`, `libxml2.so.2`,
  `libattr.so.1`, `libfreetype.so.6`.
- Compat stand-ins (base-image libs absent from the update tarball, accepted
  by the loader with warnings): `lib/libpng.so -> libpng12.so.0.43.0`
  (real libpng16 absent), `usr/lib/libcrypto.so -> libcrypto.so.0.9.8`
  (real 1.0.0 absent; `libssl.so.1.0.0 -> libssl.so -> 0.9.8` resolves).

Nickel progression under
`qemu-arm -L $R -E LD_LIBRARY_PATH=/usr/local/Kobo:/usr/local/Qt-5.2.1-arm/lib`
(+ `LC_ALL=C LANG=C`: guest glibc 2.11 aborts on host locale data):
missing-lib errors → `powermanager` prints → locale assertion (fixed by
`LC_ALL=C`) → `ui: Couldn't access /dev/fb0` (+ `/dev/mmcblk0`) → with the
shim (B.3): fb access check passes, Qt imxepd plugin opens `/dev/fb0`,
answers geometry + EPDC ioctls, Nickel runs wifi bring-up (helpers fail as
host children, §B.6) then wifi-down and idles to the 45–240 s timeout
**without crashing and — since the staged full battery — without the
`sync`+`/sbin/poweroff` ending** (rc=124 survival; previously SIGABRT, then
a poweroff attempt). Still zero painted pixels: Qt issues only 1–3
`MXCFB_SEND_UPDATE`s (driver-init clears) and never draws UI frames.
Guest log: `artifacts/usermode-<V>-nickel.log`.

### B.3 Display/touch shims

| File | Role |
|---|---|
| `shims/kobo-fb-shim.c` | ARM `LD_PRELOAD` shim: `/dev/fb0` → backing file + 800×600 RGB565 geometry ioctls (`FBIOGET_VSCREENINFO/FSCREENINFO`, accept `FBIOPUT/BLANK`, MXCFB `SEND_UPDATE` marker tracking + `WAIT_FOR_UPDATE_COMPLETE` completion-with-no-collision answers, log-and-0 other EPDC `0x462e/0x462f/0x4630` family); `/dev/input/event*` → pre-seeded backing + generic evdev capability decode (`EVIOCGBIT`/`EVIOCGABS` decoded from ioctl encoding, no hardcoded sizes); EOF grace (200×10 ms) emulating blocking device reads; activity log to `$KOBO_SHIM_LOG` |
| `shims/fb-test.c` | ARM guest prover: prints panel geometry, draws 16-gray + RGB test pattern, drains `/dev/input/event0`, prints checksum |
| `shims/hello.c` | ARM homebrew hello-world (static musl, no guest-libc dependency): the `cmd_spawn` target for the staged NickelMenu entry |
| `shims/fb-dump.py` | Host: raw RGB565 backing → PNG (stdlib only: `zlib`+`struct`) |
| `scripts/fakebin/` | Host-runnable stand-ins (`pidof→1`, `killall/ifconfig/wpa_supplicant/wpa_cli/dhcpcd/syslogd/wlarm_le→0`, selective `cp`) for Nickel's wifi helpers, which execute on the HOST under qemu-arm (see B.6); each logs invocations to `$FAKEBIN_LOG` |
| `firmware/nickelmenu/KoboRoot.tgz` | Genuine NickelMenu v0.6.0 (URL+hash in B.4) |
| `scripts/run-usermode.sh` | Orchestration: unpack → loader fixups → zig build → stage backings/touch tap/OOBE/databases/NickelMenu/battery/wifi-env → sanitized-`env -i` launch → PNG dump |

Build flags (all load-bearing, each found by bisecting guest ld.so failures):
`zig cc -target arm-linux-gnueabihf.2.11` (guest glibc is 2.11; unpinned zig
emits `GLIBC_2.34` refs) with `-Wl,-z,lazy` (guest ld.so reports garbage
`unexpected reloc type 0x84/0x5c` under zig's default BIND_NOW eager binding).
The shim constructor is empty and all `dlsym` resolution is lazy — constructor
libc calls segfault mid-bootstrap on glibc 2.11. Variadic `open/open64/openat`
always forward `mode` (kernel ignores it without `O_CREAT`).

qemu-arm quirks the script works around (all observed, not theorized):
- Absolute symlinks are not resolved under `-L` (fixups relativize them).
- For `-L`-prefixed opens that hit ENOENT — **even with O_CREAT** — qemu falls
  back to the host path: backings/log must pre-exist under the sysroot or
  they land in host `/tmp`. The script pre-creates/truncates them.
- Host `LD_LIBRARY_PATH` leaks into the guest loader: launch uses `env -i`
  with an rcS-like guest `PATH` (`/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/Kobo`).
- Static guest binaries ignore `LD_PRELOAD` (fb-test is dynamic for this reason).

Proven pipeline (`nix run .#kobo-usermode -- --mode test`, rc=0, deterministic):

```
fb-test: panel 800x600 virtual 800x600 bpp=16
fb-test: pattern drawn, pixel checksum=244284764
fb-test: touch event 0: type=3 code=0 value=400
fb-test: touch event 1: type=3 code=1 value=300
fb-test: touch event 2: type=1 code=330 value=1
fb-test: touch event 3: type=0 code=0 value=0
fb-test: touch event 4: type=1 code=330 value=0
fb-test: touch event 5: type=0 code=0 value=0
fb-test: touch: drained 6 synthetic events
fb-test: DONE
```

Artifacts: `artifacts/fb-4.38.23684-test.png` (800×600 test pattern),
`artifacts/usermode-4.38.23684-test.log`,
`artifacts/usermode-4.38.23684-nickel.log`,
`artifacts/fb-4.38.23684-nickel.png` (all-zero so far — Nickel hasn't
painted yet), `artifacts/usermode-4.38.23684-koreader.log`,
`artifacts/fb-4.38.23684-koreader.png` (KOReader calibration screen, §B.7),
`artifacts/onboard-4.38.23684/.kobo/` (OOBE staging, below).

### B.4 OOBE bypass + NickelMenu (staged; menu pickup needs a painting Nickel)

`run-usermode.sh` stages `artifacts/onboard-<V>/.kobo/` — concretely
`build/rootfs-<V>/mnt/onboard/.kobo/` — with `Kobo eReader.conf` containing
`SideloadedMode=true` (+ `WifiEnabled=false`, `AirplaneMode=true`,
`SkipWifiSetupDialog=true`, currently advisory: the wifi bring-up still runs,
§B.6). OOBE evidence from live runs: Nickel opens+reads the staged config,
preserves our keys, and appends its own first-run bookkeeping
(`[ApplicationPreferences] EarliestChangeLog=4.38.23684`,
`firstRunDate=@Variant(...)`); it writes `.kobo/version`
(`11:22:33:44:55:66,6.18.33.2,4.38.23684,...` — placeholder MAC, host kernel,
firmware) and grows `.adobe-digital-editions/device.xml` to 322 bytes.
`KoboReader.sqlite`/`BookReader.sqlite` are pre-created empty (see the
O_CREAT quirk, §B.6): Nickel opens them but never initializes a schema —
no home screen and no registration prompt ever appears, so home-vs-OOBE is
still unverifiable: the flow stalls before any UI.

NickelMenu v0.6.0 (genuine, fetched 2026-09-07):
`https://github.com/pgaskin/NickelMenu/releases/download/v0.6.0/KoboRoot.tgz`
(66939 bytes, sha256
`322ff9aa863860e8f5f7e0b55cae561c54bf95983b9bce1d19819d1225d064af`,
tarball holds `mnt/onboard/.adds/nm/doc` + `usr/local/Kobo/imageformats/libnm.so`;
note upstream tests only 4.20.14622–4.31.19086, ours is 4.38.23684).
`run-usermode.sh` stages it at onboard `.kobo/KoboRoot.tgz` (where `rcS`
picks it up) and pre-extracts it (`libnm.so` identity-verified in place via
`NickelMenuHook`/`NickelMenuController` symbols), with `.adds/nm/config`
holding one entry —
`menu_item:main:Hello:cmd_spawn:quiet:/mnt/onboard/.adds/hello`
(syntax per the shipped `doc`). No pickup marker in any log yet (Qt loads
imageformat plugins on demand; Nickel never loads images pre-UI), so menu
injection is staged-but-unverified, gated on paint.

### B.5 Debug commands

```
# guest syscalls, host-side (verified: 216 file-trace lines on `busybox true`)
nix develop -c strace -f -e trace=%file -o /tmp/str.log \
  env -i PATH=/usr/bin:/bin timeout 10 $(nix develop -c command -v qemu-arm) \
  -L build/rootfs-4.38.23684 build/rootfs-4.38.23684/bin/busybox true

# guest loader view (shows RPATH/LD_LIBRARY_PATH resolution per library)
qemu-arm -strace -L build/rootfs-V ... 2>&1 | grep open

# gdb attach (verified: connects, reads guest binary from remote target)
# t1: env -i PATH=/usr/bin:/bin qemu-arm -g 2347 -L build/rootfs-V <guest-binary>
# t2: gdb -ex 'target remote :2347'   # (gdb 16.2 speaks ARM remote)
```

### B.6 Painting campaign (2026-09-07): Nickel runs, idles, never paints

Verdict: **not painting**. Backing stays all-zero across 45–240 s runs
(`artifacts/fb-4.38.23684-nickel.png` is solid black). Qt mmaps the panel and
issues 1–3 `MXCFB_SEND_UPDATE`s (markers 2–4, full/half regions) with zero
pixel writes — driver-init clears, no UI frames. The exact stall chain,
each step evidenced by qemu `-strace` runs in `artifacts/nickel-strace*.log`:

1. **Empty `$INTERFACE` (fixed).** `rcS` exports `INTERFACE=eth0`
   (`mx50-ntx` branch) but the launcher didn't — every helper rendered as
   `ifconfig  up`, `wpa_supplicant -i  …`. Found via `libnickel.so`
   `ifconfig %1 up` templates + `rcS` lines 292–320. Launcher now exports
   the rcS set (`PLATFORM=mx50-ntx CPU=mx50 PRODUCT=trilogy INTERFACE=eth0
   WIFI_MODULE=dhd NICKEL_HOME=/mnt/onboard/.kobo`); helpers now take eth0.
2. **Helpers run on the HOST (design constraint).** Proved by tracing a
   marker file to host `/tmp`: qemu-user passes guest `execve` through, so
   Nickel's `sh -c` children run as host processes with Nickel's environ.
   `scripts/fakebin/` therefore rides in the guest `PATH` (last, so guest
   lookups still hit real Kobo binaries first). Caveat: the wifi-phase
   spawns use a scrubbed env (only the early `killall -9 on-animator.sh`
   reaches the fakes; later `pidof/killall/ifconfig/wpa_*` still 127) —
   shadowing them fully would need a writable host dir on their PATH.
3. **O_CREAT quirk (fixed).** qemu-arm creates *missing* files on the host
   (guest `touch /tmp/x` landed in host `/tmp`) while opens of existing
   files translate under `-L`. So Nickel's `O_CREAT` of `KoboReader.sqlite`,
   `BookReader.sqlite`, `version`, `.adobe-digital-editions/device.xml`
   died with ENOENT. The launcher pre-creates them empty: `version` and
   `device.xml` now get written, both sqlites open (schema never
   initialized — flow dies first).
4. **Poweroff gate (averted, not passed).** The flow was wifi-up →
   netlink interface enumeration + one `SIOCGIFINDEX("wg0")` + battery
   sysfs reads → wifi-down → `sync` + `/dev/rtc0` EACCES +
   `/sbin/poweroff -f` (fails: no host poweroff) → touch-EOF idle. Staging
   a full battery (`/sys/.../mc13892_bat/{capacity=100,status=Full}`,
   possible because `/sys` *is* translated — the DVFS knob takes writes)
   removed the poweroff over 240 s, but the aftermath is the same idle:
   main thread in the touch EOF grace (~0.5 Hz), worker threads in
   `select`/30 s futex sleeps, no timers firing, no window ever created.
5. **Remaining gate (documented, not stubbed).** After wifi-down Nickel
   idles with no pending events: no thread polls a missing file or socket,
   so there is no further syscall/ioctl to answer — the first-window trigger
   (likely link/IP state via `wpa_ctrl`/DHCP, which can never succeed with
   host-executed helpers) simply never fires. Next most promising lever:
   KOReader (no wifi gate; writes `/dev/fb0` directly) as the first-pixels
   path, or a longer soak with mid-run synthetic taps.

### B.7 KOReader first pixels (2026-09-07): PAINTS

Bundle: `koreader-kobo-v2022.01.zip`
(`https://github.com/koreader/koreader/releases/download/v2022.01/koreader-kobo-v2022.01.zip`,
42326084 bytes, sha256
`eedd6f5d466faa57a533b240138cb71d05fbc96fb2ae0c32820de5d8a1c8392d`;
provenance in `firmware/koreader/fetch-info.txt`). v2022.01 was picked
contemporary with fw 4.31.19086 (Jan 2022) for glibc compat — but the
analysis says almost any tag works: `readelf -V` over every ELF in the
bundle shows luajit + 8 bundled libs (libcrengine, libdjvulibre,
libk2pdfopt, libkoreader-nnsvg, liblept, libmupdf, libpng16, libtesseract)
needing only GLIBC_2.15 `__*_finite` libm symbols (GCC finite-math
optimization), and **all 24 are exported by Kobo's own
`lib/libm-2.11.1.so`** — Kobo backported newer libm symbol versions into
their 2.11 tree (2017-07-31 build in KoboRoot.tgz); same story for
`pthread_setname_np@GLIBC_2.12` in guest libpthread (needed by
libglib-2.0). Full NEEDED closure resolves (bundled `libs/` + guest dirs),
INTERP `/lib/ld-linux-armhf.so.3` exists. No older-tag hunt needed.

`--mode koreader` stages the bundle at `onboard/.kobo/koreader`
(marker-guarded copy; KOReader's own `crash.log`/settings persist across
runs like on device), seeds a CSV `version` line when empty (KOReader's
Lua device probe nil-crashes on an empty file), then invokes `qemu-arm`
**directly** on `luajit reader.lua` from the stage dir (subshell `cd` —
`reader.lua` uses cwd-relative `package.path`/data dirs). `koreader.sh` is
bypassed deliberately: its cpufreq/fbdepth/nickel-kill preliminaries would
execute on the HOST via qemu-arm's execve passthrough; the env it would
export is replicated instead (`PRODUCT=trilogy` → probe selects
**KoboTrilogy**, `LC_ALL=C`, `LD_LIBRARY_PATH` with koreader `libs/` first).
Also fixed en passant: `--artifacts` with an absolute path (FAKEBIN_LOG
and the koreader subshell log assumed a relative dir).

Verdict: **PAINTS**. 952447/960000 backing bytes non-zero;
`artifacts/fb-4.38.23684-koreader.png` (sha256 `7b91fa05…3086c98630f4`)
shows KOReader's first-run *"Tap the lower right corner"* calibration
screen with the hand icon — unmistakable KOReader UI. Pixels arrive via
mmap writes (1 full-screen `MXCFB_SEND_UPDATE` marker in the shim log).
Guest log `artifacts/usermode-4.38.23684-koreader.log`: `initializing for
device Kobo_trilogy`, framebuffer 600×800, one-time migrations, then the
main-loop input poll. No crash across 90–240 s runs (rc=124).

Known deviations / next levers:
- **Sideways render.** KOReader enforces portrait 600×800 into our
  landscape 800×600 backing (the shim accept-ignores rotation ioctls), so
  the portrait UI appears rotated 90°. Fix candidate: report a 600×800
  panel geometry so no rotation is needed (touches fb-test expectations —
  do it as a flag, not a default).
- **Touch: delivered, not yet acted on.** 5 synthetic taps (seeded center
  + all 4 landscape corners across 2 runs) produced byte-identical PNGs,
  but fd-layer delivery is proven: `/proc/<qemu>/fdinfo` showed the touch
  fd advance 96→192 after a 6-event tap injection. Prime suspect for the
  Lua-side gap: the input poll warns `error: 32 -> Broken pipe` every ~2 s
  (the `fake event generator` fork inside `libkoreader-input.so` appears
  dead, so the C layer consumes evdev bytes the Lua loop never receives);
  second suspect is a portrait/landscape ABS-range mismatch (shim reports
  799×599, KOReader portrait expects 599×799 — corner taps may map
  out-of-range and be discarded). Follow-up: verbose input logging or a
calibration-bypass setting, then re-try.

### B.7b KOReader book render COMPLETE (2026-09-11)

Full render proof achieved. Path: `render-proof.epub` (1197B) seeded at
`/mnt/onboard` (= FileManager Home); `quickstart_shown_version=2022010000`
staged in sysroot koreader settings so startup falls through to FileManager
listing 3 EPUBs; tap on the Render Proof row →
`opening file /mnt/onboard/render-proof.epub` → ReaderUI renders fully
legible **"Render Proof Book"** (5 KOBOEMU RENDER PROOF LINE paragraphs,
footer 0/1, backing 933401/960000 nonzero) — orchestrator visually
confirmed via `artifacts/koreader-render-proof.png`. Mirror-X tap mapping
confirmed: screen x = 600−raw, per-tap table in coder report.

**KOReader stretch goal now stands COMPLETE:**
calibration → ReaderUI → file-browser → book render.

### What works / what doesn't (Track B)

- [x] qemu-arm executes Kobo ARM userspace (busybox proven)
- [x] Nickel's full dependency closure resolves; Nickel reaches `main()` and init
- [x] Virtual 800×600 RGB565 panel: geometry + EPDC ioctls answered, Qt imxepd plugin proceeds
- [x] Synthetic touch injection: 6-event tap drained by guest, shim capability probes answered
- [x] PNG artifact pipeline (`fb-dump.py`, stdlib-only)
- [x] `nix run .#kobo-usermode` (test + nickel modes), `nix flake check` passes
- [x] rcS-faithful env (`INTERFACE=eth0` etc.), host-side helper stand-ins,
       pre-created DBs/configs, full battery staging — poweroff averted
       (240 s run, no poweroff attempt)
- [x] Genuine NickelMenu v0.6.0 staged (URL+hash above) with hello-world
       `cmd_spawn` entry; static-ARM hello proven under qemu-arm
- [x] KOReader Kobo v2022.01 paints first pixels under the shim
       (calibration screen PNG, `artifacts/fb-4.38.23684-koreader.png`;
       glibc analysis in §B.7 — Kobo's backported libm covers it)
- [x] KOReader book render COMPLETE (`artifacts/koreader-render-proof.png`;
       `render-proof.epub` via FileManager tap → ReaderUI; mirror-X mapping)
- [x] sync() trigger implemented & verified (`shims/kobo-fb-shim.c`, ~130-line pure-C rescan trigger; `pthread_once`-armed on first MXCFB_SEND_UPDATE, `invokeMethod(singleton,"sync",QueuedConnection)` with 2s debounce; test rc=0 checksum 244284764 ×3, flake PASS, shellcheck PASS; +492 repaints confirmed)
- [ ] Nickel paints first pixels (backing still zero; idles post-wifi, §B.6)
- [ ] OOBE home-vs-registration verdict (staged+honored at config layer, §B.4;
       needs a painting Nickel for the actual screen)
- [ ] NickelMenu menu pickup (staged, needs a painting Nickel)
- [ ] Homebrew via `cmd_spawn` end-to-end (binary proven, spawn needs UI)
- [ ] `qemu-kobo` fork package in `flake.nix` (katadelos/qemu `eink-emulator`
       `973f5a8`, Track A revisit) — build unverified in this session

Next steps: **sync() trigger VERIFIED 2026-09-12** (FIFO → `invokeMethod(singleton,"sync",QueuedConnection)` with 2s debounce; `pthread_once`-armed on first MXCFB_SEND_UPDATE; `libnickel` QMetaObject confirms `sync` is Public SLOT — earlier NO-GO refuted; zero regression). Remaining: DB stall → OOBE → Menu → cmd_spawn; Nickel home screen, NickelMenu pickup, homebrew cmd_spawn; Track A fork revisit stays the full-system alternative.
