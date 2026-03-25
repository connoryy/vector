#!/usr/bin/env bash
# =============================================================================
# profile-syscalls.sh -- System call profiling via strace
#
# Runs strace inside the Vector pod to produce both a summary (-c) and a
# detailed trace of system calls.
#
# Usage: profile-syscalls.sh [DURATION]
#   DURATION    Seconds to trace (default: 15)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-15}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/syscalls_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
VECTOR_PID=$(kube exec "${POD}" -- pgrep -x vector 2>/dev/null || echo "1")
log_info "Syscall profiling pod ${POD} (PID ${VECTOR_PID}) for ${DURATION}s..."

# Summary mode (syscall counts and time)
log_info "Running strace summary..."
kube exec "${POD}" -- timeout "${DURATION}" strace -c -p "${VECTOR_PID}" 2>&1 \
    > "${OUTPUT_DIR}/strace_summary.txt" || true

log_info "Strace summary:"
cat "${OUTPUT_DIR}/strace_summary.txt"

# Detailed trace (limited duration, timing info)
log_info "Running detailed strace trace..."
kube exec "${POD}" -- timeout "${DURATION}" strace -T -tt -f -p "${VECTOR_PID}" \
    -e trace=network,write,read,epoll_wait,futex 2>&1 \
    > "${OUTPUT_DIR}/strace_detail.txt" || true

# Generate per-syscall statistics
log_info "Generating per-syscall breakdown..."
python3 -c "
import re
from collections import defaultdict

times = defaultdict(list)
with open('${OUTPUT_DIR}/strace_detail.txt') as f:
    for line in f:
        m = re.search(r'(\w+)\(.*\)\s+=.*<([\d.]+)>', line)
        if m:
            syscall = m.group(1)
            duration = float(m.group(2))
            times[syscall].append(duration)

print('Syscall Latency Breakdown')
print('=' * 70)
print(f'{\"Syscall\":<20} {\"Count\":>8} {\"Total (ms)\":>12} {\"Avg (us)\":>12} {\"Max (us)\":>12}')
print('-' * 70)
for sc in sorted(times, key=lambda x: sum(times[x]), reverse=True):
    vals = times[sc]
    total_ms = sum(vals) * 1000
    avg_us = (sum(vals) / len(vals)) * 1_000_000
    max_us = max(vals) * 1_000_000
    print(f'{sc:<20} {len(vals):>8} {total_ms:>12.2f} {avg_us:>12.1f} {max_us:>12.1f}')
" > "${OUTPUT_DIR}/syscall_breakdown.txt" 2>/dev/null || true

cat "${OUTPUT_DIR}/syscall_breakdown.txt" 2>/dev/null || true

log_info "Syscall profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
