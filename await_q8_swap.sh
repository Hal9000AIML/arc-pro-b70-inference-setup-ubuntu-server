#!/usr/bin/env bash
# Waits for all Q8_0 downloads to complete, then restarts all 4 servers
LOG=/tmp/q8_swap.log
exec > "$LOG" 2>&1

echo "$(date) Waiting for downloads..."

wait_file() {
  local f=$1 min=$2
  while true; do
    sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    if [ "$sz" -ge "$min" ]; then
      echo "$(date) READY: $f"
      return 0
    fi
    sleep 30
  done
}

wait_file /mnt/models/Qwen3-14B-Q8_0.gguf            15648000000
wait_file /mnt/models/gemma-4-26B-A4B-it-Q8_0.gguf   26800000000
wait_file /mnt/models/RedSage-Qwen3-8B-DPO.Q8_0.gguf  8600000000

echo "$(date) All downloads complete. Restarting servers..."

# Kill existing servers by port
for port in 8000 8001 8002 8003; do
  pid=$(ss -tlnp 2>/dev/null | grep ":$port " | grep -oP 'pid=\K[0-9]+')
  if [ -n "$pid" ]; then
    kill "$pid"
    echo "$(date) Killed port $port pid $pid"
  fi
done
sleep 5

# Start all 4
nohup bash ~/start_gemma.sh   >/dev/null 2>&1 &
nohup bash ~/start_coder.sh   >/dev/null 2>&1 &
nohup bash ~/start_fast.sh    >/dev/null 2>&1 &
nohup bash ~/start_pentest.sh >/dev/null 2>&1 &

echo "$(date) ALL_SERVERS_RESTARTED"
