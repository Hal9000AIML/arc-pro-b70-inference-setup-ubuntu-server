#!/usr/bin/env bash
# GPU Diagnostic Logger for Intel Arc Pro B70
#
# Captures comprehensive GPU + inference state to persistent logs so we can
# diagnose intermittent issues like PCODE timeouts, xe driver init failures,
# vLLM EngineCore RPC timeouts, and oneCCL hangs.
#
# Run modes:
#   gpu_diag_logger.sh                  one-shot snapshot
#   gpu_diag_logger.sh --boot           full boot-time snapshot (extra dmesg)
#   gpu_diag_logger.sh --watch          continuous (every 60s)
#   gpu_diag_logger.sh --on-failure     called by xe/vllm failure hooks
#
# Output goes to /var/log/gpu-diag/ with daily rotation.

set -u
LOGDIR="/var/log/gpu-diag"
STATE="$LOGDIR/state.log"             # one-line per snapshot, append-only
DETAIL="$LOGDIR/detail-$(date +%F).log"  # per-day full detail
EVENTS="$LOGDIR/events.log"           # state transitions only
DMESG_LAST="$LOGDIR/dmesg-last.txt"   # full dmesg snapshot at last failure
PERSIST="$LOGDIR/last-cards"          # remembers last seen card count

mkdir -p "$LOGDIR"
chmod 755 "$LOGDIR"

MODE="${1:-snapshot}"
TS=$(date '+%F %T')

# ----- Quick state collectors -----
get_pci_count() {
    lspci 2>/dev/null | grep -c 'e223' || echo 0
}
get_card_count() {
    ls /sys/class/drm/ 2>/dev/null | grep -cE '^card[0-9]+$' || echo 0
}
get_xe_bound() {
    ls /sys/bus/pci/drivers/xe/ 2>/dev/null | grep -c '0000:' || echo 0
}
get_vllm_health() {
    curl -sf --max-time 3 http://127.0.0.1:8000/health >/dev/null 2>&1 && echo "OK" || echo "DOWN"
}
get_pcode_timeouts() {
    sudo dmesg 2>/dev/null | grep -c 'PCODE initialization timedout' || echo 0
}
get_survivability_count() {
    sudo dmesg 2>/dev/null | grep -c 'In Survivability Mode' || echo 0
}
get_engine_resets() {
    sudo dmesg 2>/dev/null | grep -cE 'Engine reset:.*engine_class' || echo 0
}

PCI=$(get_pci_count)
CARDS=$(get_card_count)
XE_BOUND=$(get_xe_bound)
VLLM=$(get_vllm_health)
PCODE_TO=$(get_pcode_timeouts)
SURV=$(get_survivability_count)
RESETS=$(get_engine_resets)

# One-line state
echo "$TS pci=$PCI cards=$CARDS xe_bound=$XE_BOUND vllm=$VLLM pcode_timeouts=$PCODE_TO survivability=$SURV engine_resets=$RESETS" >> "$STATE"

# Event detection (state transition since last snapshot)
LAST_CARDS_VAL=""
[[ -f "$PERSIST" ]] && LAST_CARDS_VAL=$(cat "$PERSIST")
echo "$CARDS" > "$PERSIST"

if [[ -n "$LAST_CARDS_VAL" && "$LAST_CARDS_VAL" != "$CARDS" ]]; then
    echo "$TS EVENT card_count_change: $LAST_CARDS_VAL -> $CARDS" >> "$EVENTS"
    MODE="--on-failure"  # auto-elevate to full detail
fi

if [[ "$VLLM" == "DOWN" ]] && [[ "$MODE" != "--watch" || "$CARDS" -lt 4 ]]; then
    echo "$TS EVENT vllm_down cards=$CARDS pci=$PCI" >> "$EVENTS"
fi

# ----- Full detail collection -----
write_detail() {
    {
        echo ""
        echo "============================================================"
        echo "=== $TS  mode=$MODE"
        echo "============================================================"
        echo ""

        echo "--- summary ---"
        echo "pci_e223=$PCI cards=$CARDS xe_bound=$XE_BOUND vllm=$VLLM"
        echo "pcode_timeouts_total=$PCODE_TO survivability_mode_count=$SURV engine_resets=$RESETS"
        echo ""

        echo "--- /sys/class/drm cards ---"
        ls /sys/class/drm/ 2>/dev/null | grep -E '^card[0-9]+$'
        echo ""

        echo "--- xe driver bindings ---"
        ls /sys/bus/pci/drivers/xe/ 2>/dev/null | grep '0000:'
        echo ""

        echo "--- lspci e223 (full) ---"
        lspci -nn 2>/dev/null | grep e223
        echo ""

        echo "--- lspci tree (e223 context) ---"
        lspci -tv 2>/dev/null | grep -B1 -A1 'e223'
        echo ""

        echo "--- per-GPU PCIe link state ---"
        for bdf in $(lspci 2>/dev/null | grep e223 | awk '{print "0000:" $1}'); do
            echo "  $bdf:"
            sudo lspci -vv -s "$bdf" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|LnkCap2:|DevSta:|NUMA' | sed 's/^/    /'
            echo "    power_state: $(cat /sys/bus/pci/devices/$bdf/power_state 2>/dev/null)"
            echo "    d3cold_allowed: $(cat /sys/bus/pci/devices/$bdf/d3cold_allowed 2>/dev/null)"
            echo "    numa_node: $(cat /sys/bus/pci/devices/$bdf/numa_node 2>/dev/null)"
        done
        echo ""

        echo "--- igsc list-devices ---"
        sudo igsc list-devices 2>&1
        echo ""

        echo "--- igsc per-GPU firmware status ---"
        for d in /dev/mei0 /dev/mei1 /dev/mei2 /dev/mei3; do
            [[ -e "$d" ]] || continue
            echo "  $d:"
            sudo igsc fw version --device "$d" 2>&1 | sed 's/^/    /'
            sudo igsc fw status 0 --device "$d" 2>&1 | sed 's/^/    /'
            sudo igsc gfsp get-mem-ppr-status --device "$d" 2>&1 | grep -iE 'error|status|firmware' | sed 's/^/    /'
        done
        echo ""

        echo "--- recent dmesg: xe / PCODE / Survivability / engine reset ---"
        sudo dmesg -T 2>/dev/null | grep -iE 'xe |pcode|survivab|engine_class|guc fail|huc fail' | tail -50
        echo ""

        echo "--- vllm status ---"
        systemctl is-active vllm-docker 2>&1
        systemctl is-active vllm-serve 2>&1
        systemctl is-active vllm-watchdog 2>&1
        docker ps --format '{{.Names}}: {{.Status}}' 2>/dev/null | grep vllm
        if [[ "$VLLM" == "OK" ]]; then
            curl -s --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null | head -c 500
            echo ""
        else
            echo "  vllm /health DOWN"
            docker exec vllm-b70 pgrep -af 'vllm serve' 2>/dev/null | head -3
            echo "  --- vllm container log tail ---"
            docker exec vllm-b70 tail -30 /tmp/vllm.log 2>/dev/null | sed 's/^/    /'
        fi
        echo ""

        if [[ "$MODE" == "--on-failure" || "$MODE" == "--boot" ]]; then
            echo "--- FULL dmesg snapshot saved to dmesg-last.txt ---"
            sudo dmesg -T 2>/dev/null > "$DMESG_LAST"
            echo "  ($(wc -l < "$DMESG_LAST") lines, $(stat -c%s "$DMESG_LAST" 2>/dev/null) bytes)"
        fi
    } >> "$DETAIL"
}

if [[ "$MODE" == "--watch" ]]; then
    while true; do
        write_detail
        sleep 60
    done
fi

write_detail

# Rotate detail logs older than 14 days
find "$LOGDIR" -name 'detail-*.log' -mtime +14 -delete 2>/dev/null

exit 0
