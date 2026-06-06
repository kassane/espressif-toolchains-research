// D analog of ee.c — emit ESP32-S3 EE.* (128-bit PIE) SIMD via LDC's
// LLVM-style inline asm `__asm` from `ldc.llvmasm` (D's classic DMD-style
// `asm{}` block has no Xtensa mnemonic support).
//
// The LLVM-IR-level inline asm is identical to what clang emits for the C
// version: a `call void asm sideeffect "..."` with three pointer operands.
module ee;
import ldc.llvmasm : __asm;

extern (C) void d_ee_add(byte* d, const byte* a, const byte* b)
{
    // ~{q0},~{q1},~{q2} declare the PIE Q-registers as clobbered. LDC passes
    // the constraint string through verbatim to LLVM, which propagates to the
    // espressif fork's XtensaRegisterInfo — the register allocator avoids reuse.
    // Parity with Zig's `.{ .memory = true, .q0 = true, .q1 = true, .q2 = true }`;
    // clang rejects ~{q*} (no q-class), so the C side can only signal `memory`.
    // See docs/16 §"Cross-frontend inline-asm clobber matrix".
    __asm!void(
        "ee.vld.128.ip q0, $1, 0\n"
        ~ "ee.vld.128.ip q1, $2, 0\n"
        ~ "ee.vadds.s8   q2, q0, q1\n"
        ~ "ee.vst.128.ip q2, $0, 0",
        "r,r,r,~{memory},~{q0},~{q1},~{q2}",
        d, a, b);
}
