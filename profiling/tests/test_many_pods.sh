#!/usr/bin/env bash
# test_many_pods.sh -- 200 pods at 10/s each for 5min, 0.1% tolerance
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "many_pods"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy
for i in $(seq 1 200); do
  deploy_producer "many-pod-${i}" 1 10
done
sleep 60  # let all 200 stabilize

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload: 5 minutes ---
sleep 300

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- assert ---
if assert_no_drops_delta "${before}" "${after}" "0.1"; then
  write_result "many_pods" "pass"
  cleanup_producers
  end_test pass
else
  write_result "many_pods" "fail"
  cleanup_producers
  end_test fail
fi
