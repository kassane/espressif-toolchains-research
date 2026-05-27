// dsp.zig - a Zig compute kernel for a bare-metal ESP app, called from Rust.
//
// FFI-safe patterns only (work on Xtensa *and* RISC-V, see docs/10):
//   - buffers passed BY POINTER (never by-value aggregate),
//   - scalars by value,
//   - a callback back into Rust.
// `export fn` gives the C ABI; no Zig std / allocator — links into -nostdlib.

// Implemented in Rust, called from here (bidirectional FFI):
extern fn rs_progress(done: usize, total: usize) callconv(.c) void;

/// Multiply each element in place, reporting progress back to Rust.
export fn zig_scale(data: [*]i32, n: usize, factor: i32) void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        data[i] *%= factor;
        rs_progress(i + 1, n);
    }
}

/// Sum of squares over a buffer (a typical perf-critical kernel).
/// i32 keeps it runnable on qemu's generic dc233c core, which lacks esp32's
/// 64-bit-multiply helpers; real esp32 silicon would handle i64 fine.
export fn zig_sum_of_squares(data: [*]const i32, n: usize) i32 {
    var acc: i32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        acc +%= data[i] *% data[i];
    }
    return acc;
}
