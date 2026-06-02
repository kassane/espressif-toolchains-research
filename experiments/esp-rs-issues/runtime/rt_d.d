// rt_d.d — D/LDC #278 caller. Same narrow-typed extern decl.
module rt_d;
extern (C):
extern uint fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                          ubyte a1, ushort a2, ubyte a3, ushort a4, ubyte a5)
    @nogc nothrow @system;
uint d_issue278_callm(ubyte a, ushort b, ubyte c, ushort d, ubyte e) @nogc nothrow @system
{
    return fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}
