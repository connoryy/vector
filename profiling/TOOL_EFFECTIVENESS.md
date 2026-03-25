# Tool Effectiveness Tracker

Updated automatically after each auto-optimize iteration.
Used to reflect on which tools and approaches produce results vs waste time.

## Tool Usage Summary

| Tool | Times Used | Led to Optimization | Wasted Time | Notes |
|------|-----------|-------------------|-------------|-------|
| `cargo bench --bench remap` | 2 | 1 (iteration 1) | 0 | Fast, reliable. Should ALWAYS run. |
| `cargo bench --bench transform` | 0 | 0 | 0 | Never tried. |
| `cargo bench --bench event` | 0 | 0 | 0 | Never tried. |
| Source code Read/Grep | ~50 | 3 | ~47 | Massively overused. Led to 14 duplicate PRs finding the same into_parts pattern. |
| `profile-cpu.sh` (perf flamegraph) | 0 | 0 | 0 | Never used — cluster wasn't running. |
| `profile-full.sh` | 0 | 0 | 0 | Never used. |
| bpftrace scripts | 0 | 0 | 0 | Never used. |
| strace | 0 | 0 | 0 | Never used. |
| valgrind/cachegrind | 0 | 0 | 0 | Never used. |
| coz (causal profiling) | 0 | 0 | 0 | Never used. |
| Custom microbenchmark | 0 | 0 | 0 | Never written. |
| macOS `sample` command | 0 | 0 | 0 | Never used. |
| Criterion HTML reports | 0 | 0 | 0 | Never checked. |

## Observations

1. **Source code analysis dominated** — The agent defaulted to reading .rs files because it's instant. This found real issues but also led to massive duplication (same hotspot 14 times).
2. **No profiling tools were ever used** — cargo bench ran twice. perf, bpftrace, strace, coz, valgrind were never invoked despite being available.
3. **No microbenchmarks were written** — The agent relied entirely on the existing remap bench (3 operations). Targeted benchmarks for specific hotspots would have been more informative.
4. **Benchmark-first wasn't enforced** — Despite the prompt saying "MANDATORY", the agent skipped benchmarks in most iterations.

## Recommendations for Next Session

- Force benchmark execution by checking for `/tmp/bench-baseline.txt` before proceeding
- Deprioritize source code browsing — it's a trap that leads to the same findings
- Try `cargo bench --bench event` to find event model overhead
- Write a custom bench for fanout cloning (Priority 1 lead)
- If cluster is running, use `profile-full.sh` at least once to get real CPU data

## Session History

### Session 1 (2026-03-24 to 2026-03-25)

**What happened:**
- 15+ iterations of auto-optimize loop
- 10 PRs created, 8 were duplicates of the same into_parts optimization
- 3 unique optimizations found: into_parts Arc avoidance, VrlTarget decompose/recompose, #[inline] annotations
- Total improvement: ~1-3% on remap benchmarks

**What worked:**
- cargo bench provided reliable before/after numbers
- Source code analysis found real hotspots (into_parts, VrlTarget lifecycle)
- The decompose/recompose change (PR #7) was the most significant

**What didn't work:**
- Optimization log was overwritten between iterations → duplicate work
- No leads file → agent re-discovered same hotspot every time
- No profiling tools used → missed opportunities for deeper analysis
- Agent defaulted to reading code instead of measuring

**Fixed for next session:**
- NEXT_LEADS.md provides cross-iteration knowledge
- Optimization log backup/restore across git operations
- Prompt says "PROFILE FIRST, CODE SECOND"
- Model upgraded to Opus
- Stream output filter shows tool calls in real time
