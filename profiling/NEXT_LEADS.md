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

## Observation: Native macOS E2E runner is unreliable

The native macOS runner (no Docker, no CPU pinning) shows bimodal throughput
distributions (~208 MiB/s and ~265 MiB/s) with ~30% run-to-run variance.
This makes it impossible to reliably detect improvements below ~10%.
Future E2E validation should use the Docker-based runner with `cpuset` pinning,
or the native runner needs system-level isolation (e.g., `taskpolicy`, process
priority, background process management).

## Observation: Remaining per-event overhead is dominated by VRL execution

After optimizations 1-5, the remaining per-event overhead in the transform path
is dominated by VRL program execution (parse_json, field access, condition eval).
These live in the external `vrl` crate and cannot be optimized within Vector.
The schema definition updates, event metadata management, and output dispatch
are now fast (Arc clone, cached lookups, AHash). Further gains require either:
1. Upstream VRL optimization (BTreeMap → IndexMap, etc.)
2. Structural changes (batching, SIMD decoding, arena allocation)
3. Non-transform-path targets (file source I/O, sink batching)

## Dismissed

- **EventMetadata UUID generation**: Completed (iter 2). Lazy UUID.
- **Arc<Inner> caching**: Completed (iter 3). LazyLock DEFAULT_INNER.
- **BytesDeserializer direct construction**: Completed (iter 4). Direct LogEvent.
- **Dedupe build_cache_entry**: Low E2E impact — dedupe not in the E2E pipeline.
- **Arc::drop_slow**: Addressed indirectly by decompose/recompose (fewer Arc allocs).
- **Schema definition lookup**: Completed (iter 16/opt 5). Single-input fast path + AHash.
- **log_to_metric tag rendering**: Attempted (iter 5b). Pre-parsed field paths at config time. E2E showed +0.0% — tag rendering is not on the E2E critical path.
- **LatencyRecorder per-event histogram**: Analyzed. Could batch histogram updates but would change reported event counts. Low benefit vs semantic risk.
