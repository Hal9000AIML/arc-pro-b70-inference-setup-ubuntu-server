#!/usr/bin/env python3
"""Tiny LAN-only HTTP endpoint serving the latest inference_diag.jsonl sample.

Runs under systemd with OOMScoreAdjust=-500 so the kernel OOM killer won't
take it — the whole point is that it stays responsive even when sshd wedges
under swap pressure.

Endpoints:
  GET /           -> most recent JSON line from inference_diag.jsonl
  GET /history    -> last N lines (default 60, max 1000) as a JSON array,
                     controlled by ?n=<int>
  GET /health     -> 200 OK "diag-http alive" plaintext — lightweight liveness

Stdlib only: http.server + json + os.
"""
from __future__ import annotations

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

CANDIDATE_LOGS = [
    "/var/log/inference_diag.jsonl",
    os.path.expanduser("~/inference_diag.jsonl"),
    "/tmp/inference_diag.jsonl",
]
PORT = int(os.environ.get("INFERENCE_DIAG_PORT", "8765"))


def pick_log() -> str | None:
    for p in CANDIDATE_LOGS:
        if os.path.isfile(p):
            return p
    return None


def tail_lines(path: str, n: int) -> list[str]:
    """Return up to the last n non-empty lines from a file. Small, safe seek-read."""
    if n <= 0:
        return []
    try:
        size = os.path.getsize(path)
        if size == 0:
            return []
        # Read up to ~256 KB * n-ish, or the whole file if smaller.
        chunk = min(size, max(8192, n * 4096))
        with open(path, "rb") as f:
            f.seek(size - chunk)
            data = f.read()
        lines = [ln.decode("utf-8", errors="replace") for ln in data.splitlines() if ln.strip()]
        return lines[-n:]
    except OSError:
        return []


class DiagHandler(BaseHTTPRequestHandler):
    # Quieter logs — we're polled every 30s, don't flood journald.
    def log_message(self, fmt: str, *args) -> None:  # noqa: A003
        pass

    def _send_json(self, code: int, body: object) -> None:
        payload = json.dumps(body, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"

        if path == "/health":
            body = b"diag-http alive\n"
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return

        log = pick_log()
        if log is None:
            self._send_json(503, {"error": "no diag log present yet"})
            return

        if path == "/":
            lines = tail_lines(log, 1)
            if not lines:
                self._send_json(503, {"error": "log empty"})
                return
            try:
                obj = json.loads(lines[-1])
            except json.JSONDecodeError:
                self._send_json(500, {"error": "latest line not valid JSON", "raw": lines[-1][:500]})
                return
            self._send_json(200, obj)
            return

        if path == "/history":
            qs = parse_qs(parsed.query)
            try:
                n = int(qs.get("n", ["60"])[0])
            except ValueError:
                n = 60
            n = max(1, min(1000, n))
            lines = tail_lines(log, n)
            out = []
            for ln in lines:
                try:
                    out.append(json.loads(ln))
                except json.JSONDecodeError:
                    continue
            self._send_json(200, out)
            return

        self._send_json(404, {"error": "not found", "path": path})


def main() -> int:
    addr = ("0.0.0.0", PORT)
    server = ThreadingHTTPServer(addr, DiagHandler)
    print(f"diag_http: listening on {addr[0]}:{addr[1]}", flush=True)
    try:
        server.serve_forever(poll_interval=1.0)
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
