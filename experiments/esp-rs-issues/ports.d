// ports.d - D ports of selected esp-rs/rust issues. Companion to ports.c /
// ports.zig. Focus: the bits that exercise the LDC frontend specifically,
// now that LDC sits on the same LLVM 21.1.3 fork as esp-clang and rustc.
//
// Issues covered:
//   #137-style: 128-bit integer arithmetic. cent/ucent are reserved in D
//               but unimplemented (DMD/LDC reject them). Captured in run.sh
//               via a tiny ucent fragment compiled separately (must fail).
//   #270-style: forced frame pointer on a register-heavy function. Compile
//               via run.sh with --frame-pointer=all to look for ICE.
//   #278-style: narrow stack-arg store width. callm takes 6 reg args + 5
//               u8/u16 stack args, mirroring open-issues.sh's clang/zig probe.

extern (C) extern uint fm(int, int, int, int, int, int,
    ubyte, ushort, ubyte, ushort, ubyte);

extern (C) uint d_issue278_callm(ubyte a, ushort b, ubyte c, ushort d, ubyte e)
{
    return fm(1, 2, 3, 4, 5, 6, a, b, c, d, e);
}

// Simpler variant from the task brief: a one-arg ubyte callback. The arg
// lives in a register (a10) under the windowed ABI, so this isn't the
// narrow-stack-store probe - it's just a sanity check that the call form
// compiles. The real #278 probe is callm above.
extern (C) void d_issue278_emit_byte_call(void function(ubyte) f)
{
    f(0x7f);
}

// #270-style: enough live values across mul/xor/sub/add to push register
// pressure. Compiled with --frame-pointer=all in run.sh.
extern (C) int d_issue270_regheavy(int a, int b, int c, int d, int e, int f)
{
    int r1 = a * b + c;
    int r2 = (d ^ e) - f;
    int r3 = (a + d) * (b + e);
    int r4 = (c - f) * (a ^ b);
    int r5 = r1 ^ r2 ^ r3 ^ r4;
    int r6 = (r5 + a) * (r5 - b);
    return r6 ^ (r1 + r2 + r3 + r4 + r5);
}

// Sanity ports (mirror ports.c / ports.zig).
enum Tag : uint { A, B, C, D }
extern (C) struct E { Tag tag; }
extern (C) ubyte d_issue95_tag(const E* e)
{
    final switch (e.tag)
    {
        case Tag.A: return 0;
        case Tag.B: return 1;
        case Tag.C: return 2;
        case Tag.D: return 3;
    }
}
extern (C) float d_issue277_pick(uint i) @safe @nogc nothrow
{
    static immutable float[2] t = [-1.0f, 1.0f];
    return t[i % 2];
}
