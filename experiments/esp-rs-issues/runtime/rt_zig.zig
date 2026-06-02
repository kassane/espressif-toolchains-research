// rt_zig.zig — Zig #278 caller. Declares fm_u32_callee with NARROW types so
// the call site emits the narrow→stack-slot writes; the C-side callee then
// reads them as u32.
extern fn fm_u32_callee(x1: i32, x2: i32, x3: i32, x4: i32, x5: i32, x6: i32,
                        a1: u8, a2: u16, a3: u8, a4: u16, a5: u8) callconv(.c) u32;
export fn zig_issue278_callm(a: u8, b: u16, c: u8, d: u16, e: u8) callconv(.c) u32 {
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
