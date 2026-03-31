#!/usr/bin/env bash
# Test: kubernetes_logs acknowledgement support verification
#
# Demonstrates two properties of the ack implementation:
#
# 1. CRASH RECOVERY: With acks enabled, no events are lost when Vector is
#    killed mid-pipeline. Without acks, events are lost because the checkpoint
#    advances before delivery is confirmed.
#
# 2. CHECKPOINT LAG: With a jittery downstream sink, memory+acks shows
#    checkpoint stalls (lag between file position and checkpoint position).
#    Disk buffers eliminate this by resolving acks at the buffer write layer.
#
# Usage: ./scripts/test-ack-crash-recovery.sh
#
# Requirements: python3, Vector release binary with sources-file + sinks-http

set -euo pipefail

VECTOR_BIN="${VECTOR_BIN:-./target/release/vector}"

if [ ! -f "$VECTOR_BIN" ]; then
    echo "Vector binary not found at $VECTOR_BIN"
    echo "Build with: cargo build --release --no-default-features --features 'sources-file,sinks-http'"
    exit 1
fi

python3 << 'PYEOF'
import subprocess, tempfile, os, time, json, socket, shutil, threading

VECTOR = "./target/release/vector"

def get_port():
    s = socket.socket(); s.bind(('', 0)); p = s.getsockname()[1]; s.close()
    return p

def start_receiver(port, recv_dir, run_id, delay_ms=20):
    return subprocess.Popen(["python3", "-c", f"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import time, os
class H(BaseHTTPRequestHandler):
    c = 0
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(n).decode('utf-8', errors='replace')
        H.c += 1
        with open(os.path.join('{recv_dir}', f'{run_id}_{{H.c:06d}}'), 'w') as f:
            f.write(body)
        time.sleep({delay_ms} / 1000.0)
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', {port}), H).serve_forever()
"""])

def start_jittery_receiver(port):
    return subprocess.Popen(["python3", "-c", f"""
from http.server import HTTPServer, BaseHTTPRequestHandler; import time
c=[0]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0))); c[0]+=1
        time.sleep(2.0 if c[0]%5==0 else 0.01); self.send_response(200); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',{port}),H).serve_forever()
"""])

def write_config(path, data_dir, log_file, port, acks, buffer_type, batch_size=10):
    ack_src = "acknowledgements.enabled = true" if acks else ""
    ack_sink = "acknowledgements = true" if acks else ""
    buf = f'type = "disk"\nmax_size = 268435488' if buffer_type == "disk" else f'type = "memory"\nmax_events = 10000'
    with open(path, "w") as f:
        f.write(f"""data_dir = "{data_dir}"
[sources.file_in]
type = "file"
include = ["{log_file}"]
read_from = "beginning"
glob_minimum_cooldown_ms = 500
{ack_src}
[sinks.out]
type = "http"
inputs = ["file_in"]
uri = "http://127.0.0.1:{port}/"
method = "post"
encoding.codec = "text"
{ack_sink}
[sinks.out.batch]
max_events = {batch_size}
timeout_secs = 1
[sinks.out.buffer]
{buf}
when_full = "block"
""")

def kill_and_wait(proc, sig="term", timeout=5):
    if sig == "kill":
        proc.kill()
    else:
        proc.terminate()
    try: proc.wait(timeout=timeout)
    except: proc.kill(); proc.wait()

# =====================================================================
# PART 1: Crash Recovery
# =====================================================================

def crash_test(acks, num_events=2000, kill_after=2, run2_wait=10):
    td = tempfile.mkdtemp()
    data_dir = os.path.join(td, "data"); os.makedirs(data_dir)
    os.makedirs(os.path.join(td, "logs"))
    log_file = os.path.join(td, "logs", "test.log")
    recv_dir = os.path.join(td, "received"); os.makedirs(recv_dir)
    port = get_port()
    cfg = os.path.join(td, "vector.toml")

    with open(log_file, "w") as f:
        for i in range(num_events):
            f.write(f"event_{i:05d}\n")

    write_config(cfg, data_dir, log_file, port, acks, "memory")

    # Run 1: start, run briefly, SIGKILL
    recv1 = start_receiver(port, recv_dir, "run1")
    time.sleep(0.5)
    vec1 = subprocess.Popen([VECTOR, "--config", cfg, "--quiet"],
                            stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(kill_after)
    vec1.kill(); vec1.wait()
    time.sleep(0.5)
    kill_and_wait(recv1)

    # Run 2: restart with same data_dir
    recv2 = start_receiver(port, recv_dir, "run2")
    time.sleep(0.5)
    vec2 = subprocess.Popen([VECTOR, "--config", cfg, "--quiet"],
                            stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(run2_wait)
    kill_and_wait(vec2)
    time.sleep(0.5)
    kill_and_wait(recv2)

    # Count unique events
    events = set()
    for fname in os.listdir(recv_dir):
        with open(os.path.join(recv_dir, fname)) as f:
            for line in f.read().strip().split('\n'):
                if line.startswith("event_"):
                    events.add(line.strip())

    run1 = len([f for f in os.listdir(recv_dir) if f.startswith("run1_")])
    run2 = len([f for f in os.listdir(recv_dir) if f.startswith("run2_")])
    shutil.rmtree(td)
    return run1, run2, len(events), num_events - len(events)

# =====================================================================
# PART 2: Checkpoint Lag
# =====================================================================

def lag_test(acks, buffer_type):
    td = tempfile.mkdtemp()
    data_dir = os.path.join(td, "data"); os.makedirs(data_dir)
    os.makedirs(os.path.join(td, "logs"))
    log_file = os.path.join(td, "logs", "test.log")
    open(log_file, "w").close()
    port = get_port()
    cfg = os.path.join(td, "vector.toml")

    write_config(cfg, data_dir, log_file, port, acks, buffer_type, batch_size=50)

    recv = start_jittery_receiver(port)
    time.sleep(1)
    vec = subprocess.Popen([VECTOR, "--config", cfg, "--quiet"],
                           stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
    time.sleep(1)

    def write_lines():
        with open(log_file, "a") as f:
            for i in range(4000):
                f.write(f"log line {i} padding data for kubernetes simulation test\n")
                f.flush(); time.sleep(0.005)
    writer = threading.Thread(target=write_lines, daemon=True)
    writer.start()

    cp_file = os.path.join(data_dir, "file_in", "checkpoints.json")
    prev = 0; stalls = 0; advances = 0; max_lag = 0
    for _ in range(40):
        time.sleep(0.5)
        fs = os.path.getsize(log_file)
        p = 0
        if os.path.exists(cp_file):
            try:
                with open(cp_file) as f:
                    d = json.load(f)
                cps = d.get("checkpoints", [])
                if cps: p = max(c.get("position", 0) for c in cps)
            except: pass
        lag = fs - p
        if lag > max_lag: max_lag = lag
        if p > prev: advances += 1
        elif fs > 0: stalls += 1
        prev = p

    kill_and_wait(vec); kill_and_wait(recv)
    shutil.rmtree(td)
    return stalls, advances, max_lag

# =====================================================================
# Run everything
# =====================================================================

print("=" * 72)
print("  kubernetes_logs Acknowledgement Verification")
print("=" * 72)
print()

# Crash recovery
print("  CRASH RECOVERY (2000 events, SIGKILL after 2s, restart)")
print("  ─────────────────────────────────────────────────────────────────")
print(f"  {'config':<22s} {'run1':>5s} {'run2':>5s} {'unique':>8s} {'lost':>6s}  result")
print(f"  {'─'*22:<22s} {'─'*5:>5s} {'─'*5:>5s} {'─'*8:>8s} {'─'*6:>6s}  {'─'*20}")

for trial in range(1, 4):
    r1, r2, uniq, lost = crash_test(acks=False)
    tag = f"no acks (trial {trial})"
    print(f"  {tag:<22s} {r1:5d} {r2:5d} {uniq:>5d}/2000 {lost:5d}  {'data loss' if lost > 0 else 'ok'}")

    r1, r2, uniq, lost = crash_test(acks=True)
    tag = f"acks (trial {trial})"
    res = "NO DATA LOSS" if lost == 0 else f"FAIL: {lost} lost"
    print(f"  {tag:<22s} {r1:5d} {r2:5d} {uniq:>5d}/2000 {lost:5d}  {res}")

print()

# Checkpoint lag
print("  CHECKPOINT LAG (4000 lines continuous, jittery HTTP: 2s every 5th)")
print("  ─────────────────────────────────────────────────────────────────")
print(f"  {'config':<25s} {'stalls':>7s} {'advances':>9s} {'max_lag':>10s}")
print(f"  {'─'*25:<25s} {'─'*7:>7s} {'─'*9:>9s} {'─'*10:>10s}")

for label, acks, buf in [
    ("memory, no acks", False, "memory"),
    ("memory + acks",   True,  "memory"),
    ("disk + acks",     True,  "disk"),
    ("disk, no acks",   False, "disk"),
]:
    s, a, lag = lag_test(acks, buf)
    print(f"  {label:<25s} {s:7d} {a:9d} {lag:8d} B")

print()
print("  ─────────────────────────────────────────────────────────────────")
print("  Crash recovery: acks prevent data loss by deferring checkpoint")
print("  advancement until the sink confirms delivery.")
print()
print("  Checkpoint lag: with a jittery sink, memory+acks checkpoints")
print("  stall during slow requests. Disk buffers resolve acks at the")
print("  buffer write layer, keeping checkpoint lag low regardless of")
print("  sink latency. The lag determines how many events are re-read")
print("  on crash recovery — lower lag = fewer duplicates on restart.")
PYEOF
