#!/usr/bin/env bash
# =============================================================================
# run-all-tests.sh -- Run all profiling tests sequentially with stream-json stats
#
# Discovers all test scripts in the tests/ directory and runs them one by one,
# streaming JSON results as each test completes.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_DIR="${SCRIPT_DIR}/../tests"
source "${SCRIPT_DIR}/../tests/lib.sh"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
export RESULTS_DIR="${RESULTS_DIR:-${SCRIPT_DIR}/../results/${TIMESTAMP}}"
mkdir -p "${RESULTS_DIR}"

# Port-forward Prometheus for all tests
start_port_forward "svc/prometheus" 9090 9090
PROMETHEUS_URL="http://localhost:9090"
export PROMETHEUS_URL

# Discover test scripts
shopt -s nullglob
TEST_SCRIPTS=("${TESTS_DIR}"/test_*.sh)
shopt -u nullglob

TOTAL=${#TEST_SCRIPTS[@]}
if [[ "${TOTAL}" -eq 0 ]]; then
    log_warn "No test scripts found in ${TESTS_DIR}"
    exit 0
fi

log_info "Found ${TOTAL} tests to run"
log_info "Results directory: ${RESULTS_DIR}"
echo ""

PASS=0
FAIL=0
SKIP=0
START_TS=$(date +%s)

# Stream JSON header
echo '{"test_run": {"timestamp": "'"${TIMESTAMP}"'", "total_tests": '"${TOTAL}"', "results": ['

FIRST=true
for test_script in "${TEST_SCRIPTS[@]}"; do
    test_name="$(basename "${test_script}" .sh)"
    test_start=$(date +%s)

    log_info "Running [$(( PASS + FAIL + SKIP + 1 ))/${TOTAL}]: ${test_name}"

    status="pass"
    output=""
    if output=$("${test_script}" 2>&1); then
        PASS=$(( PASS + 1 ))
        log_info "  PASS: ${test_name}"
    else
        exit_code=$?
        if [[ ${exit_code} -eq 77 ]]; then
            SKIP=$(( SKIP + 1 ))
            status="skip"
            log_warn "  SKIP: ${test_name}"
        else
            FAIL=$(( FAIL + 1 ))
            status="fail"
            log_error "  FAIL: ${test_name} (exit code ${exit_code})"
        fi
    fi

    test_elapsed=$(( $(date +%s) - test_start ))

    # Stream JSON result
    if [[ "${FIRST}" == "true" ]]; then
        FIRST=false
    else
        echo ","
    fi

    python3 -c "
import json, sys
result = {
    'test': '${test_name}',
    'status': '${status}',
    'elapsed_seconds': ${test_elapsed},
    'timestamp': '$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
}
print(json.dumps(result))" || echo "{\"test\": \"${test_name}\", \"status\": \"${status}\", \"elapsed_seconds\": ${test_elapsed}}"

    # Save individual result
    mkdir -p "${RESULTS_DIR}"
    python3 -c "
import json
result = {
    'test': '${test_name}',
    'status': '${status}',
    'elapsed_seconds': ${test_elapsed},
    'timestamp': '$(date -u '+%Y-%m-%dT%H:%M:%SZ')'
}
with open('${RESULTS_DIR}/test_${test_name}.json', 'w') as f:
    json.dump(result, f, indent=2)
" 2>/dev/null || true
done

TOTAL_ELAPSED=$(( $(date +%s) - START_TS ))

# Stream JSON footer
echo ""
echo "], \"summary\": {\"passed\": ${PASS}, \"failed\": ${FAIL}, \"skipped\": ${SKIP}, \"total_elapsed_seconds\": ${TOTAL_ELAPSED}}}}"

echo ""
log_info "============================================="
log_info "  Test Run Complete"
log_info "  Passed: ${PASS}  Failed: ${FAIL}  Skipped: ${SKIP}"
log_info "  Total time: ${TOTAL_ELAPSED}s"
log_info "  Results: ${RESULTS_DIR}"
log_info "============================================="

# Run the report
"${SCRIPT_DIR}/report.sh" "${RESULTS_DIR}" || true

# Exit with failure if any tests failed
[[ "${FAIL}" -eq 0 ]]
