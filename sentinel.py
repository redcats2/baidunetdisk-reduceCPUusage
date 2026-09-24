#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
BaiduNetdisk ReduceCPUusage Service
- Monitors Docker container RX speed from /proc/<pid>/net/dev
- Monitors active Web connections on port 5800
- Automatically pauses container (CPU -> 0.00%) when idle
- Supports dual wake modes:
  1. Nginx auth_request subrequest hook (port 5802)
  2. Direct Web TCP connection listener (Transparent Wake Proxy)
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
ENABLE_DIRECT_PROXY = os.environ.get("REDUCECPU_DIRECT_PROXY", "false").lower() == "true"
DIRECT_LISTEN_PORT = int(os.environ.get("REDUCECPU_DIRECT_PORT", 5800))
BACKEND_PORT = int(os.environ.get("REDUCECPU_BACKEND_PORT", 58000))

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
        check_port = DIRECT_LISTEN_PORT if ENABLE_DIRECT_PROXY else WEB_PORT
        res = subprocess.check_output(
            ["ss", "-tn", f"sport = :{check_port}"],
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

    log(f"Watchdog started. Container: {CONTAINER_NAME}, SpeedThreshold: <{SPEED_THRESHOLD_KB}KB/s, IdleTimeout: {IDLE_SECONDS}s, DirectProxy: {ENABLE_DIRECT_PROXY}")
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

# --- Nginx auth_request hook server ---
class WakeHandler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        pass

    def do_GET(self):
        ensure_unpaused("Nginx auth_request GET " + self.path)
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"OK")

    def do_HEAD(self):
        ensure_unpaused("Nginx auth_request HEAD " + self.path)
        self.send_response(200)
        self.end_headers()

def run_wake_server():
    server = HTTPServer(("127.0.0.1", WAKE_PORT), WakeHandler)
    server.serve_forever()

# --- Direct Non-Proxy Transparent TCP Bridge ---
def handle_client_tcp(client_sock):
    ensure_unpaused("Direct TCP connection on port " + str(DIRECT_LISTEN_PORT))
    try:
        backend_sock = socket.create_connection(("127.0.0.1", BACKEND_PORT), timeout=5)
    except Exception as e:
        log(f"Failed to connect to backend {BACKEND_PORT}: {e}")
        client_sock.close()
        return

    socks = [client_sock, backend_sock]
    try:
        while True:
            r, _, e = select.select(socks, [], socks, 120)
            if e or not r:
                break
            for s in r:
                data = s.recv(65536)
                if not data:
                    return
                target = backend_sock if s is client_sock else client_sock
                target.sendall(data)
    except Exception:
        pass
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        try:
            backend_sock.close()
        except Exception:
            pass

def run_direct_bridge():
    bridge = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    bridge.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    bridge.bind(("0.0.0.0", DIRECT_LISTEN_PORT))
    bridge.listen(128)
    log(f"Direct transparent wake bridge listening on 0.0.0.0:{DIRECT_LISTEN_PORT} -> 127.0.0.1:{BACKEND_PORT}")

    while True:
        try:
            client_sock, _ = bridge.accept()
            t = threading.Thread(target=handle_client_tcp, args=(client_sock,), daemon=True)
            t.start()
        except Exception as e:
            time.sleep(1)

if __name__ == "__main__":
    t_wd = threading.Thread(target=watchdog_loop, daemon=True)
    t_wd.start()

    if ENABLE_DIRECT_PROXY:
        t_bridge = threading.Thread(target=run_direct_bridge, daemon=True)
        t_bridge.start()

    run_wake_server()
