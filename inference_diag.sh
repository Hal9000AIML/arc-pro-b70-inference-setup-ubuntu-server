#!/usr/bin/env bash
# inference_diag.sh — one-shot diagnostic sampler for the ARC Pro B70 inference box.
#
# Runs every 60s via systemd timer. Writes one JSON line per sample to
# /var/log/inference_diag.jsonl (or $HOME/inference_diag.jsonl if /var/log is RO).
# Kept intentionally small (single line JSON), no external deps beyond coreutils
# and whatever tools happen to exist. Every tool lookup is guarded so a missing
# binary (e.g. xpu-smi) degrades gracefully instead of failing the sample.
#
# The companion diag_http.py process serves the most recent line on port 8765,
# so the main PC can poll box health even when sshd is wedged under swap pressure.

set -u
# NOTE: intentionally NOT using `set -e` — every probe must be tolerant.

LOG_PRIMARY="/var/log/inference_diag.jsonl"
LOG_FALLBACK="${HOME:-/root}/inference_diag.jsonl"
STATE_DIR="/run/inference_diag"
HEARTBEAT="/tmp/odin_diag.heartbeat"
ROTATE_BYTES=$((100 * 1024 * 1024))  # 100 MB

mkdir -p "$STATE_DIR" 2>/dev/null || true

# Pick log file — prefer /var/log if writable, else $HOME.
LOG="$LOG_PRIMARY"
if ! ( : >> "$LOG" ) 2>/dev/null; then
    LOG="$LOG_FALLBACK"
    ( : >> "$LOG" ) 2>/dev/null || LOG="/tmp/inference_diag.jsonl"
fi

# Rotate if oversized.
if [ -f "$LOG" ]; then
    size=$(stat -c%s "$LOG" 2>/dev/null || echo 0)
    if [ "$size" -gt "$ROTATE_BYTES" ]; then
        mv "$LOG" "${LOG}.1" 2>/dev/null || true
        gzip -f "${LOG}.1" 2>/dev/null || true
    fi
fi

# --- helpers -----------------------------------------------------------------

# JSON-escape a string (handles backslash, quote, newline, tab, CR).
jesc() {
    local s=${1-}
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '%s' "$s"
}

# Return a numeric field from /proc/meminfo in kB, defaulting to 0.
meminfo_kb() {
    local key=$1
    awk -v k="$key" '$1==k":" { print $2; exit }' /proc/meminfo 2>/dev/null || echo 0
}

now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
host=$(hostname 2>/dev/null || echo unknown)

# Uptime + loadavg
uptime_s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
read -r load1 load5 load15 _ < /proc/loadavg 2>/dev/null || { load1=0; load5=0; load15=0; }
cpu_count=$(nproc 2>/dev/null || echo 1)

# Memory + swap
mem_total=$(meminfo_kb MemTotal)
mem_free=$(meminfo_kb MemFree)
mem_avail=$(meminfo_kb MemAvailable)
swap_total=$(meminfo_kb SwapTotal)
swap_free=$(meminfo_kb SwapFree)
swap_used=$(( swap_total - swap_free ))

# Top 5 by RSS — "pid:comm:rss_kb"
top_rss_json="[]"
if command -v ps >/dev/null 2>&1; then
    top_rss_lines=$(ps -eo pid=,comm=,rss= --sort=-rss 2>/dev/null | head -5)
    if [ -n "$top_rss_lines" ]; then
        tmp=""
        while IFS= read -r line; do
            pid=$(echo "$line" | awk '{print $1}')
            rss=$(echo "$line" | awk '{print $NF}')
            comm=$(echo "$line" | awk '{$1=""; $NF=""; sub(/^  */,""); sub(/  *$/,""); print}')
            [ -z "$tmp" ] || tmp="$tmp,"
            tmp="$tmp{\"pid\":$pid,\"comm\":\"$(jesc "$comm")\",\"rss_kb\":$rss}"
        done <<< "$top_rss_lines"
        top_rss_json="[$tmp]"
    fi
fi

# /dev/dri devices
dri_count=0
if [ -d /dev/dri ]; then
    dri_count=$(ls /dev/dri 2>/dev/null | wc -l)
fi

# xpu-smi summary (optional)
xpu_status="unavailable"
xpu_device_count=0
xpu_err_count=0
if command -v xpu-smi >/dev/null 2>&1; then
    xpu_raw=$(timeout 5 xpu-smi discovery 2>&1 || true)
    if [ -n "$xpu_raw" ]; then
        xpu_device_count=$(echo "$xpu_raw" | grep -cE '^\s*\|\s*[0-9]+\s*\|' || echo 0)
        xpu_err_count=$(echo "$xpu_raw" | grep -ciE 'error|fail' || echo 0)
        xpu_status="ok"
    else
        xpu_status="timeout"
    fi
fi

# vLLM container state
vllm_state="absent"
vllm_restart_count=0
vllm_oomkilled="false"
vllm_exit_code=0
if command -v docker >/dev/null 2>&1; then
    # Try common container names
    for cname in vllm vllm-gemma gemma4 inference; do
        if docker inspect "$cname" >/dev/null 2>&1; then
            vllm_state=$(docker inspect -f '{{.State.Status}}' "$cname" 2>/dev/null || echo unknown)
            vllm_restart_count=$(docker inspect -f '{{.RestartCount}}' "$cname" 2>/dev/null || echo 0)
            vllm_oomkilled=$(docker inspect -f '{{.State.OOMKilled}}' "$cname" 2>/dev/null || echo false)
            vllm_exit_code=$(docker inspect -f '{{.State.ExitCode}}' "$cname" 2>/dev/null || echo 0)
            break
        fi
    done
fi

# vLLM API health
vllm_http="000"
vllm_time="0"
if command -v curl >/dev/null 2>&1; then
    vllm_probe=$(curl -m 3 -s -o /dev/null -w '%{http_code}|%{time_total}' \
                      http://localhost:8000/v1/models 2>/dev/null || echo "000|0")
    vllm_http=${vllm_probe%%|*}
    vllm_time=${vllm_probe##*|}
fi

# sshd PID + child count
sshd_pid=0
sshd_children=0
if command -v pgrep >/dev/null 2>&1; then
    sshd_pid=$(pgrep -o sshd 2>/dev/null || echo 0)
    if [ "$sshd_pid" != "0" ] && [ -n "$sshd_pid" ]; then
        sshd_children=$(pgrep -P "$sshd_pid" 2>/dev/null | wc -l)
    else
        sshd_pid=0
    fi
fi

# Disk usage (root + any /mnt/models-like mount)
disk_root_pct=$(df -P / 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
disk_root_pct=${disk_root_pct:-0}
disk_models_pct=0
disk_models_mount=""
for m in /mnt/models /models /mnt/data /data; do
    if mountpoint -q "$m" 2>/dev/null; then
        disk_models_mount="$m"
        disk_models_pct=$(df -P "$m" 2>/dev/null | awk 'NR==2 {gsub("%",""); print $5}')
        disk_models_pct=${disk_models_pct:-0}
        break
    fi
done

# Recent dmesg err/warn counts (last 5 min). Needs CAP_SYSLOG or dmesg readable.
dmesg_err_count=0
dmesg_recent_lines=""
if command -v dmesg >/dev/null 2>&1; then
    dmesg_out=$(dmesg -T --since '5 min ago' 2>/dev/null | grep -iE 'error|warn|fail|oom' || true)
    if [ -n "$dmesg_out" ]; then
        dmesg_err_count=$(echo "$dmesg_out" | wc -l)
        dmesg_recent_lines=$(echo "$dmesg_out" | tail -3 | tr '\n' '|' | sed 's/|$//')
    fi
fi

# Network deltas (bytes since last sample)
net_state_file="$STATE_DIR/net_last"
declare -A rx_new tx_new
primary_iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')
primary_iface=${primary_iface:-eth0}
net_rx_delta=0
net_tx_delta=0
if [ -r /proc/net/dev ]; then
    line=$(grep -E "^\s*${primary_iface}:" /proc/net/dev 2>/dev/null | head -1)
    if [ -n "$line" ]; then
        rx_cur=$(echo "$line" | awk '{print $2}')
        tx_cur=$(echo "$line" | awk '{print $10}')
        if [ -f "$net_state_file" ]; then
            read -r rx_prev tx_prev _ < "$net_state_file" 2>/dev/null || { rx_prev=0; tx_prev=0; }
            net_rx_delta=$(( rx_cur - rx_prev ))
            net_tx_delta=$(( tx_cur - tx_prev ))
            [ "$net_rx_delta" -lt 0 ] && net_rx_delta=0
            [ "$net_tx_delta" -lt 0 ] && net_tx_delta=0
        fi
        printf '%s %s\n' "$rx_cur" "$tx_cur" > "$net_state_file" 2>/dev/null || true
    fi
fi

# Heartbeat — prove the script actually ran
touch "$HEARTBEAT" 2>/dev/null || true

# --- assemble single JSON line -----------------------------------------------

json=$(cat <<EOF
{"ts":"$now_iso","host":"$(jesc "$host")","uptime_s":$uptime_s,"cpu_count":$cpu_count,"load1":$load1,"load5":$load5,"load15":$load15,"mem_total_kb":$mem_total,"mem_free_kb":$mem_free,"mem_avail_kb":$mem_avail,"swap_total_kb":$swap_total,"swap_used_kb":$swap_used,"top_rss":$top_rss_json,"dri_count":$dri_count,"xpu":{"status":"$xpu_status","devices":$xpu_device_count,"errors":$xpu_err_count},"vllm":{"state":"$vllm_state","restart_count":$vllm_restart_count,"oomkilled":$vllm_oomkilled,"exit_code":$vllm_exit_code,"http_code":"$vllm_http","time_total":"$vllm_time"},"sshd":{"pid":$sshd_pid,"children":$sshd_children},"disk":{"root_pct":$disk_root_pct,"models_mount":"$(jesc "$disk_models_mount")","models_pct":$disk_models_pct},"dmesg":{"err_count":$dmesg_err_count,"recent":"$(jesc "$dmesg_recent_lines")"},"net":{"iface":"$(jesc "$primary_iface")","rx_delta":$net_rx_delta,"tx_delta":$net_tx_delta},"heartbeat":"$HEARTBEAT"}
EOF
)

echo "$json" >> "$LOG" 2>/dev/null || echo "$json" >> "/tmp/inference_diag.jsonl"
# Also emit to stdout so journald captures it via the systemd unit.
echo "$json"
