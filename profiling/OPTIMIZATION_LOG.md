# Vector Performance Optimization Log

## Cumulative Impact

| Benchmark | Baseline | Current Best | Improvement |
|-----------|----------|-------------|-------------|
| remap/add_fields | 329.32 ns | 321.80 ns | -2.28% |
| remap/parse_json | 357.86 ns | 353.27 ns | -1.28% |
| remap/coerce | 624.56 ns | 614.48 ns | -1.61% |

---

## Iteration 2 — Optimize LogEvent::into_parts to avoid unnecessary Arc overhead
- **Date**: 2026-03-24T20:00:33Z
- **Hotspot**: `LogEvent::into_parts()` — called on every event passing through remap/VRL transforms. The method unnecessarily called `value_mut()` which invokes `Arc::make_mut` + `invalidate()` (two atomic stores to clear size caches) before `Arc::try_unwrap`, even though the Arc refcount is almost always 1 when the LogEvent is owned.
- **Change**: Removed the unnecessary `self.value_mut()` call in `into_parts()`. Now tries `Arc::try_unwrap` directly (succeeds when refcount is 1, the common case), and falls back to cloning the Inner only if the Arc has multiple owners. This eliminates: one `Arc::make_mut` atomic check, two atomic stores for cache invalidation, and the `mut` requirement on `self`.
- **Result**: MERGED
- **PR**: (will be filled after push)
- **Measurements**:
  - remap/add_fields: 329.32 ns -> 321.80 ns (-2.28%)
  - remap/parse_json: 357.86 ns -> 353.27 ns (-1.28%)
  - remap/coerce: 624.56 ns -> 614.48 ns (-1.61%)
  - Transform benchmarks (dedupe, filter, reduce): within noise, no regressions
- **Files Changed**: `lib/vector-core/src/event/log_event.rs`
