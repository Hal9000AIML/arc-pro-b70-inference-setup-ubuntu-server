#!/usr/bin/env bash
# Daily Intel driver/firmware update checker for Arc Pro B70 (Battlemage) boxes.
# Runs apt update, snapshots versions of Intel GPU-related packages, captures
# kernel + GuC firmware state, and appends a JSON line to /var/log/intel_updates.jsonl
# Safe to run repeatedly; non-interactive.

set -u
LOG=/var/log/intel_updates.jsonl
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HOST=$(hostname)

export DEBIAN_FRONTEND=noninteractive
sudo apt-get update -qq >/dev/null 2>&1 || true

PKGS=(linux-firmware intel-compute-runtime intel-level-zero-gpu level-zero xpumanager intel-media-va-driver-non-free intel-microcode intel-gpu-tools)

json_escape() {
    python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || \
    printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g' | tr -d '\n')"
}

pkg_json="{"
first=1
for p in "${PKGS[@]}"; do
    pol=$(apt policy "$p" 2>/dev/null)
    if [ -z "$pol" ] || echo "$pol" | grep -q "Unable to locate"; then
        installed="none"; candidate="none"
    else
        installed=$(echo "$pol" | awk -F': ' '/Installed:/ {print $2; exit}')
        candidate=$(echo "$pol" | awk -F': ' '/Candidate:/ {print $2; exit}')
        [ -z "$installed" ] && installed="none"
        [ -z "$candidate" ] && candidate="none"
    fi
    [ $first -eq 0 ] && pkg_json+=","
    first=0
    pkg_json+="\"$p\":{\"installed\":\"$installed\",\"candidate\":\"$candidate\"}"
done
pkg_json+="}"

UPGRADABLE=$(apt list --upgradable 2>/dev/null | grep -iE "intel|xe|gpu|firmware|level-zero|xpumanager|compute-runtime" | sed 's/"/\\"/g' | awk '{printf "\"%s\",", $0}' | sed 's/,$//')
UPGRADABLE="[${UPGRADABLE}]"

KERNEL=$(uname -r)
GUC=$(dmesg 2>/dev/null | grep -iE "xe.*guc.*loaded|bmg_guc" | tail -5 | tr '\n' '|' | sed 's/"/\\"/g; s/|$//')
XE_MOD=$(modinfo xe 2>/dev/null | grep -E "^(filename|version|srcversion):" | tr '\n' '|' | sed 's/"/\\"/g; s/|$//')

LINE="{\"timestamp\":\"$TS\",\"host\":\"$HOST\",\"kernel\":\"$KERNEL\",\"guc_dmesg\":\"$GUC\",\"xe_modinfo\":\"$XE_MOD\",\"packages\":$pkg_json,\"upgradable\":$UPGRADABLE}"

sudo touch "$LOG"
sudo chmod 644 "$LOG"
echo "$LINE" | sudo tee -a "$LOG" >/dev/null
echo "$LINE"
