# Next Leads

<!-- Prioritized optimization opportunities for the next iteration. -->

## Priority 1: BTreeMap operations in VRL Value insert (external crate)

**Source**: Profiling shows `vrl::value::value::crud::insert::insert` at 3.9% in codecs suite, `BTreeMap::insert` at 4.7% in codecs. `BTreeMap::IntoIter::dying_next` at 3.1% in event suite.
**Challenge**: The Value type is in the external `vrl` crate, not this repo. Would need to submit changes upstream or fork.
**Potential**: Replace BTreeMap<KeyString, Value> with a faster map (IndexMap, small-vec map) for the Object variant. Or optimize call patterns in Vector to reduce insertions.
**Impact estimate**: High (dominates codecs and event benchmark profiles).
**Mutation analysis**: N/A — this is a data structure replacement, not a caching optimization. BTreeMap is always mutated (insert).

## Priority 2: GroupedTraceableAllocator overhead in benchmarks

**Source**: Iteration 3 profiling shows `GroupedTraceableAllocator::alloc` at 5.5-6.5% in transform/codecs suites, `GroupedTraceableAllocator::dealloc` at 2.3%, `pthread_getspecific` at 4.0%. Total ~12% of CPU in transform suite.
**Details**: The `allocation-tracing` feature is enabled by default (`default` → `enable-unix` → `unix` → `allocation-tracing`). Even with `TRACK_ALLOCATIONS=false` (the default), the wrapper adds function call overhead + layout computation on every alloc/dealloc. The `#[inline]` annotation doesn't help because `GlobalAlloc` dispatch isn't inlined.
**Potential**: This is an instrumentation overhead, not a production code issue. Options: (1) bypass the wrapper when tracing is disabled at compile time, (2) optimize the wrapper to be truly zero-cost when tracing is off. Note: disabling for benchmarks would give misleading comparisons vs production.
**File**: `src/internal_telemetry/allocations/allocator/tracing_allocator.rs`
**Impact estimate**: Medium-High in benchmarks, but changes affect production instrumentation fidelity.
**Mutation analysis**: N/A — this is a code path optimization, not a caching/sharing change.

## Priority 3: Dedupe build_cache_entry allocations

**Source**: Profiling shows `build_cache_entry` at 2.3-2.8% in transform suite.
**Details**: `build_cache_entry` allocates a Vec and calls `coerce_to_bytes()` on every field value on every event. For IgnoreFields mode, it also chains two iterators and does ConfigTargetPath::try_from per field.
**Potential**: Pre-allocate Vec with known capacity, avoid coerce_to_bytes by hashing values directly, cache field indices.
**File**: `src/transforms/dedupe/transform.rs:90-121`
**Impact estimate**: Medium (only affects dedupe transform benchmarks, 2.5% of transform suite CPU).
**Mutation analysis**: N/A — Vec and Bytes are created per-event, not cached. Optimization is to avoid allocations entirely (hash in-place).

## Priority 4: Memory allocation/deallocation overhead (systemic)

**Source**: In event suite: `_xzm_free` at 15.1-18.6%, `_xzm_xzone_malloc` at 3.2-3.7%, `_free` at 3.0-3.2%. Total ~22-26% on allocation/deallocation.
**Details**: This is the aggregate cost of all heap allocations. Individual optimizations (LazyLock, UUID skip, DEFAULT_INNER) chip away at this, but the overall allocation pressure from BTreeMap operations, Value cloning, and event creation remains high.
**Potential**: Pool allocator for events, arena allocation for short-lived event processing, or structural changes to reduce allocations.
**Impact estimate**: High aggregate, but requires identifying specific allocation sites (not a single optimization).

## Priority 5: Arc::drop_slow in codecs suite

**Source**: Iteration 3 profiling shows `Arc::drop_slow` at 3.3% in codecs suite.
**Details**: This is the cost of dropping `Arc`s when refcount reaches zero. With the DEFAULT_INNER optimization, some Arc drops are eliminated (shared reference stays alive), but many remain from LogEvent's own `Arc<Inner>` and from Value cloning.
**Potential**: Reduce the number of Arc allocations in the event creation/destruction path, or use a different ownership model.
**Impact estimate**: Medium (3.3% of codecs CPU).

## Priority 6: String::clone (KeyString) in codec decode path

**Source**: Iteration 5 profiling shows `String::clone` at 9.8% of codecs suite CPU (806/8232 samples).
**Details**: The `KeyString` type (used as BTreeMap keys in ObjectMap) is cloned frequently during event construction and value insertion. Each clone allocates a new heap string.
**Potential**: Use `Arc<str>` or interned strings for common field names ("message", "timestamp", etc.), or restructure the event data model to avoid per-event key cloning.
**Impact estimate**: Medium-High (9.8% of codecs CPU).
**Mutation analysis**: Keys are always cloned from source strings. Optimization would be to share or intern common strings.

## Priority 7: Event drop path overhead in codecs

**Source**: Iteration 5 profiling shows event destruction at ~39.5% of codecs CPU (3253/8232 samples across drop_in_place, BTreeMap::drop, Vec::drop, Arc::drop_slow).
**Details**: Each of the ~75K events per benchmark iteration requires full BTreeMap destruction (recursive key+value drop), Arc refcount decrement, and potential Inner deallocation. The drop path is the single largest CPU consumer.
**Potential**: Arena allocation for short-lived events (create all events in a bump arena, drop the arena at end instead of per-event drop). Or reduce the depth of the event structure (fewer nested Arcs/BTreeMaps).
**Impact estimate**: High (39.5% of codecs CPU combined), but extremely difficult to implement - requires fundamental changes to the event ownership model.
**Mutation analysis**: N/A — this is a structural issue with the event data model.

## Dismissed

### EventMetadata::default() UUID generation (was Priority 3)

**Reason**: Completed in Iteration 2. Set `source_event_id: None` instead of `Uuid::new_v4()`. Improvement: 3-43% across benchmarks. PR #19.

### EventMetadata::default() remaining Arc allocation (was Priority 4)

**Reason**: Completed in Iteration 3. Cached default `Arc<Inner>` in `LazyLock` static (`DEFAULT_INNER`). Improvement: 15-27% on codec benchmarks. PR #20.

### BytesDeserializer::parse_single indirect construction (was part of Priority 3)

**Reason**: Completed in Iteration 4. Construct LogEvent directly from pre-populated ObjectMap instead of `LogEvent::default()` + `maybe_insert()`. Cached message KeyString in LazyLock. Improvement: 10-23% on codec benchmarks. PR #21.

### Decoder CharacterDelimitedDecoder::decode hot loop (was Priority 3)

**Reason**: Completed in Iteration 5. Batch frame decoding with `memchr_iter` and callback-based `Decoder::decode_all()`. Improvement: 7.7-15.7% on codec benchmarks. PR #22.
