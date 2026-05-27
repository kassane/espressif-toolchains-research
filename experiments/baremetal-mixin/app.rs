// app.rs - the Rust #![no_std] "application" for a bare-metal ESP image that
// mixes in a Zig compute kernel (dsp.zig). Rust owns the buffer and the
// high-level flow; Zig does the number-crunching. Interop is the C ABI, with all
// buffers passed BY POINTER (the universally ABI-safe pattern).
#![no_std]

extern "C" {
    fn zig_scale(data: *mut i32, n: usize, factor: i32);
    fn zig_sum_of_squares(data: *const i32, n: usize) -> i32;
}

// Called *back* from Zig (zig_scale) — e.g. feed a watchdog / progress bar.
// Kept side-effecting via a volatile counter so it isn't optimized away.
static mut TICKS: usize = 0;
#[no_mangle]
pub extern "C" fn rs_progress(done: usize, _total: usize) {
    unsafe { core::ptr::write_volatile(core::ptr::addr_of_mut!(TICKS), done); }
}

/// Application entry, invoked by the C/asm reset shim. Writes the result through
/// `out` (an i64 by pointer) and returns 0 on success.
#[no_mangle]
pub extern "C" fn app_main(out: *mut i32) -> i32 {
    let mut buf: [i32; 8] = [1, 2, 3, 4, 5, 6, 7, 8];
    unsafe {
        // Rust -> Zig (in-place transform, Zig calls back rs_progress):
        zig_scale(buf.as_mut_ptr(), buf.len(), 2); // -> 2,4,6,8,10,12,14,16
        // Rust -> Zig (compute), result by pointer:
        let s = zig_sum_of_squares(buf.as_ptr(), buf.len()); // 4+16+...+256 = 816
        core::ptr::write(out, s);
    }
    0
}

#[panic_handler]
fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
