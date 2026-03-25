# Vector Performance Optimization Log

## Format
Each iteration documents: what was profiled, what was changed, and the measured result.

## Cumulative Impact

| Benchmark | Baseline (ns/iter) | Current Best (ns/iter) | Total Improvement |
|-----------|-------------------|------------------------|-------------------|
| remap/add_fields | 335.03 | 323.87 | -3.3% |
| remap/parse_json | 358.09 | 351.17 | -1.9% |
| remap/coerce | 627.64 | 620.19 | -1.2% |

## Known Hotspots (not yet optimized)
- EventArray clone_from in fanout (multi-sink topologies)
- VRL execution engine overhead
- Metadata cloning in VRL target iterators
- Batch notifier per-event cloning
- Value .clone().try_*() patterns in metric VRL target
- ObjectMap (BTreeMap) overhead vs HashMap

---

## Iteration 12 — Optimize LogEvent::into_parts to avoid unnecessary Arc::make_mut
- **Date**: 2026-03-25T05:21:22Z
- **Hotspot**: LogEvent::into_parts() calls value_mut() which triggers Arc::make_mut + invalidate() even when Arc refcount is already 1
- **Change**: Replaced the value_mut() + Arc::try_unwrap pattern with a direct Arc::try_unwrap that falls back to cloning only when refcount > 1. This avoids unnecessary AtomicCell stores (invalidate()) and a redundant refcount check in the common case.
- **Result**: MERGED
- **PR**: (will be filled after push)
- **Measurements**:
  - remap/add_fields: 335.03 ns -> 323.87 ns (-3.3%)
  - remap/parse_json: 358.09 ns -> 351.17 ns (-1.9%)
  - remap/coerce: 627.64 ns -> 620.19 ns (-1.2%)
- **Discovery Method**: Source code analysis of LogEvent::into_parts() at log_event.rs:277, identified that value_mut() call was redundant when Arc::try_unwrap would succeed directly. The remap benchmark (add_fields at 335ns baseline) exercises this path via VrlTarget::new() which calls event.into_parts().
- **Files Changed**: lib/vector-core/src/event/log_event.rs
