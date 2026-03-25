#!/usr/bin/env bash
# =============================================================================
# profile-heap.sh -- jemalloc heap profiling
#
# Triggers jemalloc heap dumps from within the Vector pod. If MALLOC_CONF
# does not include prof:true, patches the pod environment to enable it.
#
# Usage: profile-heap.sh [NUM_DUMPS] [INTERVAL_SECONDS]
#   NUM_DUMPS   Number of heap dumps to take (default: 3)
#   INTERVAL    Seconds between dumps (default: 30)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

NUM_DUMPS="${1:-3}"
INTERVAL="${2:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/heap_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
    WORKLOAD_TYPE="statefulset"
    WORKLOAD_NAME="vector-aggregator"
else
    LABEL="${LABEL_DS}"
    WORKLOAD_TYPE="daemonset"
    WORKLOAD_NAME="vector-daemonset"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "Heap profiling pod ${POD}: ${NUM_DUMPS} dumps at ${INTERVAL}s intervals"

# Check if jemalloc profiling is enabled
CURRENT_MALLOC_CONF=$(kube exec "${POD}" -- printenv MALLOC_CONF 2>/dev/null || echo "")
log_info "Current MALLOC_CONF: ${CURRENT_MALLOC_CONF}"

if [[ "${CURRENT_MALLOC_CONF}" != *"prof:true"* ]]; then
    log_warn "jemalloc profiling not enabled. Patching ${WORKLOAD_TYPE}/${WORKLOAD_NAME}..."

    NEW_MALLOC_CONF="${CURRENT_MALLOC_CONF:+${CURRENT_MALLOC_CONF},}prof:true,prof_active:true,lg_prof_interval:30,prof_prefix:/tmp/jeprof"

    kube patch "${WORKLOAD_TYPE}" "${WORKLOAD_NAME}" --type=json \
        -p "[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/env/-\",\"value\":{\"name\":\"MALLOC_CONF\",\"value\":\"${NEW_MALLOC_CONF}\"}}]" \
        2>/dev/null || \
    kube set env "${WORKLOAD_TYPE}/${WORKLOAD_NAME}" "MALLOC_CONF=${NEW_MALLOC_CONF}"

    log_info "Waiting for pod restart..."
    kube rollout status "${WORKLOAD_TYPE}/${WORKLOAD_NAME}" --timeout=180s

    # Re-fetch pod name after restart
    sleep 5
    POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
    log_info "New pod: ${POD}"
fi

# Take heap dumps
for i in $(seq 1 "${NUM_DUMPS}"); do
    log_info "Taking heap dump ${i}/${NUM_DUMPS}..."

    # Trigger a heap dump via jemalloc mallctl
    kube exec "${POD}" -- bash -c '
        VECTOR_PID=$(pgrep -x vector || echo 1)
        kill -USR2 ${VECTOR_PID} 2>/dev/null || true
        # Also try writing to jemalloc prof.dump mallctl via gdb
        gdb -batch -ex "call mallctl(\"prof.dump\", 0, 0, 0, 0)" -p ${VECTOR_PID} 2>/dev/null || true
    ' 2>/dev/null || log_warn "Heap dump trigger may have failed"

    # Copy any heap profiles that were created
    kube exec "${POD}" -- bash -c 'ls /tmp/jeprof.* 2>/dev/null || ls /tmp/*.heap 2>/dev/null || echo "no dumps yet"' || true

    # Also collect /proc memory info
    kube exec "${POD}" -- cat /proc/1/status 2>/dev/null | grep -E "^(VmRSS|VmSize|VmPeak|VmSwap|VmData)" > "${OUTPUT_DIR}/proc_status_${i}.txt" || true
    kube exec "${POD}" -- cat /proc/1/smaps_rollup 2>/dev/null > "${OUTPUT_DIR}/smaps_rollup_${i}.txt" || true

    log_info "Dump ${i} taken. RSS: $(grep VmRSS "${OUTPUT_DIR}/proc_status_${i}.txt" 2>/dev/null | awk '{print $2, $3}' || echo 'unknown')"

    if [[ "${i}" -lt "${NUM_DUMPS}" ]]; then
        sleep "${INTERVAL}"
    fi
done

# Copy heap dump files from the pod
log_info "Copying heap dumps from pod..."
kube exec "${POD}" -- bash -c 'ls /tmp/jeprof.* /tmp/*.heap 2>/dev/null' | while read -r f; do
    local_name="$(basename "$f")"
    kube cp "${POD}:${f}" "${OUTPUT_DIR}/${local_name}" 2>/dev/null || true
done

log_info "Heap profiling complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
