// lib_zig.zig - Zig implementation of the FFI contract (prefix: zig_).
//
// `export fn` gives every symbol the C ABI. `extern struct` guarantees the
// C layout for Point/Blob. Builds as a freestanding object (-target
// xtensa-freestanding-none -mcpu=esp32) with no Zig std runtime, so it links
// cleanly into a -nostdlib image.

const Point = extern struct {
    x: i32,
    y: i32,
};

const Blob = extern struct {
    data: [24]u8,
};

const BinOp = *const fn (i32, i32) callconv(.c) i32;

export fn zig_add_i32(a: i32, b: i32) i32 {
    return a +% b;
}

export fn zig_add_i64(a: i64, b: i64) i64 {
    return a +% b;
}

export fn zig_mul_f32(a: f32, b: f32) f32 {
    return a * b;
}

export fn zig_mul_f64(a: f64, b: f64) f64 {
    return a * b;
}

export fn zig_make_point(x: i32, y: i32) Point {
    return .{ .x = x, .y = y };
}

export fn zig_point_dot(a: Point, b: Point) i32 {
    return a.x *% b.x +% a.y *% b.y;
}

export fn zig_make_blob(fill: u8) Blob {
    var b: Blob = undefined;
    var i: u8 = 0;
    while (i < 24) : (i += 1) {
        b.data[i] = fill +% i;
    }
    return b;
}

export fn zig_blob_sum(b: Blob) u32 {
    var s: u32 = 0;
    for (b.data) |v| {
        s +%= v;
    }
    return s;
}

export fn zig_apply(f: BinOp, a: i32, b: i32) i32 {
    return f(a, b);
}
