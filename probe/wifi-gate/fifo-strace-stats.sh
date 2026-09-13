#!/usr/bin/env bash
# fifo-strace-stats.sh — summarize input-fd read/poll behavior from a qemu-arm -strace log.
set -uo pipefail
LOG="${1:?usage: fifo-strace-stats.sh STRACE_LOG}"
for fd in 13 26; do
  total=$(grep -a -c -E "read\\($fd," "$LOG")
  zero=$(grep -a -E "read\\($fd," "$LOG" | grep -a -c ' = 0$' || true)
  data=$(grep -a -E "read\\($fd," "$LOG" | grep -a -c -E ' = (16|128)$' || true)
  echo "fd=$fd total_reads=$total zero=$zero data=$data"
done
echo "poll_select=$(grep -a -c -E 'poll|_newselect' "$LOG" || true)"
echo "fcntl=$(grep -a -c 'fcntl' "$LOG" || true)"
echo "total_lines=$(wc -l < "$LOG")"
