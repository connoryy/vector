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

# Parse the vector config so we can modify the data structure directly, then
# re-serialize. Raw string replacement fails because yaml.safe_load normalizes
# whitespace/newlines, so the extracted string never byte-matches the original.
config = yaml.safe_load(cm['data']['config.yaml'])

# Patch the filtered-internal-metrics filter to also pass allocation tracing
# metrics (component_allocated_bytes*), which are not in the production
# allowlist but are emitted locally when ALLOCATION_TRACING=true.
vrl = config['transforms']['filtered-internal-metrics']['condition']['source']
for metric in ['component_allocated_bytes', 'component_allocated_bytes_total',
               'component_deallocated_bytes_total']:
    if f'"{metric}"' not in vrl:
        vrl = vrl.replace('], .name)', f'  "{metric}",\n], .name)')
config['transforms']['filtered-internal-metrics']['condition']['source'] = vrl

with open('/tmp/vector.yaml', 'w') as f:
    yaml.dump(config, f, default_flow_style=False, allow_unicode=True, sort_keys=False)

with open('/tmp/vector.yaml') as f:
    written = f.read()
if 'component_allocated_bytes' in written:
    print("  Config extracted to /tmp/vector.yaml (allocation metrics added to filter)")
else:
    print("  WARNING: allocation metrics filter patch failed — memory metrics will be empty")
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
ALLOCATION_TRACING=true \
    ALLOCATION_TRACING_REPORTING_INTERVAL_MS=5000 \
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

_scrape_prometheus() {
    # Returns prometheus text on stdout; diagnostics go to stderr so they aren't
    # swallowed when the caller does raw=$(_scrape_prometheus).
    local raw
    raw=$(wget -q -O - --ca-certificate=/etc/ssl/rubix-ca/ca.pem --timeout=3 https://localhost:9598/metrics 2>/dev/null) || true
    if [ -z "$raw" ]; then
        echo "  (prometheus endpoint unreachable at :9598 — is the prometheus-metrics sink running?)" >&2
        return 1
    fi
    local nlines
    nlines=$(echo "$raw" | grep -c '^[^#]' || true)
    echo "  (scraped $nlines metric series from :9598)" >&2
    echo "$raw"
}

print_metrics() {
    # Shows received vs sent per component so you can see where events are being dropped.
    local raw
    raw=$(_scrape_prometheus) || return 0
    echo "$raw" | grep -E '^vector_component_(received|sent)_events_total' | awk '
        {
            val = $2 + 0
            cid = $0; sub(/.*component_id="/, "", cid); sub(/".*/, "", cid)
            if ($0 ~ /received/) rx[cid] = val
            else                 tx[cid] = val
        }
        END {
            if (length(rx) == 0 && length(tx) == 0) {
                print "  (no vector_component_received/sent_events_total series found)"
                exit
            }
            for (cid in rx) seen[cid] = 1
            for (cid in tx) seen[cid] = 1
            n = 0
            for (cid in seen) keys[++n] = cid
            for (i = 1; i < n; i++)
                for (j = i+1; j <= n; j++)
                    if (keys[i] > keys[j]) { t = keys[i]; keys[i] = keys[j]; keys[j] = t }
            for (i = 1; i <= n; i++)
                printf "  %-40s  rx=%8d  tx=%8d\n", keys[i], rx[keys[i]]+0, tx[keys[i]]+0
        }
    '
}

print_utilization_metrics() {
    # Shows per-component CPU utilization (fraction of time actively polling vs idle).
    # Sorted by utilization descending — directly answers "which component uses the most CPU?"
    local raw
    raw=$(_scrape_prometheus) || return 0
    local result
    result=$(echo "$raw" | grep 'utilization' | grep -v '^#' | \
        sed 's/.*component_id="\([^"]*\)"[^}]*} \([0-9.eE+-]*\).*/\2 \1/' | \
        sort -rn | \
        awk '{printf "  %-40s  %5.1f%%\n", $2, $1 * 100}')
    if [ -z "$result" ]; then
        echo "  (no vector_component_utilization_ratio series found)"
    else
        echo "$result"
    fi
}

print_memory_metrics() {
    # Shows per-component live memory (component_allocated_bytes gauge) and lifetime
    # alloc/dealloc totals from ALLOCATION_TRACING. Sorted by live bytes descending.
    local raw
    raw=$(_scrape_prometheus) || return 0
    echo "$raw" | grep -E '^vector_component_(allocated|deallocated)_bytes' | awk '
        {
            val = $2 + 0
            cid = $0; sub(/.*component_id="/, "", cid); sub(/".*/, "", cid)
            if      ($0 ~ /component_allocated_bytes\{/)       live[cid]    = val
            else if ($0 ~ /component_allocated_bytes_total/)   alloc[cid]   = val
            else if ($0 ~ /component_deallocated_bytes_total/) dealloc[cid] = val
        }
        END {
            if (length(live) == 0 && length(alloc) == 0) {
                print "  (no component_allocated_bytes series found — is ALLOCATION_TRACING=true?)"
                exit
            }
            for (cid in live)  seen[cid] = 1
            for (cid in alloc) seen[cid] = 1
            n = 0
            for (cid in seen) { keys[++n] = cid; lv[n] = live[cid]+0 }
            for (i = 1; i < n; i++)
                for (j = i+1; j <= n; j++)
                    if (lv[i] < lv[j]) {
                        t = lv[i]; lv[i] = lv[j]; lv[j] = t
                        tc = keys[i]; keys[i] = keys[j]; keys[j] = tc
                    }
            for (i = 1; i <= n; i++) {
                cid = keys[i]
                l = live[cid]+0; a = alloc[cid]+0; d = dealloc[cid]+0
                ls = l >= 1048576 ? sprintf("%.1f MB", l/1048576) : l >= 1024 ? sprintf("%.1f KB", l/1024) : sprintf("%d B", l)
                as = a >= 1048576 ? sprintf("%.1f MB", a/1048576) : a >= 1024 ? sprintf("%.1f KB", a/1024) : sprintf("%d B", a)
                ds = d >= 1048576 ? sprintf("%.1f MB", d/1048576) : d >= 1024 ? sprintf("%.1f KB", d/1024) : sprintf("%d B", d)
                printf "  %-40s  live=%10s  alloc=%10s  dealloc=%10s\n", cid, ls, as, ds
            }
        }
    '
}

save_and_print_sls_metrics() {
    local raw
    raw=$(_scrape_prometheus) || return 0
    echo "$raw" > "$OUTPUT/metrics.txt"
    echo "  Saved full prometheus snapshot to output/metrics.txt"
    local sls
    sls=$(echo "$raw" | grep -E '^(com_palantir_signals_sls_logs_count|com_palantir_signals_sls_logs_bytes_count)' | awk '$2+0 > 0')
    if [ -z "$sls" ]; then
        echo "  (no com_palantir_signals_sls_logs_count / com_palantir_signals_sls_logs_bytes_count series with non-zero values)"
        echo "  This means events did not reach sls-count-metric / sls-bytes-count-metric."
    else
        echo "$sls"
    fi
}

# --- Profile ---
if [ "${USE_TEST_LOG_PRODUCER:-false}" = "true" ]; then
    echo "Waiting for test-log-producer log output..."
    # The test-log-producer container (Docker Compose profile "test-log-producer")
    # redirects its stdout to /logs/sls.log which is mounted at
    # /tmp/test-log-producer-logs/sls.log in this container.
    for i in $(seq 1 30); do
        if [ -s /tmp/test-log-producer-logs/sls.log ]; then
            echo "  Log output detected"
            break
        fi
        if [ $i -eq 30 ]; then
            echo "ERROR: No log output from test-log-producer after 30s."
            echo "  Start it with: docker compose --profile test-log-producer up"
            kill $VECTOR_PID 2>/dev/null || true
            exit 1
        fi
        sleep 1
    done
    echo "Starting load generator (test-log-producer mode)..."
    $VECTOR_BIN --config /profiling/test-log-producer-generator.yaml &
else
    echo "Starting load generator (demo_logs mode)..."
    $VECTOR_BIN --config /profiling/generator.yaml &
fi
GEN_PID=$!

# Brief pause so the generator establishes its connection before perf starts
sleep 2

echo "Recording perf data for ${PROFILE_DURATION}s..."
perf record -F99 --call-graph dwarf -p $VECTOR_PID \
    -o "$OUTPUT/perf.data" \
    -- sleep "$PROFILE_DURATION"

echo ""
echo "Component CPU utilization (fraction of time actively processing):"
print_utilization_metrics

echo ""
echo "Component event counts:"
print_metrics

echo ""
echo "Component memory usage (live / lifetime alloc / lifetime dealloc):"
print_memory_metrics

echo ""
echo "SLS metrics (sourceproduct / sourcelogtype confirmation):"
save_and_print_sls_metrics

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
