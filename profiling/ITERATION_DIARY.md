# Iteration Diary

<!-- Auto-optimize iteration diary. Each iteration appends a structured entry below. -->

### Pre-iteration 0a — 2026-03-25 (backfilled)

**Target**: VrlTarget decomposition/reconstruction Arc allocation in remap transform
**Outcome**: MERGED (PR #7)

**Tools Used**: Manual profiling of remap hot path. Identified Arc alloc/dealloc cycle in VrlTarget::new() → into_events().

**Difficulties**: Multiple failed attempts (PRs #6, #8, #9, #10, #11, #12, #14, #15 — all closed). The final approach (decompose/recompose with mem::replace placeholder) was the 7th attempt.

**What Would Have Helped**: A clearer understanding of Arc::get_mut semantics upfront would have avoided the failed approaches.

### Pre-iteration 0b — 2026-03-25 (backfilled)

**Target**: Cross-crate function call overhead on small accessor methods
**Outcome**: MERGED (PR #13)

**Tools Used**: Transform benchmarks showing 1-5% overhead from non-inlined cross-crate calls.

**Difficulties**: None significant — straightforward #[inline] annotations.

### Iteration 1 — 2026-03-26T21:13:00Z (backfilled)

**Target**: `default_schema_definition()` repeated Arc+BTreeSet+BTreeMap allocation
**Outcome**: MERGED (PR #18)

**Tools Used**:

1. bench-and-profile.sh — identified `default_schema_definition` in profiles across 3 suites — Y useful
2. Read metadata.rs — understood the allocation pattern — Y useful

**Difficulties**: First iteration of the auto-optimize loop. Spent ~15 tool calls figuring out how to invoke bench-and-profile.sh (env vars not in prompt). Top-stacks files were empty (parse-sample-output.sh had gawk syntax). Had to manually parse raw profile files.

**What Would Have Helped**: bench-and-profile.sh flags in the prompt (fixed), working parse-sample-output.sh (fixed).

### Iteration 2 — 2026-03-27T18:30:00Z

**Target**: `Uuid::new_v4()` in `Inner::default()` — eager UUID generation on every event creation
**Outcome**: MERGED (PR #19)

**Tools Used** (in order, with usefulness rating):

1. bench-and-profile.sh (baseline) — showed `rand_chacha` at 4.5% in event suite, `EventMetadata::default` at 3.6% — Y useful
2. Explore agent for source_event_id usage analysis — confirmed field is dead (never read in src/) — Y useful
3. Read metadata.rs — understood Inner::default() allocation breakdown — Y useful
4. bench-and-profile.sh (after) — confirmed 3-43% improvement across suites — Y useful

**Time Breakdown**:

- Benchmarks: ~20 turns (two full bench runs, each ~15 min wall clock)
- Profiling: 2 turns (reading profiling output)
- Code reading: 4 turns (metadata.rs, proto.rs, log_event.rs, grep for usages)
- Writing code: 3 turns (edit default, update tests, cleanup import)
- Building/testing: 3 turns (fmt, clippy, cargo test)
- Git/PR: 5 turns (cherry-pick, push, create PR)

**Difficulties**:

- Initially targeted Priority 2 (dedupe build_cache_entry) but pivoted to Priority 3 (EventMetadata) after seeing that rand_chacha (UUID) was a larger single hotspot
- The optimization was already implemented on the optimized branch from a previous session — wasted time re-implementing identical changes before realizing this
- Had to work around git stash issues during cherry-pick (Cargo.lock modifications)

**What Would Have Helped**:

- The optimization log should have recorded iteration 2 if it was already done — would have prevented re-work
- A check at Step 2 to diff the optimized branch against master to see ALL changes not yet logged would catch this

**Leads Discovered**:

- EventMetadata::default() remaining Arc allocation still at 3.6% (Priority 4) — could cache a default Arc<Inner>
- Decoder CharacterDelimitedDecoder::decode at 6.9-8.5% (Priority 3) — worth investigating framing loop
- Memory allocation/deallocation aggregate ~26% of event suite CPU (Priority 5) — systemic issue

### Iteration 3 — 2026-03-27T20:00:00Z

**Target**: `EventMetadata::default()` → `Arc::new(Inner::default())` — heap allocation on every event creation
**Outcome**: MERGED (PR #20)

**Tools Used** (in order, with usefulness rating):

1. bench-and-profile.sh (baseline) — showed `EventMetadata::default` at 3.2% in event suite, allocation functions dominating transform suite — Y useful
2. Read event-profile.txt — confirmed `Inner::default` and `Arc::new` allocation on the call path, UUID still appearing due to other bench functions in same binary — Y useful
3. Explore agent for codec decode path analysis — confirmed EventMetadata is NEVER mutated in decode path (only LogEvent value is) — Y very useful, key insight for the optimization
4. Read metadata.rs — understood `get_mut()` → `Arc::make_mut` COW pattern — Y useful
5. Read log_event.rs `insert` — confirmed `PathPrefix::Event` branch doesn't touch metadata — Y useful
6. bench-and-profile.sh (after) — confirmed 15-27% improvement on codec suite — Y useful

**Time Breakdown**:

- Benchmarks: ~6 turns (two full bench runs, ~15 min wall clock each)
- Profiling: 4 turns (reading profiling output, understanding call stacks)
- Code reading: 8 turns (metadata.rs, log_event.rs, bytes.rs, decoder.rs, tracing_allocator.rs, Cargo.toml features)
- Analysis: 4 turns (evaluating whether COW cost negates savings, analyzing decode path mutation patterns)
- Writing code: 3 turns (edit default, add static, write tests)
- Building/testing: 4 turns (fmt, clippy, cargo test on both branches)
- Git/PR: 6 turns (commit to optimized branch, create PR branch from UUID branch, re-apply changes after branch switch, push, create PR)

**Difficulties**:

- Initially considered Priority 4 might not be impactful because events that get mutated would trigger COW copy (same total allocation cost). Key insight was that codec decode path does NOT mutate EventMetadata.
- Spent time analyzing whether UUID generation was still happening despite the removal — turned out to be profiler attributing samples from other benchmark functions running in the same binary.
- Git branch management was messy: auto/ branches kept being created, had to stash/unstash when switching between optimized and PR branches, lost changes when switching branches.
- The PR needs to be based on `claude/skip-eager-uuid-generation` (not master) because the cached default Inner has `source_event_id: None`.
- GroupedTraceableAllocator overhead discovery — 12% of transform CPU is from the allocation tracing wrapper, but this is a product design choice not an optimization target.

**What Would Have Helped**:

- Better git branch hygiene — a script to manage the optimized/PR branch workflow
- The bench-and-profile.sh remap results showed identical baseline/after values (possible caching issue with Criterion's `target/criterion` directory)

**Leads Discovered**:

- GroupedTraceableAllocator at 5.5-6.5% + 2.3% + 4.0% in transform/codecs — production instrumentation overhead
- CharacterDelimitedDecoder::decode at 8.0-10.8% in codecs — framing loop optimization potential
- Arc::drop_slow at 3.3% in codecs — Arc deallocation cost from event creation/destruction

### Iteration 4 — 2026-03-27T22:00:00Z (backfilled)

**Target**: `BytesDeserializer::parse_single` indirect LogEvent construction
**Outcome**: MERGED (PR #21)

**Tools Used**:

1. bench-and-profile.sh (baseline) — showed BTreeMap::insert 4.7%, vrl::value::crud::insert 3.9%, handle_framing_result 4.6% — Y useful
2. Read bytes.rs, decoder.rs — understood parse_single creates empty LogEvent then inserts — Y useful
3. bench-and-profile.sh (after) — confirmed 10-23% improvement on codecs — Y useful

**Difficulties**:

- After-benchmark comparison showed `change_pct: 0.0` for remap because the `collect-criterion-results.py` compares against cached `target/criterion/` data which gets overwritten between baseline and after runs. Need to fix this tooling bug.
- Git state had uncommitted test changes from iteration 2 that confused the diff.

**What Would Have Helped**:

- Fix the criterion comparison bug (after phase should compare against baseline phase JSON, not stale criterion cache)
- `cargo clean -p vector-core` at Step 2 (now fixed in prompt)

**Leads Discovered**:

- CharacterDelimitedDecoder::decode still at 8% — further framing loop optimization possible
- GroupedTraceableAllocator overhead confirmed at ~12% of transform CPU

### Iteration 5 — 2026-04-01T10:38:00Z

**Target**: `CharacterDelimitedDecoder::decode` per-frame trait dispatch loop + `Decoder::handle_framing_result`
**Outcome**: MERGED (PR #22)

**Tools Used** (in order, with usefulness rating):

1. bench-and-profile.sh (baseline) — showed CharacterDelimitedDecoder::decode at 13.0%, String::clone at 9.8%, BTreeMap::insert at 7.1%, event drop at 39.5% — Y useful
2. Read character_delimited.rs, decoder.rs, bytes.rs, mod.rs — understood the per-frame decode loop and trait dispatch chain — Y useful
3. Read benchmark files (newline_bytes.rs, character_delimited_bytes.rs) — understood how benchmarks exercise the decode path — Y useful
4. cargo instruments profiling — confirmed hotspots in the framing loop — Y useful
5. bench-and-profile.sh (after) — confirmed 7.7-15.7% improvement on codec benchmarks, no regressions — Y useful

**Time Breakdown**:

- Benchmarks: ~8 turns (two full bench runs, ~15 min wall clock each)
- Profiling: 3 turns (reading and analyzing profiling output)
- Code reading: 6 turns (character_delimited.rs, newline_delimited.rs, decoder.rs, mod.rs, bytes.rs, benchmarks)
- Analysis: 4 turns (evaluating Bytes::slice vs split_to, callback vs Vec API, cache implications)
- Writing code: 8 turns (decode_all_frames in CharacterDelimitedDecoder, delegation in NewlineDelimitedDecoder, Framer enum dispatch, Decoder::decode_all callback API, benchmark updates)
- Building/testing: 5 turns (fixing duplicate import, clippy while_let_loop lint, stale binary cache, re-applying edits, running tests)
- Git/PR: 5 turns (commit, push with pre-push hook, create PR branch, cherry-pick, create PR)

**Difficulties**:

- Duplicate `SmallVec` import in mod.rs — added it twice during edit, causing E0252. Quick fix.
- Clippy `while_let_loop` lint — initial loop/match pattern was flagged; converted to `while let`.
- Stale bench binary cache — after changing `decode_all` API signature from `-> Vec` to callback, old binary was cached. Fixed with `cargo clean -p codecs -p vector -p vector-lib`.
- File edit reverted — newline_bytes.rs edit was lost during a system file modification notification. Had to re-apply.
- Push failure — first push attempt failed with "Connection to github.com closed by remote host" during pre-push hook. Succeeded on retry.
- Pre-push hook reformatting — `while let` expression was split differently than rustfmt expected, creating an additional style commit.

**What Would Have Helped**:

- `cargo clean -p` should be standard practice before running after-benchmarks (already added to workflow)
- A way to atomically edit multiple files would prevent the file revert issue

**Leads Discovered**:

- String::clone (KeyString) at 9.8% — key cloning during event construction is a significant cost
- Event drop path at ~39.5% — BTreeMap/Arc/Vec destruction dominates CPU, but very hard to optimize without fundamental data model changes
- `call_mut` overhead in new batch path — the Framer enum dispatch adds overhead; could be mitigated with monomorphization or direct struct access
