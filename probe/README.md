# probe/ — salvaged harnesses and significant logs

Standing rule: probe harnesses and significant logs live here. `/tmp` is only
for sockets, FIFOs, and disposable bytes. Anything worth re-reading after a
reboot belongs in this tree.

## Subdirs (one line each)

- `pixel-proof/` — QImage-dump proof that Nickel paints real UI: `run-step1*.sh`
  re-runs the gdb batch dump (2nd SEND_UPDATE `constBits` → `qimage-su2*.bin`,
  600x800 RGB32); `convert-step2.py` rotates + downconverts to RGB565
  (`kobo-fb0-c*.bin`); `render-portrait.py` renders proof PNGs (`su2-*.png`);
  `gdb-step1*.txt` are the gdb scripts, `*-step1*.log` the run logs.
  `fb-A/B/C.png` (shim-fix paint check), `kr-tap1.png` (KOReader tap),
  `nickel-post-taps.png` + `nickel-tap-run.log` (post-transfer tap run).
- `pixel-transfer/` — auto pixel-transfer bring-up run: `run-xfer.sh` re-runs
  the soak, `gdb-xfer.txt` is the gdb script, `*-xfer.log` the run logs.
- `wifi-gate/` — Nickel wifi-gate evidence: `nickel-strace6.sh` re-runs the 75s
  `qemu-arm -strace` Nickel soak; `kr-strace.log` / `nickel-trace.log` are the
  small KOReader/Nickel strace captures; `soak-*.sh` + `fifo-strace-stats.sh`
  are soak helpers; `fakebin-*` / `strace-*` are invocation logs.
- `input-wedge/` — touch→UI wedge harnesses: `evsyn_stream.py` (20ms EV_SYN
  injector) + `strace_window.sh` (timed strace sampler) re-run the input
  probe; `button-stream.py`, `nickel-probe-run.sh`, `gdb-ev/probe/idle.*` are
  the earlier button/FIFO probe scripts and logs.
- `qt-flush/` — Qt flush-path hunt: `nickel-gdb-run*.sh` + `nickel-flush-run.sh`
  re-run the gdbstub-attach / flush-log soaks; `gdb-v*.txt` are the gdb
  scripts, `gdb-v*.log` / `gdb-sync.*` / `nickel-gdb*.log` their outputs;
  `fb-hunt-koreader.log` is the fb open/mmap/write sweep (KOReader side).

## Dropped (too large to keep — regenerate instead)

- `/tmp/strace-nickel.log` (~240MB, 2026-09-09) — full `qemu-arm -strace`
  Nickel soak trace. Dropped (>50MB rule). Regenerate: same staging/env as
  `scripts/run-usermode.sh --mode nickel` plus `-strace`; see
  `wifi-gate/nickel-strace6.sh` for the exact pattern (75s window).
- `/tmp/fb-hunt-nickel.log` (~211MB, 2026-09-09) — fb open/mmap/write sweep
  over a Nickel soak. Dropped (>50MB rule). Regenerate: fb-syscall sweep
  alongside a `--mode nickel` soak; KOReader-side counterpart kept at
  `qt-flush/fb-hunt-koreader.log`.
- `/tmp/evsyn_stream.log`, `/tmp/evsyn_stream2.log` — 0-byte logs, no signal.
- `logs/fork-exec.log` (116MB) already lives in-repo under `logs/`; not moved.
- `artifacts/nickel-strace*.log` already live in-repo under `artifacts/`; the
  `/tmp` top-level `nickel-strace*.log` / `gdb-v*.log` / `fork-exec.log` files
  named in the salvage request were already gone from `/tmp` (lost).
- `/tmp/opencode/koreader-probe/koreader/` (91MB third-party KOReader bundle
  copy) and `/tmp/opencode/oc-asar/` (110MB unrelated tooling) left in place.
