const Tag = enum(u32) { a, b, c, d };
const E = extern struct { tag: Tag };
export fn zig_issue95_tag(e: *const E) callconv(.c) u8 {
    return switch (e.tag) { .a => 0, .b => 1, .c => 2, .d => 3 };
}
export fn zig_issue137_u128(a: u32) callconv(.c) u128 { return @as(u128, a) *% 10; }
export fn zig_issue277_pick(i: usize) callconv(.c) f32 {
    const t = [2]f32{ -1.0, 1.0 };
    return t[i % 2];
}
