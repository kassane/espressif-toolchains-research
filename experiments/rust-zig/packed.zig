// Zig `packed struct` = bit-packed into a backing integer (supports sub-byte
// fields); NOT the same as Rust #[repr(packed)] (byte-packed, no padding).
// For C-ABI interop use `extern struct` <-> Rust #[repr(C)].
const P  = packed struct { a: u8, b: u8 };   // backing u16 -> @sizeOf 2
const E  = extern struct { a: u8, b: u8 };   // C layout    -> @sizeOf 2
const P2 = packed struct { a: u4, b: u4 };   // sub-byte    -> @sizeOf 1 (Rust can't express)
export fn z_size_packed() usize { return @sizeOf(P); }
export fn z_size_extern() usize { return @sizeOf(E); }
export fn z_size_p2()     usize { return @sizeOf(P2); }
export fn z_take_extern(s: E) u8 { return s.a +% s.b; }            // extern by value: allowed
export fn z_take_packed_ptr(s: *const P) u8 { return s.a +% s.b; } // packed: must go by pointer
// NOTE: `export fn f(s: P) ...` (packed struct by value in a C-ABI fn) is a
// compile error: "not allowed in function with calling convention 'xtensa_call0'".
