# Next Leads

Prioritized optimization opportunities for the next round of E2E-validated changes.
Focus on targets that will show measurable throughput improvement in the E2E Docker
benchmark (file → remap → filter → blackhole).

## Priority 1: BTreeMap operations in VRL Value (external crate)

**Source**: `vrl::value::value::crud::insert::insert` at 3.9% in codecs suite, `BTreeMap::insert` at 4.7%.
**Challenge**: The `Value` type lives in the external `vrl` crate. Changes would need to go upstream.
**Potential**: Replace `BTreeMap<KeyString, Value>` with `IndexMap` or `SmallVec`-based map for the Object variant. Or optimize Vector's call patterns to reduce insertions.
**E2E relevance**: High — every event goes through VRL parse_json which constructs a BTreeMap.

## Priority 2: CharacterDelimitedDecoder::decode hot loop

**Source**: 8-11% of codecs suite CPU. Processes ~75K frames per iteration.
**Potential**: Optimize framing loop, reduce per-frame `buf.split_to(idx).freeze()` overhead, batch event creation.
**E2E relevance**: Medium — the file source uses newline-delimited decoding in the E2E pipeline.

## Priority 3: Memory allocation pressure (systemic)

**Source**: `_xzm_free` at 15-19%, `_xzm_xzone_malloc` at 3-4% in event suite.
**Potential**: Pool/arena allocators for short-lived event processing, structural changes to reduce heap allocations.
**E2E relevance**: Medium — most individual allocation sites have been addressed; remaining overhead is diffuse.

## Priority 4: GroupedTraceableAllocator overhead

**Source**: ~12% of CPU in transform suite when allocation-tracing feature is enabled.
**Challenge**: This is instrumentation overhead. Disabling it changes production behavior.
**Potential**: Make the tracing wrapper truly zero-cost when `TRACK_ALLOCATIONS=false`.
**E2E relevance**: Low-Medium — this is already present in baseline, so optimizing it would help both.

## Dismissed

- **EventMetadata UUID generation**: Completed (iter 2). Lazy UUID.
- **Arc<Inner> caching**: Completed (iter 5). LazyLock DEFAULT_INNER + moved source_id/source_type out of Arc. +2.1% E2E (native).
- **BytesDeserializer direct construction**: Completed (iter 4). Direct LogEvent.
- **Dedupe build_cache_entry**: Low E2E impact — dedupe not in the E2E pipeline.
- **Arc::drop_slow**: Addressed indirectly by decompose/recompose (fewer Arc allocs).
