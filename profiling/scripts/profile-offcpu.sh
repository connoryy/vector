#!/usr/bin/env bash
# =============================================================================
# profile-offcpu.sh -- Off-CPU flamegraph via bpftrace
#
# Records off-CPU time (time spent sleeping/blocked) and produces a flamegraph.
#
# Usage: profile-offcpu.sh [DURATION] [OUTPUT_DIR]
#   DURATION    Seconds to record (default: 30)
#   OUTPUT_DIR  Directory for output files (default: results/offcpu_<timestamp>)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${2:-${RESULTS_DIR}/offcpu_${TIMESTAMP}}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
else
    LABEL="${LABEL_DS}"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "Off-CPU profiling pod ${POD} for ${DURATION}s..."

# Get the PID of the vector process inside the container
VECTOR_PID=$(kube exec "${POD}" -- pgrep -x vector || kube exec "${POD}" -- cat /proc/1/status | grep '^Pid:' | awk '{print $2}')
log_info "Vector PID: ${VECTOR_PID}"

# bpftrace one-liner for off-CPU analysis
BPFTRACE_SCRIPT="$(cat <<'BTEOF'
kprobe:finish_task_switch
{
    $prev = (struct task_struct *)arg0;
    if ($prev->tgid == VECTOR_PID) {
        @start[$prev->pid] = nsecs;
    }

    if (@start[tid]) {
        $delta = nsecs - @start[tid];
        @offcpu[kstack, comm] = sum($delta);
        delete(@start[tid]);
    }
}

interval:s:DURATION
{
    exit();
}

END
{
    print(@offcpu);
    clear(@offcpu);
    clear(@start);
}
BTEOF
)"

# Substitute PID and duration
BPFTRACE_SCRIPT="${BPFTRACE_SCRIPT//VECTOR_PID/${VECTOR_PID}}"
BPFTRACE_SCRIPT="${BPFTRACE_SCRIPT//DURATION/${DURATION}}"

log_info "Running bpftrace off-CPU analysis..."
kube exec "${POD}" -- bash -c "cat > /tmp/offcpu.bt <<'EOF'
${BPFTRACE_SCRIPT}
EOF
bpftrace /tmp/offcpu.bt" > "${OUTPUT_DIR}/offcpu_raw.txt" 2>&1 || {
    log_warn "bpftrace failed (may require privileged container). Falling back to perf sched..."

    # Fallback: use perf sched
    kube exec "${POD}" -- perf sched record -- sleep "${DURATION}" 2>/dev/null || true
    kube exec "${POD}" -- perf sched latency -s max 2>/dev/null > "${OUTPUT_DIR}/sched_latency.txt" || true
    log_info "Fallback perf sched output saved to ${OUTPUT_DIR}/sched_latency.txt"
}

# Try to generate flamegraph from raw bpftrace output
if [[ -s "${OUTPUT_DIR}/offcpu_raw.txt" ]]; then
    if command -v inferno-flamegraph &>/dev/null; then
        # Convert bpftrace output to folded format
        python3 -c "
import re, sys
stacks = {}
current_stack = []
current_count = 0
for line in open('${OUTPUT_DIR}/offcpu_raw.txt'):
    line = line.strip()
    if line.startswith('@offcpu['):
        pass
    elif line.startswith(']:'):
        m = re.search(r']:\s+(\d+)', line)
        if m and current_stack:
            key = ';'.join(reversed(current_stack))
            stacks[key] = stacks.get(key, 0) + int(m.group(1))
        current_stack = []
    elif line:
        current_stack.append(line.split('+')[0].strip())

for stack, count in sorted(stacks.items()):
    print(f'{stack} {count}')
" > "${OUTPUT_DIR}/folded.txt" 2>/dev/null || true

        if [[ -s "${OUTPUT_DIR}/folded.txt" ]]; then
            inferno-flamegraph --title "Off-CPU Flamegraph" < "${OUTPUT_DIR}/folded.txt" > "${OUTPUT_DIR}/offcpu_flamegraph.svg"
            log_info "Off-CPU flamegraph: ${OUTPUT_DIR}/offcpu_flamegraph.svg"
        fi
    fi
fi

# Cleanup
kube exec "${POD}" -- rm -f /tmp/offcpu.bt 2>/dev/null || true

log_info "Off-CPU profile complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
