// esp.zig — ESP32-P4 (RISC-V) vendor PIE/ESPV vector ops via Zig inline asm.
// Mirrors ee.zig (the xtensa s3 EE.* analog) but with `esp.*` mnemonics.
export fn esp_vadd_s8(d: [*]i8, a: [*]const i8, b: [*]const i8) void {
    asm volatile (
        \\esp.vld.128.ip q0, %[a], 0
        \\esp.vld.128.ip q1, %[b], 0
        \\esp.vadd.s8    q2, q0, q1
        \\esp.vst.128.ip q2, %[d], 0
        :
        : [d] "r" (d),
          [a] "r" (a),
          [b] "r" (b),
        : .{ .memory = true });
}
