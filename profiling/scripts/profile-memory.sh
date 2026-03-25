#!/usr/bin/env bash
# =============================================================================
# profile-memory.sh -- Memory pressure ramp test
#
# Gradually increases the log production rate while monitoring memory usage,
# testing Vector's behavior under increasing memory pressure.
#
# Usage: profile-memory.sh [MEMORY_LIMIT] [RAMP_STEPS] [MAX_RATE]
#   MEMORY_LIMIT    Pod memory limit (default: 1Gi)
#   RAMP_STEPS      Number of rate increase steps (default: 5)
#   MAX_RATE        Maximum events/sec at final step (default: 10000)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

MEMORY_LIMIT="${1:-1Gi}"
RAMP_STEPS="${2:-5}"
MAX_RATE="${3:-10000}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/memory_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

# Port-forward to Prometheus
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# Optionally set memory limit on aggregator
log_info "Setting memory limit to ${MEMORY_LIMIT} on vector-aggregator..."
kube patch statefulset vector-aggregator --type=json \
    -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/resources/limits/memory\",\"value\":\"${MEMORY_LIMIT}\"}]" \
    2>/dev/null || log_warn "Could not patch memory limit"
kube rollout status statefulset/vector-aggregator --timeout=180s 2>/dev/null || true
wait_vector_healthy "180s"

STEP_RATE=$(( MAX_RATE / RAMP_STEPS ))
CSV_FILE="${OUTPUT_DIR}/memory_ramp.csv"
echo "step,rate,rss_kb,heap_kb,events_in,events_out,oom_kills" > "${CSV_FILE}"

STEP_DURATION=30  # seconds per step

for step in $(seq 1 "${RAMP_STEPS}"); do
    current_rate=$(( STEP_RATE * step ))
    log_info "Step ${step}/${RAMP_STEPS}: rate=${current_rate} events/sec"

    configure_producer "${current_rate}"
    sleep "${STEP_DURATION}"

    # Collect memory stats
    AGG_POD=$(kube get pods -l "${LABEL_AGG}" -o jsonpath='{.items[0].metadata.name}')

    rss=$(kube exec "${AGG_POD}" -- cat /proc/1/status 2>/dev/null | grep VmRSS | awk '{print $2}' || echo "0")
    heap=$(kube exec "${AGG_POD}" -- cat /proc/1/status 2>/dev/null | grep VmData | awk '{print $2}' || echo "0")
    events_in=$(get_component_metric "vector_component_received_events_total" "pod=~\"vector-aggregator.*\"" 2>/dev/null || echo "0")
    events_out=$(get_component_metric "vector_component_sent_events_total" "pod=~\"vector-aggregator.*\"" 2>/dev/null || echo "0")

    # Check for OOM kills
    oom_kills=$(kube get pods -l "${LABEL_AGG}" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")

    echo "${step},${current_rate},${rss},${heap},${events_in},${events_out},${oom_kills}" >> "${CSV_FILE}"
    log_info "  RSS=${rss}kB heap=${heap}kB events_in=${events_in} events_out=${events_out} restarts=${oom_kills}"

    # Save smaps snapshot
    kube exec "${AGG_POD}" -- cat /proc/1/smaps_rollup 2>/dev/null > "${OUTPUT_DIR}/smaps_step${step}.txt" || true
done

# Reset producer
log_info "Resetting producer rate..."
configure_producer "100"

# Generate summary
python3 -c "
import csv
print('Memory Pressure Ramp Summary')
print('=' * 80)
print(f'{\"Step\":>4} {\"Rate\":>8} {\"RSS (MB)\":>10} {\"Heap (MB)\":>10} {\"Events In\":>12} {\"Events Out\":>12} {\"OOM\":>4}')
print('-' * 80)
with open('${CSV_FILE}') as f:
    reader = csv.DictReader(f)
    for row in reader:
        rss_mb = int(row['rss_kb']) / 1024
        heap_mb = int(row['heap_kb']) / 1024
        print(f'{row[\"step\"]:>4} {row[\"rate\"]:>8} {rss_mb:>10.1f} {heap_mb:>10.1f} {row[\"events_in\"]:>12} {row[\"events_out\"]:>12} {row[\"oom_kills\"]:>4}')
" > "${OUTPUT_DIR}/summary.txt" 2>/dev/null || true

cat "${OUTPUT_DIR}/summary.txt" 2>/dev/null || true

log_info "Memory pressure test complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
