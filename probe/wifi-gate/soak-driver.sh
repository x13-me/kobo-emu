#!/usr/bin/env bash
# soak-driver.sh — run the 150s nickel FIFO soak, injecting live taps mid-run.
set -uo pipefail
cd /home/user/kobo-emu
./scripts/run-usermode.sh --mode nickel --timeout 150 >artifacts/soak-driver.log 2>&1 &
SOAK=$!
sleep 100
./scripts/kobo-tap.sh --fifo --x 400 --y 300 || echo TAP1_FAILED
sleep 25
./scripts/kobo-tap.sh --fifo --x 750 --y 550 || echo TAP2_FAILED
sleep 20
./scripts/kobo-tap.sh --fifo --x 100 --y 100 || echo TAP3_FAILED
wait "$SOAK"
echo SOAK_DONE rc=$?
