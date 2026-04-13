# Next Leads

Prioritized optimization opportunities for the next round of E2E-validated changes.

**Current E2E baseline** (complex 16-transform pipeline with jemalloc):
- Master: ~205.65 MiB/s
- Optimized branch: ~207.97 MiB/s (+1.1%)
- Noise floor: ~±2 MiB/s (~1%), so optimizations need >2% to be reliably measurable

## Status: Plateau Reached

All remaining optimization targets of meaningful size (>1% CPU) require changes to
the **external VRL crate** or fundamental changes to the **Arc-based event model**.
Five consecutive attempts within Vector's codebase alone (iter 2a-2c, 3a) yielded 0%
E2E improvement. The 4 committed optimizations have captured all available gains within
the current architecture.

### Post-jemalloc CPU Profile (from previous session perf data)

| Category | % CPU | Status |
| --- | --- | --- |
| BTreeMap + memcmp (VRL crate) | 15.9% | Requires VRL crate change |
| Arc refcount atomics | 9.4% | Fundamental to event model |
| Value clone/drop (VRL crate) | 6.2% | Requires VRL crate change |
| String::clone / KeyString (VRL) | 2.03% | Requires VRL crate change |
| estimated_json_encoded_size_of | 1.25% | Already optimized (iter 2) |
| SipHash remaining | ~1% | Too small to measure |

## Priority 1: BTreeMap → faster map in VRL crate (EXTERNAL)

**Source**: `BTreeMap::insert` + `get_value` + `dying_next` + `insert_entry` = 10.4% of CPU.
`memcmp` for BTreeMap key comparisons = 5.5% of CPU. Combined: **15.9%**.
**What**: Replace `pub type ObjectMap = BTreeMap<KeyString, Value>` with `IndexMap<KeyString, Value, AHashBuilder>` in the VRL crate.
**Challenge**: BTreeMap provides ordered iteration; some code may depend on this. VRL is at `https://github.com/vectordotdev/vrl.git` (branch `main`).
**Potential E2E gain**: 5-10% (eliminates O(log n) tree traversal + memcmp, replaces with O(1) hash lookup).

## Priority 2: Arc refcount reduction (ARCHITECTURE)

**Source**: `__aarch64_ldadd8_rel` 5.08% + `__aarch64_ldadd8_relax` 3.55% + `__aarch64_cas8_acq` 0.74% = **9.4%**.
**What**: Reduce Arc clone/drop cycles per event. Main sources: fan-out cloning (topology edges with >1 consumer), per-transform `set_upstream_id(Arc::clone(output_id))`, LogEvent `Arc<Inner>` cloning.
**Challenge**: Arc is fundamental to LogEvent's COW semantics and the multi-consumer fan-out pattern. Any change affects the core data model.

## Priority 3: VRL Value clone/drop lifecycle (EXTERNAL)

**Source**: `clone_subtree` 2.41%, `Value::clone` 1.25%, `drop_in_place<Value>` 2.54% = **6.2%**.
**What**: Eliminate the reroute_dropped pre-VRL clone (requires VRL transactional execution for rollback on error). Or reduce Value clone cost via COW sub-trees.
**Challenge**: The clone is needed for correctness — VRL mutates in-place, so the original must be preserved for the error path.

## Dismissed

- **EventMetadata UUID generation**: Tested (iter 2a). 0% E2E improvement — already cheap.
- **Batch histogram recording**: Tested (iter 2b). 0% — blocked by metrics crate vtable.
- **jemalloc malloc_conf tuning**: Tested (iter 2c). 0% vs jemalloc defaults in Docker/VM.
- **Pre-resolved schema definitions**: Tested (iter 3a). 0% — 1-entry HashMap lookup is already ~5-8ns; savings too small vs BTreeMap/Arc overhead.
- **Memory allocation pressure**: Was 15-19% with system malloc. With jemalloc, reduced to ~10.4%. Further reduction requires VRL crate changes.
- **GroupedTraceableAllocator overhead**: Not relevant when `allocation-tracing` is disabled.
- **Remap backup clone**: Clone cost is <1% of throughput (1 BTreeMap entry at clone time).
- **Throttle template rendering**: Per-event cost too small relative to total pipeline.
- **VRL del(.) optimization**: External crate change needed.
- **Arc<Program> sharing**: Tested in previous session. 0% — jemalloc tcache handles AST clone cost efficiently.
- **TransformOutputsBuf outputs_spec clone**: Tested in previous session. 0% — per-batch, not per-event.
- **AHash for log_schema_definitions + cached lookups**: Tested in previous session. REGRESSED -11.89% — 1-entry map too small for AHash benefit, caching machinery added branch misprediction overhead.
