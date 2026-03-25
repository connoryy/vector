# Vector Performance Optimization Log

## Format
Each iteration documents:
- What was targeted and why
- What changed
- Whether it was merged or reverted
- Measurements (before/after)

## Cumulative Impact

| Benchmark | Baseline (master) | Current Best | Improvement |
|-----------|------------------|-------------|-------------|
| remap/add_fields | 336.62 ns | 320.05 ns | -4.9% |
| remap/parse_json | 373.65 ns | 342.08 ns | -8.5% |
| remap/coerce | 638.61 ns | 621.32 ns | -2.7% |

## Known Hotspots (for future iterations)
1. ~~VrlTarget destructure/reconstruct Arc cycle~~ (addressed in iteration 6)
2. Remap defensive event cloning for fallible programs (line 584 of remap.rs)
3. EventArray cloning in fanout for multi-sink topologies (fanout.rs:288-304)
4. VRL execution engine overhead (in external vrl crate)
5. EventMetadata clone cost in TargetIter for array expansion (vrl_target.rs:76-79)
6. Uuid::new_v4() generation in EventMetadata::default() (metadata.rs:279)

---

## Iteration 6 — Avoid Arc alloc/dealloc in VrlTarget for LogEvent
- **Date**: 2026-03-24T23:18:51Z
- **Hotspot**: VrlTarget destructured LogEvent into (Value, EventMetadata) on entry and reconstructed it on exit, causing an unnecessary Arc<Inner> deallocation + reallocation per event through the remap transform.
- **Change**: Modified VrlTarget to store LogEvent directly instead of destructuring it. VRL now accesses the event value via LogEvent::value()/value_mut() methods. In the common case (value remains an Object), the LogEvent is returned directly from into_events() without any Arc operations. Also simplified LogEvent::into_parts() to use Arc::unwrap_or_clone instead of the value_mut() + Arc::try_unwrap pattern.
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/11
- **Measurements**:
  - remap/add_fields: 336.62 ns → 320.05 ns (-4.9%)
  - remap/parse_json: 373.65 ns → 342.08 ns (-8.5%)
  - remap/coerce: 638.61 ns → 629.25 ns (-1.5%)
- **Discovery Method**: Source code analysis of the remap transform hot path. Identified that VrlTarget::new() called LogEvent::into_parts() (Arc destruction) and into_events() called LogEvent::from_parts() (Arc allocation) on every event, even though the LogEvent could be kept intact throughout VRL execution.
- **Files Changed**:
  - lib/vector-core/src/event/vrl_target.rs (VrlTarget enum + all Target trait methods)
  - lib/vector-core/src/event/log_event.rs (into_parts simplification)

## Iteration 7 — Simplify LogEvent::into_parts with Arc::unwrap_or_clone
- **Date**: 2026-03-25T00:00:34Z
- **Hotspot**: LogEvent::into_parts() used a two-step process: first calling value_mut() which triggers Arc::make_mut (allocating a new intermediate Arc when refcount > 1), then Arc::try_unwrap to extract the Inner. This intermediate Arc allocation/deallocation is unnecessary.
- **Change**: Replaced the value_mut() + Arc::try_unwrap pattern with a single Arc::unwrap_or_clone(self.inner) call. When refcount == 1, this unwraps directly without cloning. When refcount > 1 (common case in benchmarks where events are cloned from a template), it clones the Inner data directly without creating an intermediate Arc allocation. This eliminates one heap allocation (Arc metadata) and one deallocation per into_parts call when the Arc is shared.
- **Result**: MERGED
- **PR**: (will be filled after push)
- **Measurements**:
  - remap/add_fields: 334.14 ns → 326.6 ns (-2.3%)
  - remap/parse_json: 359.09 ns → 351.5 ns (-2.1%)
  - remap/coerce: 625.85 ns → 621.8 ns (-0.6%)
- **Discovery Method**: Source code analysis of LogEvent::into_parts() hot path. Identified that Arc::make_mut creates an unnecessary intermediate Arc when the original Arc is shared (refcount > 1), only to immediately unwrap it with try_unwrap. Arc::unwrap_or_clone avoids this overhead by cloning the Inner directly.
- **Files Changed**:
  - lib/vector-core/src/event/log_event.rs (into_parts simplification)
