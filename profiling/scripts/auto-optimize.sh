#!/usr/bin/env bash
#
# auto-optimize.sh - Systematic Vector performance optimization loop
#
# Runs Claude in a loop to identify hotspots, make focused changes,
# benchmark, and submit PRs for improvements. Automatically resumes
# from the last completed iteration.
#
# Usage:
#   ./auto-optimize.sh [--max-iterations N] [--dry-run] [--cooldown N]
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration & defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
PROFILING_DIR="${SCRIPT_DIR}/.."
OPT_LOG="${PROFILING_DIR}/OPTIMIZATION_LOG.md"

MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-}"
FORK_REMOTE="${FORK_REMOTE:-connoryy}"
FORK_REPO="${FORK_REPO:-connoryy/vector}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
MAX_ITERATIONS="${MAX_ITERATIONS:-5}"
COOLDOWN_SECS="${COOLDOWN_SECS:-30}"
VECTOR_HELM_DIR="${VECTOR_HELM_DIR:-/Volumes/git/vector-helm}"

DRY_RUN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --max-iterations)
            MAX_ITERATIONS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --cooldown)
            COOLDOWN_SECS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--max-iterations N] [--dry-run] [--cooldown N]"
            echo ""
            echo "Options:"
            echo "  --max-iterations N   Maximum optimization iterations (default: 5)"
            echo "  --dry-run            Print the prompt but do not invoke Claude"
            echo "  --cooldown N         Seconds to wait between iterations (default: 30)"
            echo ""
            echo "Environment variables:"
            echo "  FORK_REMOTE          Git remote name for fork (default: connoryy)"
            echo "  FORK_REPO            GitHub repo slug for PRs (default: connoryy/vector)"
            echo "  UPSTREAM_BRANCH      Branch to base work on (default: master)"
            echo "  MAX_ITERATIONS       Same as --max-iterations"
            echo "  COOLDOWN_SECS        Same as --cooldown"
            echo "  VECTOR_HELM_DIR      Path to vector-helm checkout"
            echo "  MINIKUBE_PROFILE     Minikube profile name (optional)"
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Colours & helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "${BLUE}[INFO]${RESET}  %s\n" "$*"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$*"; }
ok()    { printf "${GREEN}[ OK ]${RESET}  %s\n" "$*"; }
err()   { printf "${RED}[ERR]${RESET}  %s\n" "$*" >&2; }
banner() {
    printf "\n${BOLD}${CYAN}%s${RESET}\n" "================================================================"
    printf "${BOLD}${CYAN}  %s${RESET}\n" "$*"
    printf "${BOLD}${CYAN}%s${RESET}\n\n" "================================================================"
}

# ---------------------------------------------------------------------------
# Auto-detect iteration number from OPTIMIZATION_LOG.md
# ---------------------------------------------------------------------------
detect_iteration() {
    if [[ ! -f "$OPT_LOG" ]]; then
        echo 1
        return
    fi
    local last
    last=$(grep -oE '## Iteration [0-9]+' "$OPT_LOG" | grep -oE '[0-9]+' | sort -n | tail -1 || true)
    if [[ -z "$last" ]]; then
        echo 1
    else
        echo $(( last + 1 ))
    fi
}

# ---------------------------------------------------------------------------
# Backup / restore OPTIMIZATION_LOG.md across git cleanup
# ---------------------------------------------------------------------------
LEADS_FILE="${PROFILING_DIR}/NEXT_LEADS.md"

backup_opt_log() {
    if [[ -f "$OPT_LOG" ]]; then
        cp "$OPT_LOG" "${OPT_LOG}.bak"
    fi
    if [[ -f "$LEADS_FILE" ]]; then
        cp "$LEADS_FILE" "${LEADS_FILE}.bak"
    fi
    info "Backed up optimization log and leads file"
}

restore_opt_log() {
    if [[ -f "${OPT_LOG}.bak" ]]; then
        cp "${OPT_LOG}.bak" "$OPT_LOG"
    fi
    if [[ -f "${LEADS_FILE}.bak" ]]; then
        cp "${LEADS_FILE}.bak" "$LEADS_FILE"
    fi
    info "Restored optimization log and leads file"
}

# ---------------------------------------------------------------------------
# Python stream-json filter: shows tool calls and text in real time
# ---------------------------------------------------------------------------
STREAM_FILTER=$(cat <<'PYEOF'
import sys, json, os

# Claude CLI stream-json format:
#   {"type":"assistant","message":{"content":[{"type":"text","text":"..."},{"type":"tool_use","name":"Bash","input":{...}}]}}
#   {"type":"result","usage":{"input_tokens":...,"output_tokens":...},"cost_usd":...}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except json.JSONDecodeError:
        continue

    msg_type = d.get("type", "")

    if msg_type == "assistant":
        for block in d.get("message", {}).get("content", []):
            bt = block.get("type", "")
            if bt == "text" and block.get("text", "").strip():
                print(block["text"], flush=True)
            elif bt == "tool_use":
                name = block.get("name", "?")
                inp = block.get("input", {})
                if name == "Bash":
                    cmd = inp.get("command", "")[:120]
                    print(f"  \033[36m> {name}:\033[0m {cmd}", flush=True)
                elif name in ("Read", "Write", "Edit"):
                    path = inp.get("file_path", "")
                    print(f"  \033[36m> {name}:\033[0m {path}", flush=True)
                elif name == "Grep":
                    pat = inp.get("pattern", "")
                    print(f"  \033[36m> {name}:\033[0m /{pat}/", flush=True)
                else:
                    print(f"  \033[36m> {name}\033[0m", flush=True)

    elif msg_type == "result":
        usage = d.get("usage", {})
        inp = usage.get("input_tokens", 0)
        out = usage.get("output_tokens", 0)
        cache_read = usage.get("cache_read_input_tokens", 0)
        cache_create = usage.get("cache_creation_input_tokens", 0)
        cost_usd = d.get("cost_usd", 0.0)
        print(f"\n{'='*60}", flush=True)
        print(f"Tokens  - input: {inp:,}  output: {out:,}", flush=True)
        if cache_read:
            print(f"Cache   - read: {cache_read:,}  created: {cache_create:,}", flush=True)
        if cost_usd:
            print(f"Cost    - ${cost_usd:.4f}", flush=True)
        print(f"{'='*60}", flush=True)

        stats_file = os.environ.get("ITER_STATS_FILE", "")
        if stats_file:
            with open(stats_file, "w") as f:
                json.dump({
                    "input_tokens": inp,
                    "output_tokens": out,
                    "cache_read": cache_read,
                    "cache_create": cache_create,
                    "cost_usd": cost_usd
                }, f)
PYEOF
)

# ---------------------------------------------------------------------------
# Token / cost tracking
# ---------------------------------------------------------------------------
CUMULATIVE_INPUT=0
CUMULATIVE_OUTPUT=0
CUMULATIVE_COST="0.0"

update_cumulative_stats() {
    local stats_file="$1"
    if [[ ! -f "$stats_file" ]]; then
        warn "No stats file found for this iteration"
        return
    fi
    local inp out cost
    inp=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d.get('input_tokens',0))")
    out=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d.get('output_tokens',0))")
    cost=$(python3 -c "import json; d=json.load(open('$stats_file')); print(d.get('cost_usd',0.0))")

    CUMULATIVE_INPUT=$(( CUMULATIVE_INPUT + inp ))
    CUMULATIVE_OUTPUT=$(( CUMULATIVE_OUTPUT + out ))
    CUMULATIVE_COST=$(python3 -c "print(round($CUMULATIVE_COST + $cost, 4))")

    info "Iteration tokens - input: ${inp}, output: ${out}, cost: \$${cost}"
    ok "Cumulative tokens - input: ${CUMULATIVE_INPUT}, output: ${CUMULATIVE_OUTPUT}, cost: \$${CUMULATIVE_COST}"
}

# ---------------------------------------------------------------------------
# Build the Claude prompt
# ---------------------------------------------------------------------------
build_prompt() {
    local iteration="$1"
    local leads_content=""
    if [[ -f "${PROFILING_DIR}/NEXT_LEADS.md" ]]; then
        leads_content="$(cat "${PROFILING_DIR}/NEXT_LEADS.md")"
    fi
    local log_content=""
    if [[ -f "${OPT_LOG}" ]]; then
        log_content="$(cat "${OPT_LOG}")"
    fi

    cat <<PROMPT
You are optimizing Vector (a high-performance observability data pipeline in Rust) for maximum throughput and minimum latency. This is iteration ${iteration}.

PROJECT ROOT: ${PROJECT_ROOT}
PROFILING DIR: ${PROFILING_DIR}
OPTIMIZATION LOG: ${OPT_LOG}
LEADS FILE: ${PROFILING_DIR}/NEXT_LEADS.md
FORK REMOTE: ${FORK_REMOTE}
FORK REPO: ${FORK_REPO}
UPSTREAM BRANCH: ${UPSTREAM_BRANCH}
VECTOR HELM DIR: ${VECTOR_HELM_DIR}

## Principles

- **PROFILE FIRST, CODE SECOND**: Never read source code to find hotspots. Run benchmarks and profiling tools first. The data tells you where to look — then you read the code. Source-code-only analysis leads to the same optimization being attempted repeatedly.
- **Tackle by severity**: Focus on the largest bottleneck shown by profiling data. Not the most obvious code pattern.
- **Proportional changes**: The size of the change should be proportional to its impact.
- **Custom microbenchmarks are the primary tool**: Write targeted benchmarks that isolate your specific hotspot. The existing \`cargo bench --bench remap\` measures 3 operations. If your target isn't covered, add a bench.
- **Measure what matters**: Wall-clock throughput on realistic workloads is the ultimate metric.

## Available Profiling Tools (use these!)

ON MACOS (available right now, no cluster needed):
- \`cargo bench --bench remap --features remap-benches\` — Criterion microbenchmarks (add_fields, parse_json, coerce)
- \`cargo bench --bench transform --features transform-benches\` — Transform benchmarks (filter, dedupe, reduce, route)
- \`cargo bench --bench event\` — Event model benchmarks
- \`cargo bench --bench codecs --features codecs-benches\` — Codec benchmarks
- \`sample <pid> <duration> -file output.txt\` — macOS CPU stack sampling (attach to a running cargo bench)
- \`inferno-flamegraph\` — Convert stack samples to flamegraph SVG
- Criterion HTML reports in \`target/criterion/report/index.html\`

IN DOCKER CONTAINER (if cluster is running):
- perf, bpftrace, strace, coz, valgrind — via ${PROFILING_DIR}/scripts/profile-*.sh

## Critical Rules

- Prior optimizations live on fork branches (e.g. \`claude/<description>\`), NOT on master. The code on master is UNCHANGED. Do NOT re-optimize things listed as DONE in the log.
- APPEND only to OPTIMIZATION_LOG.md. Never overwrite existing entries.
- APPEND new leads to NEXT_LEADS.md when you discover potential optimizations you don't pursue this iteration.
- Include a "Discovery Method" field in each log entry.
- PRs go to **${FORK_REPO}** (not vectordotdev/vector).
- All git commits must use \`--no-gpg-sign\`.
- Branches must be named \`claude/<short-description>\` (e.g. \`claude/reduce-vrl-alloc\`).

## Optimization Log (already completed — do NOT repeat these)

${log_content}

## Next Leads (pick from here FIRST before doing new analysis)

${leads_content}

## Steps

### Step 1: Read Leads & Pick Target
Read the NEXT_LEADS.md content above. Pick the highest-priority lead.
If no leads remain, do fresh profiling (see Step 4 alternative).

### Step 2: Clean State
\`\`\`bash
cd ${PROJECT_ROOT}
git checkout ${UPSTREAM_BRANCH}
git pull origin ${UPSTREAM_BRANCH} || true
\`\`\`

### Step 3: Run Baseline Benchmarks & Profile (MANDATORY — do this FIRST before any code reading)
You MUST run benchmarks before reading ANY source code. This tells you WHERE to look.

\`\`\`bash
cd ${PROJECT_ROOT}

# Run the main benchmarks
cargo bench --bench remap --features remap-benches 2>&1 | tee /tmp/bench-baseline.txt

# If you have a specific lead, also run the relevant bench suite:
# cargo bench --bench event 2>&1 | tee -a /tmp/bench-baseline.txt
# cargo bench --bench transform --features transform-benches 2>&1 | tee -a /tmp/bench-baseline.txt
\`\`\`

Record the exact ns/iter numbers. These are your baseline.

OPTIONAL but highly valuable — CPU profile during benchmarks:
\`\`\`bash
# Run a benchmark in the background, then sample it
cargo bench --bench remap --features remap-benches -- --profile-time 10 &
BENCH_PID=\$!
sample \$BENCH_PID 10 -file /tmp/cpu-profile.txt
# Convert to flamegraph:
# cat /tmp/cpu-profile.txt | inferno-collapse-guess | inferno-flamegraph > /tmp/flamegraph.svg
\`\`\`

### Step 4: Investigate the Lead Using Profiling Data
NOW read the code — but only the functions that showed up as hot in profiling.

If you picked a lead from NEXT_LEADS.md:
1. Verify the specific function/path is actually hot in the benchmark data
2. If the lead mentions a function that doesn't show up in profiling, it may not be impactful — consider skipping
3. Write a TARGETED MICROBENCHMARK that isolates just that code path:
\`\`\`rust
// Add to benches/remap.rs or create a new bench file
group.bench_function("my_target/description", |b| {
    // Set up the specific scenario that exercises the hotspot
    b.iter(|| {
        // The operation you want to measure
    });
});
\`\`\`
4. Run your targeted benchmark to get a precise baseline for that specific operation

If no lead was available, use profiling to find a NEW hotspot:
- Which benchmark is slowest? That's where to start.
- What functions dominate the CPU profile? Read THOSE functions.
- Do NOT just browse source files looking for patterns.

### Step 5: Make ONE Focused Change
- Target the specific function/data structure identified by your benchmark
- The change CAN span multiple files
- You CAN add a new permanent benchmark if it fills a coverage gap
- Clean up throwaway code before committing

### Step 6: Build & Validate
\`\`\`bash
make fmt
make check-clippy
cargo test -p <changed-crate> --lib 2>&1 | tail -20
\`\`\`

### Step 7: Run After Benchmarks (MANDATORY)
Run the SAME benchmarks from Step 3 plus your targeted microbenchmark:
\`\`\`bash
cargo bench --bench remap --features remap-benches 2>&1 | tee /tmp/bench-after.txt
\`\`\`
Compare ns/iter numbers. Calculate percentage change for each.
If improvement < 1% on ALL benchmarks, REVERT.
If any benchmark REGRESSED > 2%, REVERT.

### Step 8: Decision
- If measurable improvement (>= 1% on any benchmark):
  **MERGE**:
  \`\`\`bash
  git checkout -b claude/<short-description>
  git add -A
  git commit --no-gpg-sign -m "perf: <description>

  Benchmark: <name> <before>ns -> <after>ns (<X>% improvement)

  Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
  git push ${FORK_REMOTE} claude/<short-description>
  gh pr create --repo ${FORK_REPO} --base ${UPSTREAM_BRANCH} --title "perf: <title>" --body "<body with benchmark numbers>"
  \`\`\`
- If no improvement or regression:
  **REVERT**:
  \`\`\`bash
  git checkout -- .
  git clean -fd
  \`\`\`

### Step 8: Update Optimization Log
APPEND a new section to ${OPT_LOG}:
\`\`\`markdown
## Iteration ${iteration}

**Date**: $(date -u +%Y-%m-%dT%H:%M:%SZ)
**Discovery Method**: <how you found the hotspot>
**Target**: <component/function>
**Change**: <what you did>
**Result**: MERGED / REVERTED
**Improvement**: <percentage or "no improvement">
**PR**: <URL or "N/A">

### Baseline
<benchmark numbers>

### After
<benchmark numbers>

### Analysis
<brief explanation>
\`\`\`

### Step 9: Update Leads for Next Iteration
This is CRITICAL for avoiding duplicate work:
1. Remove the lead you just investigated from ${PROFILING_DIR}/NEXT_LEADS.md (whether it succeeded or failed)
2. If during your investigation you noticed OTHER potential optimizations, ADD them as new leads to NEXT_LEADS.md with:
   - Source (how you found it)
   - What the issue is
   - Which files to look at
   - Estimated impact
   - Suggested approach
3. If the lead was invalid or not impactful, move it to the "Dismissed Leads" section with reasoning

This ensures the next iteration can start immediately with a concrete target instead of re-analyzing the same code.
PROMPT
}

# ---------------------------------------------------------------------------
# Run one iteration
# ---------------------------------------------------------------------------
run_iteration() {
    local iteration="$1"
    local stats_file
    stats_file=$(mktemp /tmp/iter-stats-XXXXXXXX)
    mv "$stats_file" "${stats_file}.json"
    stats_file="${stats_file}.json"

    banner "Iteration ${iteration} / ${MAX_ITERATIONS}"

    # Back up the log before we hand control to Claude (which may git checkout)
    backup_opt_log

    local prompt
    prompt=$(build_prompt "$iteration")

    if [[ "$DRY_RUN" == true ]]; then
        info "[DRY RUN] Would invoke Claude with the following prompt:"
        echo "---"
        echo "$prompt"
        echo "---"
        return 0
    fi

    info "Invoking Claude for iteration ${iteration}..."

    # Export stats file path so the Python filter can write to it
    export ITER_STATS_FILE="$stats_file"

    set +e
    CLAUDECODE= claude \
        -p "$prompt" \
        --model opus \
        --output-format stream-json \
        --verbose \
        --dangerously-skip-permissions \
        2>&1 | python3 -u -c "$STREAM_FILTER"
    local exit_code=$?
    set -e

    # Restore log in case Claude's git operations removed it
    restore_opt_log

    if [[ $exit_code -ne 0 ]]; then
        warn "Claude exited with code ${exit_code} on iteration ${iteration}"
    fi

    # Collect stats
    update_cumulative_stats "$stats_file"
    rm -f "$stats_file"

    return $exit_code
}

# ---------------------------------------------------------------------------
# Main loop
# ---------------------------------------------------------------------------
main() {
    banner "Vector Auto-Optimize"
    info "Project root:    ${PROJECT_ROOT}"
    info "Profiling dir:   ${PROFILING_DIR}"
    info "Fork remote:     ${FORK_REMOTE}"
    info "Fork repo:       ${FORK_REPO}"
    info "Upstream branch: ${UPSTREAM_BRANCH}"
    info "Max iterations:  ${MAX_ITERATIONS}"
    info "Cooldown:        ${COOLDOWN_SECS}s"
    info "Dry run:         ${DRY_RUN}"
    echo ""

    # Verify prerequisites
    if ! command -v claude &>/dev/null; then
        err "claude CLI not found in PATH"
        exit 1
    fi
    if ! command -v python3 &>/dev/null; then
        err "python3 not found in PATH"
        exit 1
    fi
    if ! command -v cargo &>/dev/null; then
        err "cargo not found in PATH"
        exit 1
    fi

    local start_iteration
    start_iteration=$(detect_iteration)
    local end_iteration=$(( start_iteration + MAX_ITERATIONS - 1 ))

    if [[ $start_iteration -gt 1 ]]; then
        ok "Resuming from iteration ${start_iteration} (detected prior runs)"
    fi

    local succeeded=0
    local failed=0

    for (( i=start_iteration; i<=end_iteration; i++ )); do
        set +e
        run_iteration "$i"
        local rc=$?
        set -e

        if [[ $rc -eq 0 ]]; then
            (( succeeded++ ))
        else
            (( failed++ ))
        fi

        # Cooldown between iterations (skip after last)
        if [[ $i -lt $end_iteration ]]; then
            info "Cooling down for ${COOLDOWN_SECS}s before next iteration..."
            sleep "$COOLDOWN_SECS"
        fi
    done

    # ---------------------------------------------------------------------------
    # Summary
    # ---------------------------------------------------------------------------
    banner "Optimization Complete"
    echo ""
    info "Iterations attempted: $(( succeeded + failed ))"
    ok   "Succeeded: ${succeeded}"
    if [[ $failed -gt 0 ]]; then
        warn "Failed: ${failed}"
    fi
    echo ""
    info "Cumulative token usage:"
    info "  Input:  ${CUMULATIVE_INPUT}"
    info "  Output: ${CUMULATIVE_OUTPUT}"
    info "  Cost:   \$${CUMULATIVE_COST}"
    echo ""

    if [[ -f "$OPT_LOG" ]]; then
        ok "Optimization log: ${OPT_LOG}"
    fi
}

main "$@"
