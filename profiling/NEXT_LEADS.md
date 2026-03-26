# Next Optimization Leads

This file contains specific, actionable optimization leads discovered during
profiling iterations. Each lead should be investigated and either promoted to
an optimization attempt or dismissed with reasoning.

**Instructions for the auto-optimize loop:**
1. READ this file FIRST before doing any analysis
2. Pick the highest-priority lead that hasn't been attempted
3. After investigating, either attempt the optimization or remove the lead with a note
4. If you discover NEW leads during your work, ADD them here for future iterations

---

## Priority 1: Fanout EventArray cloning (fanout.rs:303)

**Source:** Static analysis of lib/vector-core/src/fanout.rs
**What:** When events go to N sinks, the last sink gets ownership (move) but N-1 sinks get `clone_from(&events)`. This deep-clones the entire EventArray for each additional sink.
**Why it matters:** Our aggregator has 6 sinks. Every event is cloned 5 times.
**Approach:** Wrap EventArray in Arc so cloning is O(1). Only deep-clone when a sink needs to mutate.
**Files:** `lib/vector-core/src/fanout.rs`
**Estimated impact:** 5-10% throughput for multi-sink configs

## Priority 2: Size cache invalidation on every mutation (log_event.rs:191)

**Source:** Code review of LogEvent::value_mut()
**What:** Every call to `value_mut()` does `result.invalidate()` which writes to two AtomicCell fields. This happens on EVERY field mutation in VRL, potentially dozens of times per event.
**Why it matters:** Atomic stores are expensive (~5-20ns each) and there are 2 per mutation.
**Approach:** Use a dirty flag instead. Only recalculate size when actually queried.
**Files:** `lib/vector-core/src/event/log_event.rs`
**Estimated impact:** 2-5% on VRL-heavy transforms

## Priority 3: Batch notifier cloning per event

**Source:** Code review of event finalization
**What:** Each event in a batch gets its own `EventFinalizer::new(batch.clone())` which clones an Arc.
**Why it matters:** Arc clone is ~15-20ns per event, called for every event in every batch.
**Approach:** Share the batch notifier across events without per-event Arc clone.
**Files:** `lib/vector-core/src/event/array.rs`
**Estimated impact:** 1-3%

## Priority 4: VRL runtime.clear() allocation

**Source:** Code review of src/transforms/remap.rs:445
**What:** `self.runtime.clear()` is called after every event. If it deallocates internal buffers, it forces re-allocation on the next event.
**Approach:** Check if clear() actually frees memory. If so, use a pool or just reset pointers.
**Files:** External VRL crate — may need to check if Vector wraps it
**Estimated impact:** Unknown, needs investigation

---

## Dismissed Leads

(Add dismissed leads here with reasoning)

