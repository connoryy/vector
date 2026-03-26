#!/usr/bin/env bash
# =============================================================================
# profile-cachegrind.sh -- Cache miss profiling via perf stat hardware counters
#
# Uses perf stat to collect CPU cache miss rates and other hardware performance
# counters for the Vector process.
#
# Usage: profile-cachegrind.sh [DURATION]
#   DURATION    Seconds to collect (default: 30)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/cachegrind_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
VECTOR_PID=$(kube exec "${POD}" -- pgrep -x vector 2>/dev/null || echo "1")
log_info "Cache profiling pod ${POD} (PID ${VECTOR_PID}) for ${DURATION}s..."

# Collect hardware counters
EVENTS="cache-misses,cache-references,L1-dcache-load-misses,L1-dcache-loads,L1-icache-load-misses,LLC-load-misses,LLC-loads,LLC-store-misses,LLC-stores,dTLB-load-misses,dTLB-loads,iTLB-load-misses,iTLB-loads,branch-misses,branches,instructions,cycles"

log_info "Running perf stat with hardware counters..."
kube exec "${POD}" -- perf stat -e "${EVENTS}" -p "${VECTOR_PID}" -- sleep "${DURATION}" \
    2> "${OUTPUT_DIR}/perf_stat.txt" || {
    # Some counters may not be available in all environments; retry with a subset
    log_warn "Some hardware counters not available, retrying with basic set..."
    kube exec "${POD}" -- perf stat -e "cache-misses,cache-references,instructions,cycles,branch-misses,branches" \
        -p "${VECTOR_PID}" -- sleep "${DURATION}" \
        2> "${OUTPUT_DIR}/perf_stat.txt" || true
}

log_info "perf stat results:"
cat "${OUTPUT_DIR}/perf_stat.txt"

# Generate summary with cache miss ratios
python3 -c "
import re

values = {}
with open('${OUTPUT_DIR}/perf_stat.txt') as f:
    for line in f:
        m = re.match(r'\s*([\d,]+)\s+([\w-]+)', line.strip())
        if m:
            count = int(m.group(1).replace(',', ''))
            name = m.group(2)
            values[name] = count

print()
print('Cache Performance Summary')
print('=' * 50)

def ratio(num_key, den_key, label):
    if num_key in values and den_key in values and values[den_key] > 0:
        pct = values[num_key] / values[den_key] * 100
        print(f'  {label}: {pct:.2f}% ({values[num_key]:,} / {values[den_key]:,})')

ratio('cache-misses', 'cache-references', 'Overall cache miss rate')
ratio('L1-dcache-load-misses', 'L1-dcache-loads', 'L1 data cache miss rate')
ratio('L1-icache-load-misses', 'L1-dcache-loads', 'L1 instruction cache miss rate')
ratio('LLC-load-misses', 'LLC-loads', 'LLC load miss rate')
ratio('LLC-store-misses', 'LLC-stores', 'LLC store miss rate')
ratio('dTLB-load-misses', 'dTLB-loads', 'dTLB miss rate')
ratio('iTLB-load-misses', 'iTLB-loads', 'iTLB miss rate')
ratio('branch-misses', 'branches', 'Branch misprediction rate')

if 'instructions' in values and 'cycles' in values and values['cycles'] > 0:
    ipc = values['instructions'] / values['cycles']
    print(f'  IPC (instructions per cycle): {ipc:.2f}')

print()
print('Guidelines:')
print('  Cache miss rate > 5%: Consider data layout optimization')
print('  Branch mispredict > 2%: Consider branch-free algorithms')
print('  IPC < 1.0: Memory-bound workload')
print('  IPC > 2.0: Compute-efficient workload')
" | tee "${OUTPUT_DIR}/summary.txt"

log_info "Cache profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
