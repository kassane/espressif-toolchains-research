// D analog of vec.c — explicit vector type via the language built-in
// `__vector(byte[16])` (also exposed as `core.simd.byte16`). On esp32s3 LDC,
// like clang's vector_size(16) and zig's @Vector(16,i8), this is expected to
// scalarize (no q-reg codegen) because no DAG legalization rule maps it to
// the `ee.*` PIE instruction set.
module vec;
import core.simd : byte16;

extern (C) byte16 d_vadd16(byte16 a, byte16 b)
{
    return a + b;
}
