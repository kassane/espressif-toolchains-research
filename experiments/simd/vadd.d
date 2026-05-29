// D analog of vadd.c — four textbook auto-vectorizable element-wise loops.
// LDC autovec on xtensa-esp32s3 is expected to behave like clang/gcc: scalar
// loops, 0 EE.* (the Xtensa LLVM backend has no autovec costing model for the
// `ee.*` 128-bit PIE unit). -betterC drops druntime so the object links freely.
module vadd;
extern (C):

// @system on each function so the bodies still type-check under
// `-preview=safer` (raw pointer indexing in a default-safety function is
// rejected with that preview enabled — env.sh adds `-preview=all`). These
// kernels are C-ABI consumers of caller-provided buffers, so @system is the
// honest annotation.

@system void d_vadd_i8 (byte*  c, const byte*  a, const byte*  b, int n)
{ for (int i = 0; i < n; i++) c[i] = cast(byte)(a[i] + b[i]); }

@system void d_vadd_i16(short* c, const short* a, const short* b, int n)
{ for (int i = 0; i < n; i++) c[i] = cast(short)(a[i] + b[i]); }

@system void d_vadd_i32(int*   c, const int*   a, const int*   b, int n)
{ for (int i = 0; i < n; i++) c[i] = a[i] + b[i]; }

@system void d_vmul_f32(float* c, const float* a, const float* b, int n)
{ for (int i = 0; i < n; i++) c[i] = a[i] * b[i]; }
