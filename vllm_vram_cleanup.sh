#!/usr/bin/env bash
# vllm_vram_cleanup.sh — Pre-start cleanup for vLLM to reclaim VRAM held by
# crashed worker processes. Defense-in-depth against dirty-restart
# UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY failures on Intel Arc Pro B70 (xe driver).
#
# Safe to run idempotently. Runs as root via systemd ExecStartPre=.
#
# Order of operations:
#   1. Kill any host process holding /dev/dri/renderD*
#   2. Kill stale vllm processes inside the vllm-b70 container (if up)
#   3. Verify via xpu-smi that VRAM dropped below threshold; wait up to 30s
#   4. If still elevated AND no XPU consumer is left, rmmod/modprobe xe
#      (last-resort kernel driver reset)
#   5. Re-verify; log warning and proceed regardless

set -u
LOG_TAG="vllm-vram-cleanup"
log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

MEM_THRESHOLD_MIB=100
WAIT_TIMEOUT=30
CONTAINER_NAME="vllm-b70"

log "starting pre-start cleanup"

# --- 1. Kill host processes holding renderD nodes ---------------------------
for dev in /dev/dri/renderD*; do
    [ -e "$dev" ] || continue
    pids=$(fuser "$dev" 2>/dev/null | tr -s ' ')
    if [ -n "${pids// /}" ]; then
        log "killing host pids holding $dev: $pids"
        for pid in $pids; do
            # Never kill PID 1 or ourselves
            [ "$pid" = "1" ] && continue
            [ "$pid" = "$$" ] && continue
            kill -9 "$pid" 2>/dev/null || true
        done
    fi
done

# --- 2. Clean stale vllm procs inside the container ------------------------
if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
    log "container ${CONTAINER_NAME} is up; pkill'ing any stale vllm procs inside"
    docker exec "$CONTAINER_NAME" bash -c '
        pkill -9 -f "vllm serve" 2>/dev/null || true
        pkill -9 -f "vllm"       2>/dev/null || true
        pkill -9 -f "EngineCore" 2>/dev/null || true
        rm -f /dev/shm/psm_* /dev/shm/vllm_* 2>/dev/null || true
    ' 2>/dev/null || true
    sleep 2
fi

# --- 3. xpu-smi VRAM verification loop -------------------------------------
get_max_mem_mib() {
    # Returns the highest "Memory Used" reading across all devices in MiB.
    # xpu-smi stats output format varies; we grep lines containing MiB/MB used.
    # Fall back to 0 if xpu-smi not available or parse fails.
    command -v xpu-smi >/dev/null 2>&1 || { echo 0; return; }
    local max=0
    for d in 0 1 2 3; do
        local line
        line=$(xpu-smi stats -d "$d" 2>/dev/null | grep -iE "GPU Memory Used" | head -1)
        # Expected like: "| GPU Memory Used (MiB)        | 1234 |"
        local val
        val=$(echo "$line" | grep -oE '[0-9]+' | tail -1)
        [ -z "$val" ] && continue
        if [ "$val" -gt "$max" ]; then max=$val; fi
    done
    echo "$max"
}

end=$((SECONDS + WAIT_TIMEOUT))
max_mem=0
while [ $SECONDS -lt $end ]; do
    max_mem=$(get_max_mem_mib)
    if [ "$max_mem" -lt "$MEM_THRESHOLD_MIB" ]; then
        log "xpu-smi max VRAM in use = ${max_mem} MiB (< ${MEM_THRESHOLD_MIB}); clean"
        break
    fi
    log "xpu-smi max VRAM in use = ${max_mem} MiB (>= ${MEM_THRESHOLD_MIB}); waiting..."
    sleep 3
done

# --- 4. Last-resort xe kernel driver reset ---------------------------------
if [ "$max_mem" -ge "$MEM_THRESHOLD_MIB" ]; then
    log "VRAM still elevated after ${WAIT_TIMEOUT}s (${max_mem} MiB); checking xe consumers"
    # Safety: only rmmod xe if nothing has renderD open. vLLM is the only XPU
    # consumer on this box, so under normal circumstances this is safe.
    in_use=""
    for dev in /dev/dri/renderD*; do
        [ -e "$dev" ] || continue
        if lsof "$dev" 2>/dev/null | tail -n +2 | grep -q .; then
            in_use="$in_use $dev"
        fi
    done
    if [ -n "$in_use" ]; then
        log "WARNING: refusing to rmmod xe — still in use by:$in_use"
    else
        log "rmmod xe && modprobe xe (last-resort driver reset)"
        rmmod xe 2>&1 | logger -t "$LOG_TAG" || true
        sleep 2
        modprobe xe 2>&1 | logger -t "$LOG_TAG" || true
        sleep 5
        max_mem=$(get_max_mem_mib)
        log "post-reload xpu-smi max VRAM in use = ${max_mem} MiB"
    fi
fi

if [ "$max_mem" -ge "$MEM_THRESHOLD_MIB" ]; then
    log "WARNING: proceeding with VRAM still at ${max_mem} MiB"
fi

log "cleanup done"
exit 0
