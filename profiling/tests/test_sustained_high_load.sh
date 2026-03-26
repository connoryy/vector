#!/usr/bin/env bash
# test_sustained_high_load.sh -- 50 pods at 200/s for 10min, 0.01% tolerance
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "sustained_high_load"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy
for i in $(seq 1 50); do
  deploy_producer "highload-producer-${i}" 1 200
done
sleep 60  # let all 50 stabilize

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload: 10 minutes ---
sleep 600

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- assert ---
if assert_no_drops_delta "${before}" "${after}" "0.01"; then
  write_result "sustained_high_load" "pass"
  cleanup_producers
  end_test pass
else
  write_result "sustained_high_load" "fail"
  cleanup_producers
  end_test fail
fi
