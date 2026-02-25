#![allow(missing_docs)]

#[cfg(feature = "allocation-tracing")]
pub mod allocations;

#[cfg(feature = "component-probes")]
pub mod component_probes;

pub const fn is_allocation_tracking_enabled() -> bool {
    cfg!(feature = "allocation-tracing")
}
