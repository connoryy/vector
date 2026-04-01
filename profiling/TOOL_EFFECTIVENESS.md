# Tool Effectiveness

<!-- Auto-optimize tool effectiveness tracker. Updated after each iteration. -->

## Summary (across all iterations)

| Tool | Uses | Useful | Notes |
| ------ | ------ | -------- | ------- |
| bench-and-profile.sh | Every iteration (5+) | HIGH | Core tool. Must pass --features/--binaries/--extra flags. Still the most valuable tool in the workflow. |
| parse-sample-output.sh | Every iteration | HIGH (after fix) | Was broken (gawk syntax). Fixed in iteration 2 timeframe. |
| Explore agent | 2 | HIGH | Good for usage analysis (source_event_id, EventMetadata mutation paths) |
| cargo clean -p | 1 needed | HIGH | Required after git reset to avoid stale bench binaries. Added to Step 2. |
| WebFetch | 12+ (iter 3) | LOW | Used to find external crate code. Massive waste. Fixed with anti-pattern #7. |
| Manual sample profile parsing | 2 (iter 1-2) | MEDIUM | Workaround for broken parse-sample-output.sh. No longer needed. |

## Iteration 1 (backfilled)

### bench-and-profile.sh

- **Effectiveness**: LOW (due to tooling bugs)
- **Notes**: Claude couldn't invoke it correctly — env vars not in prompt. Spent ~15 tool calls figuring out BENCH_FEATURES/BENCH_BINARIES/BENCH_EXTRA. Top-stacks files were empty (parse-sample-output.sh broken). Eventually ran cargo bench directly.

### parse-sample-output.sh

- **Effectiveness**: BROKEN
- **Notes**: Used gawk `match($0, /pattern/, m)` third-arg capture — fails silently on macOS BSD awk. Produced empty output. Fixed later.

## Iteration 2

### bench-and-profile.sh

- **Effectiveness**: HIGH
- **Notes**: Ran all 4 bench suites + CPU profiling in one command. Identified `rand_chacha` at 4.5% which directly pointed to UUID generation. The summary.txt and top-stacks.txt output was immediately actionable.

### Explore agent (for usage analysis)

- **Effectiveness**: HIGH
- **Notes**: Used to search entire codebase for `source_event_id` usage. Correctly identified that it's only used in proto serialization and tests — confirmed the optimization was safe. Saved significant manual grep time.

### Anti-pattern observed

- **Issue**: Re-implemented an optimization that was already on the branch. The `git reset --hard connoryy/connor/vector-optimized` included commit `bb2a1d234` which was the exact same change.
- **Root cause**: The optimization log didn't have an entry for this commit, so it appeared as new work.
- **Fix**: At Step 2, always run `git log --oneline master..HEAD` to see ALL commits on the optimized branch and compare against the optimization log. If there are unlogged commits, log them first before starting new work.

## Iteration 3

### bench-and-profile.sh

- **Effectiveness**: HIGH
- **Notes**: Ran correctly with flags. Top-stacks worked (parse-sample-output.sh fixed). Noise detection flagged 17 unreliable benchmarks. However, Claude used stale cached results from a prior run instead of re-running fresh.

### Explore agent (for codec mutation analysis)

- **Effectiveness**: HIGH
- **Notes**: Confirmed EventMetadata is never mutated in codec decode path — key insight that made the DEFAULT_INNER optimization viable.

### Anti-pattern observed

- **Issue**: ~60 tool calls hunting for `coerce_to_bytes` in external VRL crate. grep, find, cargo doc, WebFetch — all wasted.
- **Root cause**: Function is in `~/.cargo/git/checkouts/vrl-.../src/value/value/serde.rs`. Claude didn't know to check there.
- **Fix**: Anti-pattern #7 added ("max 3 calls to find a function definition, check ~/.cargo/{git,registry}").

### Anti-pattern observed

- **Issue**: Used stale benchmark results ("from 12:21 today") instead of running fresh. Noise detection showed 17 benchmarks unreliable.
- **Fix**: Anti-pattern #6 added ("DO NOT reuse stale benchmark results").

## Iteration 4 (backfilled)

### bench-and-profile.sh

- **Effectiveness**: HIGH
- **Notes**: Benchmark comparison had a bug — remap results showed `change_pct: 0.0` because `collect-criterion-results.py` compares against `target/criterion/` cache which gets overwritten. The after-phase should diff against baseline JSON instead.

### Known tooling bug

- **Issue**: `collect-criterion-results.py --previous` flag works correctly, but `target/criterion/` data is overwritten by the after-run, making the comparison use after-vs-after instead of baseline-vs-after.
- **Workaround**: Back up `target/criterion/` between baseline and after runs, or compare using the JSON files directly.
- **Status**: NOT YET FIXED.

## Iteration 5

### bench-and-profile.sh

- **Effectiveness**: HIGH
- **Notes**: Baseline profiling clearly identified CharacterDelimitedDecoder::decode at 13.0% as the top single-function hotspot. After benchmarks confirmed 7.7-15.7% improvement with no regressions. The tool continues to be the most valuable in the workflow.

### Code reading (Read tool)

- **Effectiveness**: HIGH
- **Notes**: Reading 6 source files (character_delimited.rs, newline_delimited.rs, decoder.rs, mod.rs, bytes.rs, benchmarks) was essential for understanding the per-frame decode loop, trait dispatch chain, and how to design the batch API. Understanding the benchmark structure was critical for updating them correctly.

### cargo clean -p

- **Effectiveness**: HIGH (saved debugging time)
- **Notes**: After changing the `decode_all` API from returning `Vec` to taking a callback, the stale bench binary still had the old signature cached. `cargo clean -p codecs -p vector -p vector-lib` was necessary to force recompilation. This should be standard practice before after-benchmarks.

### Anti-pattern observed

- **Issue**: File edit reverted during system file modification notification. An edit to `newline_bytes.rs` was silently lost and had to be re-applied.
- **Root cause**: When the file system notifies of a modification while an edit is in progress, the edit can be lost.
- **Workaround**: After editing, always verify the edit was applied by re-reading the file.

### Known tooling issue (from iteration 4, still present)

- **Issue**: `collect-criterion-results.py --previous` comparison bug — `target/criterion/` data is overwritten by the after-run, making comparison unreliable.
- **Status**: NOT YET FIXED. Workaround: manually compare baseline and after JSON files.
