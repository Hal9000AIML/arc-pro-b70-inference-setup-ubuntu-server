#!/usr/bin/env bash
# capture_last_boot.sh — forensics trail after a hard reset.
#
# Invoked by inference-boot-forensics.service early in boot. Dumps the
# previous boot's errors and the tail of its journal to /var/log so we can
# read them after the fact — essential when sshd wedged and the only recovery
# was a physical power cycle.

set -u

OUT_DIR="/var/log"
ERR_FILE="$OUT_DIR/last_boot_errors.txt"
TAIL_FILE="$OUT_DIR/last_boot_tail.txt"
META_FILE="$OUT_DIR/last_boot_meta.txt"

# Fall back to $HOME if /var/log isn't writable for any reason.
if ! ( : >> "$ERR_FILE" ) 2>/dev/null; then
    OUT_DIR="${HOME:-/root}"
    ERR_FILE="$OUT_DIR/last_boot_errors.txt"
    TAIL_FILE="$OUT_DIR/last_boot_tail.txt"
    META_FILE="$OUT_DIR/last_boot_meta.txt"
fi

{
    echo "=== captured at $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
    echo "current boot id: $(cat /proc/sys/kernel/random/boot_id 2>/dev/null || echo unknown)"
    echo "boots known to journald:"
    journalctl --list-boots 2>/dev/null | tail -5
} > "$META_FILE" 2>/dev/null || true

# Previous boot = -1. If there is no previous boot recorded (first boot after
# journald rotation), journalctl exits non-zero — that's fine, swallow it.
journalctl -b -1 -p err --no-pager > "$ERR_FILE" 2>/dev/null || echo "no previous boot errors available" > "$ERR_FILE"
journalctl -b -1 --no-pager 2>/dev/null | tail -500 > "$TAIL_FILE" || echo "no previous boot tail available" > "$TAIL_FILE"

# Also snapshot the last 200 lines of the diag JSONL if it still exists, because
# that often captures the death spiral leading up to the wedge.
DIAG_LOG="/var/log/inference_diag.jsonl"
if [ -f "$DIAG_LOG" ]; then
    tail -200 "$DIAG_LOG" > "$OUT_DIR/last_boot_diag_tail.jsonl" 2>/dev/null || true
fi

exit 0
