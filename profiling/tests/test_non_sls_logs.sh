#!/usr/bin/env bash
# test_non_sls_logs.sh -- plain text (non-SLS) logs, delta assertion
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "non_sls_logs"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy

# Deploy producer emitting plain text (non-JSON, non-SLS)
deploy_producer "nonsls-producer" 3 100 \
  "This is a plain text log line without any SLS structure $(date +%s)"
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
if assert_no_drops_delta "${before}" "${after}" "1.0"; then
  write_result "non_sls_logs" "pass"
  cleanup_producers
  end_test pass
else
  write_result "non_sls_logs" "fail"
  cleanup_producers
  end_test fail
fi
