#!/usr/bin/env bash
# run.sh - call NON-extern-"C" (name-mangled) C++ and Rust functions from Zig,
# using Zig's @"mangled_symbol" identifier syntax. Host x86_64 so we can run it.
#
# Findings (see docs/12):
#   - C++: clean. Itanium `_Z...` symbols are global + stable; free-function C++
#     ABI == C ABI, so `extern fn @"_Z..." callconv(.c)` just works (even picks a
#     specific overload).
#   - Rust: works only if the symbol is exported GLOBAL. A `pub extern "C" fn`
#     (no #[no_mangle]) is internalized by `staticlib`, by `-O`, and by legacy
#     mangling; you need v0 mangling + `--crate-type=lib` (rlib) + opt-level=0.
#     And the v0 name carries an unstable crate hash -> extract it, don't hardcode.
set -euo pipefail
cd "$(dirname "$0")"
source ../../scripts/env.sh
HT=x86_64-linux-gnu
B=../../build/mangled-ffi; mkdir -p "$B"

echo "===== C++ : Zig calls mangled demo::add + a scale() overload ====="
"$ZIG" c++ -target "$HT" -O2 -c cpp_lib.cpp -o "$B/cpp_lib.o"
"$ZIG" build-obj -target "$HT" -O ReleaseSmall -femit-bin="$B/zig_caller.o" zig_caller.zig
"$ZIG" cc -target "$HT" main.c "$B/zig_caller.o" "$B/cpp_lib.o" -o "$B/mtest"
"$B/mtest"

echo "===== Rust: Zig calls a v0-mangled (extern \"C\" ABI) Rust fn ====="
# rlib + opt-level=0 + v0  => the pub fn keeps a GLOBAL mangled symbol.
"$RUSTC" --edition 2021 --crate-type=lib -C panic=abort -C symbol-mangling-version=v0 \
    -C opt-level=0 --target x86_64-unknown-linux-gnu rust_lib.rs -o "$B/librust.rlib"
rm -rf "$B/rx" && mkdir "$B/rx" && ( cd "$B/rx" && llvm-ar x ../librust.rlib )
RO=$(ls "$B"/rx/*.rcgu.o | head -1)
V0=$(llvm-nm "$RO" | grep -E ' T .*11rust_triple' | awk '{print $3}' | head -1)
echo "  extracted global v0 symbol: $V0"
printf 'extern fn @"%s"(x: i32) callconv(.c) i32;\nexport fn zig_calls_rust(x: i32) i32 { return @"%s"(x); }\n' "$V0" "$V0" > "$B/zig_calls_rust.gen.zig"
"$ZIG" build-obj -target "$HT" -O ReleaseSmall -femit-bin="$B/zig_calls_rust.o" "$B/zig_calls_rust.gen.zig"
"$ZIG" cc -target "$HT" rmain.c "$B/zig_calls_rust.o" "$RO" -o "$B/rmtest"
"$B/rmtest"
