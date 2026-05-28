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
    __asm!void(
        "ee.vld.128.ip q0, $1, 0\n"
        ~ "ee.vld.128.ip q1, $2, 0\n"
        ~ "ee.vadds.s8   q2, q0, q1\n"
        ~ "ee.vst.128.ip q2, $0, 0",
        "r,r,r,~{memory}",
        d, a, b);
}
