#!/usr/bin/env bash
# =============================================================================
# report.sh -- Read test result JSON files and print pass/fail summary
#
# Scans the results directory for test_*.json files and prints a table of
# test names, statuses, and durations.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../tests/lib.sh"

RESULTS="${1:-${RESULTS_DIR}}"

if [[ ! -d "${RESULTS}" ]]; then
    log_error "Results directory not found: ${RESULTS}"
    exit 1
fi

# Find all test result files
shopt -s nullglob
RESULT_FILES=("${RESULTS}"/test_*.json "${RESULTS}"/*.json)
shopt -u nullglob

if [[ ${#RESULT_FILES[@]} -eq 0 ]]; then
    log_warn "No test result files found in ${RESULTS}"
    exit 0
fi

python3 -c "
import json, os, sys, glob

results_dir = '${RESULTS}'
files = sorted(glob.glob(os.path.join(results_dir, '*.json')))

if not files:
    print('No result files found')
    sys.exit(0)

results = []
for f in files:
    try:
        with open(f) as fh:
            data = json.load(fh)
            results.append(data)
    except (json.JSONDecodeError, IOError) as e:
        print(f'WARN: could not parse {f}: {e}', file=sys.stderr)

pass_count = sum(1 for r in results if r.get('status') == 'pass')
fail_count = sum(1 for r in results if r.get('status') == 'fail')
skip_count = sum(1 for r in results if r.get('status') == 'skip')
other_count = len(results) - pass_count - fail_count - skip_count

print()
print('=' * 78)
print(f'  TEST RESULTS SUMMARY  ({len(results)} tests)')
print('=' * 78)
print()
print(f'  {\"Test Name\":<40} {\"Status\":<8} {\"Duration\":>10} {\"Metric\":<20}')
print(f'  {\"-\" * 40} {\"-\" * 8} {\"-\" * 10} {\"-\" * 20}')

for r in sorted(results, key=lambda x: x.get('test', '')):
    name = r.get('test', 'unknown')
    status = r.get('status', 'unknown')
    elapsed = r.get('elapsed_seconds', r.get('duration_seconds', 0))
    metric = ''
    if r.get('metric'):
        metric = f\"{r['metric']}={r.get('value', 'N/A')}\"
    elif r.get('message'):
        metric = str(r['message'])[:20]

    status_display = status.upper()
    if status == 'pass':
        status_display = 'PASS'
    elif status == 'fail':
        status_display = 'FAIL'
    elif status == 'skip':
        status_display = 'SKIP'

    print(f'  {name:<40} {status_display:<8} {elapsed:>8}s  {metric:<20}')

print()
print(f'  Summary: {pass_count} passed, {fail_count} failed, {skip_count} skipped', end='')
if other_count > 0:
    print(f', {other_count} other', end='')
print()

if fail_count > 0:
    print()
    print('  FAILED TESTS:')
    for r in results:
        if r.get('status') == 'fail':
            msg = r.get('message', r.get('metric', ''))
            print(f'    - {r.get(\"test\", \"unknown\")}: {msg}')

print('=' * 78)

sys.exit(1 if fail_count > 0 else 0)
"
