#!/usr/bin/env bash
# test_steady_state_no_drops.sh -- 10 pods at 100/s for 5min, 0% drop tolerance
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "steady_state_no_drops"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy
for i in $(seq 1 10); do
  deploy_producer "steady-producer-${i}" 1 100
done
sleep 30  # let producers stabilize

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload: 5 minutes ---
sleep 300

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- assert ---
if assert_no_drops_delta "${before}" "${after}" "0"; then
  write_result "steady_state_no_drops" "pass"
  cleanup_producers
  end_test pass
else
  write_result "steady_state_no_drops" "fail"
  cleanup_producers
  end_test fail
fi
