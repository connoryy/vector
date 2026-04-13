# Next Leads

Prioritized optimization opportunities for the next round of E2E-validated changes.

**Current E2E baseline** (complex 16-transform pipeline with jemalloc):
- Master: ~205.65 MiB/s
- Optimized branch: ~207.97 MiB/s (+1.1%)
- Noise floor: ~±2 MiB/s (~1%), so optimizations need >2% to be reliably measurable

## Critical: Re-profile with jemalloc

The profiling data in the dismissed/priority sections below was collected with **system malloc**,
not jemalloc. With jemalloc enabled, the hot-path profile will be different — allocation
overhead drops from 15-19% to much less, which will reveal the actual bottlenecks.

**Action needed**: Run a fresh perf profile with the `unix` feature enabled to identify
the real top-of-profile functions with jemalloc as the allocator.

## Priority 1: BTreeMap operations in VRL Value (external crate)

**Source**: `vrl::value::value::crud::insert::insert` at 3.9% in codecs suite, `BTreeMap::insert` at 4.7%.
**Challenge**: The `Value` type lives in the external `vrl` crate. Changes would need to go upstream.
**Potential**: Replace `BTreeMap<KeyString, Value>` with `IndexMap` or `SmallVec`-based map for the Object variant. Or optimize Vector's call patterns to reduce insertions.
**E2E relevance**: High — every event goes through VRL parse_json which constructs a BTreeMap.
**Status**: Still the highest-priority code-level optimization, and likely MORE impactful relative
to other costs now that allocation overhead is reduced.

## Priority 2: CharacterDelimitedDecoder::decode hot loop

**Source**: 8-11% of codecs suite CPU. Processes ~75K frames per iteration.
**Potential**: Optimize framing loop, reduce per-frame `buf.split_to(idx).freeze()` overhead, batch event creation.
**E2E relevance**: Medium — the file source uses newline-delimited decoding in the E2E pipeline.

## Priority 3: Per-event schema definition HashMap lookup

**Source**: `update_runtime_schema_definition` in `lib/vector-core/src/transform/mod.rs` does
a `HashMap<OutputId, Arc<Definition>>` lookup per event at every transform output.
**Potential**: Pre-compute single definition shortcut when HashMap has ≤1 entry (common case).
Skip the HashMap lookup entirely, replacing with a direct Arc pointer write.
**E2E relevance**: Medium — called 16× per event in the complex pipeline. But each lookup is
O(1) amortized, so the per-call cost is small (~5-10ns).

## Priority 4: Reduce per-event telemetry overhead

**Source**: Each transform output records latency histogram (`LatencyRecorder::on_send`) and
events-received counters via the `metrics` crate. Each `histogram.record()` call does
3 atomic operations through vtable dispatch.
**Challenge**: The `metrics` crate's `Arc<dyn HistogramFn>` vtable prevents batch optimization
(the `record_many` default loops per-event). Would need upstream crate changes or bypassing
the `metrics` crate.
**E2E relevance**: Low-Medium — with 16 transforms × ~1M events/sec, this is ~48M atomic
operations/sec, but atomics are fast on modern CPUs.

## Dismissed

- **EventMetadata UUID generation**: Tested (iter 2a). 0% E2E improvement — already cheap.
- **Batch histogram recording**: Tested (iter 2b). 0% — blocked by metrics crate vtable.
- **jemalloc malloc_conf tuning**: Tested (iter 2c). 0% vs jemalloc defaults in Docker/VM.
- **Memory allocation pressure**: Was 15-19% with system malloc. With jemalloc, this is
  dramatically reduced. Re-profile needed to quantify remaining allocation overhead.
- **GroupedTraceableAllocator overhead**: Not relevant when `allocation-tracing` is disabled
  (which it is in the E2E build without the full `unix` feature set).
- **Remap backup clone**: Investigated — clone cost is <1% of throughput for the E2E pipeline
  (each event has only 1 BTreeMap entry at clone time, ~50ns per event).
- **Throttle template rendering**: Per-event BTreeMap lookup + string allocation (~1-2µs),
  but throttle is only one of 16 transforms and has high pass-through rate.
- **VRL del(.) optimization**: External crate change needed, can't optimize from Vector side.
