# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Build
cargo build                          # dev build
make build-dev                       # dev build via make
make build                           # release build

# Check / lint (CI enforces these)
cargo fmt                            # format
cargo check                          # fast type-check
cargo vdev check rust                # clippy + fmt + deny
make check-all                       # everything (slow)

# Test
cargo nextest run                    # unit tests (preferred runner)
cargo nextest run sources::file      # single component
make test SCOPE="transforms::remap"  # via make with scope filter
make test-integration SCOPE="kafka"  # integration tests (spawns Docker services)
make test-vrl                        # VRL language tests

# Profiling
cd profiling && make profile         # docker+perf flamegraph (see profiling/)
```

`cargo vdev` is an alias for `cargo run --quiet --package vdev --` (defined in `.cargo/config.toml`). The `vdev` tool wraps most CI tasks — run `cargo vdev --help` for the full list.

Forbidden in source: `print!`, `println!`, `eprint!`, `eprintln!`, `dbg!` — all denied by clippy flags in `.cargo/config.toml`. Use `tracing::` instead.

## Architecture

Vector is a pipeline engine: **sources** ingest events → **transforms** process them → **sinks** emit them. The topology is built at startup from config and runs entirely on Tokio.

### Key crates

The workspace has ~30 crates. The most important:

| Crate | Path | Role |
|---|---|---|
| `vector` | `.` | Binary, topology wiring, CLI |
| `vector-core` | `lib/vector-core` | `Event`, `Value`, core traits (`SourceSender`, `Sink`) |
| `vector-lib` | `lib/vector-lib` | Re-exports + shared utilities used across components |
| `vector-config` | `lib/vector-config` | Derive macros + schema for component config structs |
| `vector-buffers` | `lib/vector-buffers` | Disk/memory buffers between topology nodes |
| `vector-vrl` | `lib/vector-vrl` | VRL runtime and stdlib |
| `vdev` | `vdev/` | Dev tooling (CI tasks, integration test orchestration) |

### Component structure

Every source/transform/sink lives under `src/{sources,transforms,sinks}/<name>/`. Each component must:
- Be behind a feature flag (e.g., `sources-kafka`) declared in root `Cargo.toml`
- Emit `InternalEvent` types defined in `src/internal_events/<name>.rs`
- Be registered via the inventory/component registry (`src/components/`)

Config structs use `#[configurable_component]` from `vector-config` which auto-generates schema and docs.

### Event model

`Event` (in `vector-core`) is the unit of data. It's an enum: `LogEvent`, `MetricEvent`, or `TraceEvent`. `LogEvent` wraps a `Value` (a recursive enum similar to `serde_json::Value`). VRL operates on `Value`.

### Config loading

`src/config/` handles loading → validation → topology building. Configs are TOML/YAML. The `src/topology/` module converts a validated config into a running Tokio task graph.

### Profiling setup

`profiling/` contains a Docker+perf setup for flamegraph profiling. See `profiling/Makefile`. Run `make setup` once (exports macOS CA certs) then `make profile`. The aggregator config is extracted from the Kubernetes ConfigMap at `profiling/config/cm.yaml`. The generator sends synthetic `service.1` SLS log events to exercise the full transform pipeline.
