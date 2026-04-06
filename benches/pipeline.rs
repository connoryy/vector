//! Pipeline benchmark — measures cumulative decode → filter → drop throughput.
//!
//! Simulates the hot path of a typical Vector pipeline:
//!   1. Decode newline-delimited JSON bytes into Events (BytesDeserializer)
//!   2. Apply a filter transform (always-pass and always-fail variants)
//!   3. Drop to an output buffer (simulates blackhole sink)
//!
//! Run with: cargo bench --bench pipeline --features pipeline-benches

use std::time::Duration;

use bytes::BytesMut;
use criterion::{
    BatchSize, BenchmarkGroup, Criterion, SamplingMode, Throughput, criterion_group, criterion_main,
    measurement::WallTime,
};
use tokio_util::codec::Decoder;
use vector::{
    conditions::Condition,
    transforms::{FunctionTransform, OutputBuffer, filter::Filter},
};
use vector_lib::{
    codecs::{BytesDeserializer, CharacterDelimitedDecoder, decoding::Framer},
    event::Event,
};

/// A single JSON log line (similar to what test-log-producer emits).
const JSON_LOG_LINE: &str = r#"{"time":"2026-01-01T00:00:00Z","level":"INFO","type":"service.1","origin":"/app","message":"BenchmarkPayloadDataHereToSimulateRealisticLogLineLengthWithEnoughContentToExerciseTheParserAndTransformPipeline"}"#;

/// Build a BytesMut buffer with `n` copies of the JSON log line, newline-delimited.
fn build_input(n: usize) -> BytesMut {
    let line_with_newline = format!("{}\n", JSON_LOG_LINE);
    let total_len = line_with_newline.len() * n;
    let mut buf = BytesMut::with_capacity(total_len);
    for _ in 0..n {
        buf.extend_from_slice(line_with_newline.as_bytes());
    }
    buf
}

struct PipelinePayload {
    input: BytesMut,
    framer: CharacterDelimitedDecoder,
    deserializer: BytesDeserializer,
    filter: Filter,
    output: OutputBuffer,
}

/// Decode-only: frame + deserialize, no transform.
fn decode_only(payload: PipelinePayload) -> usize {
    let mut framer = payload.framer;
    let deserializer = payload.deserializer;
    let mut input = payload.input;
    let mut count = 0;

    while let Ok(Some(frame)) = framer.decode(&mut input) {
        let _events = deserializer.parse(frame.into(), Default::default());
        count += 1;
    }
    count
}

/// Full pipeline: frame + deserialize + filter (pass or fail).
fn decode_and_filter(payload: PipelinePayload) -> usize {
    let mut framer = payload.framer;
    let deserializer = payload.deserializer;
    let mut filter = payload.filter;
    let mut output = payload.output;
    let mut input = payload.input;
    let mut count = 0;

    while let Ok(Some(frame)) = framer.decode(&mut input) {
        let events = deserializer.parse(frame.into(), Default::default());
        for event in events {
            filter.transform(&mut output, event);
            count += 1;
        }
    }
    count
}

fn pipeline(c: &mut Criterion) {
    let mut group: BenchmarkGroup<WallTime> = c.benchmark_group("pipeline");
    group.sampling_mode(SamplingMode::Auto);

    let n_events = 1024;
    let input = build_input(n_events);
    let input_bytes = input.len() as u64;

    // --- Decode only (no transform) ---
    group.throughput(Throughput::Elements(n_events as u64));
    group.bench_function("decode_only", |b| {
        b.iter_batched(
            || PipelinePayload {
                input: input.clone(),
                framer: CharacterDelimitedDecoder::new(b'\n'),
                deserializer: BytesDeserializer,
                filter: Filter::new(Condition::AlwaysPass),
                output: OutputBuffer::from(Vec::with_capacity(n_events)),
            },
            decode_only,
            BatchSize::SmallInput,
        )
    });

    // --- Decode + filter (always pass) ---
    group.throughput(Throughput::Elements(n_events as u64));
    group.bench_function("decode_filter_pass", |b| {
        b.iter_batched(
            || PipelinePayload {
                input: input.clone(),
                framer: CharacterDelimitedDecoder::new(b'\n'),
                deserializer: BytesDeserializer,
                filter: Filter::new(Condition::AlwaysPass),
                output: OutputBuffer::from(Vec::with_capacity(n_events)),
            },
            decode_and_filter,
            BatchSize::SmallInput,
        )
    });

    // --- Decode + filter (always fail / drop all) ---
    group.throughput(Throughput::Elements(n_events as u64));
    group.bench_function("decode_filter_fail", |b| {
        b.iter_batched(
            || PipelinePayload {
                input: input.clone(),
                framer: CharacterDelimitedDecoder::new(b'\n'),
                deserializer: BytesDeserializer,
                filter: Filter::new(Condition::AlwaysFail),
                output: OutputBuffer::from(Vec::with_capacity(n_events)),
            },
            decode_and_filter,
            BatchSize::SmallInput,
        )
    });

    // --- Byte throughput variant (same pipeline, measured in bytes) ---
    group.throughput(Throughput::Bytes(input_bytes));
    group.bench_function("decode_filter_pass_bytes", |b| {
        b.iter_batched(
            || PipelinePayload {
                input: input.clone(),
                framer: CharacterDelimitedDecoder::new(b'\n'),
                deserializer: BytesDeserializer,
                filter: Filter::new(Condition::AlwaysPass),
                output: OutputBuffer::from(Vec::with_capacity(n_events)),
            },
            decode_and_filter,
            BatchSize::SmallInput,
        )
    });

    group.finish();
}

criterion_group!(
    name = benches;
    config = Criterion::default()
        .warm_up_time(Duration::from_secs(5))
        .measurement_time(Duration::from_secs(30))
        .noise_threshold(0.01)
        .significance_level(0.05)
        .confidence_level(0.95)
        .nresamples(100_000)
        .sample_size(300);
    targets = pipeline
);

criterion_main!(benches);
