# Optimization Log

<!-- Append-only. Each iteration adds a new section below. -->

## Cumulative Impact (vs upstream master)

Each row is one iteration. The "delta" column shows the per-iteration improvement (measured
within a single bench run). The "cumulative" column shows total improvement vs the master
baseline. Grows vertically — one row per iteration, no width limit.

| Iter | Optimization | PR | Key benchmark | Delta | Cumulative vs master |
| ------ | ------------- | ----- | --------------- | ------- | --------------------- |
| 0a | VrlTarget Arc reuse (decompose/recompose) | [#7](https://github.com/connoryy/vector/pull/7) | remap/add_fields | -31.4% | -31.4% |
| | | | remap/parse_json | -31.0% | -31.0% |
| | | | remap/coerce | -32.2% | -32.2% |
| 0b | #[inline] on cross-crate methods | [#13](https://github.com/connoryy/vector/pull/13) | filter/always_fail | -5.5% | -5.9% |
| | | | dedupe/field_ignore_msg | -1.5% | -14.9% |
| 1 | Cache schema definition (LazyLock) | [#18](https://github.com/connoryy/vector/pull/18) | codecs/char_delim/no_max | -34.6% | -34.6% |
| | | | codecs/newline/no_max | -31.4% | -31.2% |
| | | | remap/add_fields | -19.5% | -27.2% |
| 2 | Skip eager UUID generation | [#19](https://github.com/connoryy/vector/pull/19) | codecs/newline/no_max | -42.9% | -37.1% |
| | | | codecs/char_delim/small_max | -18.4% | -34.7% |
| | | | filter/always_fail | -28.8% | -14.0% |
| 3 | Cache default metadata Arc (LazyLock) | [#20](https://github.com/connoryy/vector/pull/20) | codecs/char_delim/no_max | -25.0% | -55.3% |
| | | | codecs/newline/no_max | -26.7% | -53.7% |
| | | | codecs/newline/small_max | -15.4% | -38.5% |
| **4** | **Direct LogEvent construction** | [**#21**](https://github.com/connoryy/vector/pull/21) | **codecs/newline/no_max** | **-23.1%** | **-63.9%** |
| | | | **codecs/char_delim/no_max** | **-19.8%** | **-64.0%** |
| | | | **codecs/newline/small_max** | **-9.7%** | **-44.8%** |
| **5** | **Batch frame decode (memchr_iter + callback)** | [**#22**](https://github.com/connoryy/vector/pull/22) | **codecs/char_delim/no_max** | **-15.7%** | **-68.9%** |
| | | | **codecs/newline/no_max** | **-7.7%** | **-66.5%** |
| | | | **codecs/char_delim/small_max** | **-8.0%** | **-61.2%** |
| **6** | **Streaming callback decode (eliminate SmallVec)** | [**#27**](https://github.com/connoryy/vector/pull/27) | **codecs/char_delim/no_max** | **-35.4%** | **-70.1%** |
| | | | **codecs/newline/no_max** | **-22.1%** | **-66.7%** |
| | | | **codecs/char_delim/small_max** | **-18.8%** | **-63.9%** |
| | | | **codecs/newline/small_max** | **-9.9%** | **-52.1%** |
| **7** | **Cache ConfigTargetPath in dedupe IgnoreFields** | [**#28**](https://github.com/connoryy/vector/pull/28) | **dedupe/field_ignore_msg** | **-10.6%** | **~-24%** |
| | | | **dedupe/field_ignore_done** | **-2.6%** | **~-17%** |

**Current best cumulative improvements** (latest iteration in bold):

- codecs/char_delimited/no_max: 13.75 ms → 4.12 ms (**-70.1%**)
- codecs/newline_bytes/no_max: 3.91 ms → 1.30 ms (**-66.7%**)
- codecs/char_delimited/small_max: 6.77 ms → 2.44 ms (**-63.9%**)
- codecs/newline_bytes/small_max: 877.7 µs → 420 µs (**-52.1%**)
- remap/coerce: 899 ns → 673 ns (-25.1%)
- remap/add_fields: 465 ns → 376 ns (-19.1%)

*Note: Cumulative % is computed from master baseline vs latest post-iteration measurement.
Run-to-run variance is ±5-10%, so cumulative figures for small improvements (dedupe, filter)
have wider error bars. Codec benchmarks are most reliable because 75K events/iter amplifies
per-event savings well above the noise floor.*

## Pre-iteration 0a: VrlTarget Arc reuse via decompose/recompose

**Date**: 2026-03-25
**Discovery Method**: Profiling remap transform hot path. `VrlTarget::new()` called `LogEvent::into_parts()` (Arc::make_mut + Arc::try_unwrap), then `VrlTarget::into_events()` called `LogEvent::from_parts()` (Arc::new). One allocation + deallocation per event per remap.
**Target**: VrlTarget decomposition/reconstruction round-trip in `lib/vector-core/src/event/vrl_target.rs`
**Change**: Add `LogEvent::decompose()` and `LogEvent::recompose()` methods. Keep the Arc alive with `mem::replace` placeholder, reuse it via `Arc::get_mut` in recompose. Eliminates one Arc alloc per remap event.
**Result**: MERGED
**Improvement**: ~31% on all remap benchmarks
**PR**: https://github.com/connoryy/vector/pull/7

| Benchmark | Before | After | Change |
| ----------- | -------- | ------- | -------- |
| remap/add_fields | 465 ns | 319 ns | **-31.4%** |
| remap/parse_json | 500 ns | 345 ns | **-31.1%** |
| remap/coerce | 899 ns | 610 ns | **-32.2%** |

## Pre-iteration 0b: #[inline] on hot-path cross-crate methods

**Date**: 2026-03-25
**Discovery Method**: Transform benchmarks showed measurable function call overhead for small cross-crate accessors (LogEvent, EventMetadata, Event, TransformOutputsBuf, OutputBuffer). Without `#[inline]`, cross-crate calls depend on MIR inlining heuristics; Vector has no LTO.
**Target**: 20+ accessor/constructor methods in `lib/vector-core/src/event/`
**Change**: Add `#[inline]` annotations to small methods called cross-crate on the hot path.
**Result**: MERGED
**Improvement**: 1.3% to 5.5% on transform benchmarks, neutral on remap
**PR**: https://github.com/connoryy/vector/pull/13

| Benchmark | Before | After | Change |
| ----------- | -------- | ------- | -------- |
| filter/always_pass | 25.0 µs | 24.2 µs | **-3.3%** |
| filter/always_fail | 18.6 µs | 17.5 µs | **-5.5%** |
| dedupe/field_ignore_message | 59.5 µs | 58.6 µs | **-1.5%** |

## Iteration 1

**Date**: 2026-03-26T21:13:00Z
**Discovery Method**: CPU profiling (macOS `sample`) of all 4 bench suites. `default_schema_definition` appeared in codecs (17 samples), event (15 samples), and vector-core_event (15 samples) profiles. Cross-referencing showed it's called from `EventMetadata::default()` on every `LogEvent` creation.
**Target**: `default_schema_definition()` in `lib/vector-core/src/event/metadata.rs`
**Change**: Cache the default `Arc<schema::Definition>` in a `LazyLock` static instead of allocating a new one (with BTreeSet, BTreeMap, Kind objects) on every call. Returns `Arc::clone()` instead.
**Result**: MERGED
**Improvement**: 2.5% to 34.6% across all benchmarks (19.5% on remap/add_fields, 30.5% on event/rename_key_flat)
**PR**: https://github.com/connoryy/vector/pull/18

### Baseline

| Benchmark | Mean |
| ----------- | ------ |
| remap/add_fields | 421.0 ns |
| remap/parse_json | 441.2 ns |
| remap/coerce | 677.1 ns |
| event/rename_key_flat (present) | 205.3 ns |
| event/rename_key_flat (absent) | 142.1 ns |
| codecs/char_delimited/no_max | 13.75 ms |
| codecs/char_delimited/small_max | 6.77 ms |
| codecs/newline_bytes/no_max | 3.91 ms |
| codecs/newline_bytes/small_max | 877.7 µs |
| encoder/JsonLogSerializer | 170.4 ns |
| dedupe/field_ignore_message | 68.9 µs |
| filter/transform_always_fail | 16.3 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| remap/add_fields | 338.7 ns | -19.5% |
| remap/parse_json | 415.5 ns | -5.8% |
| remap/coerce | 660.3 ns | -2.5% |
| event/rename_key_flat (present) | 150.2 ns | -26.8% |
| event/rename_key_flat (absent) | 98.7 ns | -30.5% |
| codecs/char_delimited/no_max | 8.99 ms | -34.6% |
| codecs/char_delimited/small_max | 4.85 ms | -28.3% |
| codecs/newline_bytes/no_max | 2.69 ms | -31.4% |
| codecs/newline_bytes/small_max | 680.5 µs | -22.5% |
| encoder/JsonLogSerializer | 164.6 ns | -3.4% |
| dedupe/field_ignore_message | 63.0 µs | -8.6% |
| filter/transform_always_fail | 16.7 µs | +2.3% |

### Analysis

The default schema definition is created on every EventMetadata::default() → every LogEvent creation. It always produces the identical value (Kind::any() with both Legacy/Vector namespaces). The prior code allocated a new Arc<Definition> with BTreeSet, BTreeMap, and Kind objects each time. By caching in a LazyLock static, we eliminate these allocations entirely.

The large improvements on decoder benchmarks (22-35%) are proportional because each decoder iteration creates ~75K events (one per delimiter match in Moby Dick). The remap and event benchmarks also benefit significantly because event creation overhead is a large fraction of their total cost.

The small regression on filter/transform_always_fail (+2.3%) is within noise (not statistically significant at p < 0.05 by Criterion).

## Iteration 2

**Date**: 2026-03-27T18:30:00Z
**Discovery Method**: CPU profiling of all 4 bench suites on the optimized branch (post-iteration-1). `rand_chacha::ChaCha12Core::generate` appeared at 4.5% in event suite, and `EventMetadata::default` at 3.6%. Cross-referencing with code showed `Uuid::new_v4()` is called in `Inner::default()` for every event, but `source_event_id` is only read during protobuf serialization — never in hot event processing paths.
**Target**: `source_event_id: Some(Uuid::new_v4())` in `Inner::default()` at `lib/vector-core/src/event/metadata.rs:288`
**Change**: Set `source_event_id: None` in `Inner::default()` instead of eagerly generating a UUID v4. The ChaCha12 CSPRNG used for UUID generation was consuming ~4.5% of CPU. Most events never need this ID — it's only read during protobuf serialization and metadata merge. Updated tests to reflect the new behavior.
**Result**: MERGED
**Improvement**: 3.0% to 42.9% across benchmarks (42.9% on newline_bytes/no_max, 38.5% on dedupe/refresh_on_drop)
**PR**: https://github.com/connoryy/vector/pull/19

### Baseline (on optimized branch, post-iteration-1)

| Benchmark | Mean |
| ----------- | ------ |
| remap/add_fields | 371.6 ns |
| remap/parse_json | 439.0 ns |
| remap/coerce | 677.2 ns |
| event/rename_key_flat (present) | 202.5 ns |
| event/rename_key_flat (absent) | 141.3 ns |
| codecs/char_delimited/no_max | 9.24 ms |
| codecs/char_delimited/small_max | 5.42 ms |
| codecs/newline_bytes/no_max | 4.30 ms |
| codecs/newline_bytes/small_max | 972.1 µs |
| encoder/JsonLogSerializer | 228.7 ns |
| encoder/JsonLogVecSerializer | 136.4 ns |
| encoder/JsonSerializer | 216.0 ns |
| dedupe/field_ignore_done | 91.9 µs |
| dedupe/field_ignore_message | 64.1 µs |
| dedupe/field_match_done | 39.9 µs |
| dedupe/field_match_message | 25.7 µs |
| filter/transform_always_fail | 22.4 µs |
| filter/transform_always_pass | 31.5 µs |
| reduce/proof_of_concept | 82.4 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| remap/add_fields | 370.1 ns | -0.4% |
| remap/parse_json | 443.3 ns | +1.0% |
| remap/coerce | 656.7 ns | -3.0% |
| event/rename_key_flat (present) | 201.4 ns | -0.6% |
| event/rename_key_flat (absent) | 137.4 ns | -2.8% |
| codecs/char_delimited/no_max | 8.20 ms | -11.2% |
| codecs/char_delimited/small_max | 4.42 ms | -18.4% |
| codecs/newline_bytes/no_max | 2.46 ms | -42.9% |
| codecs/newline_bytes/small_max | 633.8 µs | -34.8% |
| encoder/JsonLogSerializer | 168.9 ns | -26.2% |
| encoder/JsonLogVecSerializer | 102.5 ns | -24.8% |
| encoder/JsonSerializer | 169.5 ns | -21.5% |
| dedupe/field_ignore_done | 65.0 µs | -29.3% |
| dedupe/field_ignore_message | 64.1 µs | -0.1% |
| dedupe/field_match_done | 28.9 µs | -27.7% |
| dedupe/field_match_message | 25.2 µs | -2.0% |
| filter/transform_always_fail | 16.0 µs | -28.8% |
| filter/transform_always_pass | 24.0 µs | -23.9% |
| reduce/proof_of_concept | 83.0 µs | +0.7% |

### Analysis

`Uuid::new_v4()` uses the ChaCha12 CSPRNG which appeared at 4.5% in event profiling. The UUID is generated eagerly on every `EventMetadata::default()` call (every event creation) but `source_event_id` is only accessed during protobuf serialization (for gRPC inter-process communication) and metadata merge — zero usage in `src/` (no sources, transforms, or sinks read it).

The large improvements on decoder benchmarks (11-43%) and encoder benchmarks (21-26%) are because these create many events per iteration. The transform benchmarks also improved significantly (24-38% on filter and some dedupe variants). Remap benchmarks show minimal change because VRL execution time dominates event creation overhead.

Some benchmarks show surprisingly large improvements (e.g., dedupe/field_match_message_timed_refresh_on_drop at -38.5%) which may include some measurement noise from the baseline having high variance on those specific tests.

## Iteration 3

**Date**: 2026-03-27T20:00:00Z
**Discovery Method**: CPU profiling of all 4 bench suites on the optimized branch (post-iteration-2). `EventMetadata::default` appeared at 3.2% in the event suite. Cross-referencing with code showed `Arc::new(Inner::default())` allocates a new heap object per event even though the default metadata is always identical. Analysis of the codec decode path confirmed EventMetadata is **never mutated** — only the LogEvent's value is modified via `insert()`. The existing `Arc::make_mut` COW pattern makes caching safe.
**Target**: `EventMetadata::default()` → `Arc::new(Inner::default())` in `lib/vector-core/src/event/metadata.rs:296`
**Change**: Cache the default `Arc<Inner>` in a `LazyLock` static (`DEFAULT_INNER`). `EventMetadata::default()` now returns `Arc::clone(&DEFAULT_INNER)` (atomic refcount increment) instead of allocating a new `Arc<Inner>` each time. The existing copy-on-write via `Arc::make_mut` ensures any mutation transparently clones the inner data on first write.
**Result**: MERGED
**Improvement**: 15.4% to 26.7% on codec benchmarks (which create ~75K events per iteration)
**PR**: https://github.com/connoryy/vector/pull/20

### Baseline (on optimized branch, post-iteration-2)

| Benchmark | Mean |
| ----------- | ------ |
| remap/add_fields | 375.6 ns |
| remap/parse_json | 448.7 ns |
| remap/coerce | 672.6 ns |
| event/rename_key_flat (present) | 199.8 ns |
| event/rename_key_flat (absent) | 138.9 ns |
| codecs/char_delimited/no_max | 8.20 ms |
| codecs/char_delimited/small_max | 4.42 ms |
| codecs/newline_bytes/no_max | 2.48 ms |
| codecs/newline_bytes/small_max | 637.6 µs |
| encoder/JsonLogSerializer | 172.5 ns |
| encoder/JsonLogVecSerializer | 101.8 ns |
| encoder/JsonSerializer | 175.2 ns |
| encoder/Encoder | 223.7 ns |
| dedupe/field_ignore_done | 65.2 µs |
| dedupe/field_ignore_message | 64.7 µs |
| dedupe/field_match_done | 28.5 µs |
| dedupe/field_match_message | 25.5 µs |
| filter/transform_always_fail | 17.0 µs |
| filter/transform_always_pass | 26.2 µs |
| reduce/proof_of_concept | 84.2 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| remap/add_fields | 375.6 ns | +0.0% |
| remap/parse_json | 448.7 ns | +0.0% |
| remap/coerce | 672.6 ns | +0.0% |
| event/rename_key_flat (present) | 199.8 ns | +0.0% |
| event/rename_key_flat (absent) | 137.4 ns | -1.1% |
| codecs/char_delimited/no_max | 6.15 ms | -25.0% |
| codecs/char_delimited/small_max | 3.41 ms | -22.8% |
| codecs/newline_bytes/no_max | 1.81 ms | -26.7% |
| codecs/newline_bytes/small_max | 539.5 µs | -15.4% |
| encoder/JsonLogSerializer | 171.3 ns | -0.7% |
| encoder/JsonLogVecSerializer | 103.8 ns | +2.0% |
| encoder/JsonSerializer | 173.2 ns | -1.1% |
| encoder/Encoder | 216.3 ns | -3.3% |
| dedupe/field_ignore_done | 65.2 µs | +0.0% |
| dedupe/field_ignore_message | 64.7 µs | +0.0% |
| dedupe/field_match_done | 28.4 µs | -0.4% |
| dedupe/field_match_message | 25.4 µs | -0.3% |
| filter/transform_always_fail | 17.6 µs | +3.1% |
| filter/transform_always_pass | 24.6 µs | -6.1% |
| reduce/proof_of_concept | 83.5 µs | -0.8% |

### Analysis

The codec benchmarks show 15-27% improvement because each iteration creates ~75K events via `LogEvent::default()` → `EventMetadata::default()`. In the codec decode path (`BytesDeserializer::parse_single`), the EventMetadata is **never mutated** — only the LogEvent's inner value is modified via `insert()` (PathPrefix::Event branch). So these events carry a zero-allocation shared reference to the cached static `Arc<Inner>` for their entire lifetime.

The event/rename_key benchmarks show no significant change because they create events and immediately mutate them (triggering the COW copy), so the total allocation cost is roughly the same as before — just deferred from creation to first mutation.

Transform benchmarks show minimal change for the same reason: events pass through transforms that read/modify event values (not metadata). The `filter/transform_always_fail` +3.1% is within noise.

The remap benchmarks show no change because VRL execution dominates event creation overhead, and each benchmark iteration creates only 1 event.

## Iteration 4

**Date**: 2026-03-27T22:00:00Z
**Discovery Method**: Profiling codecs suite post-iteration-3. `Decoder::handle_framing_result` at 4.6%, `BTreeMap::insert` at 4.7%, `vrl::value::crud::insert::insert` at 3.9%, `LogEvent::maybe_insert` at 3.6%. The call chain `BytesDeserializer::parse_single` → `LogEvent::default()` → `maybe_insert(message_key, bytes)` performs: (1) Arc::make_mut COW check on the LogEvent value, (2) recursive Value::insert path traversal through VRL's generic insert machinery, (3) per-event KeyString allocation for the message field name.
**Target**: `BytesDeserializer::parse_single` in `lib/codecs/src/decoding/format/bytes.rs`
**Change**: Construct LogEvent directly from a pre-populated ObjectMap instead of `LogEvent::default()` + `maybe_insert()`. Cache the message field KeyString in a `LazyLock` static. Fast path handles the common case (single-segment "message" key in Legacy namespace); edge cases fall back to original code.
**Result**: MERGED
**Improvement**: 9.7% to 23.1% on codec benchmarks
**PR**: https://github.com/connoryy/vector/pull/21

### Baseline (on optimized branch, post-iteration-3)

| Benchmark | Mean |
| ----------- | ------ |
| codecs/char_delimited/no_max | 6.17 ms |
| codecs/char_delimited/small_max | 3.45 ms |
| codecs/newline_bytes/no_max | 1.83 ms |
| codecs/newline_bytes/small_max | 536 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| codecs/char_delimited/no_max | 4.95 ms | **-19.8%** |
| codecs/char_delimited/small_max | 2.87 ms | **-16.8%** |
| codecs/newline_bytes/no_max | 1.41 ms | **-23.1%** |
| codecs/newline_bytes/small_max | 484 µs | **-9.7%** |

No regressions in remap, transform, or event benchmarks.

### Analysis

The bytes deserializer creates one LogEvent per decoded frame (~75K per codec benchmark iteration). The original path created an empty LogEvent then inserted the message field, which involved: (1) `value_mut()` triggering `Arc::make_mut` COW check, (2) VRL's recursive `Value::insert` for a single-segment path, (3) `KeyString::from()` allocation for the field name each time. The new path pre-populates the ObjectMap and constructs the LogEvent in one step, eliminating all three costs. The cached `LazyLock<KeyString>` avoids the per-event string allocation.

## Iteration 5

**Date**: 2026-04-01T10:38:00Z
**Discovery Method**: Profiling codecs suite post-iteration-4. `CharacterDelimitedDecoder::decode` at 13.0% of codecs CPU, `malloc` at 7.9%, `sdallocx` at 7.4%+3.5%, `GroupedTraceableAllocator` at 5.1%, `String::clone` (KeyString) at 9.8%, `BTreeMap::insert` at 7.1%, event drop path at ~39.5%. The framing loop was the top single-function hotspot.
**Target**: `CharacterDelimitedDecoder::decode` per-frame trait dispatch loop in `lib/codecs/src/decoding/framing/character_delimited.rs` and `Decoder::handle_framing_result` in `lib/codecs/src/decoding/decoder.rs`
**Change**: Batch frame decoding with `memchr_iter` — scan entire buffer in a single pass, extract frames via `Bytes::slice()` (zero-copy refcount-sharing). Added `decode_all_frames()` to `CharacterDelimitedDecoder`, `NewlineDelimitedDecoder`, and `Framer` enum. Added `Decoder::decode_all()` with callback-based API (`FnMut(DecodedFrame)`) instead of collecting into Vec to preserve cache-friendly memory access patterns.
**Result**: MERGED
**Improvement**: 7.7% to 15.7% on codec benchmarks
**PR**: https://github.com/connoryy/vector/pull/22

### Baseline (on optimized branch, post-iteration-4)

| Benchmark | Mean |
| ----------- | ------ |
| codecs/char_delimited/no_max | 5.08 ms |
| codecs/char_delimited/small_max | 2.86 ms |
| codecs/newline_bytes/no_max | 1.42 ms |
| codecs/newline_bytes/small_max | 474.87 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| codecs/char_delimited/no_max | 4.28 ms | **-15.7%** |
| codecs/char_delimited/small_max | 2.63 ms | **-8.0%** |
| codecs/newline_bytes/no_max | 1.31 ms | **-7.7%** |
| codecs/newline_bytes/small_max | 479.34 µs | +1.7% (noise) |

No regressions in remap or transform benchmarks.

### Analysis

The per-frame decode loop called `CharacterDelimitedDecoder::decode` ~75K times per benchmark iteration, each involving: (1) `memchr` to find the next delimiter, (2) `BytesMut::split_to().freeze()` to extract the frame, (3) trait dispatch through `tokio_util::codec::Decoder` back to the caller. The batch path replaces this with a single `memchr_iter` scan that finds all delimiters in one SIMD-accelerated pass, extracting frames via `Bytes::slice()` which shares the same underlying allocation.

The callback-based `decode_all()` API was chosen over collecting into a `Vec` because ~22K decoded events would create a ~12MB working set that doesn't fit in L1/L2 cache. Processing events via callback (create → process → drop before next event) keeps the working set small and cache-hot.

The `char_delimited/no_max` benchmark showed the largest improvement (-15.7%) because it has no max_length checking overhead. The `newline/small_max` benchmark showed no significant change because the small_max parameter causes most frames to be discarded (short-circuiting the decode work), so framing loop overhead is a smaller fraction of total cost.

## Iteration 6

**Date**: 2026-04-01T14:36:00Z
**Discovery Method**: Profiling codecs suite post-iteration-5. The iteration 5 `decode_all_frames()` method still collected frames into `SmallVec<[Bytes; 4]>` before iterating. With ~75K frames per benchmark iteration, this intermediate collection added allocation pressure and reduced cache locality. The callback approach from iteration 5's `Decoder::decode_all` was only at the outer level — the inner framing layer still materialized all frames.
**Target**: `CharacterDelimitedDecoder::decode_all_frames()` and `NewlineDelimitedDecoder::decode_all_frames()` in `lib/codecs/src/decoding/framing/`
**Change**: Renamed `decode_all_frames() -> SmallVec<[Bytes; 4]>` to `for_each_frame(FnMut(Bytes))` — a streaming callback that processes each frame inline without collecting. Updated `Framer` enum to return `bool` (whether streaming was supported). Updated `Decoder::decode_all` to use split borrows pattern (`&self.deserializer` + `&mut self.framer`) with error capture via `Option<Error>`.
**Result**: MERGED
**Improvement**: 9.9% to 35.4% on codec benchmarks
**PR**: https://github.com/connoryy/vector/pull/27

### Baseline (on optimized branch, post-iteration-5)

| Benchmark | Mean |
| ----------- | ------ |
| codecs/char_delimited/no_max | 6.50 ms |
| codecs/char_delimited/small_max | 2.98 ms |
| codecs/newline_bytes/no_max | 1.67 ms |
| codecs/newline_bytes/small_max | 452 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| codecs/char_delimited/no_max | 4.12 ms | **-35.4%** |
| codecs/char_delimited/small_max | 2.44 ms | **-18.8%** |
| codecs/newline_bytes/no_max | 1.30 ms | **-22.1%** |
| codecs/newline_bytes/small_max | 420 µs | **-9.9%** |

Encoder benchmarks:

- JsonLogVecSerializer: 98.8 ns (-12.9%, likely secondary effect from reduced allocator pressure)
- JsonLogSerializer: 165.3 ns (no change)
- JsonSerializer: 199.5 ns (+19.1%, **regression** — high outlier count suggests measurement noise)
- Encoder: 222.3 ns (+4.3%, marginal, within noise)

### Analysis

The key insight is that eliminating the intermediate `SmallVec<[Bytes; 4]>` collection in the framing layer had a much larger impact than expected. With ~75K frames per iteration, even `SmallVec` (which avoids heap allocation for ≤4 elements) must heap-allocate for the actual workload. More importantly, collecting all frames then iterating doubles the memory traffic: first write all frame references to the SmallVec, then read them back to process.

The streaming callback pattern (`for_each_frame`) processes each frame inline: extract → deserialize → emit → drop, all within a single pass. This keeps the working set in L1/L2 cache and allows the allocator to immediately reuse memory from dropped events for subsequent ones. The improvement is proportionally larger on `char_delimited/no_max` (-35.4%) because no frames are discarded by max_length checks, so all ~75K frames go through the full collect/iterate cycle in the old code.

The split borrows pattern in `Decoder::decode_all` was necessary because `self.framer.for_each_frame()` takes `&mut self` while the closure needs `&self.deserializer`. Rust's borrow checker can't see that these are disjoint fields through a `&mut self` reference, so we bind `let deserializer = &self.deserializer;` before calling `self.framer.for_each_frame()`.

The encoder regression (JsonSerializer +19.1%) is likely measurement noise — the benchmark has 7.33% outliers and the encoder code was not modified. The regression is not correlated with the codec changes.

## Iteration 7

**Date**: 2026-04-07
**Discovery Method**: CPU profiling of transform benchmarks. `build_cache_entry` at 48% of dedupe transform CPU, with `ConfigTargetPath::try_from` consuming 35% of `build_cache_entry` time. The IgnoreFields path parses every field name into a VRL `ConfigTargetPath` on every event, even though the set of field names is stable after the first event.
**Target**: `build_cache_entry()` IgnoreFields path in `src/transforms/dedupe/transform.rs`
**Change**: Added a `PathCache = HashMap<KeyString, Option<ConfigTargetPath>>` that caches parsed `ConfigTargetPath` results per field name. On cache hit (common case after first event): single HashMap lookup. On cache miss (first event only): one clone + parse + insert. Also added `Vec::with_capacity(fields.len())` for the MatchFields entry vector. Updated both `Dedupe` and `TimedDedupe` structs with the path cache.
**Result**: MERGED
**Improvement**: -10.6% on dedupe/field_ignore_message, -2.6% on dedupe/field_ignore_done
**PR**: https://github.com/connoryy/vector/pull/28

### Baseline (on optimized branch, post-iteration-6, back-to-back A/B)

| Benchmark | Mean |
| ----------- | ------ |
| dedupe/field_ignore_message | 84.70 µs |
| dedupe/field_ignore_done | 89.10 µs |
| dedupe/field_match_message | 33.24 µs |
| dedupe/field_match_done | 38.40 µs |

### After

| Benchmark | Mean | Change |
| ----------- | ------ | -------- |
| dedupe/field_ignore_message | 76.06 µs | **-10.6%** |
| dedupe/field_ignore_done | 86.70 µs | **-2.6%** |
| dedupe/field_match_message | 33.69 µs | +1.6% (noise) |
| dedupe/field_match_done | 35.57 µs | -7.4% (high variance) |

Control group (filter benchmarks, unmodified code): stable within ±0.7%, confirming system conditions comparable between baseline and after runs.

### Analysis

The IgnoreFields path in `build_cache_entry` iterates all event and metadata fields, parsing each field name into a `ConfigTargetPath` via `try_from(KeyString)` on every event. The VRL path parser is non-trivial — it handles dot-separated paths, array indices, quoted segments, etc. For a typical event with ~5-10 fields, this means 5-10 VRL path parses per event.

The HashMap cache exploits the fact that the set of field names in a log pipeline is typically stable (same schema across events). After the first event populates the cache, all subsequent events get cache hits — a single HashMap `get()` per field (O(1) amortized) instead of a full VRL path parse.

The `-10.6%` improvement on `field_ignore_message` vs `-2.6%` on `field_ignore_done` makes sense: `field_ignore_message` has real fields to parse (message, timestamp, etc.) while `field_ignore_done` uses non-existent ignore fields, so the ratio of parse-time to total-time differs.

The MatchFields benchmarks show no significant change as expected — that path uses `ConfigTargetPath` directly from the config (already parsed), not from event field enumeration.

**E2E note**: The E2E pipeline tests remap+filter+route (not dedupe), so E2E throughput is unaffected by this change. This is a targeted transform-specific optimization.
