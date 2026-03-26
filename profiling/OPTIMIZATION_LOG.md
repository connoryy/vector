# Vector Optimization Log

This file tracks all optimization attempts made by the automated optimization loop.
Each entry documents what was tried, why, and whether it worked. This prevents
duplicate work across iterations.

## Format

Each entry follows this structure:
- **Date**: ISO timestamp
- **Hotspot**: What profiling identified as the bottleneck
- **Change**: What optimization was attempted
- **Result**: MERGED (with PR link) or REVERTED (with explanation)
- **Measurements**: Before/after throughput, CPU%, memory

## Cumulative Impact

Track total improvement across all merged optimizations:

| Metric | Baseline | Current Best | Total Improvement |
|--------|----------|-------------|-------------------|
| Max throughput (events/sec) | TBD | TBD | — |
| CPU per event (µs) | TBD | TBD | — |
| Memory RSS at 1k/s steady (Mi) | TBD | TBD | — |
| P99 latency (ms) | TBD | TBD | — |
| `cargo bench --bench remap` parse_json (ns/iter) | 518 | 345 | ~33.4% |
| `cargo bench --bench remap` add_fields (ns/iter) | 464 | 319 | ~31.3% |
| `cargo bench --bench remap` coerce (ns/iter) | 900 | 610 | ~32.2% |

Update this table after each successful optimization with the new "Current Best" value.
The baseline should be captured on the first iteration before any changes.

---

## Known Hotspots (from static analysis)

These are the areas identified as likely bottlenecks based on codebase analysis.
The auto-optimize loop should work through these roughly in priority order:

1. **Event cloning in remap transform** (`src/transforms/remap.rs:581-584`) — Full event clone before VRL execution when `drop_on_error + reroute_dropped`. Could use copy-on-write or checkpoint-rollback instead.
2. **JSON parsing via serde_json** (VRL `parse_json` stdlib) — Could benefit from simd-json. Called 1-3x per event.
3. **Token redaction regex applied to multiple fields** — encode_json + replace + parse_json round-trip in VRL config. Could be replaced with recursive field walker.
4. **BTreeMap for Value::Object** (VRL crate) — O(log n) lookup per field access. HashMap would give O(1).
5. **Fanout EventArray cloning** (`lib/vector-core/src/fanout.rs:303`) — Deep clone for N-1 sinks. Could use Arc<EventArray>.
6. **Arc::make_mut in VrlTarget::into_parts** — Forces deep clone when Arc refcount > 1.
7. **metrics-sanitizer for_each loops** — Regex on every tag key/value per metric.1 event.
8. **Size cache invalidation** (`log_event.rs:191`) — Invalidates on every mutation, even when size isn't queried.

---

## Iteration 1 — Optimize LogEvent::into_parts to avoid unnecessary Arc::make_mut

- **Date**: 2026-03-24T17:46:08Z
- **Hotspot**: `LogEvent::into_parts()` in `lib/vector-core/src/event/log_event.rs:277` — Called on every event in the remap transform hot path via `VrlTarget::new()`. Previously called `self.value_mut()` which invokes `Arc::make_mut()` + `invalidate()` before `Arc::try_unwrap()`, adding unnecessary overhead.
- **Change**: Replaced `value_mut()` + `Arc::try_unwrap().unwrap_or_else(unreachable)` with direct `Arc::try_unwrap()` + fallback field clone. When refcount==1 (common case), this skips the `Arc::make_mut` check and two atomic writes for size cache invalidation. When refcount>1, it clones only the `fields` Value instead of the full `Inner` struct + Arc allocation.
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/6
- **Measurements**:
  - `add_fields/remap`: 464 ns → 453 ns (~2.4% improvement)
  - `parse_json/remap`: 518 ns → 503 ns (~2.9% improvement, statistically significant p<0.05)
  - `coerce/remap`: 900 ns → 893 ns (~0.8% improvement)
- **Files Changed**: `lib/vector-core/src/event/log_event.rs`

## Iteration 2 — Reuse Arc allocation in VrlTarget via decompose/recompose

- **Date**: 2026-03-24T19:30:00Z
- **Hotspot**: `VrlTarget::new()` and `VrlTarget::into_events()` — the LogEvent decomposition/reconstruction round-trip. Previously, `into_parts()` called `value_mut()` (Arc::make_mut + invalidate + Arc::try_unwrap) to extract the Value, and `from_parts()` called `Arc::new(Inner::from(value))` to wrap it back. This allocated a new Arc on every event through the remap transform.
- **Change**: Added `LogEvent::decompose()` and `LogEvent::recompose()` methods that extract the Value from the Arc while keeping the Arc allocation alive (via `mem::replace` with a Null placeholder). After VRL execution, `recompose()` puts the mutated Value back into the same Arc using `Arc::get_mut()` — no new heap allocation needed. Introduced `LogEventResidual` opaque type to carry the Arc between decompose and recompose. Modified `VrlTarget::LogEvent` variant to store the residual and use it in `into_events()` for the common Object case.
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/7
- **Measurements**:
  - `add_fields/remap`: 465 ns → 319 ns (~31.4% improvement)
  - `parse_json/remap`: 500 ns → 345 ns (~31.1% improvement)
  - `coerce/remap`: 899 ns → 610 ns (~32.2% improvement)
  - All statistically significant (p < 0.05)
- **Files Changed**: `lib/vector-core/src/event/log_event.rs`, `lib/vector-core/src/event/vrl_target.rs`, `lib/vector-core/src/event/mod.rs`

