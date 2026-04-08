# Inference Box Diagnostics

Persistent health logging for the ARC Pro B70 inference box at **192.168.1.2**.
Designed so that when the box wedges (swap pressure → sshd hang), you can still
tell what happened — both live (via the LAN HTTP endpoint) and after a hard
reset (via boot-forensics captures).

## Components

| Piece | File | Runs as |
| --- | --- | --- |
| 60s sampler (bash) | `/opt/inference_diag/inference_diag.sh` | `inference-diag.timer` → `inference-diag.service` |
| LAN HTTP endpoint (Python stdlib) | `/opt/inference_diag/diag_http.py` | `inference-diag-http.service` (port **8765**) |
| Previous-boot forensics | `/opt/inference_diag/capture_last_boot.sh` | `inference-boot-forensics.service` (once per boot) |
| Installer | `install_inference_diag.sh` | invoked by `odin-b70-setup.sh` |

All systemd units are OOM-protected with `OOMScoreAdjust=-500` and get elevated
`CPUWeight`/`IOWeight`, so they stay responsive even when the box is actively
OOMing or swap-thrashing.

## Where logs live

| Path | Contents |
| --- | --- |
| `/var/log/inference_diag.jsonl` | Rolling single-line JSON samples, one per minute. Rotated at 100 MB to `.1.gz`. |
| `/var/log/last_boot_errors.txt` | `journalctl -b -1 -p err` from the previous boot. |
| `/var/log/last_boot_tail.txt` | Last 500 lines of the previous boot's journal. |
| `/var/log/last_boot_diag_tail.jsonl` | Last 200 diag samples from the previous boot (if any). |
| `/var/log/last_boot_meta.txt` | Boot ID + `journalctl --list-boots` tail. |
| `/tmp/odin_diag.heartbeat` | Touched by every successful sampler run (proves the script ran this minute). |
| `journalctl -u inference-diag.service` | Same JSON lines, via journald. |

If `/var/log` is not writable for any reason, everything falls back to
`$HOME/inference_diag.jsonl` and then `/tmp/inference_diag.jsonl`.

## Sample JSON schema

```json
{
  "ts": "2026-04-07T12:34:56Z",
  "host": "proB70",
  "uptime_s": 3600,
  "cpu_count": 64,
  "load1": 1.23, "load5": 1.10, "load15": 0.90,
  "mem_total_kb": 16000000, "mem_free_kb": 200000, "mem_avail_kb": 600000,
  "swap_total_kb": 134217728, "swap_used_kb": 98765432,
  "top_rss": [{"pid": 1234, "comm": "python3", "rss_kb": 12345678}, ...],
  "dri_count": 4,
  "xpu": {"status": "ok|timeout|unavailable", "devices": 4, "errors": 0},
  "vllm": {"state": "running", "restart_count": 0, "oomkilled": false,
           "exit_code": 0, "http_code": "200", "time_total": "0.042"},
  "sshd": {"pid": 987, "children": 2},
  "disk": {"root_pct": 42, "models_mount": "/mnt/models", "models_pct": 61},
  "dmesg": {"err_count": 0, "recent": ""},
  "net": {"iface": "enp3s0", "rx_delta": 12345, "tx_delta": 6789},
  "heartbeat": "/tmp/odin_diag.heartbeat"
}
```

## Reading health from any LAN machine (no SSH needed)

The `diag_http.py` daemon listens on **0.0.0.0:8765** and exposes:

| Endpoint | Purpose |
| --- | --- |
| `GET /` | Latest JSON sample. |
| `GET /history?n=60` | Last N samples (default 60, max 1000) as a JSON array. |
| `GET /health` | Plaintext liveness probe (`diag-http alive`). |

Examples:

```bash
curl -s http://192.168.1.2:8765/ | python3 -m json.tool
curl -s 'http://192.168.1.2:8765/history?n=120' | jq '.[-5:]'
curl -s http://192.168.1.2:8765/health
```

From PowerShell on the main PC:

```powershell
Invoke-RestMethod http://192.168.1.2:8765/
```

This daemon has higher OOM resistance than sshd, so **it should still answer
even when SSH has wedged**. If `/` responds but `/v1/models` at port 8000 does
not, vLLM is the broken part, not the box. If `/health` responds but `/`
doesn't, the sampler died but the HTTP process is alive.

## Alert thresholds (used by the main-PC poller)

The poller at `C:\AI_Vector\scripts\check_inference_health.py` raises alerts on:

| Condition | Severity |
| --- | --- |
| `swap_used / swap_total > 0.85` | high — death spiral imminent |
| `load5 / cpu_count > 4` | high — runqueue overloaded |
| `vllm.time_total > 5s` OR `vllm.http_code != "200"` | high — inference API degraded |
| `vllm.oomkilled == true` or `vllm.restart_count` increased | critical |
| `dmesg.err_count > 0` | medium |
| No successful `/` poll in 3 minutes | critical — box possibly wedged |
| `disk.root_pct > 90` or `disk.models_pct > 95` | high |

Alerts are printed to stdout and appended to
`C:\AI_Vector\data\inference_health\alerts.jsonl`.

## Recovering from a wedged sshd

When the box is swap-thrashing hard enough to hang sshd:

1. **Check the HTTP endpoint first.** If `curl http://192.168.1.2:8765/` still
   answers, read the JSON — you'll usually see `swap_used_kb` near
   `swap_total_kb` and a huge `top_rss` python3 process. That's the root cause.
2. **Poll `/history?n=60`** for the trend. If swap was climbing for >10 samples
   before the wedge, the fix is RAM / `--max-num-seqs` / `--gpu-memory-util`,
   not a reboot.
3. **Physical reset is the only recovery** once sshd is gone. There is no
   software path back in — the OOM killer can't kill processes fast enough and
   new sshd child forks fail. Power-cycle the box.
4. **After reboot, immediately read**:
   - `/var/log/last_boot_errors.txt` — journal errors from the dead boot.
   - `/var/log/last_boot_tail.txt` — last 500 journal lines.
   - `/var/log/last_boot_diag_tail.jsonl` — last 200 diag samples, which show
     exactly how the death spiral progressed.
5. Correlate with `C:\AI_Vector\data\inference_health\<date>.jsonl` on the main
   PC (the poller keeps its own copy, so even if the box lost its log you have
   a LAN-side record).

## Operational commands

```bash
# Is the sampler running?
systemctl status inference-diag.timer inference-diag.service

# Is the HTTP endpoint alive?
systemctl status inference-diag-http.service
curl -s http://localhost:8765/health

# Force a sample now
sudo systemctl start inference-diag.service

# Tail the JSONL
tail -f /var/log/inference_diag.jsonl

# View last 10 samples via journald
journalctl -u inference-diag.service -n 10 --no-pager

# Re-run installer (idempotent)
sudo bash /path/to/ProB70_Install/install_inference_diag.sh
```

## Design notes

- **Single-line JSON only.** This file grows once a minute forever; pretty-
  printing would 5x it.
- **Stdlib only on the HTTP side.** No httpx / FastAPI / anything pip. A wedge
  that blocks pip would otherwise kill the health endpoint itself.
- **Every external-tool lookup is guarded** (`command -v xpu-smi || ...`) so a
  missing binary degrades gracefully to `"unavailable"` in the JSON, not a
  silent sample drop.
- **Net/process deltas use `/run/inference_diag/` for state.** `tmpfs`, cleared
  on boot — correct behavior, since byte counters reset on boot too.
- **No auth on port 8765 on purpose.** The data is diagnostic only, the
  endpoint is firewalled to `192.168.1.0/24`, and adding auth would introduce
  a dependency that could itself wedge.
