Added a per-sink `authoritative` field to the `acknowledgements` configuration block.
In fan-out topologies where events are sent to multiple sinks, sources that support
end-to-end acknowledgements normally wait for **all** connected sinks before
acknowledging events at the source. Setting `authoritative: false` on a sink causes
the source to not wait for that sink, decoupling non-critical sinks (such as
best-effort observability outputs) from the acknowledgement chain. This allows
sources to acknowledge events as soon as all "authoritative" sinks have finished
processing, preventing slow or unavailable non-critical sinks from blocking the
entire pipeline.

The field defaults to `true`, preserving existing behavior. No configuration
changes are required for existing deployments.

Example usage:
```yaml
sinks:
  durable_storage:
    type: aws_s3
    acknowledgements:
      enabled: true
      # authoritative defaults to true — source waits for this sink
  monitoring:
    type: loki
    acknowledgements:
      enabled: false
      authoritative: false  # source does NOT wait for this sink
```

authors: connoryy
