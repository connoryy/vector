#!/usr/bin/env bash
# =============================================================================
# profile-cpu.sh -- CPU flamegraph via perf record + inferno
#
# Runs perf record inside the Vector pod and converts output to a flamegraph
# SVG using inferno-flamegraph (or flamegraph.pl fallback).
#
# Usage: profile-cpu.sh [DURATION] [OUTPUT_DIR]
#   DURATION    Seconds to record (default: 30)
#   OUTPUT_DIR  Directory for output files (default: results/cpu_<timestamp>)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

DURATION="${1:-30}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${2:-${RESULTS_DIR}/cpu_${TIMESTAMP}}"

mkdir -p "${OUTPUT_DIR}"

TARGET="${TARGET:-aggregator}"  # aggregator | daemonset

if [[ "${TARGET}" == "aggregator" ]]; then
    LABEL="${LABEL_AGG}"
    POD_PREFIX="vector-aggregator"
else
    LABEL="${LABEL_DS}"
    POD_PREFIX="vector-daemonset"
fi

POD=$(kube get pods -l "${LABEL}" -o jsonpath='{.items[0].metadata.name}')
log_info "CPU profiling pod ${POD} for ${DURATION}s..."

# Run perf record inside the pod
log_info "Starting perf record..."
kube exec "${POD}" -- perf record -F 99 -g --call-graph dwarf -o /tmp/perf.data -- sleep "${DURATION}"

# Generate folded stacks
log_info "Generating folded stacks..."
kube exec "${POD}" -- perf script -i /tmp/perf.data > "${OUTPUT_DIR}/perf.script"

# Copy raw perf data
kube cp "${POD}:/tmp/perf.data" "${OUTPUT_DIR}/perf.data" 2>/dev/null || true

# Generate flamegraph
log_info "Generating flamegraph..."
if command -v inferno-collapse-perf &>/dev/null && command -v inferno-flamegraph &>/dev/null; then
    inferno-collapse-perf < "${OUTPUT_DIR}/perf.script" > "${OUTPUT_DIR}/folded.txt"
    inferno-flamegraph < "${OUTPUT_DIR}/folded.txt" > "${OUTPUT_DIR}/flamegraph.svg"
elif command -v stackcollapse-perf.pl &>/dev/null && command -v flamegraph.pl &>/dev/null; then
    stackcollapse-perf.pl < "${OUTPUT_DIR}/perf.script" > "${OUTPUT_DIR}/folded.txt"
    flamegraph.pl < "${OUTPUT_DIR}/folded.txt" > "${OUTPUT_DIR}/flamegraph.svg"
else
    log_warn "Neither inferno nor flamegraph.pl found. Install with: cargo install inferno"
    log_info "Raw perf script saved to ${OUTPUT_DIR}/perf.script"
fi

# Cleanup inside pod
kube exec "${POD}" -- rm -f /tmp/perf.data 2>/dev/null || true

log_info "CPU profile complete. Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
