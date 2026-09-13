# HANDOVER — kobo-emu (Kobo Touch N905 emulator, QEMU + Nix)

Standalone continuation doc. Assumes only a copy of this repo, no chat
context. Source of truth is the repo itself; this file summarizes it.
Evidence: README.md (§Track B / B.1–B.7), flake.nix, scripts/*.sh,
scripts/fakebin/*, shims/*, .remember/now.md, .gitignore,
firmware/*/fetch-info.txt, artifacts/ listing. No invented results.

RULE: refresh this HANDOVER.md after every phase (Phases 1–4, see §7).
A phase is not done until this file is updated to match the repo.

## 1. Goal

- Complete all TODOs in README (Track B checklist: touch→UI, Nickel
  paint, OOBE verdict, NickelMenu pickup, cmd_spawn end-to-end).
- Validate the emulator on both tracks:
  - Track A (full-system): boot stock N905 firmware under QEMU.
  - Track B (user-mode): stock ARM userspace under qemu-arm + shims.
- Stretch goals (in order): KOReader past calibration → file browser →
  book render **COMPLETE**; Nickel home screen; NickelMenu pickup; homebrew
  cmd_spawn end-to-end; Track A revisit via qemu-kobo fork.
- Handover-after-every-phase rule (§7) is part of the goal, not extra.

## 2. Current state (as of 2026-09-09; repo files dated 2026-09-07) — **Phase 1 CLOSED**

> Phase 1 close: README Status section added 2026-09-09 (4-row matrix + firmware pointer + repro commands + handover rule). HANDOVER.md v1 verified; plan review APPROVE (furious-bronze-baboon). See §7 Phase 1 close note.
>
> Phase 2 progress — input pipeline fully fixed (execve env repair, O_NONBLOCK EAGAIN, nickel FIFO transport; all three changes review-APPROVE, test rc=0 checksum 244284764 preserved, koreader unchanged); Nickel paint isolated to Qt backing-store no-copy defect (heap QImage paints real widgets, blit() sends SEND_UPDATE with zero pixel transfer); pixel-transfer implementation pending.

### 2.0 What works

| Item | Evidence |
|---|---|
| User-mode pipeline, test mode | `nix run .#kobo-usermode -- --mode test` → rc=0; fb-test prints `panel 800x600 … bpp=16`, `pixel checksum=244284764`, drains 6 synthetic events, `DONE` |
| Test pattern PNG | `artifacts/fb-4.38.23684-test.png` (800x600) |
| Nickel survives startup | `--mode nickel` runs 45–240 s, no crash, no poweroff attempt (full-battery staging); rc=124 (timeout, not crash) |
| KOReader paints | `--mode koreader` → 952447/960000 backing bytes non-zero; `artifacts/fb-4.38.23684-koreader.png` shows first-run "Tap the lower right corner" calibration screen; 1 full-screen MXCFB_SEND_UPDATE; no crash over 90–240 s (rc=124) |
| Portrait support (koreader) | `KOBO_FB_PORTRAIT=1` → 600x800 panel geometry; `fb-dump.py --width 600 --height 800`; upright portrait confirmed (see .remember/now.md 13:48) |
| Touch fd-layer delivery | fdinfo showed touch fd advance 96→192 after tap injection; 8-event taps delivered intact per .remember/now.md 13:48 |
| FIFO touch transport (koreader) | Empty FIFO staged in koreader mode; `scripts/kobo-tap.sh --fifo` injects live mid-run taps, fails loudly (ENXIO) with no reader |
| NickelMenu staged | Genuine v0.6.0 `firmware/nickelmenu/KoboRoot.tgz` (66939 B); pre-extracted (`libnm.so` symbol-verified); `.adds/nm/config` holds `menu_item:main:Hello:cmd_spawn:quiet:/mnt/onboard/.adds/hello`; static-ARM hello proven under qemu-arm |
| OOBE staging honored at config layer | Nickel reads staged `Kobo eReader.conf` (keys preserved), appends first-run bookkeeping, writes `.kobo/version` + 322 B `device.xml` |
| Poweroff gate averted | Staged full battery (mc13892_bat capacity=100/status=Full); 240 s run with no `sync`+`/sbin/poweroff` |
| Loader fixups | 38 absolute symlinks relativized; missing sonames recreated; compat `libpng.so`, `libcrypto.so` stand-ins; `LC_ALL=C LANG=C`; rcS env (`PLATFORM=mx50-ntx CPU=mx50 PRODUCT=trilogy INTERFACE=eth0 WIFI_MODULE=dhd NICKEL_HOME=…`) |
| `nix flake check` passes; `shellcheck -S warning` clean | README Phase-2 status + B-track status lines |
| Nickel wifi-path delivery | execve env-repair shim fix (FAKEBIN_DIR passthrough): all `command not found` gone; fakebin runs full arc ifconfig→wlarm_le→wpa_supplicant(exact template)→dhcpcd lease→teardown; 150s soak rc=124 |
| Nickel input hot-spin eliminated | O_NONBLOCK guard (EAGAIN on empty) + nickel-mode FIFO transport (KOBO_TOUCH_FIFO=1); 35s strace 10,053 lines vs 7M/40s before; 7 real-geometry SEND_UPDATEs markers 2–8; 3 live --fifo taps consumed |
| KOReader book render **COMPLETE** | `artifacts/koreader-render-proof.png` shows fully legible "Render Proof Book" (5 KOBOEMU RENDER PROOF LINE paragraphs, footer 0/1, backing 933401/960000 nonzero) — orchestrator visually confirmed. Path: seeded `render-proof.epub` (1197B) at /mnt/onboard (= FileManager Home), staged `quickstart_shown_version=2022010000` in sysroot koreader settings so startup falls through to FileManager listing 3 EPUBs, tap on the Render Proof row → `opening file /mnt/onboard/render-proof.epub` → ReaderUI. Mirror-X tap mapping: screen x = 600−raw, per-tap table in coder report |

### 2.1 What doesn't work

| Item | Evidence |
|---|---|
| Track A full-system boot | 0-byte serial on all runs (4.38/cubieboard 180 s, 4.31/cubieboard 120 s, 4.38/realview-pb-a8 60 s); 2.6.35 mach-mx50 zImage fails ATAG machine-ID check on non-i.MX50 boards; debug UART writes hit unmapped i.MX50 phys addrs |
| Nickel paint (Qt backing-store no-copy) | Qt KoboFrameBufferBackingStore never copies heap QImage (600x800 RGB32, genuinely painting: white→black pixel→431x103 widget rect, window exposed, setOrientation fired, einkv byte8=0x00 plain-blit path) into fb mmap (960000B all-zero, md5 abaab7c0, PNG 368d863f blank); DBs 0 bytes; OOBE/Menu/cmd_spawn unreachable until first paint. KOBO_DEBUG_FLUSHES=1 inert in this build. Recommended fix: shim-side rotate+downconvert copy on SEND_UPDATE (portrait RGB32 → landscape RGB565); pixel-transfer task hung — needs re-queue. **First-pixels proof (2026-09-09, offline, host-side — no tree changes):** heap QImage dump (`/tmp/kobo-step1/qimage-su2.bin`, 1920000 B) — 94.25% white `FFFFFFFF`, 4.23% black, 210 distinct values, 27585 non-white px, bbox x32..567 y0..799; two runs structurally identical (md5s differ — live UI). Offline rotate+RGB565 conversion renders recognizable Nickel UI in portrait: X-close top-right, low-battery icon top-center (nub-cap, charge bar, lightning badge), book-cover placeholder grid, grey footer bar with two icons — looks like charging/battery dialog over library grid. Rotation default CW (portrait-top toward right edge); caveat: frame has no text so CW vs CCW not visually decisive — isolated one-line flip. `blit#2` received `QRegion::shared_empty` while SU#2 still fired 600x600: damage does NOT flow through blit's arg; SU rect authoritative for dest, QImage for pixels. **FIRST PAINT LANDED (2026-09-09, live, shim automation implemented):** `shims/kobo-fb-shim.c` (+~250 lines, `NICKEL_ROTATE_CW=1` default) interposes `QBackingStore::flush` (note: 13-char symbol `_ZN13QBackingStore5flushERK7QRegionP7QWindowRK6QPointRK5QListI5QPairI5QRectjEE`, NOT the 12-char variant) + `mmap`/`mmap64`/`munmap`; on each `SEND_UPDATE` runs `nickel_transfer_on_update()` full-frame copy (portrait RGB32 → landscape RGB565 CW). Payload correlation: NO MATCH at any offset — ioctl `mxcfb_update_data` words w08–w16 all zero, w17 varyi... (line truncated to 2000 chars) |
| Touch → UI reaction | **PARTIAL — input path proven end-to-end; contentless.** First-paint landed; 4 live --fifo taps (180 s nickel soak, 4.38.23684): Tap 1 (400,550) footer bar → SU 3→4 marker=5 full repaint, backing db859e20→9784ee96 (+7764 nonzero): REPAINT. Taps 2-4 (center 400,300; right edge 700,300; left edge 100,300) → no change: NO-REACTION. Final PNG `artifacts/fb-4.38.23684-nickel.png` (ca4ae62f): two-row book-cover grid as empty outline boxes (covers/fonts not loading — placeholders only); tap-1 delta was same-screen state change, not navigation. DBs 0B throughout, no OOBE strings, no NickelMenu/cmd_spawn. Verdict PARTIAL: UI alive to touch, not deaf, but contentless. Working hypothesis: Nickel never indexes the library (empty SideloadedMode library → nothing to open). **Cover-cell taps (260s run):** 3 cover taps IGNORED (PNG pinned 05e2d992); footer tap REPARTIAL → SU 4 marker 5, PNG ca4ae62f; PNG-diff 43097px (9.0%) bbox y53-546 — battery/charging overlay dismissed, grid redrew full-bleed: footer tap NAVIGATED, cover placeholders inert. 10-min soak (2026-09-10) confirms DB stall is a MISSING WAKE-UP EVENT (both DBs hit 1024B then frozen ~10 min; no schema tables; BookReader SQLCipher-encrypted). **Idle-strace (110s, 2026-09-10):** main in ~20Hz pselect timeout loop (3659× identical args, always 0); Qt input thread healthy armed epoll_wait(-1) on touch FIFO; netlink ROUTE socket drained+closed; dbus handshake completes then silent; inotify ZERO syscalls. The one concrete missing trigger: HW-status monitor thread open(/tmp/nickel-hardware-status) = ENOENT → parks on own eventfd forever. libnm.so: dlopened PROT_EXEC (mmap2 PROT_EXEC|PROT_READ 173728B = Qt-plugin signature; prior PROT_EXEC claim was qemu pathname-attribution error — qemu prints paths on open/read, never mmap). Healthy init: metadata pread → dlopen → failsafe nh_failsafe_create → config read 177B (Hello + Rescan) → 4× mprotect GOT-patch (dlhook _nm_menu_hook*) → helper restores .failsafe.... (line truncated to 2000 chars) |
| OOBE home-vs-registration verdict | **ROOT CAUSE + FIX landed (2026-09-09):** qemu-arm `-L` maps stat/open/read/write to sysroot but O_CREAT-missing + unlink fall to HOST. Nickel journal commit: write journal OK → unlink(journal) → ENOENT → stale journal hot → ftruncate64(main,0) rollback → infinite loop; DBs 0B forever. Fix: `shims/kobo-fb-shim.c` interposes `unlink`+`unlinkat` — real call first, ENOENT + absolute path + `$KOBO_SYSROOT` → retry sysroot-prefixed; fail-open. `run-usermode.sh` step 6a pre-creates `*-journal`/`*-wal`; exports `KOBO_SYSROOT`. **Long-soak outcome (10-min nickel soak, rc=124, 2026-09-10):** both DBs reach 1024B within ~7s of launch, then zero bytes change for ~10 min (mtimes frozen). SUs frozen at 3, guest log 17 lines, shim log 59 lines after ~4.5 min. `SCHEMA TABLES: NO` — strings/grep over KoboReader.sqlite show only `SQLite format 3`, schema cookie 0, no CREATE TABLE/content rows. `BookReader.sqlite` CLASSIFIED: SQLCipher-encrypted header (entropy 7.817 bits/byte, 252/256 distinct values, 5 zeros; md5 identical mid→end; fresh random per boot). libnickel.so.1 + nickel embed SQLCipher 3.4.0; both DB names sit in its SQL string table. Both header commits LANDED; neither progressed to schema/data. **Reclassification CONFIRMED: stall is a MISSING WAKE-UP EVENT, not a blocked write.** Idle-strace (110s) named the block: main in ~20Hz pselect timeout loop; Qt input healthy on touch FIFO; netlink/dbus/inotify all idle; the one concrete missing trigger is HW-status monitor thread open(/tmp/nickel-hardware-status) = ENOENT → parks on own eventfd forever. libnm.so dlopened PROT_EXEC but hooks never fire (no QMenu opened); zero /mnt/onboard or *.epub ops in 110s. Seed test (2 EPUBs, 170s) confirms: KoboReader 0→1024B + WAL-mode + 32KB -shm with valid WAL-index header, still 0 tables; BookReader fresh SQLCipher; zero scan/index lines in guest stdout; PNG pinned 05e2d992, SUs 2,3,4. Seeding doesn't wake indexing because nothing ever looks. **Wire... (line truncated to 2000 chars) |
| NickelMenu pickup | **MENU HUNT OUTCOME** (600s soak, 8 tap sessions — NO QMenu opened, 2026-09-10): zero NickelHook.log, no popup overlay in any PNG, SUs advance only on full-screen repaints. Taps exhausted as trigger vector: only bottom-right zone (~700-770,~550-560) live (dialog-dismiss/refresh); everything else inert incl. double-taps; `kobo-tap.sh` has no long-press/hold param. Screens seen: `05e2d992` (grid + rail + battery dialog + X) → `ca4ae62f` (full-bleed grid, no chrome) → `dbf0dd43` (partial grid right 2/3 + ↑ arrow top-right). No header menu button painted anywhere. Rescan NOT fired; DBs frozen 1024B; guest log wifi-only. OOBE/Menu-spawn still gated. NM injection HEALTHY (libnm.so dlopened PROT_EXEC; failsafe → config read Hello+Rescan; 4× mprotect GOT-patch dlhook `_nm_menu_hook*`) but hooks fire on QMenu::popup/aboutToShow — no QMenu opened, so no hook fired. |
| cmd_spawn end-to-end | Binary proven; spawn needs UI |
| qemu-kobo fork build | `flake.nix` package `qemu-kobo` (katadelos/qemu eink-emulator @ 973f5a8d7f4f54ab27c5198edb1fa9207671e945) — build UNVERIFIED in any session |

## 3. Exact reproduction commands (run from repo root)

```
nix develop                                   # shell: qemu, gdb, dtc, e2fsprogs, mtools, ubootTools, curl, unzip, zig, strace, shellcheck, …
nix run .#fetch-firmware -- 4.38.23684        # primary fw (kobo3/Apr2026; 107569899 B)
nix run .#fetch-firmware -- 4.31.19086        # fallback fw (kobo3/Jan2022; 95260246 B)
nix run .#build-sd -- 4.38.23684              # build/kobo-sd-<V>.img (1 GiB) + build/zImage-<V>

# Track A (expect 0-byte serial hang; kill via timeout):
nix run .#kobo-emu -- --version 4.38.23684 --machine cubieboard --timeout 60
# or: scripts/boot-kobo.sh [--version V] [--machine M] [--timeout S] [--display none|sdl|vnc]

# Track B:
nix run .#kobo-usermode -- --mode test                     # rc=0, checksum 244284764
nix run .#kobo-usermode -- --mode nickel --timeout 45      # rc=124 = survived
nix run .#kobo-usermode -- --mode koreader --timeout 60    # paints calibration PNG
# direct: scripts/run-usermode.sh [--version V] [--mode test|nickel|koreader] [--timeout S] [--artifacts DIR]

# Live tap into a RUNNING koreader guest (FIFO transport):
scripts/kobo-tap.sh --x 300 --y 400 --fifo
# file-backed modes (test/nickel): scripts/kobo-tap.sh --x 400 --y 300

# Debug:
nix develop -c strace -f -e trace=%file -o /tmp/str.log \
  env -i PATH=/usr/bin:/bin timeout 10 $(nix develop -c command -v qemu-arm) \
  -L build/rootfs-4.38.23684 build/rootfs-4.38.23684/bin/busybox true
# qemu-arm -strace … 2>&1 | grep open        # guest loader view
# qemu-arm -g 2347 … + gdb `target remote :2347`   # gdb attach
```

Key artifacts: `artifacts/fb-<V>-<mode>.png`, `artifacts/usermode-<V>-<mode>.log`,
`artifacts/fakebin-<V>-<mode>.log`, sysroot `build/rootfs-<V>/tmp/kobo-shim.log`,
`artifacts/nickel-strace*.log`, guest logs `artifacts/usermode-*.log`.

## 4. Immediate next steps (priority order)

> **Interference rule:** serialize live-guest probes — two concurrent soaks stomped shared sysroot FIFOs; check for running guests before staging.
>
> **KEYS EXHAUSTED** — KEY_MENU(139)/KEY_HOMEPAGE(172) bursts delivered+consumed (EAGAIN-drain proof) but zero SU/md5/PNG/log change; shim EV_KEY mask advertised only BTN_TOUCH. One-line fix added 139/172 to the mask (test rc=0 checksum 244284764, flake PASS); re-probe STILL zero — taps+keys both exhausted as QMenu vectors.
>
> **SD PATH VETOED** — `sd add /dev/mmcblk1p1`, bare-token variant, and `sd mount fail` all consumed silently (SU 3→3, md5 pinned, DBs 0B), consistent with `SD plug ignored due to FTE veto`; FIFO event paths to sync() are dead ends under headless SideloadedMode.

### gdb-sideload3 breakthrough — gate BYPASSED (2026-09-13)

**Verdict: script-path staging DOES bypass the unsigned-device gate.** The §2.4e plain-run failure (DBs frozen 1024B) was a **timing issue** — sync FIFO fired at 3 SUs before guest settled (260 SUs). With gdb attached, the guest settles fully, `Settings::getSetting` reads `SideloadedMode=true` from the in-memory cache (populated at boot from `/mnt/onboard/.kobo/Kobo/Kobo eReader.conf`), `sideloadedModeEv` returns TRUE, `FSSyncManager::sync` HIT + `retrieveSideLoadedFiles` HIT, and KoboReader.sqlite grows 1024B → **381952B with 33 tables** (full content/user/shelves schema). BookReader stays 1024B SQLCipher. EPUBs onboard (alice + 3 probes).

**Contradiction with §2.4e:** same staged config, same trigger path — but gdb attachment vs plain run flips the verdict. The gate is bypassed when the cache is fully populated before firing.

**Next:** run full script path **WITHOUT gdb**, fire at settled park (≥200 SUs), verify DB growth + content rows for `alice-gutenberg11.epub`. See §2.4f for details. **FAILED — see §2.4g (2026-09-13): guest freezes at 3 SUs entire 300 s, no settled park reachable; gate-bypass without gdb NOT demonstrated.** Next probe: instrument halted-start + gdb-resume changes.

### NM DOC VERDICT
`probe/nm-docs/` now holds the extracted NickelMenu doc (the only doc file in `KoboRoot.tgz` besides `libnm.so`). The doc defines exactly 4 directive families (`menu_item`, `chain_*`, `generator`, `experimental`) and every action including `nickel_misc:rescan_books` fires **ONLY** on user tap of a menu item. The `generator` runs at startup but only generates items — never executes actions. Grep for `auto`/`trigger`/`boot`/`start`/`event`/`condition` found **no autofire directive**. **Verdict: NOT POSSIBLE** — config-only autofire of `rescan_books` without a QMenu is not documented. > **Keys-exhausted note:** KEY_MENU/KEY_HOMEPAGE bursts produced zero change — QMenu vectors exhausted; NM DOC verdict stands, blocking factor is not input-key delivery.
### Direct sync() trigger — IMPLEMENTED & VERIFIED (2026-09-12)

**Verdict: trigger works end-to-end with zero regression. Remaining: DB stall → OOBE → Menu → cmd_spawn.**

Implementation in `shims/kobo-fb-shim.c` (~130-line pure-C rescan trigger):
- `pthread_once`-armed on first `MXCFB_SEND_UPDATE`; watcher resolves `_ZN19PlugWorkflowManager14sharedInstanceEv` + full-signature `invokeMethod`.
- Reads singleton `0x422fdbf4` = historic probe value; watches `$KOBO_SYNC_FIFO` default `/tmp/kobo-sync.fifo`.
- Fires `invokeMethod(singleton,"sync",QueuedConnection)` with 2 s debounce; `onSdMounted()` fallback.
- `libnickel` QMetaObject parse (rev 7, 27 methods) confirms `sync` is method [13], argc=0, flags `0x0a` = **Public SLOT** — earlier researched NO-GO on direct string-invoke was empirically **refuted** (live fire returned `true`).

Design deviations (evidence-first):
- **Constructor-spawn design DEVIATED**: 8/8 deterministic SIGSEGVs at ~0.5 s in dlopen storm with early polling (fault PC in QtCore `si_addr=0x44`); 7/7 survivals without — arming moved to first paint.
- **Helper-QObject design DELETED**: unnecessary; hand-built vtables correlated with crashes.
- V0–V14 bisection trail in session record.

Probe results:
- 90 s survival run: 12 SUs, PNG `05e2d992` baseline-identical.
- Parked pre-fire: 24 SUs, PNG identical, DBs 1024 B.
- Fire once → `FIFO fired, queueing sync()` → `invoke sync() -> queued (true)`.
- Post-fire +120 s: SUs 24→516 (+492 repaints), PNG `→6969e664` changed, DBs still 1024 B (pre-existing SQLite-commit stall unaffected).
Verification: `test` rc=0 checksum 244284764 (×3), `nix flake check` PASS, `shellcheck` PASS, `.so` NEEDED unchanged (`libpthread`/`libc`/`libdl`, no `libstdc++`).

### Post-fire sync() forensics (2026-09-12)

The sync() fire reaches `queued(true)` but the scan never starts — proven by coder forensic probe.

Key findings (`artifacts/forensic-sync-*`):
- Post-fire window (24332 lines of 48313 total strace) has ZERO `*.epub` opens/stats, ZERO `getdents`/`opendir` of `/mnt/onboard` (vs 28 at boot), ZERO `imageformats` (vs 44 at boot), ZERO `libnm`.
- DBs frozen at 1024 B (KoboReader md5 `9948b4ef`, BookReader 1024 B, no schema, no journals/WALs, no mtime change).
- Zero MassStorage/SyncClient/VolumeManager/sideload markers; guest stdout +1 line (`/sbin/reboot` missing).
- PNGs cycle animation frames (`05e2d992`→`48165818`→`8c896350`→`110f64f2`) never showing content; SUs 3→232.
- Second fire 180 s later is an idempotent no-op (same storm rate, no advance).
- Post-fire touched paths form a certified closed-set: battery sysfs, Qt xdg conf probes (ENOENT), onboard `.kobo` conf probes, `Kobo.tgz`/`Root.tgz` stats, `db_integrity` unlink, sqlite stat-only + failed `-wal` opens (qemu `-L` `O_CREAT` quirk, no writes), `activation.xml` lstat, `/sbin/reboot` exec miss.

**VERDICT:** `sync()` never reaches the scan — gated inside `N3FSSyncManager::sync(QStringList)` (UNSIGNED-DEVICE EARLY EXIT, §2.4c). `retrieveSideLoadedFiles` does NOT run.

**Next decisive probe RESOLVED (2026-09-12, §2.4c):** gate is UNSIGNED-DEVICE EARLY EXIT in `N3FSSyncManager::sync`.

### KOReader file-browser stretch (fallback content path)
If sync() is inert, navigate KOReader's file browser to load an epub — a content path independent of Nickel indexing that may wake the DB via a different code path.
### KOReader book-render stretch COMPLETE (2026-09-11)

Path: `render-proof.epub` (1197B) seeded at `/mnt/onboard` (= FileManager Home); `quickstart_shown_version=2022010000` staged in sysroot koreader settings so startup falls through to FileManager listing 3 EPUBs; tap on the Render Proof row → `opening file /mnt/onboard/render-proof.epub` → ReaderUI renders fully legible "Render Proof Book" (5 KOBOEMU RENDER PROOF LINE paragraphs, footer 0/1, backing 933401/960000 nonzero). Mirror-X tap mapping confirmed: screen x = 600−raw, per-tap table in coder report. **KOReader stretch goal now stands calibration→ReaderUI→file-browser→book render COMPLETE.**

### 2.1 qemu-kobo fork build (Track A alternative)
- Package exists in flake.nix (`qemu-kobo`, katadelos/qemu eink-emulator
  rev 973f5a8d7f4f54ab27c5198edb1fa9207671e945, subproject-vendoring
  postUnpack). Build UNVERIFIED — needs an aarch64 builder (full QEMU
  rebuild too heavy/slow for x86_64 WSL2 here).
- `nix build .#qemu-kobo` on aarch64; then check `qemu-system-arm -M help`
  for `imx50-kobotouch`; on success, re-run Track A boot with the fork
  (`-M imx50-kobotouch -m 256M`) and record serial bytes.

### 2.2 Tap-probe results + backend park analysis (NEW — 2026-09-09)
Context: first paint landed (shim `QBackingStore::flush` hook + CW RGB32→RGB565 copy); 4 live --fifo taps injected into a running nickel guest (180 s soak).

**Tap results:**
- Tap 1 (400,550) footer bar → SU 3→4 marker=5 full repaint; backing md5 db859e20→9784ee96 (+7764 nonzero bytes): **REPAINT**. Input path proven end-to-end (FIFO → Qt → pixels).
- Taps 2-4 (center 400,300; right edge 700,300; left edge 100,300) → **NO-REACTION** (PNG byte-identical pre/post).
- Final PNG `artifacts/fb-4.38.23684-nickel.png` (ca4ae62f): two-row book-cover grid as empty outline boxes — covers/fonts not loading, placeholders only. Tap-1 delta was a same-screen state change, not navigation.

**Verdict:** PARTIAL — UI is alive to touch (not deaf), but contentless (DBs 0B, no OOBE strings, no NickelMenu/cmd_spawn).

**Working hypothesis:** Nickel never indexes the library (empty SideloadedMode library → nothing to open).

**Next steps (priority order):**
1. **sync() trigger VERIFIED** (2026-09-12) — implemented in `shims/kobo-fb-shim.c`; trigger works end-to-end, zero regression. See §4 "Direct sync() trigger".
2. **KOReader file-browser stretch** — if sync() is inert, navigate KOReader's file browser to load an epub, providing a content path independent of Nickel indexing.

### 2.3 Nickel soak
- 180 s nickel soak with 4 live --fifo taps completed (2026-09-09); first-paint + tap-1 repaint confirmed. Park the soak; resume only if park analysis (§2.2) needs more data.

### 2.4 sync() trigger — VERIFIED (2026-09-12)

In-process sync() trigger implemented and verified end-to-end with zero regression. See §4 "Direct sync() trigger" for implementation details and probe results. **Verdict: trigger works; remaining: DB stall → OOBE → Menu → cmd_spawn.**

### 2.4b Post-fire sync() forensics (2026-09-12)

Coder forensic probe (`artifacts/forensic-sync-*`): parked Nickel + one FIFO fire → `invoke sync()->queued(true)`.

**Post-fire behavior (confirmed):**
- One 600×600 repaint, then endless 95×18 + 472 + 252 1 Hz ticker (battery sysfs poll).
- SUs 3→232; PNGs cycle `05e2d992`→`48165818`→`8c896350`→`110f64f2` (animation frames, never content).
- Guest stdout +1 line only (`sh: /sbin/reboot: No such file`).
- Zero MassStorage / SyncClient / VolumeManager / sideload markers.
- DBs frozen: KoboReader 1024 B md5 `9948b4ef`, BookReader 1024 B, no schema, no journals/WALs, no mtime change.

**Strace 48313 lines — post-fire window (24332 lines) has ZERO:**
- `*.epub` opens/stats
- `getdents`/`opendir` of `/mnt/onboard` (vs 28 at boot)
- `imageformats` (vs 44 at boot)
- `libnm`

**Post-fire touched paths certified closed-set:** battery sysfs, Qt xdg conf probes (ENOENT), onboard `.kobo` conf probes, `Kobo.tgz`/`Root.tgz` stats, `db_integrity` unlink, sqlite stat-only + failed `-wal` opens (qemu `-L` `O_CREAT` quirk, no writes), `activation.xml` lstat, `/sbin/reboot` exec miss.

**Second fire 180 s later: idempotent no-op** (same storm rate, no advance).

**VERDICT:** `sync()` never reaches the scan — gated inside `N3FSSyncManager::sync(QStringList)` (see §2.4c). `retrieveSideLoadedFiles` does NOT run.

**Next decisive probe RESOLVED (2026-09-12, §2.4c):** gate is UNSIGNED-DEVICE EARLY EXIT in `N3FSSyncManager::sync`; open question is why staged `SideloadedMode=true` doesn't bypass it.

New artifacts: `artifacts/forensic-sync-guest.log`, `forensic-sync-strace.log` (48313 lines), `forensic-sync-pre/mid/post180/post2.png`.

### 2.4c N3FSSyncManager gate — FOUND (2026-09-12)

The "next decisive probe" (Qt-metaobject/gdb breakpoints on `retrieveSideLoadedFiles`/`sync` internals) was executed by the coder. Result: the gate is **inside `N3FSSyncManager::sync(QStringList)`**, not in `PlugWorkflowManager::sync()` and not in `retrieveSideLoadedFiles`.

**Verified symbols (from `artifacts/gdb-gate-transcript.log` + `artifacts/gdb-gate-post.png`):**

| Symbol | Address | Status |
|---|---|---|
| `VolumeManager::retrieveSideLoadedFiles(bool)` | `00a6b3e9` | **MISS** — certified never reached |
| `PlugWorkflowManager::syncEv` | `00f353d5` | Hit (event delivery confirmed) |
| `PlugWorkflowManager::sync(QStringList)` | `00f34d91` | Hit (QueuedConnection delivery confirmed) |
| `PlugWorkflowManager::usbPlugAllowedEv` | `00f3623d` | — |
| `PlugWorkflowManager::sdMountAllowedEv` | `00f34fe5` | — |
| `PlugWorkflowManager::onSdMountedEv` | `00f376a1` | — |
| `PlugWorkflowManager::sideloadedModeEv` | `009fd1d1` | — |
| `PlugWorkflowManager::usbPluggedEv` | `008cd381` | — |
| `N3FSSyncManager::sync(QStringList)` | `010a5ef5` | **HIT** — gate location |

**Breakpoint chain (4 HITs, silent `bt`/`continue`, zero infcalls):**
`sync()` ← `QObject::event` ← `QApplication::notify` ← `Nickel3Application::notify` (QueuedConnection delivery confirmed) → `sync(QStringList)` → `N3FSSyncManager::sync` → `FSSyncManager::finished()` (8-frame bt).

**Static corroboration (from `artifacts/gdb-gate-transcript.log`):**
- `sync()` / `sync(QStringList)` contain **no gate** — they simply forward.
- The gate is **wholly inside `N3FSSyncManager::sync`**: `DatabaseAdapter::retrieve<User>` → empty-user branch → `Settings` + `sideloadedMode()` checks → single `finished()` call site `0x10a5ffe` (unreached real-sync site `0x10a602c`).
- Rodata literals found: `"N3FSSyncManager::sync(const QStringList&)"` and `"Device is not signed, it will not sync FS."` (42 B). The silent sub-branch is taken; nothing appears in the guest log.

**GATE VERDICT: UNSIGNED-DEVICE EARLY EXIT.** A fresh 1024 B header-only DB (zero User rows) diverts execution to `finished()` before the scan ever starts. The device-unsigned literal string confirms this is the path taken.

**Open question:** The staged config holds `SideloadedMode=true` (preserved across fires), yet the gate fires anyway. Either (a) `Settings` reads a different store than the staged config, or (b) a downstream check gates independently. Next narrower probe already launched: live `sideloadedModeEv` return value + `Settings::getSetting` backing-store inspection.

**Forensic numbers (consistent with §2.4b):** SUs 12→92→172→796; PNG `d613130fd111143ad3dc19932a5b4bb3`; DBs frozen (KoboReader 1024 B md5 `9948b4ef` = §2.4b baseline); guest log 1669 B (`wifi+`/`/sbin/reboot` only); re-attach impossible (stub single-session re-confirmed).

### 2.4d SideloadedMode durability validation (2026-09-12)

The open question from §2.4c ("Settings cache populated at boot from wrong section/key") is partially answered by a full-script-path durability probe: the staged SideloadedMode config IS correct and survives the entire launch path, but the gate still fires.

**Probe:** step-6 heredoc writes `SideloadedMode=true` at four config scopes (top-level, `[Application]`, `[ApplicationPreferences]`, `[General]`), then stages the full Nickel launch via `nix run .#kobo-usermode -- --mode nickel`.

**Verified facts:**

| Check | Result |
|---|---|
| Step-6 heredoc survives full script path | YES — `SideloadedMode=true` present at all 4 scopes after launch |
| Nickel parking point | 3 SUs, PNG `05e2d992` (baseline identical) |
| FIFO fire → `invoke sync()` | `queued(true)` confirmed |
| SUs progression | 3→332 (+329 repaints) |
| PNG animation frames | `05e2d992`→`d613130f`→`6969e664`→`110f64f2`→`8c896350` (known cycle) |
| DB state | Frozen 1024 B header-only; KoboReader md5 `9948b4ef`, 0 tables |
| Guest log | wifi-only + `/sbin/reboot` miss |
| OOBE strings | ZERO |
| Nickel config rewrite | Adds `EarliestChangeLog`/`firstRunDate`, re-sorts sections — confirms Nickel reads + writes staged config |

**Verdict:** durability YES — `SideloadedMode=true` is correctly staged and read by Nickel. The real sync trigger HIT (`queued(true)`). The scan still NOT HIT. UI/home/OOBE NOT REACHED.

**Blocker unchanged:** `N3FSSyncManager::sync` unsigned-device early exit gates the scan. Staged `SideloadedMode=true` is read but does **not** bypass the gate — the unsigned-device literal string `"Device is not signed, it will not sync FS."` still diverts to `finished()` at `0x10a5ffe` before `retrieveSideLoadedFiles` runs.

**Refined open question:** Settings cache populated at boot from wrong section/key. The config is staged correctly at all 4 scopes, yet the gate fires — suggesting `Settings::getSetting("sideloadedMode")` reads from a different backing store or section than where step-6 wrote, or the cache is populated before the staged config is applied.
### 2.4e Sync probe — 2026-09-13

Continuation of the §2.4d durability validation. Same setup (staged `SideloadedMode=true` at 4 scopes), different run with EPUBs present and longer timeout.

**Verified facts:**

| Check | Result |
|---|---|
| EPUBs present | `alice-gutenberg11.epub` (187712 B) + 3 probes |
| Full script path | `nix run .#kobo-usermode -- --mode nickel --timeout 300` |
| Parking point | 3 SUs, PNG `05e2d992` (baseline identical) |
| FIFO fire → `invoke sync()` | `queued(true)` confirmed |
| SUs progression | 3→320 (+317 repaints) |
| PNG animation frames | Known cycle (`05e2d992`→…) plus final `b55e901cb9d793fe788d55983a35f852` — **NEW** (near-black panel, idle-dim candidate) |
| DB state | Frozen 1024 B header-only; KoboReader md5 `9948b4ef` (identical to all baselines), 0 tables |
| Guest log | 17 lines, wifi-only + `/sbin/reboot` miss |
| OOBE strings | ZERO |
| Post-fire markers | ZERO MassStorage / SyncClient / VolumeManager / sideload |
| Nickel config rewrite | Confirms Nickel reads staged config (same as §2.4d) |

**Verdict:** Trigger path healthy end-to-end (FIFO → `PlugWorkflowManager::sync` → `N3FSSyncManager::sync` → `queued(true)`). Scan path dead — the `N3FSSyncManager::sync` unsigned-device early-exit gate (`"Device is not signed, it will not sync FS."` → `finished()` at `0x10a5ffe`) still blocks before `retrieveSideLoadedFiles` runs. Staged `SideloadedMode=true` at 4 scopes is read by Nickel (config rewrite proves it) but does **not** satisfy the gate.

**Next narrow step:** queued `sideloadedModeEv` return-value + `Settings::getSetting` backing-store probe — determine whether `Settings::getSetting("sideloadedMode")` reads from a different backing store or section than where the step-6 heredoc wrote, or whether the cache is populated before the staged config is applied.

### 2.4f gdb-sideload3 breakthrough — gate BYPASSED (2026-09-13)

The §2.4e open question ("`Settings::getSetting` backing-store discrepancy") is **RESOLVED** by a gdb-attached probe. The 2026-09-13 plain-run failure (DBs frozen 1024B, gate blocking) was a **timing issue** — the sync FIFO was fired too early (3 SUs) before the guest had settled (260 SUs). With gdb attached and the guest fully settled, the gate is **bypassed**.

**Probe:** `nix run .#kobo-usermode -- --mode nickel --timeout 20` with gdb attached (`qemu-arm -g 2347` + `target remote :2347`). Script-path staging via `nix run .#kobo-usermode -- --mode nickel --timeout 20` with gdb attached.

**Verified facts:**

| Check | Result |
|---|---|
| Script-path staging | `nix run .#kobo-usermode -- --mode nickel --timeout 20` with gdb attached |
| Live `sideloadedModeEv` return | **TRUE** |
| `Settings::getSetting` backing store | In-memory cache populated at boot from `/mnt/onboard/.kobo/Kobo/Kobo eReader.conf` |
| SideloadedMode scopes | `true` at 3 scopes: [General] + [Application] + [ApplicationPreferences] |
| Gate status | **BYPASSED** — `FSSyncManager::sync` HIT + `retrieveSideLoadedFiles` HIT |
| KoboReader.sqlite growth | 1024 B → **381952 B** with **33 tables** (full content/user/shelves schema) |
| BookReader.sqlite | Frozen 1024 B SQLCipher (unchanged) |
| EPUBs onboard | `alice-gutenberg11.epub` + 3 probe EPUBs |

**Key insight:** Script-path staging **DOES** work to bypass the unsigned-device gate. The `SideloadedMode=true` config at 3 scopes is read correctly, `Settings::getSetting` returns the right value from the in-memory cache, and `retrieveSideLoadedFiles` executes — populating KoboReader.sqlite with 33 tables and 381952 B of content.

**Contradiction with §2.4e (2026-09-13 plain-run probe):** §2.4e showed DBs frozen at 1024B with the gate blocking. The difference is **gdb attachment vs plain run**. The plain-run failure was a timing issue: the FIFO sync was fired at 3 SUs (before the guest settled at ~260 SUs), so `Settings::getSetting` returned a stale/empty cache value and the gate early-exited. With gdb attached, the guest settles fully before the fire, the cache is populated, and the gate is bypassed.

**Verdict:** The gate-bypass path is confirmed working via script-path staging. The unsigned-device early-exit in `N3FSSyncManager::sync` is bypassed when `SideloadedMode=true` is correctly read from the in-memory cache (populated at boot from the staged config) — which requires the guest to be sufficiently settled before firing the sync FIFO.

**Next step:** Run the full script path **WITHOUT gdb**, fire at a settled park (≥200 SUs), and verify DB growth + content rows for `alice-gutenberg11.epub`. This will confirm the gate-bypass works in production (no gdb) and that the §2.4e failure was purely a timing issue.

### 2.4g Settled-park plain-run FAILURE — gate-bypass NOT demonstrated (2026-09-13)

The §2.4f next step — plain-run gate-bypass at a settled park — was attempted and **FAILED**. The guest never settled; it froze at 3 SUs for the entire 300 s timeout, so the ≥200 SUs fire condition could never be reached.

**Probe:** `nix run .#kobo-usermode -- --mode nickel --timeout 300` (plain, no gdb). Full script-path staging: step-6 heredoc writes `SideloadedMode=true` at 4 scopes, then Nickel launch.

**Verified facts:**

| Check | Result |
|---|---|
| Full script path | `nix run .#kobo-usermode -- --mode nickel --timeout 300` |
| Parking point | **3 SUs, frozen entire 300 s** (no settled park ≥200 SUs) |
| PNG | `05e2d992` baseline-identical throughout |
| FIFO fire | **NEVER FIRED** (sync never reached, so no `invoke sync()`) |
| DB state | Frozen 1024 B header-only; KoboReader md5 `9948b4ef`, **0 tables** |
| Guest log | 16 lines, wifi-only + `/sbin/reboot` miss |
| OOBE/markers | **ZERO** |

**CONTRADICTION found in gdb runs' own logs (2026-09-13):**

- Run 3 pre-fire DB = post-fire DB = **381952 B** (zero growth from fire).
- Growth occurred runs 1→2 **under gdb attach** (1024 B → 381952 B).
- All gdb runs settled spontaneously 20→260 SUs in 60 s **WITHOUT** fire.
- Plain run freezes at 3 SUs; no growth, no fire.

**Reframed hypothesis:** DB growth correlates with **gdb-attached settled runs** — Nickel auto-syncs on its internal timer once init completes (confirmed by gdb runs reaching 260 SUs and growing DBs). The sync FIFO is NOT the trigger for auto-sync; it is only needed for the manual `invoke sync()` path. The plain run never settles because something about the gdb-attached startup changes Nickel's init completion behavior.

**Gate-bypass without gdb: NOT DEMONSTRATED.** The §2.4f conclusion that script-path staging bypasses the gate remains unconfirmed in production, because the only run that grew DBs used gdb.

**Next probe (§2.4i): attach + arm sideload3 breakpoint set but never fire (vs strace-only no gdb) to separate mechanism (1) from mechanism (2). See §2.4h.**

### 2.4h gdb-attach variant isolation — halted-wait irrelevant (2026-09-13)

The §2.4g next step (halted-start + gdb-resume) was decomposed into three variants to isolate what actually changes when gdb attaches. All three were run with identical script-path staging (`SideloadedMode=true` at 3 scopes, 4 EPUBs onboard), differing only in launch/attach timing.

**Variants tested:**

| Variant | Description | Launch | Attach | Breakpoints |
|---|---|---|---|---|
| A | Contaminated | `qemu-arm -g 2347` halted, port probe done | After 30s (SUs already advanced) | None |
| A2 | Clean 60s halt + attach+continue | `qemu-arm -g 2347` halted, no port probe | After 60s verified halt | None |
| B | Control: immediate attach+continue | `qemu-arm -g 2347` launched live | Immediately | None |

**Verified facts (ALL THREE produce identical frozen 3-marker park):**

| Check | A (contaminated) | A2 (clean 60s halt) | B (immediate) |
|---|---|---|---|
| SUs at pre-fire | 12 (contaminated during halt) | 0→12 (halt-proof verified) | 12 |
| SEND_UPDATE lines | 12 | 12 | 12 |
| Real paints (markers) | 3 | 3 | 3 |
| PNG pre/post md5 | `05e2d992` | `05e2d992` | `05e2d992` |
| DBs pre/post | KoboReader 1024B, 0 tables | KoboReader 1024B, 0 tables | KoboReader 1024B, 0 tables |
| Guest log lines | 16 (wifi-only) | 16 (wifi-only) | 16 (wifi-only) |
| Settled by run+180s? | **NO** | **NO** | **NO** |
| Artifact prefix | `gdb-attach-A-*` | `gdb-attach-A2-*` | `gdb-attach-B-*` |

**Key findings:**

- **Gdb attachment itself does NOT enable settled park.** A2 verified a clean 60s halt (`HALT-PROOF halt+5s/30s/60s: lines=0, markers=0, qemuCPU=00:00:00`) — the guest was truly frozen. After `gdb attach+continue` (no breakpoints), SUs remained locked at 12/3 for the entire run+180s window. The frozen park is identical to B (immediate attach, no halt wait at all).
- **Halted-wait variable is irrelevant: A2 ≡ B.** Whether the guest was halted for 60s with verified zero CPU before attach, or attached immediately at launch, the outcome is identical — frozen 12 SUs, 3 paints, `05e2d992` PNG, 1024B/0-table DBs. The halt duration has no effect on post-attach settlement.
- **Variant A is contaminated but still frozen.** A's port probe caused SUs to advance to 12 during the halt window (unlike A2's verified-zero halt), but post-attach behavior is identical — still frozen at 12 SUs. The contamination changes the pre-attach SUs count but not the post-attach freeze.
- **Guest log 16 lines (wifi-only) across all variants.** No OOBE strings, no MassStorage/SyncClient/VolumeManager/sideload markers, no `/sbin/reboot` except B (which has the extra reboot miss line = 17 lines total).
- **No breakpoints were armed in any variant.** These runs confirm that mere gdb attachment + continue — without any armed breakpoints — does nothing to change Nickel's parking behavior.

**What the §2.4f gdb-sideload3 settle (24→264 lines, 1024B→381952B/33 tables) MUST have come from:**

Since gdb attachment alone (no breakpoints) freezes the guest identically to plain launch, the DB growth observed in §2.4f **cannot** be explained by gdb attachment alone. It must come from one of two mechanisms:

1. **Armed breakpoints with stop/bt/continue round-trips** (massive timing dilation) — the gdb-sideload3 transcript (`artifacts/gdb-sideload3-transcript.log`) shows 5+ breakpoints armed on `PlugWorkflowManager::sync`, `N3FSSyncManager::sync`, `FSSyncManager::sync`, `ApplicationSettings::sideloadedModeEv`, etc. Each breakpoint fires, stops the guest, forces a `bt` (backtrace), then `continue` — this round-trip creates enormous timing dilation that allows Nickel to reach its internal auto-sync timer (confirmed by gdb runs reaching 260 SUs). This is a **timing/race effect**, not a debugger-feature effect.
2. **strace -f syscall overhead** (run3.sh wrapped guest) — strace intercepts every syscall with `ptrace`-level overhead, similarly slowing the guest enough to reach the auto-sync timer. The `artifacts/gdb-sideload3-strace.log` (9353 lines) confirms strace was running alongside the guest.

**These two mechanisms are confounded in §2.4f.** The gdb-sideload3 run used BOTH armed breakpoints AND strace wrapping, so the individual contribution of each is unknown.

**Next probe (§2.4i): separate mechanism (1) from mechanism (2).**

- **Probe 1:** Attach + arm sideload3 breakpoint set but **never fire** (breakpoint on a function that's never reached) + NO strace. If the guest still settles and grows DBs → mechanism (1) is sufficient (breakpoint presence alone, even without firing, changes timing). If guest stays frozen → mechanism (1) requires the breakpoint to actually fire.
- **Probe 2:** strace-only, NO gdb, NO breakpoints. If the guest settles and grows DBs → mechanism (2) is sufficient (syscall overhead alone). If guest stays frozen → strace overhead alone is insufficient.
- **Probe 3 (control):** gdb attach + continue + NO breakpoints + NO strace (this is exactly what A/A2/B already proved → frozen). Confirms the baseline.

### 2.5 OOBE / Menu / cmd_spawn

Gated on a *contentful* Nickel (currently contentless). Prerequisite: seed library or fix indexing so SideloadedMode has entries, then proceed: OOBE home-vs-registration verdict → NickelMenu pickup marker → `cmd_spawn` hello end-to-end (`/mnt/onboard/.adds/hello` + staged `.adds/nm/config` entry).

The sync trigger path is verified healthy (§2.4–§2.4e) and the gate is **bypassed** (§2.4f). The remaining open question is whether the bypass works **without gdb** — the plain-run settled-park test **FAILED** (§2.4g: guest freezes at 3 SUs, no settled park reachable), and the three-variant gdb-attach isolation (**§2.4h**) confirms that gdb attachment alone does NOT enable settlement (A2 ≡ B). Next probe (§2.4i): separate armed-breakpoint timing dilation (mechanism 1) from strace syscall overhead (mechanism 2) to identify what actually caused the §2.4f gdb-sideload3 DB growth. Once confirmed, OOBE/Menu/cmd_spawn become reachable.

## 5. Validation matrix + regression

| Check | Command | Current expectation |
|---|---|---|
| Flake | `nix flake check` | passes |
| Lint | `shellcheck -S warning scripts/*.sh scripts/fakebin/*` | clean |
| Build all apps | `nix build .#kobo-emu .#fetch-firmware .#build-sd .#kobo-usermode` | all build (qemu-kobo excluded: unverified, needs aarch64) |
| Test mode | `nix run .#kobo-usermode -- --mode test` | rc=0, checksum 244284764, 6 events drained |
| Nickel mode | `… --mode nickel --timeout 45` | rc=124 survival, FIRST PAINT landed (backing 919302/960000 non-zero, PNG md5 05e2d992) |
| Koreader mode | `… --mode koreader --timeout 60` | rc=124, calibration PNG non-blank |

Run the full matrix after every change; record rc + PNG sha where relevant.

## 6. Tribal knowledge gotchas (all observed, load-bearing)

- Absolute symlinks under `-L`: qemu-arm does NOT resolve absolute
  symlinks under `-L` (ENOENT despite existing). `run-usermode.sh`
  relativizes them (38 in KoboRoot) + recreates missing sonames
  (`libdbus-1.so.3`, `libiconv.so.2`, `libjpeg.so.62`, `libudev.so.0`,
  `libz.so.1`, `libstdc++.so.6`, `libxml2.so.2`, `libattr.so.1`,
  `libfreetype.so.6`) + compat `libpng.so→libpng12`, `libcrypto.so→0.9.8`.
- O_CREAT host fallback: opens of MISSING files under `-L` (even O_CREAT)
  land on the HOST (e.g. guest `touch /tmp/x` → host /tmp). Pre-create
  backings, shim log, sqlites, `version`, `device.xml` under the sysroot.
- `env -i` PATH leak: host `LD_LIBRARY_PATH` leaks into the guest loader;
  launch uses `env -i` with rcS-like guest PATH + `LC_ALL=C LANG=C`
  (guest glibc 2.11 aborts on host locale data) + `INTERFACE=eth0` etc.
- Guest execve passthrough: Nickel's `sh -c` children run as HOST
  processes → `scripts/fakebin/` stand-ins ride the guest PATH (last);
  `koreader.sh` preliminaries bypassed for the same reason (env replicated).
- Static vs LD_PRELOAD: static guest binaries ignore LD_PRELOAD —
  fb-test is dynamic; hello is static musl (no guest-libc dependency).
- Shim build flags (each found by bisect): `zig cc -target
  arm-linux-gnueabihf.2.11 -Wl,-z,lazy` (guest glibc 2.11; unpinned zig
  emits GLIBC_2.34 refs; BIND_NOW eager binding → `unexpected reloc type
  0x84/0x5c`). Empty constructor + lazy dlsym (constructor libc calls
  segfault mid-bootstrap on 2.11). Variadic open always forwards `mode`.
- SD image: exactly 1 GiB (cubieboard rejects non-pow2); `mke2fs -d`
  (no fakeroot → build-uid owners, cosmetic); mtools needs temp MTOOLSRC
  drive-letter mapping; HW CONFIG sector 1024 zeroed → `PLATFORM=freescale`.
- Cubieboard rejects `-m 256M` (512M floor; `KOBO_MEM_MB` overrides);
  real N905 has 256M — documented deviation.
- `nix run` hermetic PATH: scripts need coreutils/gnugrep/util-linux/
  findutils in runtimeInputs (timeout, grep, sfdisk, find).
- KOReader specifics: v2022.01 (`firmware/koreader/fetch-info.txt`;
  glibc satisfiable via Kobo's backported libm 2.11); launch luajit
  directly from stage dir (cwd-relative package.path); seed `version`
  CSV line when empty (Lua nil-crash); `--artifacts` absolute-path bug
  previously fixed (assume relative); portrait dump needs
  `--width 600 --height 800`.
- `build/ logs/ artifacts/ *.img result*` gitignored; firmware zips +
  KoboRoot.tgz gitignored (re-fetchable); never commit them.

## 7. Phases + refresh rule

- Phase 1: fetch + verify firmware (**COMPLETE** — 4.38.23684 primary + 4.31.19086 fallback, hashes in `firmware/*/fetch-info.txt`). Milestone record: [README Status (2026-09-09)](#status-2026-09-09).
- Phase 2: SD build + Track A boot attempts (done: 0-byte serial verdict, cubieboard primary, realview-pb-a8 probe, fallback justification). **PROGRESS** — input pipeline fully fixed (execve env repair, O_NONBLOCK EAGAIN, nickel FIFO transport; all review-APPROVE, test rc=0 checksum 244284764); input sub-steps done; pixel pipeline proven end-to-end LIVE (FIRST PAINT landed 2026-09-09; DB stall root cause+fix landed: qemu-arm unlink host-fallback fixed via shim KOBO_SYSROOT redirect); cover-tap results (footer tap NAVIGATED, 3 covers IGNORED); 10-min soak (2026-09-10) confirms DB stall is a MISSING WAKE-UP EVENT (both DBs 1024B then frozen, no schema tables; BookReader SQLCipher-encrypted); automation COMPLETE; **idle-strace (110s) + seed test (2 EPUBs, 170s) COMPLETE — missing-wake-up-event hypothesis CONFIRMED.** Wire-format + import-trigger reconstruction recorded §2.1. **Wake-up probe results (2026-09-10, 420s soak):** FIFO dispatch OK (bat change / usb plug add / remove all consumed, correct handlers); usbPlugged suppressed before sync() (zero /mnt/onboard, zero epub, zero sqlite, no repaint); NM rescan_books tapped (tap 1 → SU 3→4, tap 2 → SUs 4→7, 3 screens contentless); NM injection confirmed HEALTHY (libnm.so dlopened PROT_EXEC; triggers on QMenu::popup/aboutToShow). **NEXT: forensic sync() probe (2026-09-12) COMPLETE** — sync() reaches `queued(true)` but never scans; gated inside `N3FSSyncManager::sync(QStringList)` (UNSIGNED-DEVICE EARLY EXIT, see §2.4c). `retrieveSideLoadedFiles` does NOT run. **Decisive probe RESOLVED (2026-09-12, §2.4c):** `N3FSSyncManager::sync(QStringList)` gate = UNSIGNED-DEVICE EARLY EXIT (`DatabaseAdapter::retrieve<User>` → empty-user → `Settings`+`sideloadedMode()` → `finished()` `0x10a5ffe` bypasses real-sync `0x10a602c`; rodata `"Device is not signed, it will not sync FS."` confirms). `VolumeManager::retrieveSideLoadedFiles` certified MISS. **SideloadedMode durability YES (2026-09-12, 2.4d):** config survives full script path, sync() fires queued(true), but gate still blocks scan. **Follow-up probe 2026-09-13 (2.4e):** EPUBs present, 300s timeout — same verdict: trigger queued(true), scan dead, gate unchanged. Open: sideloadedModeEv return-value plus Settings::getSetting backing-store probe. sync() fires `queued(true)`, but gate still blocks scan. **Follow-up probe 2026-09-13 (§2.4e):** EPUBs present (alice-gutenberg11.epub 187712B + 3 probes), 300s timeout — same verdict: trigger `queued(true)`, scan dead, gate unchanged, final PNG `b55e901c` NEW near-black idle-dim candidate. Open: `sideloadedModeEv` return-value + `Settings::getSetting` backing-store probe. — next probe live `sideloadedModeEv` + `Settings::getSetting` backing store. Milestone record: §2.4c. Structural USB veto confirmed (fifo-read → stat64(Kobo eReader.conf) → dbus send into void → idle; event recorded then silently dropped; zero usbPlugged/sync/sqlite/epub syscalls in 105k+53k lines). FTE-incomplete is permanent under headless SideloadedMode boot → USB path to sync() is a DEAD END until FTE completes (needs registration UI). Deprioritize. **Side correction:** battery 10s poll loop runs CONTINUOUSLY from boot (identical pre/post probe) — prior plug-trigger claim was watcher-startup alignment. Remaining: OOBE verdict → Menu pickup → cmd_spawn (gated on content). Milestone record: §2.1 idle-tr... (line truncated to 2000 chars)
- Phase 3: Track B user-mode — **STRETCH COMPLETE** (test proven, Nickel survives, KOReader paints, touch→UI PARTIAL, Nickel paint open, **book render COMPLETE** 2026-09-11, **sync() trigger VERIFIED** 2026-09-12).
- Phase 4: OOBE verdict → NickelMenu pickup → cmd_spawn; Track A fork
  revisit; remaining stretch (Nickel home screen, NickelMenu pickup, homebrew
  cmd_spawn); **sync() trigger VERIFIED 2026-09-12** (end-to-end, zero
  regression; remaining: N3FSSyncManager unsigned-device gate → DB stall →
  OOBE → Menu → cmd_spawn; **§2.4d confirms staged `SideloadedMode=true`
  durability YES — config survives full script path, sync() fires `queued(true)`,
  but gate still blocks scan. **§2.4e (2026-09-13) confirms same verdict with
  EPUBs present** — open: `sideloadedModeEv` return-value + `Settings::getSetting`
  backing-store probe. **§2.4f (2026-09-13 gdb-sideload3) RESOLVES the open
  question: gate IS bypassed when `Settings::getSetting` reads the populated
  in-memory cache — plain-run failure was a timing issue (fire at 3 SUs vs
  260 SUs settled). Script-path staging DOES work. **§2.4g (2026-09-13) FAILED
  the plain-run settled-park test — guest freezes at 3 SUs entire 300 s;
   gate-bypass without gdb NOT demonstrated.** **§2.4h (2026-09-13) isolates
   the gdb-attach effect into three variants (A contaminated / A2 clean 60s
   halt / B immediate attach): ALL THREE produce identical frozen 3-marker
   park (12 SEND_UPDATE lines = 3 real paints), PNG `05e2d992`, DBs
   1024B/0 tables, guest log 16 lines wifi-only. Gdb attachment alone does
   NOT enable settlement; halted-wait is irrelevant (A2 ≡ B). The §2.4f
   sideload3 settle (24→264 lines, 1024B→381952B/33 tables) must come from
   either (1) armed breakpoints with stop/bt/continue round-trips (massive
   timing dilation) or (2) strace -f syscall overhead — these two
   mechanisms are confounded in §2.4f and must be separated in §2.4i.** Next
   probe (§2.4i): attach + arm sideload3 breakpoint set but never fire
   (vs strace-only no gdb).
- After EVERY phase (and every sub-step that changes verdicts): update
  README checklist/tables AND this HANDOVER.md (state tables, next
  steps, validation results). A phase is not done until both are current.
