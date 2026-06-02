// rt_zig016.zig — legacy $ZIG_016 (Zig 0.16.0-xtensa, LLVM 21.1.0) #278
// caller. Side-by-side with rt_zig.zig (canonical $ZIG 0.17 / LLVM 22.1.4)
// to verify whether the narrow-vs-wide stack-arg-store policy changed
// between Zig versions. Same source, different export name.
extern fn fm_u32_callee(x1: i32, x2: i32, x3: i32, x4: i32, x5: i32, x6: i32,
                        a1: u8, a2: u16, a3: u8, a4: u16, a5: u8) callconv(.c) u32;
export fn zig016_issue278_callm(a: u8, b: u16, c: u8, d: u16, e: u8) callconv(.c) u32 {
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
