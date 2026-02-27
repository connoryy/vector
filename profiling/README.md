# Vector Profiling

This directory previously contained the profiling toolchain. It has been moved
to **vector-helm** (`profiling/flamegraph/`) to keep all operational tooling in
one place. Only the `component-probes` Rust feature lives here.

## The `component-probes` Feature

The `component-probes` Rust feature (`--features component-probes`) instruments
Vector with two `#[no_mangle] #[inline(never)]` symbols:

- `vector_component_enter(component_id: *const u8, len: usize)`
- `vector_component_exit()`

bpftrace attaches uprobes to these symbols to record nanosecond-precision
component enter/exit transitions. A Python script in vector-helm
(`profiling/flamegraph/scripts/collapse-labeled.py`) joins those transitions
with `perf record` stacks (by TID + timestamp) to produce component-attributed
flamegraphs.

See `src/internal_telemetry/component_probes.rs` for the implementation and
`src/trace.rs` for the tracing subscriber integration.

## Publishing a Pre-built Binary

The GitHub Actions workflow (`.github/workflows/component-probes-release.yml`)
builds `cargo build --release --features component-probes` and uploads
`vector-component-probes-linux-x86_64.tar.gz` to GitHub Releases on every tag
matching `component-probes-v*`.

To publish a new version:

```bash
git tag component-probes-v0.49.0
git push origin component-probes-v0.49.0
# GH Actions builds and uploads (~30 min first time; cached ~5-15 min after)
```

## Running Flamegraph Profiles

From vector-helm (requires Docker + Linux):

```bash
make -C profiling/flamegraph profile
make -C profiling/flamegraph profile-realistic
BENCHMARK_MOCK=openshift-cloud make -C profiling/flamegraph profile
```

See `profiling/flamegraph/` in vector-helm for full documentation.
