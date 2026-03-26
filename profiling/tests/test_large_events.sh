#!/usr/bin/env bash
# test_large_events.sh -- 4 phases (200B/2KB/100KB/2.5MB), per-phase delta assertions
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "large_events"
trap 'cleanup_producers; end_test fail' ERR

wait_vector_healthy
overall_pass=true

run_phase() {
  local phase_name="$1" size="$2" rate="$3" duration="$4" tolerance="$5"
  log_info "Phase ${phase_name}: size=${size}B rate=${rate}/s duration=${duration}s"

  local padding
  padding="$(python3 -c "print('x' * ${size})")"
  local msg="{\"level\":\"INFO\",\"message\":\"${padding}\",\"v\":1}"

  deploy_producer "large-events-producer" 1 "${rate}" "${msg}"
  sleep 15  # stabilize

  local before after
  before="$(snapshot_pipeline)"
  sleep "${duration}"
  after="$(snapshot_pipeline)"

  cleanup_producers
  sleep 10  # drain

  if ! assert_no_drops_delta "${before}" "${after}" "${tolerance}"; then
    log_error "Phase ${phase_name} FAILED"
    overall_pass=false
  fi
}

# Phase 1: 200B events at 100/s for 60s
run_phase "200B"   200   100 60 "0.1"
# Phase 2: 2KB events at 50/s for 60s
run_phase "2KB"    2000  50  60 "0.5"
# Phase 3: 100KB events at 10/s for 60s
run_phase "100KB"  100000 10 60 "1.0"
# Phase 4: 2.5MB events at 1/s for 60s
run_phase "2.5MB"  2500000 1 60 "2.0"

if [[ "${overall_pass}" == "true" ]]; then
  write_result "large_events" "pass"
  end_test pass
else
  write_result "large_events" "fail"
  end_test fail
fi
