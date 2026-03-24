# Vector Performance Optimization Log

## Format

Each iteration documents:
- **Date**: When the optimization was attempted
- **Hotspot**: What profiling/analysis identified as the target
- **Change**: What was modified and why
- **Result**: MERGED or REVERTED
- **PR**: Link to pull request (if merged)
- **Measurements**: Before/after benchmark data
- **Discovery Method**: Tools/techniques used to find the hotspot
- **Files Changed**: List of modified files

## Cumulative Impact

| Benchmark | Baseline | Current Best | Improvement |
|-----------|----------|-------------|-------------|
| remap/add_fields | 334.38 ns | 319.11 ns | -4.6% |
| remap/parse_json | 354.71 ns | 348.46 ns | -1.8% |
| remap/coerce | 637.88 ns | 620.87 ns | -2.7% |

## Known Hotspots (for future iterations)

1. VRL execution engine field access (BTreeMap lookups) — ~60-70% of remap time
2. Arc::new() allocation in LogEvent::from_parts() — called per-event on output
3. Event clone in remap error path (line 584) — only when program is fallible
4. Metadata Arc::make_mut in VRL target operations
5. String allocations in VRL string operations

---

## Iteration 5 — Optimize LogEvent::into_parts() to avoid unnecessary Arc::make_mut

- **Date**: 2026-03-24T22:07:55Z
- **Hotspot**: `LogEvent::into_parts()` unconditionally called `value_mut()` which triggers `Arc::make_mut()` (atomic refcount check) and cache invalidation (2 atomic stores), even when the Arc has sole ownership and `Arc::try_unwrap()` would succeed directly.
- **Change**: Replaced the `value_mut()` + `Arc::try_unwrap().unwrap()` pattern with a direct `Arc::try_unwrap()` that falls back to `arc.fields.clone()` on shared ownership. This eliminates unnecessary atomic operations (1 `Arc::make_mut` check + 2 cache invalidation stores) in the common single-owner case, and avoids cloning the size cache `AtomicCell`s in the shared case.
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/10
- **Measurements**:
  - remap/add_fields: 334.38 ns -> 319.11 ns (-4.6%)
  - remap/parse_json: 354.71 ns -> 348.46 ns (-1.8%)
  - remap/coerce: 637.88 ns -> 620.87 ns (-2.7%)
  - transform benchmarks: neutral (within noise)
- **Discovery Method**: Source code analysis of remap.rs hot path -> VrlTarget::new() -> LogEvent::into_parts() -> value_mut() -> Arc::make_mut(). Identified that `into_parts()` always called `value_mut()` to ensure sole Arc ownership before `try_unwrap()`, but this is unnecessary when the Arc is already sole-owned (refcount=1), which is the common case. The `try_unwrap` attempt directly handles both cases without the overhead.
- **Files Changed**: lib/vector-core/src/event/log_event.rs
