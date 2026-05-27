// Zig language-level SIMD — also scalarizes on esp32s3 (no autovec to EE.*).
export fn zvadd(a: @Vector(16, i8), b: @Vector(16, i8)) @Vector(16, i8) { return a +% b; }
