#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BaiduNetdisk ReduceCPUusage Service
- Monitors Docker container RX speed from /proc/<pid>/net/dev
- Monitors active Web connections on port 5800
- Automatically pauses container (CPU -> 0.00%) when idle
- Wakes up container immediately on incoming HTTP requests from Nginx
"""

import os
import sys
import time
import socket
import select
import threading
import subprocess
from http.server import HTTPServer, BaseHTTPRequestHandler

# Config via environment variables or default values
WAKE_PORT = int(os.environ.get("REDUCECPU_WAKE_PORT", 5802))
CONTAINER_NAME = os.environ.get("REDUCECPU_CONTAINER_NAME", "baidunetdisk")
SPEED_THRESHOLD_KB = float(os.environ.get("REDUCECPU_SPEED_KB", 30))  # RX speed threshold in KB/s
IDLE_SECONDS = int(os.environ.get("REDUCECPU_IDLE_SECONDS", 180))     # Idle timeout (seconds)
WEB_PORT = int(os.environ.get("REDUCECPU_WEB_PORT", 5800))

last_active_time = time.time()
lock = threading.Lock()

def log(msg):
    print(f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {msg}", flush=True)

def is_container_paused():
    try:
        out = subprocess.check_output(
            ["docker", "inspect", CONTAINER_NAME, "--format", "{{.State.Status}}"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        return out == "paused"
    except Exception:
        return False

def ensure_unpaused(reason="web_request"):
    global last_active_time
    with lock:
        last_active_time = time.time()
    if is_container_paused():
        log(f"Waking up container '{CONTAINER_NAME}' (reason: {reason})...")
        subprocess.run(["docker", "unpause", CONTAINER_NAME], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log("Container resumed (active).")

def get_container_rx_bytes():
    try:
        pid = subprocess.check_output(
            ["docker", "inspect", CONTAINER_NAME, "--format", "{{.State.Pid}}"],
            stderr=subprocess.DEVNULL
        ).decode().strip()
        if not pid or pid == "0":
            return None
        with open(f"/proc/{pid}/net/dev", "r") as f:
            for line in f:
                if "eth0:" in line:
                    parts = line.split()
                    return int(parts[1])
    except Exception:
        return None
    return None

def has_active_web_connections():
    try:
        res = subprocess.check_output(
            ["ss", "-tn", f"sport = :{WEB_PORT}"],
            stderr=subprocess.DEVNULL
        ).decode()
        lines = [l for l in res.strip().split("\n") if "ESTAB" in l]
        return len(lines) > 0
    except Exception:
        return False

def watchdog_loop():
    global last_active_time
    last_rx = get_container_rx_bytes()
    last_check_time = time.time()

    log(f"Watchdog started. Container: {CONTAINER_NAME}, SpeedThreshold: <{SPEED_THRESHOLD_KB}KB/s, IdleTimeout: {IDLE_SECONDS}s")
    while True:
        time.sleep(15)
        if is_container_paused():
            continue

        now = time.time()
        elapsed = now - last_check_time
        curr_rx = get_container_rx_bytes()

        rx_speed_kb = 0.0
        if curr_rx is not None and last_rx is not None and elapsed > 0:
            rx_speed_kb = ((curr_rx - last_rx) / 1024.0) / elapsed

        last_rx = curr_rx
        last_check_time = now

        web_active = has_active_web_connections()

        if rx_speed_kb >= SPEED_THRESHOLD_KB or web_active:
            with lock:
                last_active_time = now
        else:
            with lock:
                idle_duration = now - last_active_time

            if idle_duration >= IDLE_SECONDS:
                if not is_container_paused():
                    log(f"Idle for {int(idle_duration)}s (speed: {rx_speed_kb:.2f}KB/s < {SPEED_THRESHOLD_KB}KB/s, web idle). Freezing container...")
                    subprocess.run(["docker", "pause", CONTAINER_NAME], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    log("Container frozen (CPU -> 0.00%).")

class WakeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        ensure_unpaused("GET " + self.path)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def do_HEAD(self):
        ensure_unpaused("HEAD " + self.path)
        self.send_response(200)
        self.end_headers()

if __name__ == "__main__":
    t = threading.Thread(target=watchdog_loop, daemon=True)
    t.start()
    server = HTTPServer(("127.0.0.1", WAKE_PORT), WakeHandler)
    server.serve_forever()
