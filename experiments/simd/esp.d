// esp.d — ESP32-P4 vendor PIE/ESPV vector ops via LDC's LLVM-style inline asm
// (`__asm` from ldc.llvmasm). D's classic DMD-style `asm{}` block has no
// RISC-V vendor extension support — `__asm` lowers to a regular LLVM
// `call asm sideeffect` indistinguishable from clang's `__asm__ volatile`.
module esp;
import ldc.llvmasm : __asm;

extern (C) void d_esp_add(byte* d, const byte* a, const byte* b)
{
    __asm!void(
        "esp.vld.128.ip q0, $1, 0\n"
        ~ "esp.vld.128.ip q1, $2, 0\n"
        ~ "esp.vadd.s8    q2, q0, q1\n"
        ~ "esp.vst.128.ip q2, $0, 0",
        "r,r,r,~{memory}",
        d, a, b);
}
