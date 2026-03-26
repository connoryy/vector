#!/usr/bin/env bash
# =============================================================================
# profile-alloc.sh -- Vector allocation tracing
#
# Enables Vector's --allocation-tracing feature and scrapes
# component_allocated_bytes metrics over time.
#
# Usage: profile-alloc.sh [DURATION] [INTERVAL]
#   DURATION    Total seconds to collect (default: 60)
#   INTERVAL    Seconds between metric samples (default: 5)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-60}"
INTERVAL="${2:-5}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/alloc_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

# Enable allocation tracing
log_info "Enabling allocation tracing on ${TARGET}..."
enable_allocation_tracing "${TARGET}"

# Wait for Vector to be healthy again
wait_vector_healthy "180s"

# Port-forward to Prometheus
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# Collect allocation metrics
CSV_FILE="${OUTPUT_DIR}/allocations.csv"
echo "timestamp,component_id,component_type,allocated_bytes" > "${CSV_FILE}"

ITERATIONS=$(( DURATION / INTERVAL ))
log_info "Collecting allocation metrics: ${ITERATIONS} samples at ${INTERVAL}s intervals..."

for i in $(seq 1 "${ITERATIONS}"); do
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Query component_allocated_bytes from Prometheus
    curl -s "${PROMETHEUS_URL}/api/v1/query?query=component_allocated_bytes" \
        | python3 -c "
import json, sys
data = json.load(sys.stdin)
for result in data.get('data', {}).get('result', []):
    metric = result['metric']
    value = result['value'][1]
    component_id = metric.get('component_id', 'unknown')
    component_type = metric.get('component_type', 'unknown')
    print(f'${ts},{component_id},{component_type},{value}')
" >> "${CSV_FILE}" 2>/dev/null || true

    if (( i % 10 == 0 )); then
        log_info "  Sample ${i}/${ITERATIONS}..."
    fi

    sleep "${INTERVAL}"
done

# Generate summary
log_info "Generating allocation summary..."
python3 -c "
import csv, sys
from collections import defaultdict

allocations = defaultdict(list)
with open('${CSV_FILE}') as f:
    reader = csv.DictReader(f)
    for row in reader:
        key = (row['component_id'], row['component_type'])
        try:
            allocations[key].append(float(row['allocated_bytes']))
        except ValueError:
            pass

print('Component Allocation Summary')
print('=' * 70)
print(f'{\"Component\":<30} {\"Type\":<15} {\"Min (MB)\":>10} {\"Max (MB)\":>10} {\"Avg (MB)\":>10}')
print('-' * 70)
for (cid, ctype), values in sorted(allocations.items()):
    mn = min(values) / 1048576
    mx = max(values) / 1048576
    avg = sum(values) / len(values) / 1048576
    print(f'{cid:<30} {ctype:<15} {mn:>10.2f} {mx:>10.2f} {avg:>10.2f}')
" > "${OUTPUT_DIR}/summary.txt" 2>/dev/null || true

cat "${OUTPUT_DIR}/summary.txt" 2>/dev/null || true

# Disable allocation tracing
log_info "Disabling allocation tracing..."
disable_allocation_tracing "${TARGET}"

log_info "Allocation profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
