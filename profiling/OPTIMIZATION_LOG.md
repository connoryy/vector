# Vector Performance Optimization Log

Tracks all optimization attempts. **APPEND only — never overwrite.**

## Cumulative Impact

| Benchmark | Baseline (ns/iter) | Current Best (ns/iter) | Improvement |
|-----------|-------------------|------------------------|-------------|
| remap/add_fields | 335.03 | 323.87 | -3.3% |
| remap/parse_json | 358.09 | 351.17 | -1.9% |
| remap/coerce | 627.64 | 620.19 | -1.2% |

---

## Open PRs

| PR | Branch | Optimization | Status |
|----|--------|-------------|--------|
| [#7](https://github.com/connoryy/vector/pull/7) | `claude/reuse-arc-vrl-target` | VrlTarget decompose/recompose — eliminates Arc alloc/dealloc per event | Best perf PR, +145/-13 |
| [#13](https://github.com/connoryy/vector/pull/13) | `claude/inline-hot-path-methods` | `#[inline]` on cross-crate hot-path methods | Dirty diff, needs rebase |
| [#16](https://github.com/connoryy/vector/pull/16) | `connor/profiling-infrastructure` | Profiling infrastructure (86 files) | Infrastructure |

## Completed Hotspots

1. **DONE** — `LogEvent::into_parts` Arc::make_mut avoidance (PR #7 supersedes #15)
2. **DONE** — `#[inline]` on cross-crate methods (PR #13)
3. **DONE** — VrlTarget Arc alloc/dealloc cycle (PR #7)

## Remaining Hotspots (see NEXT_LEADS.md)

4. TODO — Fanout EventArray clone_from for multi-sink topologies
5. TODO — Size cache invalidation on every mutation
6. TODO — Batch notifier per-event cloning
7. TODO — VRL runtime.clear() allocation overhead
8. TODO — JSON parsing (serde_json → simd-json)
9. TODO — Token redaction regex encode/replace/parse round-trip
10. TODO — BTreeMap for Value::Object → HashMap

---

## Iteration 1 — LogEvent::into_parts Arc::make_mut avoidance

- **Date**: 2026-03-24
- **Change**: Removed unnecessary `self.value_mut()` call before `Arc::try_unwrap` in `into_parts()`. When refcount is 1 (common case), skips atomic stores for cache invalidation.
- **Result**: MERGED → PR #15 (closed, superseded by #7)
- **Measurements**: remap/add_fields -3.3%, remap/parse_json -1.9%, remap/coerce -1.2%
- **Discovery Method**: Source code analysis of remap.rs → VrlTarget::new() → into_parts() call chain

## Iteration 2 — VrlTarget decompose/recompose

- **Date**: 2026-03-24
- **Change**: Added `LogEvent::decompose()` and `recompose()` to avoid Arc alloc→dealloc→realloc cycle on every event through the remap transform.
- **Result**: MERGED → PR #7
- **Measurements**: Pending
- **Discovery Method**: Source code analysis of VrlTarget lifecycle

## Iteration 3 — #[inline] on hot-path cross-crate methods

- **Date**: 2026-03-25
- **Change**: Added `#[inline]` to ~20 small accessor/constructor methods in vector-core called cross-crate.
- **Result**: MERGED → PR #13
- **Measurements**: Pending
- **Discovery Method**: Source code analysis of cross-crate call boundaries

---

*Note: The auto-optimize loop initially produced duplicate PRs (iterations 1-15 all found the same into_parts hotspot) because the log was overwritten between runs. Fixed by adding log backup/restore and NEXT_LEADS.md for cross-iteration knowledge transfer.*
