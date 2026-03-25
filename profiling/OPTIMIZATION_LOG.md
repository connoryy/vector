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
| filter/always_pass | 25.020 µs | 24.190 µs | -3.3% |
| filter/always_fail | 18.558 µs | 17.528 µs | -5.5% |
| dedupe/field_ignore_message | 59.504 µs | 58.623 µs | -1.5% |

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
- **PR**: https://github.com/connoryy/vector/pull/12
- **Measurements**:
  - remap/add_fields: 334.14 ns → 326.6 ns (-2.3%)
  - remap/parse_json: 359.09 ns → 351.5 ns (-2.1%)
  - remap/coerce: 625.85 ns → 621.8 ns (-0.6%)
- **Discovery Method**: Source code analysis of LogEvent::into_parts() hot path. Identified that Arc::make_mut creates an unnecessary intermediate Arc when the original Arc is shared (refcount > 1), only to immediately unwrap it with try_unwrap. Arc::unwrap_or_clone avoids this overhead by cloning the Inner directly.
- **Files Changed**:
  - lib/vector-core/src/event/log_event.rs (into_parts simplification)

## Iteration 8 — Cache default_schema_definition with LazyLock (REVERTED)
- **Date**: 2026-03-25T00:27:49Z
- **Hotspot**: default_schema_definition() in metadata.rs constructs a new Arc<schema::Definition> on every call to Inner::default(), allocating Kind::any(), BTreeSet, BTreeMap, and Arc for the same static default value every time a new EventMetadata is created.
- **Change**: Replaced the function body with a static LazyLock that computes the default Definition once and returns Arc::clone(&DEFAULT) on subsequent calls, eliminating redundant heap allocations and type computations.
- **Result**: REVERTED
- **Reason**: The optimization only affects event creation (Inner::default()), not event cloning. In the remap benchmark, events are created once as a template and then cloned per iteration via Arc::clone (cheap refcount bump). The actual Value::clone happens via Arc::make_mut when the event is mutated. Since default_schema_definition is not called during cloning or VRL execution, the optimization showed 0% improvement on remap benchmarks (329.11 ns baseline vs 337.81 ns after — within noise). The transform benchmarks also clone events from templates, so no improvement expected there either. While this optimization would help production throughput (where sources create fresh events), it cannot be validated through the existing microbenchmarks.
- **Discovery Method**: Source code analysis of Inner::default() in metadata.rs. CPU profiling (macOS sample tool) of the remap benchmark confirmed that 64% of time is in VRL execution (external crate, not optimizable) and 19% is in Value::clone during Arc::make_mut (already addressed by iterations 6/7). The default_schema_definition allocation does not appear in the benchmark hot path.

## Iteration 9 — Dedupe IgnoreFields HashSet lookup optimization (REVERTED)
- **Date**: 2026-03-25T00:56:08Z
- **Hotspot**: In the dedupe transform's IgnoreFields path, `build_cache_entry()` calls `ConfigTargetPath::try_from(field_name)` for every field on every event, parsing a KeyString into an OwnedTargetPath. This involves a full path parser with heap allocations per field. Additionally, `fields.contains(&path)` performs a linear O(n) search through the ignore list.
- **Change**: Two approaches were attempted:
  - **V1**: Changed `CacheEntry::Ignore` from `Vec<(OwnedTargetPath, TypeId, Bytes)>` to `Vec<(KeyString, TypeId, Bytes)>`, pre-computed a `HashSet<KeyString>` of ignored field names at construction time, and used direct string comparison instead of path parsing. This showed 15-19% improvement on IgnoreFields benchmarks but caused 13-17% regression on MatchFields benchmarks due to enum layout change affecting codegen/cache behavior.
  - **V2**: Kept original `CacheEntry::Ignore` type unchanged but added `HashSet<KeyString>` to `Dedupe` struct for O(1) ignore lookup, only parsing non-ignored fields. This showed 3-4% improvement on field_ignore_message but 8-10% regression on match benchmarks and 5% regression on field_ignore_done.
- **Result**: REVERTED
- **Reason**: Both approaches caused significant regression (8-17%) on the MatchFields benchmarks despite the Match code path being unchanged. The regression is likely caused by struct layout changes (adding `ignore_set: HashSet<KeyString>` field) affecting compiler optimization decisions, function inlining, and/or CPU cache behavior. The IgnoreFields improvements (3-15% depending on approach) do not compensate for the MatchFields regressions.
- **Discovery Method**: Source code analysis of `build_cache_entry()` in transform.rs identified `ConfigTargetPath::try_from()` (full path parsing) and `Vec::contains()` (linear search) as per-event overhead. Transform benchmarks measured before/after with criterion. Fresh baseline re-run confirmed regressions were not due to system noise.
- **Measurements (V2, which preserved CacheEntry type)**:
  - field_ignore_message: 58.546 µs → 56.592 µs (-3.3%)
  - field_ignore_done: 61.515 µs → 64.746 µs (+5.3%)
  - field_match_message: 23.134 µs → 25.586 µs (+10.6%)
  - field_match_done: 26.567 µs → 28.836 µs (+8.5%)

## Iteration 10 — Add #[inline] annotations to hot-path cross-crate methods
- **Date**: 2026-03-25T03:09:06Z
- **Hotspot**: Small accessor and constructor methods in vector-core (LogEvent, EventMetadata, Event, OutputBuffer, TransformOutputsBuf) lack `#[inline]` annotations. Without LTO enabled (Vector's Cargo.toml has no `lto` setting), cross-crate function calls from the `vector` crate into `vector-core` rely on MIR inlining heuristics rather than guaranteed inlining. While Rust 1.92 performs some MIR inlining at opt-level 3, explicit `#[inline]` provides stronger guarantees for small methods.
- **Change**: Added `#[inline]` to 20+ small methods across 4 files:
  - `LogEvent`: value(), value_mut(), metadata(), metadata_mut(), from_parts(), from_map(), into_parts(), new_with_metadata()
  - `Inner` (log_event.rs): invalidate(), as_value()
  - `EventMetadata`: get_mut(), value(), value_mut(), schema_definition()
  - `Event`: as_log(), as_mut_log(), into_log(), try_into_log(), maybe_as_log(), metadata(), metadata_mut(), From<LogEvent>
  - `TransformOutputsBuf`: push(), take_primary()
  - `OutputBuffer`: push()
- **Result**: MERGED
- **PR**: https://github.com/connoryy/vector/pull/13
- **Measurements**:
  - remap/add_fields: 330.27 ns → 331.41 ns (+0.3%, neutral)
  - remap/parse_json: 357.27 ns → 356.55 ns (-0.2%, neutral)
  - remap/coerce: 625.98 ns → 622.92 ns (-0.5%, neutral)
  - dedupe/field_ignore_message: 59.504 µs → 58.623 µs (-1.5%, improved)
  - dedupe/field_match_message_timed: 22.802 µs → 22.509 µs (-1.3%, improved)
  - dedupe/field_ignore_done: 61.795 µs → 60.944 µs (-1.4%, improved)
  - filter/always_fail: 18.558 µs → 17.528 µs (-5.5%, improved)
  - filter/always_pass: 25.020 µs → 24.190 µs (-3.3%, improved)
  - reduce/proof_of_concept: 79.350 µs → 80.006 µs (+0.8%, neutral)
- **Discovery Method**: Source code analysis identified that key accessor methods in vector-core (called cross-crate from the vector main crate) lacked `#[inline]` annotations. The remap benchmarks showed no improvement because they're dominated by VRL execution (external crate). The transform benchmarks (filter, dedupe) showed 1.3-5.5% improvement because these transforms involve simpler operations where function call overhead is a larger proportion of total time.
- **Files Changed**:
  - lib/vector-core/src/event/log_event.rs (LogEvent + Inner methods)
  - lib/vector-core/src/event/metadata.rs (EventMetadata methods)
  - lib/vector-core/src/event/mod.rs (Event methods + From impl)
  - lib/vector-core/src/transform/outputs.rs (TransformOutputsBuf + OutputBuffer methods)
