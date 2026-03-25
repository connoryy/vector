#!/usr/bin/env bash
# =============================================================================
# profile-throughput.sh -- Throughput measurement across the pipeline
#
# Configures the test-log-producer to a specific rate, then measures actual
# events/sec at each pipeline stage (DS ingress, DS egress, AGG ingress,
# AGG egress, Loki receipt).
#
# Usage: profile-throughput.sh [RATE] [PODS] [DURATION]
#   RATE        Target events/sec per pod (default: 1000)
#   PODS        Number of producer pods (default: 3)
#   DURATION    Measurement window in seconds (default: 60)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

RATE="${1:-1000}"
PODS="${2:-3}"
DURATION="${3:-60}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/throughput_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

# Port-forward to Prometheus
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# Configure producer
log_info "Setting producer rate=${RATE} with ${PODS} pods..."
configure_producer "${RATE}"
scale_producer "${PODS}"

# Wait for stabilization
log_info "Waiting 15s for pipeline to stabilize..."
sleep 15

# Collect baseline
log_info "Collecting baseline metrics..."
BASELINE=$(collect_pipeline_counts)
BASELINE_TS=$(date +%s)

# Wait for measurement window
log_info "Measuring throughput over ${DURATION}s..."
sleep "${DURATION}"

# Collect final metrics
log_info "Collecting final metrics..."
FINAL=$(collect_pipeline_counts)
FINAL_TS=$(date +%s)

ELAPSED=$(( FINAL_TS - BASELINE_TS ))

# Calculate throughput
python3 -c "
import json

baseline = json.loads('''${BASELINE}''')
final = json.loads('''${FINAL}''')
elapsed = ${ELAPSED}
target_rate = ${RATE} * ${PODS}

stages = {
    'DS Ingress':  (float(final['ds_events_in'])  - float(baseline['ds_events_in'])),
    'DS Egress':   (float(final['ds_events_out']) - float(baseline['ds_events_out'])),
    'AGG Ingress': (float(final['agg_events_in']) - float(baseline['agg_events_in'])),
    'AGG Egress':  (float(final['agg_events_out']) - float(baseline['agg_events_out'])),
    'Loki':        (float(final['loki_events'])    - float(baseline['loki_events'])),
}

print('Throughput Results')
print('=' * 70)
print(f'Target rate: {target_rate} events/sec ({${RATE}}/pod x {${PODS}} pods)')
print(f'Measurement window: {elapsed}s')
print()
print(f'{\"Stage\":<15} {\"Total Events\":>14} {\"Events/sec\":>12} {\"% of Target\":>12}')
print('-' * 55)
for stage, total in stages.items():
    eps = total / elapsed if elapsed > 0 else 0
    pct = (eps / target_rate * 100) if target_rate > 0 else 0
    print(f'{stage:<15} {total:>14.0f} {eps:>12.1f} {pct:>11.1f}%')

# Write JSON result
result = {
    'target_rate': target_rate,
    'duration': elapsed,
    'stages': {k: {'total': v, 'events_per_sec': v/elapsed if elapsed > 0 else 0} for k, v in stages.items()},
}
import json as j
with open('${OUTPUT_DIR}/throughput.json', 'w') as f:
    j.dump(result, f, indent=2)
" | tee "${OUTPUT_DIR}/summary.txt"

log_info "Throughput profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
