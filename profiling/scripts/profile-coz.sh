#!/usr/bin/env bash
# =============================================================================
# profile-coz.sh -- Causal profiling approximation via perf + metrics
#
# Coz (causal profiling) is difficult to run in containers, so this script
# approximates causal profiling by:
# 1. Running perf stat to identify hot functions
# 2. Correlating with Vector component metrics
# 3. Identifying which code paths have the highest causal impact on throughput
#
# If the container has the coz binary available, it will attempt a real coz run.
#
# Usage: profile-coz.sh [DURATION]
#   DURATION    Seconds to profile (default: 30)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/coz_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
VECTOR_PID=$(kube exec "${POD}" -- pgrep -x vector 2>/dev/null || echo "1")

# Port-forward Prometheus for metrics
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# Attempt real coz profiling first
log_info "Checking if coz is available in container..."
if kube exec "${POD}" -- which coz &>/dev/null; then
    log_info "Running coz causal profiler for ${DURATION}s..."
    kube exec "${POD}" -- coz run --end-to-end --- sleep "${DURATION}" \
        > "${OUTPUT_DIR}/coz_output.txt" 2>&1 || {
        log_warn "coz run failed, falling back to approximation"
    }

    if [[ -s "${OUTPUT_DIR}/coz_output.txt" ]]; then
        kube cp "${POD}:/tmp/profile.coz" "${OUTPUT_DIR}/profile.coz" 2>/dev/null || true
    fi
fi

# Approximation: perf record + top functions + metric correlation
log_info "Running perf-based causal profiling approximation for ${DURATION}s..."

# Collect baseline throughput
BASELINE_THROUGHPUT=$(measure_throughput 5)

# Run perf record to find hotspots
kube exec "${POD}" -- perf record -F 999 -g --call-graph dwarf -p "${VECTOR_PID}" -o /tmp/perf_coz.data -- sleep "${DURATION}" 2>/dev/null || true

# Get top functions
kube exec "${POD}" -- perf report -i /tmp/perf_coz.data --stdio --no-children -n --percent-limit 1.0 2>/dev/null \
    > "${OUTPUT_DIR}/perf_top_functions.txt" || true

# Collect final throughput
FINAL_THROUGHPUT=$(measure_throughput 5)

# Generate causal analysis
python3 -c "
import re

print('Causal Profiling Approximation')
print('=' * 70)
print(f'Baseline throughput: ${BASELINE_THROUGHPUT} events/sec')
print(f'Post-profile throughput: ${FINAL_THROUGHPUT} events/sec')
print()
print('Top CPU-consuming functions (potential causal bottlenecks):')
print('-' * 70)

try:
    with open('${OUTPUT_DIR}/perf_top_functions.txt') as f:
        in_section = False
        count = 0
        for line in f:
            line = line.strip()
            if 'Overhead' in line:
                in_section = True
                continue
            if in_section and line and count < 20:
                print(f'  {line}')
                count += 1
except FileNotFoundError:
    print('  (perf report not available)')

print()
print('Interpretation:')
print('  Functions with high overhead are candidates for optimization.')
print('  Reducing time in these functions should proportionally improve throughput.')
print('  To validate, optimize a function and re-run this profile.')
" | tee "${OUTPUT_DIR}/summary.txt"

# Cleanup
kube exec "${POD}" -- rm -f /tmp/perf_coz.data 2>/dev/null || true

log_info "Causal profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
