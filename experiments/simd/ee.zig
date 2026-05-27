// ESP32-S3 SIMD via inline asm. Zig 0.15+ uses struct-form clobbers:
// `: .{ .memory = true, .q0 = true, ... }` instead of the old `: "memory"`.
export fn ee_vadd_s8(d: [*]i8, a: [*]const i8, b: [*]const i8) void {
    asm volatile (
        \\ee.vld.128.ip q0, %[a], 0
        \\ee.vld.128.ip q1, %[b], 0
        \\ee.vadds.s8   q2, q0, q1
        \\ee.vst.128.ip q2, %[d], 0
        :
        : [d] "r" (d),
          [a] "r" (a),
          [b] "r" (b),
        : .{ .memory = true, .q0 = true, .q1 = true, .q2 = true });
}
