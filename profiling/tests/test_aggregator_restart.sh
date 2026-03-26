#!/usr/bin/env bash
# test_aggregator_restart.sh -- kill aggregator, verify recovery (events_after > 0)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib.sh"

begin_test "aggregator_restart"
trap 'cleanup_producers; end_test fail' ERR

# --- setup ---
wait_vector_healthy
deploy_producer "restart-producer" 1 100
sleep 30  # stabilize

# --- before snapshot (pre-kill) ---
before="$(snapshot_pipeline)"
log_info "Before kill snapshot: ${before}"

# --- kill aggregator ---
log_info "Deleting aggregator pod to trigger restart..."
kube delete pod -l "${LABEL_AGG}" --wait=false
sleep 5

# --- wait for aggregator recovery ---
kube_wait_ready "${LABEL_AGG}" "120s"
log_info "Aggregator recovered"
sleep 60  # let events flow again

# --- after snapshot (post-recovery) ---
after="$(snapshot_pipeline)"
log_info "After recovery snapshot: ${after}"

# --- assert: events flowed after restart ---
events_after_restart="$(python3 -c "
a = [float(x) for x in '${after}'.split()]
b = [float(x) for x in '${before}'.split()]
print(a[3] - b[3])
")"
log_info "Events received after restart: ${events_after_restart}"

if python3 -c "exit(0 if float('${events_after_restart}') > 0 else 1)"; then
  write_result "aggregator_restart" "pass"
  cleanup_producers
  end_test pass
else
  log_error "No events flowed after aggregator restart"
  write_result "aggregator_restart" "fail"
  cleanup_producers
  end_test fail
fi
