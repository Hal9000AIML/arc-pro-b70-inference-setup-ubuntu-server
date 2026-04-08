#!/usr/bin/env bash
# xe_tuning.sh — Intel xe driver tuning for vLLM XPU workloads on Arc Pro B70.
#
# Problem: Default per-engine job_timeout_ms on xe is 5000 (5s). Large prefill
# batches for Gemma 4 26B-A4B FP8 with TP=4 + enforce_eager=True can exceed 5s
# on a single compute command submission, causing the GuC watchdog to fire
# (xe_guc_submit.c:1291 guc_exec_queue_timedout_job), which triggers a GT
# reset that kills vLLM workers and leaks level_zero VRAM context. The next
# vLLM start then fails with UR_RESULT_ERROR_OUT_OF_DEVICE_MEMORY.
#
# Fix: raise job_timeout_ms to the engine max (kernel-enforced cap of 10000 ms
# on xe 6.17 — we request 30000 and the per-engine clamp-to-max logic below
# brings it down), set preempt_timeout_us to the engine
# max (disabling compute-engine preemption timeouts), pin GT frequency to
# max (no DVFS stalls on idle->busy transitions), and force PCIe ASPM to
# performance mode.
#
# Idempotent. Run at boot via xe-tuning.service before vllm-docker.service.
# Safe to re-run at any time.

set -u
LOG_TAG="xe-tuning"
log() { logger -t "$LOG_TAG" -- "$*"; echo "[$LOG_TAG] $*"; }

JOB_TIMEOUT_MS=30000

log "starting xe driver tuning"

# --- 1. Per-engine job_timeout_ms ------------------------------------------
#
# Path layout (xe, not i915):
#   /sys/devices/pci*/.../tile0/gt<N>/engines/<ccs|rcs|bcs|vcs|vecs>/job_timeout_ms
#
# The .defaults/ sibling holds factory defaults and is read-only; skip it.
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    # Clamp to engine-reported max if our value exceeds it.
    max_file="$(dirname "$f")/job_timeout_max"
    target=$JOB_TIMEOUT_MS
    if [ -r "$max_file" ]; then
        engine_max=$(cat "$max_file" 2>/dev/null || echo 0)
        if [ "${engine_max:-0}" -gt 0 ] && [ "$target" -gt "$engine_max" ]; then
            target=$engine_max
        fi
    fi
    if echo "$target" > "$f" 2>/dev/null; then
        count=$((count + 1))
    else
        log "WARN: failed to write $target to $f"
    fi
done < <(find /sys/devices -name job_timeout_ms 2>/dev/null)
log "job_timeout_ms: updated $count engines to $JOB_TIMEOUT_MS ms (clamped to engine max where needed)"

# --- 2. Per-engine preempt_timeout_us --------------------------------------
#
# Set to the engine-reported max (effectively disables preempt timeout for
# long-running compute kernels). Writing 0 is rejected on xe.
count=0
while IFS= read -r f; do
    [ -z "$f" ] && continue
    case "$f" in *".defaults"*) continue ;; esac
    max_file="$(dirname "$f")/preempt_timeout_max"
    if [ -r "$max_file" ]; then
        target=$(cat "$max_file" 2>/dev/null || echo 0)
    else
        target=0
    fi
    [ "${target:-0}" -le 0 ] && continue
    if echo "$target" > "$f" 2>/dev/null; then
        count=$((count + 1))
    else
        log "WARN: failed to write $target to $f"
    fi
done < <(find /sys/devices -name preempt_timeout_us 2>/dev/null)
log "preempt_timeout_us: raised $count engines to their max"

# --- 3. Pin GT frequency min = max (disable DVFS) --------------------------
#
# xe layout: tile0/gt<N>/freq0/{min_freq,max_freq,rp0_freq}
count=0
while IFS= read -r freq_dir; do
    [ -d "$freq_dir" ] || continue
    rp0=$(cat "$freq_dir/rp0_freq" 2>/dev/null || echo "")
    [ -z "$rp0" ] && continue
    # Raise max first, then min (order matters — min must be <= max)
    echo "$rp0" > "$freq_dir/max_freq" 2>/dev/null || true
    echo "$rp0" > "$freq_dir/min_freq" 2>/dev/null || true
    count=$((count + 1))
done < <(find /sys/devices -type d -path "*tile0/gt*/freq0" 2>/dev/null)
log "gt frequency: pinned min=max=rp0 on $count GTs"

# --- 4. PCIe ASPM policy ---------------------------------------------------
#
# GRUB already has pcie_aspm=off, but re-assert the policy here as belt-and-
# suspenders in case a rescan re-enabled it.
if [ -w /sys/module/pcie_aspm/parameters/policy ]; then
    echo performance > /sys/module/pcie_aspm/parameters/policy 2>/dev/null || true
    log "pcie_aspm policy: $(cat /sys/module/pcie_aspm/parameters/policy 2>/dev/null)"
fi

log "xe tuning complete"
exit 0
