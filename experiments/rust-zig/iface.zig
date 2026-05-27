// Zig side: ABI of types relevant to Rust<->Zig FFI (incl. ones C can't express
// on Xtensa: u128/f128/f16). Compared against the Rust equivalents (rs/lib.rs).
export fn zig_add_u128(a: u128, b: u128) u128 { return a +% b; }
export fn zig_add_f16(a: f16, b: f16) f16 { return a + b; }
export fn zig_add_f128(a: f128, b: f128) f128 { return a + b; }
export fn zig_not(b: bool) bool { return !b; }
const E = enum(c_int) { a, b, c };
export fn zig_enum(e: E) i32 { return @intFromEnum(e) +% 1; }
