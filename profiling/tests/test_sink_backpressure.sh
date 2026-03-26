#!/usr/bin/env bash
# test_sink_backpressure.sh -- inject 500ms latency, measure drop_newest behavior
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "sink_backpressure"
trap 'cleanup_producers; reset_sink_config; end_test fail' ERR

# --- setup ---
wait_vector_healthy
deploy_producer "bp-producer" 5 500  # high volume to trigger backpressure
sleep 20

# --- inject 500ms latency ---
inject_sink_latency 500
sleep 10  # let latency take effect

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload under backpressure: 2 minutes ---
sleep 120

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- measure: compute drop rate (expect some drops with drop_newest) ---
drop_info="$(python3 -c "
b = [float(x) for x in '${before}'.split()]
a = [float(x) for x in '${after}'.split()]
sent = a[0] - b[0]
recv = a[3] - b[3]
drop_pct = ((sent - recv) / sent * 100) if sent > 0 else 0
print(f'{drop_pct:.2f}')
")"
log_info "Drop rate under backpressure: ${drop_info}%"

# --- cleanup ---
reset_sink_config
cleanup_producers

# Pass if pipeline did not crash and events flowed (drops are expected)
delta_loki="$(python3 -c "
a = [float(x) for x in '${after}'.split()]
b = [float(x) for x in '${before}'.split()]
print(a[3] - b[3])
")"

if python3 -c "exit(0 if float('${delta_loki}') > 0 else 1)"; then
  write_result "sink_backpressure" "pass" "drop_rate_pct" "${drop_info}"
  end_test pass
else
  write_result "sink_backpressure" "fail"
  end_test fail
fi
