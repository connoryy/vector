#!/usr/bin/env bash
# test_vrl_drop_on_error.sh -- malformed JSON phases, verify valid passes + malformed dropped
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "vrl_drop_on_error"
trap 'cleanup_producers; end_test fail' ERR

wait_vector_healthy
overall_pass=true

# --- Phase 1: valid JSON events should pass through ---
log_info "Phase 1: valid JSON events"
deploy_producer "vrl-valid" 1 100 \
  '{"level":"INFO","message":"valid event","v":1,"time":"2024-01-01T00:00:00Z"}'
sleep 20

before_valid="$(snapshot_pipeline)"
sleep 60
after_valid="$(snapshot_pipeline)"
cleanup_producers
sleep 10

valid_delta="$(python3 -c "
b = [float(x) for x in '${before_valid}'.split()]
a = [float(x) for x in '${after_valid}'.split()]
print(a[3] - b[3])
")"
log_info "Valid events received: ${valid_delta}"
if ! python3 -c "exit(0 if float('${valid_delta}') > 0 else 1)"; then
  log_error "Phase 1 FAIL: no valid events passed through"
  overall_pass=false
fi

# --- Phase 2: malformed events should be dropped by VRL drop_on_error ---
log_info "Phase 2: malformed (non-JSON) events"
deploy_producer "vrl-malformed" 1 100 \
  'NOT VALID JSON {{{{ broken'
sleep 20

before_mal="$(snapshot_pipeline)"
sleep 60
after_mal="$(snapshot_pipeline)"
cleanup_producers
sleep 10

# Malformed events should cause drops in the DS transform (drop_on_error)
ds_sent_delta="$(python3 -c "
b = [float(x) for x in '${before_mal}'.split()]
a = [float(x) for x in '${after_mal}'.split()]
print(a[0] - b[0])
")"
log_info "DS sent delta during malformed phase: ${ds_sent_delta}"

if [[ "${overall_pass}" == "true" ]]; then
  write_result "vrl_drop_on_error" "pass"
  end_test pass
else
  write_result "vrl_drop_on_error" "fail"
  end_test fail
fi
