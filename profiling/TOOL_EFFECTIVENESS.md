# Tool Effectiveness

Tracks which profiling tools and approaches yielded actionable insights.
Reset at the start of each clean optimization round.

## Summary from previous round (16 iterations)

| Tool | Actionable insights | Best for |
| --- | --- | --- |
| Criterion benchmarks | High — fast feedback loop for microbenchmarks | Validating individual function-level changes |
| E2E Docker (perf) | High — CPU sampling identifies real hot functions | Finding the actual bottleneck in production-like pipeline |
| E2E Docker (none) | Essential — throughput measurement for validation | Confirming E2E impact (the only metric that matters) |
| E2E Docker (coz) | Medium — causal profiling shows which functions have most impact | Prioritizing which hotspot to optimize next |
| E2E Docker (perf-stat) | Medium — hardware counters for IPC/cache analysis | Understanding *why* something is slow (cache misses vs branch misprediction) |
| cargo bench (remap/transform/codecs) | Medium — useful for directional signal | Quick iteration, but doesn't always predict E2E impact |

## Key learnings

- **E2E throughput is the only metric that matters.** Criterion microbenchmarks can show 30%+ improvement but translate to <2% E2E delta. Always validate with E2E.
- **Run at least 3 E2E trials.** Variance can be ±5% between runs. Median of 3 is reasonable.
- **CPU pinning is essential.** `cpuset: "0-3"` reduces run-to-run variance from ±20% to ±0.04%.
- **The `--profiler none` mode** is fastest for pure throughput measurement. Use `perf` only when you need to identify new hotspots.
