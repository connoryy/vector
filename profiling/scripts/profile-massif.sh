#!/usr/bin/env bash
# =============================================================================
# profile-massif.sh -- Heap snapshots over time via /proc/PID/smaps
#
# Periodically snapshots the memory map of the Vector process to track heap
# growth, shared vs private pages, and memory fragmentation.
#
# Usage: profile-massif.sh [DURATION] [INTERVAL]
#   DURATION    Total seconds to collect (default: 60)
#   INTERVAL    Seconds between snapshots (default: 5)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-60}"
INTERVAL="${2:-5}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/massif_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "Memory snapshots for pod ${POD}: ${DURATION}s at ${INTERVAL}s intervals"

ITERATIONS=$(( DURATION / INTERVAL ))
CSV_FILE="${OUTPUT_DIR}/memory_timeline.csv"
echo "timestamp,elapsed_s,rss_kb,vm_size_kb,vm_data_kb,vm_stk_kb,shared_clean_kb,shared_dirty_kb,private_clean_kb,private_dirty_kb,swap_kb" > "${CSV_FILE}"

START_TS=$(date +%s)

for i in $(seq 0 "${ITERATIONS}"); do
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    elapsed=$(( $(date +%s) - START_TS ))

    # Read /proc/1/status for VmRSS etc.
    STATUS=$(kube exec "${POD}" -- cat /proc/1/status 2>/dev/null || echo "")
    rss=$(echo "${STATUS}" | grep VmRSS | awk '{print $2}' || echo "0")
    vm_size=$(echo "${STATUS}" | grep VmSize | awk '{print $2}' || echo "0")
    vm_data=$(echo "${STATUS}" | grep VmData | awk '{print $2}' || echo "0")
    vm_stk=$(echo "${STATUS}" | grep VmStk | awk '{print $2}' || echo "0")
    swap=$(echo "${STATUS}" | grep VmSwap | awk '{print $2}' || echo "0")

    # Read smaps_rollup for shared/private breakdown
    SMAPS=$(kube exec "${POD}" -- cat /proc/1/smaps_rollup 2>/dev/null || echo "")
    shared_clean=$(echo "${SMAPS}" | grep "Shared_Clean:" | awk '{print $2}' || echo "0")
    shared_dirty=$(echo "${SMAPS}" | grep "Shared_Dirty:" | awk '{print $2}' || echo "0")
    private_clean=$(echo "${SMAPS}" | grep "Private_Clean:" | awk '{print $2}' || echo "0")
    private_dirty=$(echo "${SMAPS}" | grep "Private_Dirty:" | awk '{print $2}' || echo "0")

    echo "${ts},${elapsed},${rss},${vm_size},${vm_data},${vm_stk},${shared_clean},${shared_dirty},${private_clean},${private_dirty},${swap}" >> "${CSV_FILE}"

    # Also save full smaps at regular intervals
    if (( i % 5 == 0 )); then
        kube exec "${POD}" -- cat /proc/1/smaps 2>/dev/null > "${OUTPUT_DIR}/smaps_${i}.txt" || true
    fi

    if (( i % 10 == 0 )); then
        log_info "  Snapshot ${i}/${ITERATIONS}: RSS=${rss}kB VmSize=${vm_size}kB"
    fi

    if [[ "${i}" -lt "${ITERATIONS}" ]]; then
        sleep "${INTERVAL}"
    fi
done

# Generate summary
python3 -c "
import csv

print('Memory Timeline Summary')
print('=' * 80)

rows = []
with open('${CSV_FILE}') as f:
    reader = csv.DictReader(f)
    for row in reader:
        rows.append(row)

if not rows:
    print('No data collected')
    exit(0)

rss_values = [int(r['rss_kb']) for r in rows]
private_dirty_values = [int(r['private_dirty_kb']) for r in rows]

print(f'Duration: {rows[-1][\"elapsed_s\"]}s ({len(rows)} samples)')
print()
print(f'{\"Metric\":<20} {\"Start (MB)\":>12} {\"End (MB)\":>10} {\"Min (MB)\":>10} {\"Max (MB)\":>10} {\"Growth\":>10}')
print('-' * 72)

def summary(label, values):
    start = values[0] / 1024
    end = values[-1] / 1024
    mn = min(values) / 1024
    mx = max(values) / 1024
    growth = ((values[-1] - values[0]) / values[0] * 100) if values[0] > 0 else 0
    print(f'{label:<20} {start:>12.1f} {end:>10.1f} {mn:>10.1f} {mx:>10.1f} {growth:>9.1f}%')

summary('RSS', rss_values)
summary('Private Dirty', private_dirty_values)
summary('VmSize', [int(r['vm_size_kb']) for r in rows])
summary('VmData', [int(r['vm_data_kb']) for r in rows])
" | tee "${OUTPUT_DIR}/summary.txt"

log_info "Memory snapshots complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
