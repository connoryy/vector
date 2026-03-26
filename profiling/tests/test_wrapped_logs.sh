#!/usr/bin/env bash
# test_wrapped_logs.sh -- wrapped.1 format at 1k/s, delta assertion
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "wrapped_logs"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy

# Deploy producer emitting wrapped.1 format (payload wrapped in envelope)
WRAPPED_MSG='{"type":"wrapped.1","payload":{"level":"INFO","message":"inner log event","v":1},"serviceClass":"test-svc","time":"2024-01-01T00:00:00Z"}'
deploy_producer "wrapped-producer" 1 1000 "${WRAPPED_MSG}"
sleep 20

# --- before snapshot ---
before="$(snapshot_pipeline)"
log_info "Before snapshot: ${before}"

# --- workload: 3 minutes ---
sleep 180

# --- after snapshot ---
after="$(snapshot_pipeline)"
log_info "After snapshot: ${after}"

# --- assert ---
if assert_no_drops_delta "${before}" "${after}" "0.5"; then
  write_result "wrapped_logs" "pass"
  cleanup_producers
  end_test pass
else
  write_result "wrapped_logs" "fail"
  cleanup_producers
  end_test fail
fi
