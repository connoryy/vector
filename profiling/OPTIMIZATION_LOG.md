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
| **All** | **cumulative (stacked)** | **208.02** | **208.02** | **208.05** | **0.02** | **+6.6%** | **+6.6%..+6.6%** | |

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

### Notes

- E2E pipeline: `file` source → `remap` (VRL parse_json + add fields) → `filter` (VRL condition) → `blackhole` sink
- Docker image built with `CARGO_PROFILE_RELEASE_DEBUG=2` for symbol retention, jemalloc allocator
- 4-core CPU pinning via `cpuset: "0-3"` in docker-compose
- The wide 95% CIs are dominated by master baseline variance (σ=9.97). All optimized runs consistently exceed 200 MiB/s while master has one run at 185.73 MiB/s
- Individual optimizations show similar deltas (+3.8% to +5.4%) but cumulative is only +6.6%, indicating overlapping hot-path coverage rather than independent bottlenecks
- The optimizations target different points on the same per-event path: Arc::make_mut avoidance (iter 9), Arc reuse (iter 10), clone elimination (iter 11), and hash speedup (iter 15)

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
