#!/usr/bin/env bash
# install_inference_diag.sh — idempotent installer for the inference box
# diagnostic logger, LAN HTTP endpoint, and boot forensics service.
#
# Safe to re-run. Invoked on next boot / RAM upgrade rebuild. Does NOT touch
# the running vLLM container or ODIN. Call from odin-b70-setup.sh or run by
# hand:  sudo bash install_inference_diag.sh
#
# What it does:
#   1. Copies inference_diag.sh, diag_http.py, capture_last_boot.sh to
#      /opt/inference_diag/ with correct modes.
#   2. Installs the four systemd units (diag timer+service, http service,
#      boot forensics service).
#   3. Enables + starts the timer and the HTTP endpoint.
#   4. Runs one sample immediately so /var/log/inference_diag.jsonl exists.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/opt/inference_diag"
SYSTEMD_DIR="/etc/systemd/system"

if [ "$(id -u)" -ne 0 ]; then
    echo "install_inference_diag.sh: must run as root (use sudo)" >&2
    exit 1
fi

echo "[+] creating $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

echo "[+] installing scripts"
install -m 0755 "$SRC_DIR/inference_diag.sh"    "$INSTALL_DIR/inference_diag.sh"
install -m 0755 "$SRC_DIR/capture_last_boot.sh" "$INSTALL_DIR/capture_last_boot.sh"
install -m 0755 "$SRC_DIR/diag_http.py"         "$INSTALL_DIR/diag_http.py"
if [ -f "$SRC_DIR/INFERENCE_DIAGNOSTICS.md" ]; then
    install -m 0644 "$SRC_DIR/INFERENCE_DIAGNOSTICS.md" "$INSTALL_DIR/INFERENCE_DIAGNOSTICS.md"
fi

echo "[+] installing systemd units"
install -m 0644 "$SRC_DIR/systemd/inference-diag.service"           "$SYSTEMD_DIR/inference-diag.service"
install -m 0644 "$SRC_DIR/systemd/inference-diag.timer"             "$SYSTEMD_DIR/inference-diag.timer"
install -m 0644 "$SRC_DIR/systemd/inference-diag-http.service"      "$SYSTEMD_DIR/inference-diag-http.service"
install -m 0644 "$SRC_DIR/systemd/inference-boot-forensics.service" "$SYSTEMD_DIR/inference-boot-forensics.service"

echo "[+] ensuring log file exists and is world-readable"
touch /var/log/inference_diag.jsonl 2>/dev/null || true
chmod 0644 /var/log/inference_diag.jsonl 2>/dev/null || true

echo "[+] reloading systemd"
systemctl daemon-reload

echo "[+] enabling + starting units"
systemctl enable --now inference-diag.timer
systemctl enable --now inference-diag-http.service
systemctl enable inference-boot-forensics.service || true

echo "[+] firing one sample so the log is non-empty"
systemctl start inference-diag.service || true

echo "[+] firewall: allow 8765/tcp from LAN if ufw is active"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow from 192.168.1.0/24 to any port 8765 proto tcp || true
fi

echo
echo "=== inference diag install complete ==="
echo "  latest sample:   curl -s http://localhost:8765/ | python3 -m json.tool"
echo "  history (60):    curl -s http://localhost:8765/history"
echo "  journal:         journalctl -u inference-diag.service --since '10 min ago'"
echo "  raw jsonl:       tail -f /var/log/inference_diag.jsonl"
echo
