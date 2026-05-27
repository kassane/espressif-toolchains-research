export fn zig_atomic_add(p: *u32) u32 { return @atomicRmw(u32, p, .Add, 1, .seq_cst); }
export fn zig_atomic_cas(p: *u32, e: u32, n: u32) u32 {
    return @cmpxchgStrong(u32, p, e, n, .seq_cst, .seq_cst) orelse e;
}
