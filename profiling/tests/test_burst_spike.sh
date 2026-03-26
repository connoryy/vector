#!/usr/bin/env bash
# test_burst_spike.sh -- 1 pod at 40000/s for 2s burst, drain 30s, 0.1% tolerance
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "burst_spike"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload: burst 40k/s for ~2s via high-rate producer ---
deploy_producer "burst-producer" 1 40000
sleep 2
cleanup_producers

# --- drain period ---
log_info "Draining for 30s..."
sleep 30

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- assert ---
if assert_no_drops_delta "${before}" "${after}" "0.1"; then
  write_result "burst_spike" "pass"
  end_test pass
else
  write_result "burst_spike" "fail"
  end_test fail
fi
