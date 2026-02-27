/// Uprobe attachment point: called once per component at startup to register
/// the mapping from allocation group ID to component name.
///
/// bpftrace attaches `uprobe:BINARY:vector_register_component` here at probe
/// startup to build a `group_id → component_id` lookup table. At sample time,
/// bpftrace reads the thread-local allocation group stack to get the current
/// group ID and looks it up in that table.
///
/// Arguments follow the C ABI so bpftrace can read them reliably:
///   arg0 = group_id (u8)
///   arg1/arg2 = component_id (ptr, len)
///
/// `black_box` prevents LTO from eliding the call site.
#[no_mangle]
#[inline(never)]
pub extern "C" fn vector_register_component(id: u8, name_ptr: *const u8, name_len: usize) {
    std::hint::black_box((id, name_ptr, name_len));
}

/// Uprobe attachment point: called on every allocation group enter (i.e. every Tokio task poll
/// that enters a component's group). bpftrace attaches here to record the active component ID
/// on the current thread without needing span machinery.
///
/// Arguments follow the C ABI so bpftrace can read them reliably:
///   arg0 = group_id (u8)
#[no_mangle]
#[inline(never)]
pub extern "C" fn vector_component_enter(id: u8) {
    std::hint::black_box(id);
}

/// Uprobe attachment point: called on every allocation group exit (i.e. every Tokio task poll
/// that exits a component's group). bpftrace attaches here to clear the active component ID.
#[no_mangle]
#[inline(never)]
pub extern "C" fn vector_component_exit() {
    std::hint::black_box(0u8);
}
