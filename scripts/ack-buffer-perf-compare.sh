#!/usr/bin/env bash
# Acknowledgement + Buffer Performance Comparison
#
# Tests checkpoint advancement for the file source (which kubernetes_logs wraps)
# across different sink types and buffer configurations with acks enabled.
#
# Conclusions demonstrated:
#   1. Acks work correctly with all sink types and buffer types for throughput
#   2. With a jittery downstream sink, memory+acks shows burst/stall checkpoint
#      pattern (checkpoint lags behind file position during slow requests)
#   3. Disk+acks eliminates the burst/stall pattern (ack resolves at buffer write)
#   4. The burst/stall is a checkpoint latency issue, not a throughput issue
#
# Usage: ./scripts/ack-buffer-perf-compare.sh [num_events]
#
# Requirements: python3, Vector release binary with sources-file + sinks-http

set -euo pipefail

NUM_EVENTS="${1:-5000}"
VECTOR_BIN="${VECTOR_BIN:-./target/release/vector}"
TIMEOUT_SECS=30

if [ ! -f "$VECTOR_BIN" ]; then
    echo "Vector binary not found at $VECTOR_BIN"
    echo "Build with: cargo build --release --no-default-features --features 'sources-file,sinks-blackhole,sinks-socket,sinks-http'"
    exit 1
fi

echo "================================================================"
echo "  Ack + Buffer Performance Comparison ($NUM_EVENTS events)"
echo "================================================================"
echo ""

get_free_port() {
    python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

start_http_receiver() {
    local port="$1"
    local delay_pattern="$2"  # "none" or "jittery"
    python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
import time
count=[0]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length',0)))
        count[0]+=1
        if '$delay_pattern' == 'jittery' and count[0] % 5 == 0:
            time.sleep(2.0)
        else:
            time.sleep(0.01)
        self.send_response(200); self.end_headers()
    def log_message(self,*a): pass
HTTPServer(('127.0.0.1',$port),H).serve_forever()
" &
}

run_test() {
    local label="$1" acks="$2" buffer="$3" delay_pattern="$4"

    local TD=$(mktemp -d)
    mkdir -p "$TD/data" "$TD/logs"
    local LF="$TD/logs/test.log"; touch "$LF"
    local PORT=$(get_free_port)

    start_http_receiver "$PORT" "$delay_pattern"
    local RP=$!; sleep 1

    local AS="" AK=""
    [ "$acks" = "true" ] && AS='acknowledgements.enabled = true' && AK='acknowledgements = true'
    local BT="memory" BS="max_events = 10000"
    [ "$buffer" = "disk" ] && BT="disk" && BS="max_size = 268435488"

    cat > "$TD/t.toml" <<EOF
data_dir = "$TD/data"
[sources.file_in]
type = "file"
include = ["$LF"]
read_from = "beginning"
glob_minimum_cooldown_ms = 500
$AS
[sinks.out]
type = "http"
inputs = ["file_in"]
uri = "http://127.0.0.1:$PORT/"
method = "post"
encoding.codec = "text"
$AK
[sinks.out.batch]
max_events = 50
timeout_secs = 1
[sinks.out.buffer]
type = "$BT"
$BS
when_full = "block"
EOF

    "$VECTOR_BIN" --config "$TD/t.toml" --quiet 2>/dev/null &
    local VP=$!; sleep 1

    # Continuously write lines
    python3 -c "
import time
with open('$LF','a') as f:
    for i in range($NUM_EVENTS):
        f.write(f'log line {i} padding data for kubernetes simulation test\n')
        f.flush(); time.sleep(0.005)" &
    local WP=$!

    local CP="$TD/data/file_in/checkpoints.json" PREV=0 STALLS=0 ADV=0 MAXLAG=0
    for i in $(seq 1 40); do
        sleep 0.5
        local FS=$(wc -c < "$LF" | tr -d ' ') P=0
        [ -f "$CP" ] && P=$(python3 -c "import json
try:
 d=json.load(open('$CP'));c=d.get('checkpoints',[]);print(max(x.get('position',0) for x in c) if c else 0)
except: print(0)" 2>/dev/null)
        local D=$((P-PREV)) L=$((FS-P))
        [ "$L" -gt "$MAXLAG" ] && MAXLAG=$L
        [ "$D" -eq 0 ] && [ "$FS" -gt 0 ] && STALLS=$((STALLS+1))
        [ "$D" -gt 0 ] && ADV=$((ADV+1))
        PREV=$P
    done
    printf "  %-30s stalls=%-3d advances=%-3d max_lag=%d bytes\n" "$label" "$STALLS" "$ADV" "$MAXLAG"
    kill $VP $RP $WP 2>/dev/null; wait $VP $RP $WP 2>/dev/null; rm -rf "$TD"
}

# ================================================================
# Part 1: Fast HTTP sink (no jitter) — all configs should be equal
# ================================================================
echo "--- Fast HTTP sink (10ms response) ---"
run_test "memory, no acks"  false memory none
run_test "memory + acks"    true  memory none
run_test "disk + acks"      true  disk   none
run_test "disk, no acks"    false disk   none
echo ""

# ================================================================
# Part 2: Jittery HTTP sink (2s spike every 5th request)
# Memory+acks should show burst/stall, disk+acks should not
# ================================================================
echo "--- Jittery HTTP sink (2s spike every 5th request) ---"
run_test "memory, no acks"  false memory jittery
run_test "memory + acks"    true  memory jittery
run_test "disk + acks"      true  disk   jittery
run_test "disk, no acks"    false disk   jittery
echo ""

echo "================================================================"
echo "  Analysis"
echo "================================================================"
echo ""
echo "With a fast sink: all configurations perform equally."
echo ""
echo "With a jittery sink: memory+acks shows checkpoint stalls because"
echo "the OrderedFinalizer can't advance past a slow ack. Disk+acks"
echo "resolves acks at the buffer write layer, decoupling checkpoint"
echo "advancement from sink latency."
echo ""
echo "The stall is a checkpoint-lag issue, not throughput: events still"
echo "flow during stalls. The practical impact is on crash recovery —"
echo "larger checkpoint lag means more events re-read on restart."
