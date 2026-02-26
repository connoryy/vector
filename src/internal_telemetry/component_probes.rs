use tracing::{Id, Subscriber};
use tracing_subscriber::{layer::Context, registry::LookupSpan, Layer};

/// Fields extracted from a component span and stored in span extensions.
struct ComponentFields {
    id: String,
}

/// Visitor that extracts `component_id` from span attributes.
#[derive(Default)]
struct ComponentFieldVisitor {
    id: Option<String>,
}

impl tracing::field::Visit for ComponentFieldVisitor {
    fn record_str(&mut self, field: &tracing_core::Field, value: &str) {
        if field.name() == "component_id" {
            self.id = Some(value.to_owned());
        }
    }

    fn record_debug(&mut self, field: &tracing_core::Field, value: &dyn std::fmt::Debug) {
        if field.name() == "component_id" {
            self.id = Some(format!("{value:?}"));
        }
    }
}

/// Uprobe attachment point: called on every component span enter.
///
/// bpftrace attaches `uprobe:BINARY:vector_component_enter` here.
/// Arguments follow the C ABI so bpftrace can read them reliably:
///   arg0/arg1 = component_id (ptr, len)
///
/// `black_box` on the arguments creates an opaque side effect that prevents
/// LTO from proving the function body is empty and eliding the call sites.
/// When no tracer is attached the overhead is a single call + ret per
/// component span enter.
#[no_mangle]
#[inline(never)]
pub extern "C" fn vector_component_enter(id_ptr: *const u8, id_len: usize) {
    std::hint::black_box((id_ptr, id_len));
}

/// Uprobe attachment point: called on every component span exit.
/// bpftrace attaches `uprobe:BINARY:vector_component_exit` here.
#[no_mangle]
#[inline(never)]
pub extern "C" fn vector_component_exit() {
    std::hint::black_box(0u8);
}

/// Tracing layer that calls the uprobe attachment points on component span
/// enter/exit, giving bpftrace a hook to maintain a `tid → component_id` map
/// at every Tokio task poll boundary.
pub struct ComponentProbeLayer;

impl ComponentProbeLayer {
    pub fn new() -> Self {
        ComponentProbeLayer
    }
}

impl Default for ComponentProbeLayer {
    fn default() -> Self {
        ComponentProbeLayer::new()
    }
}

impl<S> Layer<S> for ComponentProbeLayer
where
    S: Subscriber + for<'a> LookupSpan<'a>,
{
    fn on_new_span(
        &self,
        attrs: &tracing_core::span::Attributes<'_>,
        id: &Id,
        ctx: Context<'_, S>,
    ) {
        let mut visitor = ComponentFieldVisitor::default();
        attrs.record(&mut visitor);
        if let Some(cid) = visitor.id {
            if let Some(span_ref) = ctx.span(id) {
                span_ref
                    .extensions_mut()
                    .insert(ComponentFields { id: cid });
            }
        }
    }

    fn on_enter(&self, id: &Id, ctx: Context<'_, S>) {
        if let Some(span_ref) = ctx.span(id) {
            if let Some(fields) = span_ref.extensions().get::<ComponentFields>() {
                let id = fields.id.as_bytes();
                vector_component_enter(id.as_ptr(), id.len());
            }
        }
    }

    fn on_exit(&self, _id: &Id, _ctx: Context<'_, S>) {
        // Intentionally a no-op. In async Rust, on_exit fires every time the
        // Tokio task yields (every await point), which makes each component span
        // only ~14μs long. Clearing the label here means perf samples almost
        // always land in gaps between polls and get labeled "unknown".
        //
        // Instead, we keep the label live until the span is fully closed (the
        // component shuts down). The label becomes "last component to run on
        // this thread", which correctly attributes Tokio runtime overhead
        // between polls to whichever component triggered it.
    }

    fn on_close(&self, id: Id, ctx: Context<'_, S>) {
        if let Some(span_ref) = ctx.span(&id) {
            if span_ref.extensions().get::<ComponentFields>().is_some() {
                vector_component_exit();
            }
        }
    }
}
