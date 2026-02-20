#!/bin/bash
set -e

PROFILE_DURATION="${PROFILE_DURATION:-60}"
VECTOR_BIN=/vector/target/release/vector
OUTPUT=/profiling/output

echo "=== Vector Profiling ==="

# perf requires this; privileged mode lets us set it inside the container
echo -1 | tee /proc/sys/kernel/perf_event_paranoid > /dev/null

# --- Extract vector config from the Kubernetes ConfigMap ---
echo "Extracting vector config from ConfigMap..."
python3 - <<'EOF'
import yaml
with open('/profiling/config/cm.yaml') as f:
    cm = yaml.safe_load(f)
config = cm['data']['config.yaml']
with open('/tmp/vector.yaml', 'w') as f:
    f.write(config)
print("  Config extracted to /tmp/vector.yaml")
EOF

# --- Generate TLS certs ---
# The aggregator config expects:
#   CA:     /etc/ssl/rubix-ca/ca.pem
#   Server: /mnt/secrets/certs/tls.crt + tls.key
#   Client certs are required because verify_certificate: true
echo "Generating TLS certificates..."
mkdir -p /etc/ssl/rubix-ca /mnt/secrets/certs /tmp/profiling-certs

# CA
openssl req -newkey rsa:2048 -nodes \
    -keyout /tmp/profiling-certs/ca.key \
    -x509 -days 365 \
    -out /etc/ssl/rubix-ca/ca.pem \
    -subj "/CN=vector-profiling-ca" 2>/dev/null

# Server cert signed by CA
openssl req -newkey rsa:2048 -nodes \
    -keyout /mnt/secrets/certs/tls.key \
    -out /tmp/profiling-certs/server.csr \
    -subj "/CN=localhost" 2>/dev/null
openssl x509 -req -days 365 \
    -in /tmp/profiling-certs/server.csr \
    -CA /etc/ssl/rubix-ca/ca.pem \
    -CAkey /tmp/profiling-certs/ca.key \
    -CAcreateserial \
    -out /mnt/secrets/certs/tls.crt 2>/dev/null

# Client cert (required by verify_certificate: true on the aggregator)
openssl req -newkey rsa:2048 -nodes \
    -keyout /tmp/profiling-certs/client.key \
    -out /tmp/profiling-certs/client.csr \
    -subj "/CN=vector-client" 2>/dev/null
openssl x509 -req -days 365 \
    -in /tmp/profiling-certs/client.csr \
    -CA /etc/ssl/rubix-ca/ca.pem \
    -CAkey /tmp/profiling-certs/ca.key \
    -CAcreateserial \
    -out /tmp/profiling-certs/client.crt 2>/dev/null

echo "  Certificates generated"

# --- Build vector if needed ---
if [ ! -f "$VECTOR_BIN" ]; then
    echo "Building vector with debug symbols (this takes a while)..."
    cd /vector
    cargo build --release 2>&1
    echo "  Build complete"
else
    echo "Using existing binary at $VECTOR_BIN"
fi

# --- Start aggregator ---
mkdir -p /vector-data-dir /tmp/vector-gen-data "$OUTPUT"

echo "Starting vector aggregator..."
$VECTOR_BIN --config /tmp/vector.yaml &
VECTOR_PID=$!
echo "  Vector PID: $VECTOR_PID"

# Wait for API to be ready
echo "Waiting for vector API..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8686/health > /dev/null 2>&1; then
        echo "  Ready"
        break
    fi
    if [ $i -eq 30 ]; then
        echo "ERROR: Vector failed to become ready. Check logs above."
        kill $VECTOR_PID 2>/dev/null || true
        exit 1
    fi
    sleep 1
done

print_metrics() {
    # Scrape the prometheus_exporter sink which exports vector_component_* internal metrics.
    # Shows received vs sent per component so you can see where events are being dropped.
    curl -sf --max-time 3 http://localhost:9598/metrics 2>/dev/null | \
    python3 -c "
import sys, re
data = {}
for line in sys.stdin:
    if line.startswith('#'):
        continue
    m = re.match(r'vector_component_(received|sent)_events_total\{[^}]*component_id=\"([^\"]+)\"[^}]*\}\s+(\S+)', line)
    if m:
        kind, cid, val = m.groups()
        data.setdefault(cid, {})[kind] = int(float(val))
for cid in sorted(data):
    d = data[cid]
    rx = d.get('received', 0)
    tx = d.get('sent', 0)
    print(f'  {cid:40s}  rx={rx:>8}  tx={tx:>8}')
" 2>/dev/null || echo "  (metrics unavailable)"
}

# --- Profile ---
echo "Starting load generator..."
$VECTOR_BIN --config /profiling/generator.yaml &
GEN_PID=$!

# Brief pause so the generator establishes its connection before perf starts
sleep 2

echo "Recording perf data for ${PROFILE_DURATION}s..."
perf record -F99 --call-graph dwarf -p $VECTOR_PID \
    -o "$OUTPUT/perf.data" \
    -- sleep "$PROFILE_DURATION"

echo ""
echo "Component event counts:"
print_metrics

echo ""
echo "Profiling complete. Stopping processes..."
# SIGKILL the generator immediately — no need for clean shutdown, and waiting for
# it to drain its buffer to the now-dead aggregator takes up to 60 seconds.
kill -9 $GEN_PID 2>/dev/null || true
# Give the aggregator a moment to flush, then shut it down cleanly.
sleep 1
kill $VECTOR_PID 2>/dev/null || true
wait $VECTOR_PID 2>/dev/null || true

# --- Generate flamegraph ---
echo "Generating flamegraph..."
cd "$OUTPUT"
perf script -i perf.data | inferno-collapse-perf > stacks.folded
inferno-flamegraph stacks.folded > flamegraph.svg

echo ""
echo "=== Done ==="
echo "Flamegraph: profiling/output/flamegraph.svg"
echo "Raw stacks: profiling/output/stacks.folded"
