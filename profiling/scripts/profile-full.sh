#!/usr/bin/env bash
# =============================================================================
# profile-full.sh -- Run ALL profiling tools and produce a consolidated report
#
# Collects: perf stat, perf record + flamegraph, perf report, strace, smaps,
# vector metrics, utilization, kubectl top.
#
# Output: results/full_profile_<timestamp>/
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/full_profile_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
VECTOR_PID=$(kube exec "${POD}" -- pgrep -x vector 2>/dev/null || echo "1")

log_info "Full profile of pod ${POD} (PID ${VECTOR_PID}) for ${DURATION}s"
log_info "Output directory: ${OUTPUT_DIR}"

# Port-forward Prometheus
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# ---------------------------------------------------------------------------
# 1. kubectl top
# ---------------------------------------------------------------------------
log_info "[1/8] Collecting kubectl top..."
kube top pods -l "${LABEL}" 2>/dev/null > "${OUTPUT_DIR}/kubectl_top.txt" || true
kube top pods --namespace=profiling 2>/dev/null >> "${OUTPUT_DIR}/kubectl_top.txt" || true

# ---------------------------------------------------------------------------
# 2. perf stat (hardware counters)
# ---------------------------------------------------------------------------
log_info "[2/8] Running perf stat (${DURATION}s)..."
kube exec "${POD}" -- perf stat -e "cycles,instructions,cache-misses,cache-references,branch-misses,branches" \
    -p "${VECTOR_PID}" -- sleep "${DURATION}" \
    2> "${OUTPUT_DIR}/perf_stat.txt" || log_warn "perf stat failed"

# ---------------------------------------------------------------------------
# 3. perf record + flamegraph
# ---------------------------------------------------------------------------
log_info "[3/8] Running perf record (${DURATION}s)..."
kube exec "${POD}" -- perf record -F 99 -g --call-graph dwarf -p "${VECTOR_PID}" \
    -o /tmp/perf_full.data -- sleep "${DURATION}" 2>/dev/null || log_warn "perf record failed"

kube exec "${POD}" -- perf script -i /tmp/perf_full.data 2>/dev/null > "${OUTPUT_DIR}/perf.script" || true

if command -v inferno-collapse-perf &>/dev/null && command -v inferno-flamegraph &>/dev/null; then
    inferno-collapse-perf < "${OUTPUT_DIR}/perf.script" 2>/dev/null > "${OUTPUT_DIR}/folded.txt" || true
    inferno-flamegraph < "${OUTPUT_DIR}/folded.txt" 2>/dev/null > "${OUTPUT_DIR}/flamegraph.svg" || true
fi

# ---------------------------------------------------------------------------
# 4. perf report
# ---------------------------------------------------------------------------
log_info "[4/8] Generating perf report..."
kube exec "${POD}" -- perf report -i /tmp/perf_full.data --stdio --no-children -n --percent-limit 0.5 \
    2>/dev/null > "${OUTPUT_DIR}/perf_report.txt" || true
kube exec "${POD}" -- rm -f /tmp/perf_full.data 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. strace summary
# ---------------------------------------------------------------------------
log_info "[5/8] Running strace summary (15s)..."
kube exec "${POD}" -- timeout 15 strace -c -p "${VECTOR_PID}" \
    2>&1 > "${OUTPUT_DIR}/strace_summary.txt" || true

# ---------------------------------------------------------------------------
# 6. smaps snapshot
# ---------------------------------------------------------------------------
log_info "[6/8] Collecting memory maps..."
kube exec "${POD}" -- cat /proc/1/status 2>/dev/null > "${OUTPUT_DIR}/proc_status.txt" || true
kube exec "${POD}" -- cat /proc/1/smaps_rollup 2>/dev/null > "${OUTPUT_DIR}/smaps_rollup.txt" || true
kube exec "${POD}" -- cat /proc/1/smaps 2>/dev/null > "${OUTPUT_DIR}/smaps_full.txt" || true

# ---------------------------------------------------------------------------
# 7. Vector metrics snapshot
# ---------------------------------------------------------------------------
log_info "[7/8] Collecting Vector metrics..."

# Collect all component metrics
for metric in \
    "vector_component_received_events_total" \
    "vector_component_sent_events_total" \
    "vector_component_errors_total" \
    "vector_buffer_events" \
    "vector_buffer_byte_size" \
    "vector_utilization"; do
    result=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=${metric}" 2>/dev/null || echo "{}")
    echo "=== ${metric} ===" >> "${OUTPUT_DIR}/vector_metrics.txt"
    echo "${result}" | python3 -c "
import json,sys
try:
    data = json.load(sys.stdin)
    for r in data.get('data',{}).get('result',[]):
        m = r['metric']
        v = r['value'][1]
        labels = ', '.join(f'{k}={v}' for k,v in sorted(m.items()) if k != '__name__')
        print(f'  {labels}: {v}')
except:
    print('  (no data)')
" >> "${OUTPUT_DIR}/vector_metrics.txt" 2>/dev/null
done

# ---------------------------------------------------------------------------
# 8. Utilization and resource usage
# ---------------------------------------------------------------------------
log_info "[8/8] Collecting utilization data..."
kube exec "${POD}" -- cat /proc/1/stat 2>/dev/null > "${OUTPUT_DIR}/proc_stat.txt" || true
kube exec "${POD}" -- cat /proc/loadavg 2>/dev/null > "${OUTPUT_DIR}/loadavg.txt" || true

# Also grab vector internal metrics directly from the pod
kube exec "${POD}" -- curl -sf http://localhost:9598/metrics 2>/dev/null \
    > "${OUTPUT_DIR}/vector_raw_metrics.txt" || true

# ---------------------------------------------------------------------------
# Generate consolidated summary
# ---------------------------------------------------------------------------
log_info "Generating consolidated summary..."

cat > "${OUTPUT_DIR}/summary.txt" <<SUMMARY
===============================================================================
FULL PROFILE SUMMARY
Pod: ${POD}  |  PID: ${VECTOR_PID}  |  Duration: ${DURATION}s
Timestamp: ${TIMESTAMP}
===============================================================================

--- kubectl top ---
$(cat "${OUTPUT_DIR}/kubectl_top.txt" 2>/dev/null || echo "(unavailable)")

--- perf stat ---
$(cat "${OUTPUT_DIR}/perf_stat.txt" 2>/dev/null || echo "(unavailable)")

--- Strace Summary ---
$(cat "${OUTPUT_DIR}/strace_summary.txt" 2>/dev/null || echo "(unavailable)")

--- Memory (/proc/1/status) ---
$(grep -E "^(VmRSS|VmSize|VmPeak|VmData|VmStk|VmSwap)" "${OUTPUT_DIR}/proc_status.txt" 2>/dev/null || echo "(unavailable)")

--- smaps rollup ---
$(cat "${OUTPUT_DIR}/smaps_rollup.txt" 2>/dev/null || echo "(unavailable)")

--- Vector Component Metrics ---
$(cat "${OUTPUT_DIR}/vector_metrics.txt" 2>/dev/null || echo "(unavailable)")

--- Files Generated ---
$(ls -lh "${OUTPUT_DIR}/" 2>/dev/null)
===============================================================================
SUMMARY

cat "${OUTPUT_DIR}/summary.txt"

log_info "Full profile complete. Output: ${OUTPUT_DIR}/"
