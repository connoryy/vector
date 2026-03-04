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
# The binary must be built with the component-probes feature.
# A stamp file records the flags used; we only rebuild when those change or the
# binary is missing. This avoids a full rebuild on every profiling run.
PROFILING_FLAGS="component-probes,frame-pointers"
STAMP_FILE="${VECTOR_BIN}.profiling-stamp"

if [ ! -f "$VECTOR_BIN" ] || [ ! -f "$STAMP_FILE" ] || [ "$(cat "$STAMP_FILE")" != "$PROFILING_FLAGS" ]; then
    echo "Building vector with component-probes feature (this takes a while)..."
    cd /vector
    RUSTFLAGS="-C force-frame-pointers=yes" cargo build --release --features component-probes 2>&1
    echo "$PROFILING_FLAGS" > "$STAMP_FILE"
    echo "  Build complete"
else
    echo "Using existing binary at $VECTOR_BIN (built with profiling flags)"
fi

# --- Start bpftrace BEFORE Vector ---
# bpftrace must start first so it catches vector_register_component uprobes
# during Vector startup. These fire once per component and provide the
# ASLR-resolved address of VECTOR_COMPONENT_LABELS needed by the profile probe.
mkdir -p /vector-data-dir /tmp/vector-gen-data "$OUTPUT"

echo "Recording perf + bpftrace data for ${PROFILE_DURATION}s..."

# tracefs is required for uprobes but isn't auto-mounted in Docker Desktop.
mount -t tracefs tracefs /sys/kernel/tracing 2>/dev/null || true

# Substitute the actual binary path into the bpftrace script.
sed "s|VECTOR_BINARY|${VECTOR_BIN}|g" \
    /profiling/label-profile.bt > /tmp/label-profile-resolved.bt

echo "Starting bpftrace component sampler..."
bpftrace /tmp/label-profile-resolved.bt \
    > "$OUTPUT/bpftrace-samples.txt" 2>&1 &
BPFTRACE_PID=$!

# Give bpftrace time to attach uprobes to the binary on disk.
sleep 3
if ! kill -0 "$BPFTRACE_PID" 2>/dev/null; then
    echo "  WARNING: bpftrace exited early — labeled flamegraph will be skipped"
    echo "  bpftrace output:"
    head -10 "$OUTPUT/bpftrace-samples.txt" | sed 's/^/    /'
    unset BPFTRACE_PID
fi

# --- Start aggregator ---
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

# Print sanity check for bpftrace output (should have captured register uprobes).
if [ -n "${BPFTRACE_PID:-}" ]; then
    echo "  [bpftrace sanity] first lines of bpftrace-samples.txt:"
    head -5 "$OUTPUT/bpftrace-samples.txt" | sed 's/^/    /'
fi

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

perf record -F99 --call-graph fp -p $VECTOR_PID \
    -o "$OUTPUT/perf.data" \
    -- sleep "$PROFILE_DURATION"

# Signal bpftrace to flush its maps and exit, then wait for it.
if [ -n "${BPFTRACE_PID:-}" ]; then
    kill -INT $BPFTRACE_PID 2>/dev/null || true
    wait $BPFTRACE_PID 2>/dev/null || true
fi


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

# --- Generate flamegraphs ---
echo "Generating flamegraphs..."
cd "$OUTPUT"

# Suffix output filenames so profile and profile-realistic don't overwrite each other.
PROFILE_SUFFIX=""
[ "${USE_TEST_LOG_PRODUCER:-false}" = "true" ] && PROFILE_SUFFIX="-realistic"

# Run perf script once; reuse the output for both the unlabeled and labeled
# flamegraph passes.
perf script -i perf.data > perf-script.txt

# Unlabeled flamegraph (unchanged pipeline — perf → inferno)
inferno-collapse-perf < perf-script.txt > stacks.folded
inferno-flamegraph stacks.folded > flamegraph${PROFILE_SUFFIX}.svg

# Labeled flamegraph (bpftrace samples + perf stacks → timestamp join → inferno)
if [ -s bpftrace-samples.txt ]; then
    python3 /profiling/scripts/collapse-labeled.py \
        bpftrace-samples.txt perf-script.txt \
        > stacks-labeled.folded
    if [ -s stacks-labeled.folded ]; then
        inferno-flamegraph stacks-labeled.folded > flamegraph-labeled${PROFILE_SUFFIX}.svg
        echo "  Labeled flamegraph: profiling/output/flamegraph-labeled${PROFILE_SUFFIX}.svg"
    else
        echo "  WARNING: labeled stacks empty — check bpftrace-samples.txt for errors"
    fi
else
    echo "  WARNING: bpftrace-samples.txt is empty — check bpftrace errors in output"
fi

echo ""
echo "=== Done ==="
echo "Flamegraph:         profiling/output/flamegraph${PROFILE_SUFFIX}.svg"
echo "Labeled flamegraph: profiling/output/flamegraph-labeled${PROFILE_SUFFIX}.svg"
echo "Raw stacks:         profiling/output/stacks.folded"
echo "bpftrace output:    profiling/output/bpftrace-samples.txt"
