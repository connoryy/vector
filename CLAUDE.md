# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Vector?

Vector is a high-performance observability data pipeline (agent + aggregator) for logs, metrics, and traces. Written in Rust, it uses Tokio for async I/O and runs components as a DAG of sources, transforms, and sinks wired together with channels.

## Build Commands

```bash
cargo check                    # Fast compilation check
cargo build                    # Debug build
cargo build --release          # Release build (or: make build)

# Build with specific features only (much faster iteration):
cargo check --no-default-features --features sinks-console
cargo check --features component-probes,allocation-tracing
```

## Testing

```bash
# Unit tests
cargo test sources::demo_logs              # Single module
cargo test --lib --no-default-features --features sinks-console sinks::console  # Feature-isolated

# Integration tests (require Docker)
make test-integration SCOPE="sources::example"
make test-integration SCOPE="sources::example" AUTOSPAWN=false  # Against live services

# All tests
cargo test                     # Full unit suite
make test-integration          # Full integration suite
```

Requires [`cargo-nextest`](https://nexte.st/) for `make test`. Use `TEST_LOG=vector=debug` for verbose test output.

## Formatting and Linting

```bash
cargo fmt                      # Format code
cargo clippy                   # Lint
make check-all                 # All checks (fmt, clippy, docs, licenses, etc.)
```

## Architecture

### Component Model

Every component implements one of three config traits (`src/config/`):
- **`SourceConfig`** — `build()` returns a `Source` (BoxFuture). Emits events via `SourceSender`.
- **`TransformConfig`** — `build()` returns a `Transform` enum with three variants:
  - `FunctionTransform`: stateless, single output, parallelizable
  - `SyncTransform`: supports multiple named outputs (e.g., `route`)
  - `TaskTransform`: async stream-based (e.g., `reduce`, `aggregate`)
- **`SinkConfig`** — `build()` returns `(VectorSink, Healthcheck)`.

All configs use `#[typetag::serde(tag = "type")]` for dynamic deserialization from TOML/JSON/YAML.

### Registration Pattern

Components are registered via the `#[configurable_component]` proc macro and feature-gated:
```rust
#[configurable_component(source("demo_logs", "Generate fake log events."))]
pub struct DemoLogsConfig { ... }

// In src/sources/mod.rs:
#[cfg(feature = "sources-demo_logs")]
pub mod demo_logs;
```

New components require: a feature flag in `Cargo.toml`, a module in `src/{sources,transforms,sinks}/`, and the `#[configurable_component]` annotation.

### Event Model (`lib/vector-core/src/event/`)

```
Event = Log(LogEvent) | Metric(Metric) | Trace(TraceEvent)
EventArray = Logs(Vec) | Metrics(Vec) | Traces(Vec)  // batched for efficiency
```

Data flows between components as `Stream<EventArray>`.

### Topology (`src/topology/`)

`builder.rs` constructs the DAG. Each component becomes a Tokio task. Sources get a pump task + fanout per output. Transforms pull chunks from input channels and drain into fanouts. Sinks have buffers (memory or disk) and healthchecks. Wiring happens via `connect_diff` in `running.rs`, which also handles live config reloads.

### Key Workspace Crates (`lib/`)

- `vector-core` — Event types, transform trait, core abstractions
- `vector-lib` — Re-exports of core traits
- `vector-config` + `vector-config-macros` — Configuration system and `#[configurable_component]` macro
- `vector-buffers` — Memory and disk buffer implementations
- `codecs` — Encoding/decoding (JSON, protobuf, syslog, etc.)
- `vector-vrl` — Vector Remap Language integration
- `file-source` — Shared file-tailing logic

### Internal Telemetry (`src/internal_telemetry/`)

- **Allocation tracking** (`allocations/`): Per-component memory tracking via `GroupedTraceableAllocator` wrapping jemalloc. 256 allocation groups. Enabled with `allocation-tracing` feature.
- **Component probes** (`component_probes.rs`): `VECTOR_COMPONENT_LABELS` shared-memory array for bpftrace-based CPU profiling attribution. Enabled with `component-probes` feature. Uses a single `vector_register_component` uprobe at startup; runtime attribution is via atomic byte writes (no uprobes in hot path).

## Code Conventions

- **Logging**: Use tracing key/value style: `warn!(message = "Failed.", %error)` — not `warn!("Failed: {}", err)`. Capitalize messages, end with `.`, spell out `error` (never `e`/`err`), prefer `%` (Display) over `?` (Debug).
- **No panics** in general. If unavoidable, document in function docs.
- **Feature flags**: Every component behind its own feature flag. Optional deps gated to component features.
- **No `once_cell`**: Use `std::sync::OnceLock`, `std::cell::OnceCell`, `std::sync::LazyLock` instead (enforced by clippy).
- **No `write()`**: Use `write_all()` instead (enforced by clippy).
- **Healthchecks**: Prefer false positives over false negatives. Mimic what the sink itself does; don't check permissions the sink won't need.
- **Dependencies**: Minimize carefully. See `docs/REVIEWING.md` for review criteria.
- **Rust edition**: 2021. Toolchain: 1.88 (see `rust-toolchain.toml`). MSRV: 1.86.
