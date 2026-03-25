# Vector Performance Optimization Log

## Format
Each iteration documents: what was profiled, what was changed, and the measured result.
Entries are append-only — never rewrite prior entries.

## Cumulative Impact

| Benchmark | Baseline | Current Best | Improvement |
|-----------|----------|-------------|-------------|
| remap/add_fields | 337.40 ns | 323.65 ns | -4.07% |
| remap/parse_json | 365.38 ns | 352.93 ns | -3.41% |
| remap/coerce | 634.31 ns | 621.72 ns | -1.98% |

## Known Hotspots (ordered by estimated impact)
1. VRL execution engine (external crate — limited optimization surface)
2. Event cloning on fallible remap transforms (event.clone() at remap.rs:584)
3. Arc::make_mut in LogEvent field mutations (log_event.rs:188)
4. EventArray clone per sink in fanout (fanout.rs:303)
5. Namespace detection via metadata path lookup (log_event.rs:207)
6. EventMetadata Arc cloning patterns (metadata.rs)
7. String allocations in error paths

---

## Iteration 11 — Optimize LogEvent::into_parts to avoid unnecessary Arc::make_mut
- **Date**: 2026-03-25T04:24:18Z
- **Hotspot**: LogEvent::into_parts() calls value_mut() which triggers Arc::make_mut + invalidate() before Arc::try_unwrap, adding unnecessary atomic operations on every event passing through VRL transforms
- **Change**: Replaced the value_mut() + Arc::try_unwrap pattern with a direct Arc::try_unwrap, falling back to cloning fields only if refcount > 1. This eliminates 3 unnecessary atomic operations (2 atomic stores for cache invalidation + 1 conditional atomic check from make_mut) per event when refcount is 1 (the common case). Also removes the unreachable!() panic path in favor of graceful handling.
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/14
- **Measurements**:
  - remap/add_fields: 337.40 ns → 323.65 ns (-4.07%)
  - remap/parse_json: 365.38 ns → 352.93 ns (-3.41%)
  - remap/coerce: 634.31 ns → 621.72 ns (-1.98%)
- **Discovery Method**: Source code analysis of the VRL hot path (remap.rs → VrlTarget::new → LogEvent::into_parts → value_mut → Arc::make_mut + invalidate). Identified that into_parts was calling value_mut() solely to ensure refcount=1 for try_unwrap, but this added unnecessary atomic operations.
- **Files Changed**: lib/vector-core/src/event/log_event.rs
