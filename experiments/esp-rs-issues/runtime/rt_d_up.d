// rt_d_up.d — $LDC2_UPSTREAM (LDC 1.42.0-git on upstream LLVM 22.1.2, pre-
// 2026-05-30 byval/sret fix) #278 caller. Side-by-side with rt_d.d
// (canonical $LDC2 1.42.0 on espressif LLVM 22.1.4) to see whether the
// universal byval/sret fix affected anything stack-arg-related (it
// shouldn't — different lowering paths — but verify).
module rt_d_up;
extern (C):
extern uint fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                          ubyte a1, ushort a2, ubyte a3, ushort a4, ubyte a5)
    @nogc nothrow @system;
uint d_upstream_issue278_callm(ubyte a, ushort b, ubyte c, ushort d, ubyte e)
    @nogc nothrow @system
{
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
