#!/usr/bin/env bash
# =============================================================================
# collect-metrics.sh -- Continuous Prometheus metrics scraper to CSV
#
# Periodically queries Prometheus for Vector pipeline metrics and writes them
# to CSV files for offline analysis.
#
# Usage: collect-metrics.sh [INTERVAL] [DURATION]
#   INTERVAL    Seconds between samples (default: 5)
#   DURATION    Total seconds to collect (default: 300)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

INTERVAL="${1:-5}"
DURATION="${2:-300}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
OUTPUT_DIR="${RESULTS_DIR}/metrics_${TIMESTAMP}"

mkdir -p "${OUTPUT_DIR}"

# Port-forward to Prometheus
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

ITERATIONS=$(( DURATION / INTERVAL ))
log_info "Collecting metrics: ${ITERATIONS} samples at ${INTERVAL}s intervals (${DURATION}s total)"
log_info "Output: ${OUTPUT_DIR}/"

# Initialize CSV files
PIPELINE_CSV="${OUTPUT_DIR}/pipeline.csv"
COMPONENT_CSV="${OUTPUT_DIR}/components.csv"
RESOURCE_CSV="${OUTPUT_DIR}/resources.csv"

echo "timestamp,ds_sent,agg_received,agg_sent,loki_received" > "${PIPELINE_CSV}"
echo "timestamp,component_id,component_type,pod,events_received,events_sent,errors" > "${COMPONENT_CSV}"
echo "timestamp,pod,rss_kb,cpu_usage" > "${RESOURCE_CSV}"

for i in $(seq 1 "${ITERATIONS}"); do
    ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

    # Pipeline-level metrics
    snap="$(snapshot_pipeline 2>/dev/null || echo "0 0 0 0")"
    echo "${ts},$(echo "${snap}" | tr ' ' ',')" >> "${PIPELINE_CSV}"

    # Component-level metrics
    for metric_type in "received" "sent"; do
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=vector_component_${metric_type}_events_total" 2>/dev/null \
            | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    for r in data.get('data',{}).get('result',[]):
        m = r['metric']
        cid = m.get('component_id','')
        ctype = m.get('component_type','')
        pod = m.get('pod','')
        val = r['value'][1]
        print(f'${ts},{cid},{ctype},{pod},{val if '${metric_type}' == 'received' else ''},{val if '${metric_type}' == 'sent' else ''},')
except:
    pass
" >> "${COMPONENT_CSV}" 2>/dev/null || true
    done

    # Resource metrics via kubectl top
    kube top pods --no-headers 2>/dev/null | while read -r pod cpu mem _rest; do
        mem_kb=$(echo "${mem}" | sed 's/Mi/*1024/;s/Gi/*1048576/;s/Ki//' | bc 2>/dev/null || echo "0")
        echo "${ts},${pod},${mem_kb},${cpu}" >> "${RESOURCE_CSV}"
    done 2>/dev/null || true

    if (( i % 20 == 0 )); then
        log_info "  Sample ${i}/${ITERATIONS} ($(( i * INTERVAL ))s / ${DURATION}s)"
    fi

    sleep "${INTERVAL}"
done

# Summary
LINES_PIPELINE=$(wc -l < "${PIPELINE_CSV}")
LINES_COMPONENT=$(wc -l < "${COMPONENT_CSV}")
LINES_RESOURCE=$(wc -l < "${RESOURCE_CSV}")

log_info "Collection complete."
log_info "  Pipeline samples: $(( LINES_PIPELINE - 1 ))"
log_info "  Component samples: $(( LINES_COMPONENT - 1 ))"
log_info "  Resource samples: $(( LINES_RESOURCE - 1 ))"
log_info "Output: ${OUTPUT_DIR}/"
ls -lh "${OUTPUT_DIR}/"
