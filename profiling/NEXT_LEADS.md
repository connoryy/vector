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

## Priority 4: Value::estimated_json_encoded_size_of (1.23% E2E)

**Source**: E2E perf profile shows 1.23% in `estimated_json_encoded_size_of`.
**Potential**: This walks the entire Value tree. If called multiple times per event, caching the result could help. Already partially addressed by eager size cache in iter 10, but may still be called in other paths.
**E2E relevance**: Medium — directly visible in E2E profile.

## Priority 5: memcmp (4.60% E2E) — BTreeMap key comparison

**Source**: E2E perf profile shows `memcmp` at 4.60% + `memcmp$plt` at 1.00% = 5.60%.
**Analysis**: This is BTreeMap key comparison (KeyString is a string type). BTreeMap uses binary search which requires O(log n) comparisons per lookup. The keys are VRL field names like "message", "timestamp", "host".
**Challenge**: BTreeMap is in the external VRL crate. Would need upstream changes.
**Potential**: Short-string optimization or interned keys could reduce comparison cost.
**E2E relevance**: High — 5.60% of total E2E CPU.

## Dismissed

- **EventMetadata UUID generation**: Completed (iter 2). Lazy UUID.
- **Arc<Inner> caching**: Completed (iter 3). LazyLock DEFAULT_INNER.
- **BytesDeserializer direct construction**: Completed (iter 4). Direct LogEvent.
- **Dedupe build_cache_entry**: Low E2E impact — dedupe not in the E2E pipeline.
- **Arc::drop_slow**: Addressed indirectly by decompose/recompose (fewer Arc allocs).
- **AHash for log_schema_definitions**: Attempted iter 5a, reverted. Map too small (1-2 entries) for hash function to matter. 0% E2E impact.
- **Remove allocation-tracing from unix**: Attempted iter 5b, reverted. Relaxed atomic + branch prediction make the fast path zero-cost. Perf attribution misleading. 0% E2E impact.
- **GroupedTraceableAllocator overhead**: Investigated iter 5b — the 4.05% attributed by perf includes inlined jemalloc time. Actual wrapper overhead is zero on modern CPUs.
- **Batch-level schema definition resolution**: Attempted iter 5c, reverted. Pre-resolving schema definitions per-batch and eliminating per-event HashMap lookup + EventMutRef enum matching showed 0% E2E impact. The per-event metadata update overhead is negligible vs VRL execution and BTreeMap operations.
- **Definition::any() per-event allocation**: Completed (iter 6). Cached in static LazyLock, restructured metadata preparation to mutate in-place.
- **estimated_json_encoded_size_of running sum**: Investigated iter 6. Cache hits are already cheap (AtomicCell load); the O(n) iteration at send time is negligible. Expected impact <0.5%.
- **String::clone at 1.68%**: Investigated iter 6. Almost entirely in error paths and config-time code, not in the hot path. Filter, route, and throttle transforms are read-only (no string cloning).
- **Bytes shared_clone/shared_drop at 1.77%**: Investigated iter 6. Inherent to the `bytes` crate's atomic refcounting; most usage is in VRL internals. Cannot optimize without VRL crate changes.
