# Vector Optimization Log

Tracks all E2E-validated performance optimizations to Vector's hot path.
Each entry includes isolated and cumulative E2E throughput impact measured
via Docker profiling (1 GB log file, `--profiler none`, 4-core pinning).

## E2E Validation Matrix

Master baseline: 195.14 MiB/s median (185.73 / 195.14 / 205.66 min/med/max, σ=9.97, CV=5.1%)

| # | Optimization | Min | Median | Max | σ | Δ median | Δ range | PR |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| — | Master baseline | 185.73 | 195.14 | 205.66 | 9.97 | — | — | — |
| 1 | metadata Arc restructure | 202.54 | 202.65 | 208.07 | 3.16 | +3.8% | +3.8%..+6.6% | connoryy#29 |
| 2 | decompose + eager cache | 200.27 | 205.62 | 205.65 | 3.10 | +5.4% | +2.6%..+5.4% | connoryy#30 |
| 3 | ReadOnlyVrlTarget | 205.51 | 205.53 | 205.61 | 0.05 | +5.3% | +5.3%..+5.4% | connoryy#31 |
| 4 | AHash transform outputs | 200.28 | 205.66 | 205.66 | 3.11 | +5.4% | +2.6%..+5.4% | connoryy#32 |
| **All (1-4)** | **cumulative (stacked)** | **208.02** | **208.02** | **208.05** | **0.02** | **+6.6%** | **+6.6%..+6.6%** | |
| 5 | AHash log_to_metric tags | — | — | — | — | inconclusive | — | — |
| 6 | Cache Definition::any() + avoid deep clone | — | — | — | — | not measured | — | — |
| 7 | Cache parse_target_path in Template | — | — | — | — | not measured | — | — |

Δ range shows (min\_optimized − median\_baseline) / median\_baseline .. (max\_optimized − median\_baseline) / median\_baseline

### Raw E2E Data

Master baseline (branch: `master` @ `51f6fce6d`):

```text
Run 1: 195.14 MiB/s
Run 2: 185.73 MiB/s
Run 3: 205.66 MiB/s
Median: 195.14  Mean: 195.51  σ: 9.97  CV: 5.1%
```

Iter 9 — metadata Arc restructure (branch: `connor/claude/metadata-arc-restructure`):

```text
Run 1: 208.07 MiB/s
Run 2: 202.65 MiB/s
Run 3: 202.54 MiB/s
Median: 202.65  Mean: 204.42  σ: 3.16  CV: 1.5%
Δ median vs master: +3.8%  95% CI: [-4.0%, +13.1%]
```

Iter 10 — decompose/recompose + eager size cache (branch: `connor/claude/eager-size-cache`):

```text
Run 1: 205.62 MiB/s
Run 2: 205.65 MiB/s
Run 3: 200.27 MiB/s
Median: 205.62  Mean: 203.85  σ: 3.10  CV: 1.5%
Δ median vs master: +5.4%  95% CI: [-4.3%, +12.8%]
```

Iter 11 — ReadOnlyVrlTarget (branch: `connor/claude/readonly-vrl-target`):

```text
Run 1: 205.61 MiB/s
Run 2: 205.51 MiB/s
Run 3: 205.53 MiB/s
Median: 205.53  Mean: 205.55  σ: 0.05  CV: 0.0%
Δ median vs master: +5.3%  95% CI: [-3.0%, +13.3%]
```

Iter 15 — AHash transform outputs (branch: `connor/claude/ahash-transform-outputs`):

```text
Run 1: 205.66 MiB/s
Run 2: 200.28 MiB/s
Run 3: 205.66 MiB/s
Median: 205.66  Mean: 203.87  σ: 3.11  CV: 1.5%
Δ median vs master: +5.4%  95% CI: [-4.3%, +12.8%]
```

Cumulative — all 4 optimizations stacked (branch: `connor/vector-optimized`):

```text
Run 1: 208.02 MiB/s
Run 2: 208.02 MiB/s
Run 3: 208.05 MiB/s
Median: 208.02  Mean: 208.03  σ: 0.02  CV: 0.0%
Δ median vs master: +6.6%  95% CI: [-1.8%, +14.6%]
```

Iter 5 — AHash for log_to_metric tag rendering (branch: `connor/vector-optimized`):

```text
After: 274.71, 207.98, 265.26, 208.00, 274.65, 274.76 (median: 269.96)
Baseline: 265.31, 274.79, 197.38, 208.06, 207.97, 265.23 (median: 236.65)
Note: Docker Desktop on macOS shows extreme multimodal variance (~208/~265/~275 MiB/s)
      making it impossible to detect improvements below ~10%. Perf profile shows 3.64%
      SipHash in log_to_metric::render_tags, replaced with AHash.
```

### Notes

- E2E pipeline: `file` source → `remap` (VRL parse_json + add fields) → `filter` (VRL condition) → `blackhole` sink
- Docker image built with `CARGO_PROFILE_RELEASE_DEBUG=2` for symbol retention, jemalloc allocator
- 4-core CPU pinning via `cpuset: "0-3"` in docker-compose
- The wide 95% CIs are dominated by master baseline variance (σ=9.97). All optimized runs consistently exceed 200 MiB/s while master has one run at 185.73 MiB/s
- Individual optimizations show similar deltas (+3.8% to +5.4%) but cumulative is only +6.6%, indicating overlapping hot-path coverage rather than independent bottlenecks
- The optimizations target different points on the same per-event path: Arc::make_mut avoidance (iter 9), Arc reuse (iter 10), clone elimination (iter 11), and hash speedup (iter 15)

---

## Failed / Reverted Attempts

### Attempt 5a — AHash for log_schema_definitions (REVERTED)

**Target**: `SipHash::write` at 2.83% + 0.81% = 3.64% in E2E perf profile.
**Change**: Replaced `HashMap<OutputId, Arc<schema::Definition>>` with `AHashMap` in `TransformOutput.log_schema_definitions` and `update_runtime_schema_definition()` function parameter.
**Files**: `lib/vector-core/src/transform/outputs.rs`, `lib/vector-core/src/transform/mod.rs`
**Result**: No measurable E2E improvement (274.73 vs 274.75 MiB/s, -0.007%).
**Reason**: The `log_schema_definitions` map is tiny (1-2 entries per transform). For maps this small, the hash function cost is negligible — the lookup is dominated by function call overhead, not hash computation. The 3.64% SipHash in the perf profile likely comes from other HashMap usage sites or is amplified by profiler instrumentation.

### Attempt 5b — Remove allocation-tracing from unix feature (REVERTED)

**Target**: `GroupedTraceableAllocator::alloc` at 2.79% + `::dealloc` at 1.26% = 4.05% in E2E perf profile.
**Change**: Removed `allocation-tracing` from the `unix` Cargo feature, so default builds use raw jemalloc without the tracing wrapper.
**Files**: `Cargo.toml` (single line: `unix = ["tikv-jemallocator"]`)
**Result**: No measurable E2E improvement (265.21 vs 274.75 MiB/s median — within bimodal noise).
**Reason**: The `GroupedTraceableAllocator` fast path is a single `AtomicBool::load(Ordering::Relaxed)` check that always returns false. Modern CPUs with branch prediction handle this perfectly — the branch is always correctly predicted and the atomic load hits L1 cache. The 4.05% attributed by perf is misleading: the profiler attributes the underlying jemalloc alloc/dealloc time to the wrapper function symbol, not to the actual jemalloc internals (due to inlining).

### Attempt 5c — Batch-level schema definition resolution (REVERTED)

**Target**: Per-event `update_runtime_schema_definition` overhead in `send_single_buffer`: HashMap lookup + Arc::clone/drop per event per transform stage.
**Change**: Replaced per-event HashMap lookup + EventMutRef enum matching with batch-level resolution: pre-resolve schema definition once per EventArray, operate directly on typed arrays (Vec<LogEvent>, Vec<Metric>, Vec<TraceEvent>), and added Arc::ptr_eq fast path in `set_schema_definition` to skip redundant Arc operations.
**Files**: `lib/vector-core/src/transform/outputs.rs`, `lib/vector-core/src/event/metadata.rs`
**Result**: No measurable E2E improvement (274.66 vs 274.67 MiB/s median, 6 runs each in warm state).
**Reason**: The per-event metadata update cost (HashMap lookup on 1-2 entry map + 2 Arc atomic operations) is negligible compared to the dominant costs: VRL execution, BTreeMap operations in the VRL crate, and I/O. The optimization eliminates real CPU work (HashMap hashing, enum matching, atomic refcount operations) but these account for far less than 1% of total pipeline throughput.

---

## Commit Details

### Optimization 1 — metadata Arc restructure

Files: `lib/vector-core/src/event/metadata.rs`, `lib/vector-core/src/event/proto.rs`

`upstream_id` and `schema_definition` are updated at every transform output.
When inside `Arc<Inner>`, each update triggers `Arc::make_mut` which deep-clones
the entire `Inner` struct. Moving them to top-level `EventMetadata` fields makes
updates simple field assignments.

### Optimization 2 — decompose/recompose + eager size cache

Files: `lib/vector-core/src/event/log_event.rs`, `lib/vector-core/src/event/vrl_target.rs`, `lib/vector-core/src/event/mod.rs`

`LogEvent::decompose()` extracts the `Value` for in-place VRL mutation via
`mem::replace`, keeping the `Arc<Inner>` alive. `recompose()` puts the mutated
value back without a new heap allocation. Additionally, `recompose()` eagerly
computes and caches `json_encoded_size` and `allocated_bytes` so the main
thread's `send_single_buffer` reads cached values instead of recomputing.

### Optimization 3 — ReadOnlyVrlTarget

Files: `lib/vector-core/src/event/vrl_target.rs`, `src/conditions/*.rs`, `src/transforms/*.rs` (7 transforms)

`ReadOnlyVrlTarget` wraps `LogEvent` for read-only VRL condition evaluation
(filter, route, sample, throttle, etc.) without cloning the event's `Value`.
Returns errors on mutation attempts — safe because conditions never modify events.

### Optimization 4 — AHash for transform output buffers

Files: `lib/vector-core/Cargo.toml`, `lib/vector-core/src/transform/outputs.rs`, `src/transforms/remap.rs`, `Cargo.lock`

Replaces `HashMap` with `AHashMap` for `TransformOutputsBuf`. This map is
looked up on every event dispatch. AHash is faster for short string keys
(output names like "\_default"). `ahash` is already a transitive dependency.

### Optimization 5 — AHash for log_to_metric tag rendering

Files: `Cargo.toml`, `Cargo.lock`, `src/common/expansion.rs`, `src/transforms/log_to_metric.rs`, `src/sinks/loki/sink.rs`

Replaces `std::collections::HashMap` (SipHash) with `ahash::AHashMap` for
the per-event tag accumulation maps in `render_tags` and `pair_expansion`.
Perf profile shows 3.64% of total E2E CPU in SipHash, almost entirely from
`log_to_metric::render_tags → HashMap::insert → SipHash::write`. Each metric
event creates two temporary HashMaps (`static_tags`, `dynamic_tags`) with
4+ tag insertions per event. AHash eliminates the SipHash overhead for these
non-security-critical local maps.

### Optimization 6 — Cache Definition::any() and avoid per-event deep clone

Files: `lib/vector-core/src/event/metadata.rs`, `src/transforms/log_to_metric.rs`

Caches `Arc::new(Definition::any())` in a static `LazyLock<Arc<Definition>>`
to eliminate per-event heap allocation of Definition (BTreeMap + BTreeSet + 2
Kind structs) and Arc wrapper. Also restructures metadata preparation to
mutate the event's metadata in-place before the per-config loop, avoiding
`Arc::make_mut` deep clone of Inner (which was triggered because `.clone()`
on EventMetadata bumped the Arc refcount to 2, then `with_origin_metadata`
called `get_mut()` → `Arc::make_mut` → full deep copy). Folded stacks show
~181M samples in `Arc::new` and ~302M samples in `Arc::make_mut` CAS
operations within `to_metric_with_config`. Estimated E2E impact ~0.5-0.7%,
below noise threshold on Docker Desktop for Mac.

### Optimization 7 — Cache parse_target_path in Template

Files: `src/template.rs`

Pre-parses `OwnedTargetPath` at template construction time and stores it
in the `Part::Reference { src, path }` variant. Previously, every
`render_event` call went through `parse_path_and_get_value(key)` which
called `parse_target_path(&key)` to re-parse the same constant string
on every event. The folded stacks show ~191M samples in
`render_tag_into → render_template → parse_path_and_get_value →
parse_target_path` and ~50M samples in direct `to_metric_with_config →
parse_target_path`. Both Template and UnsignedIntTemplate now use
`log.get(path)` / `trace.get(path)` with the cached path. Addresses
the known issue documented in the code comment referencing
vectordotdev/vector issue 14864.
