Added `ComponentProbeLayer` tracing subscriber layer that emits `#[no_mangle]` uprobe attachment points (`vector_component_enter` / `vector_component_exit`) on component span boundaries, enabling bpftrace scripts to maintain a `tid → component_id` mapping and generate per-component CPU flamegraphs from live Vector processes.

authors: connoryy