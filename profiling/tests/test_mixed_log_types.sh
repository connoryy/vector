#!/usr/bin/env bash
# test_mixed_log_types.sh -- mixed SLS log types, delta assertion
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "mixed_log_types"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy

# Deploy producers with different SLS log formats
deploy_producer "mixed-service1" 1 50 \
  '{"level":"INFO","message":"sls service.1 log","v":1,"time":"2024-01-01T00:00:00Z"}'
deploy_producer "mixed-audit" 1 50 \
  '{"level":"WARN","message":"sls audit.3 log","v":3,"time":"2024-01-01T00:00:00Z"}'
deploy_producer "mixed-request" 1 50 \
  '{"level":"DEBUG","message":"sls request.2 log","v":2,"time":"2024-01-01T00:00:00Z"}'
sleep 30

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
  write_result "mixed_log_types" "pass"
  cleanup_producers
  end_test pass
else
  write_result "mixed_log_types" "fail"
  cleanup_producers
  end_test fail
fi
