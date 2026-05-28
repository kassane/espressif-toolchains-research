#!/usr/bin/env bash
# run.sh - call NON-extern-"C" (name-mangled) functions across Zig/C/C++/Rust/D
# using each frontend's "name-the-symbol-directly" mechanism:
#   - Zig:  `@"mangled"` identifier syntax  (extern fn @"_Z..." callconv(.c) ...)
#   - D:    `pragma(mangle, "literal")`     (overrides the computed symbol name)
#   - D:    `extern(C++)` / `extern(C++,"ns")` (emits Itanium `_Z...` directly)
#   - C/C++: the mangled name IS a valid C identifier (`[A-Za-z0-9_]`, leading `_`),
#           so an `extern int _Z...(int,int);` declaration just works.
# Host x86_64 so we can run it.
#
# Findings (see docs/12):
#   - C++: clean. Itanium `_Z...` symbols are global + stable; free-function C++
#     ABI == C ABI, so `extern fn @"_Z..." callconv(.c)` just works (even picks a
#     specific overload).
#   - Rust: works only if the symbol is exported GLOBAL. A `pub extern "C" fn`
#     (no #[no_mangle]) is internalized by `staticlib`, by `-O`, and by legacy
#     mangling; you need v0 mangling + `--crate-type=lib` (rlib) + opt-level=0.
#     And the v0 name carries an unstable crate hash -> extract it, don't hardcode.
#   - D:   LDC implements all three Itanium-compatible flavours plus its own
#     `_D...` mangling. `pragma(mangle, "...")` overrides one symbol's name
#     (D's analogue of Zig's `@"..."`). `extern(C++)` / `extern(C++,"ns")` emit
#     byte-identical Itanium symbols, so D <-> C++ <-> Zig interop is wrapper-free.
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

echo "===== Reverse: Zig EXPORTS C++-mangled symbols that C++ links against ====="
# @"..." works on `export fn` too: Zig defines _ZN4demo3addEii / _Z5scaleii, and
# C++ (which only declares demo::add / scale) calls into the Zig implementations.
"$ZIG" build-obj -target "$HT" -O ReleaseSmall -femit-bin="$B/zig_export.o" zig_export.zig
"$ZIG" c++ -target "$HT" cpp_caller.cpp "$B/zig_export.o" -o "$B/etest" 2>/dev/null
"$B/etest"

echo "===== libc++ from Zig: extern \"c++\" names the dep, -lc++ links it ====="
# `extern "c++"` requires the dependency to be confirmed with -lc++ on BOTH the
# build-obj and the final link (Zig errors otherwise). @"_Znwm"/@"_ZdlPv" are
# libc++'s operator new/delete. (Bare-metal ESP avoids libc++ entirely; this is
# a host-context demonstration of the mechanism — docs/12.)
"$ZIG" build-obj -target "$HT" -lc++ -O ReleaseSmall -femit-bin="$B/zig_libcxx.o" zig_libcxx.zig
"$ZIG" cc -target "$HT" -lc++ lmain.c "$B/zig_libcxx.o" -o "$B/ltest"
"$B/ltest"

###############################################################################
# D leg: four probes (extern(D), extern(C++), D->Rust v0, D<->Zig Itanium)
###############################################################################
echo "===== D (1/4): C calls D's NATIVE mangled symbol (_D...) ====="
# d_lib.d defines `int d_secret(int)` with D's default linkage (extern(D)).
# LDC mangles it as `_D5d_lib8d_secretFiZi` — a string of [A-Za-z0-9_] starting
# with `_`, i.e. a legal C identifier. So a C extern declaration with that exact
# spelling resolves to the D-defined symbol. nm extracts the actual symbol name.
"$LDC2" -c -betterC d_lib.d -of="$B/d_lib.o"
DSYM=$(llvm-nm "$B/d_lib.o" | grep -E ' T _D[0-9]' | awk '{print $3}' | head -1)
echo "  extracted D-native symbol: $DSYM"
sed "s/%DSYM%/$DSYM/g" dmain_native.c.tpl > "$B/dmain_native.c"
"$ZIG" cc -target "$HT" "$B/dmain_native.c" "$B/d_lib.o" -o "$B/dtest_native"
"$B/dtest_native"

echo "===== D (2/4): C++ calls D's extern(C++) cpp_add + ns::fn (shared _Z... ABI) ====="
# d_lib.d also emits `_Z7cpp_addii` (extern(C++)) and `_ZN2ns2fnEv` (extern(C++,"ns")).
# These are byte-identical to what clang/gcc would mangle from the same C++ decls,
# so cpp_consumes_d.cpp just declares `int cpp_add(int,int);` and `namespace ns { int fn(); }`.
"$ZIG" c++ -target "$HT" cpp_consumes_d.cpp "$B/d_lib.o" -o "$B/dtest_cpp"
"$B/dtest_cpp"

echo "===== D (3/4): D calls Rust's v0-mangled rust_triple via pragma(mangle, \"_R...\") ====="
# The Rust v0 symbol (extracted above as $V0) is referenced from D using
#   `extern(C) pragma(mangle, "_RNv...") int rust_triple_v0(int);`
# pragma(mangle, ...) overrides the symbol name on a single declaration — this is
# D's analogue of Zig's `extern fn @"_R..." callconv(.c)`. extern(C) is correct
# because Rust's `pub extern "C" fn` uses the C ABI even though its name is v0.
# (Module-name with `.` is not a valid D module identifier, so we write to *_gen.d.)
sed "s|%V0%|$V0|g" d_calls_rust.d > "$B/d_calls_rust_gen.d"
"$LDC2" -c -betterC "$B/d_calls_rust_gen.d" -of="$B/d_calls_rust.o"
"$ZIG" cc -target "$HT" dmain_rust.c "$B/d_calls_rust.o" "$RO" -o "$B/dtest_rust"
"$B/dtest_rust"

echo "===== D (4/4): D consumes Zig's _ZN2ns2fnEv via extern(C++, \"ns\") int fn() ====="
# Zig defines `export fn @"_ZN2ns2fnEv"() callconv(.c) i32` in zig_ns_export.zig.
# D declares the same function as `extern(C++, "ns") int fn();` — LDC mangles
# that into `_ZN2ns2fnEv`, so it links against the Zig-supplied definition.
# Symmetric to D-defined / Zig-consumed (the d_lib.o + zig_caller-style pairing).
"$ZIG" build-obj -target "$HT" -O ReleaseSmall -femit-bin="$B/zig_ns_export.o" zig_ns_export.zig
"$LDC2" -c -betterC d_consumes_zig.d -of="$B/d_consumes_zig.o"
"$ZIG" cc -target "$HT" dmain_zig.c "$B/d_consumes_zig.o" "$B/zig_ns_export.o" -o "$B/dtest_zig"
"$B/dtest_zig"

echo
echo "===== Parity table: producers / consumers of each mangled ABI ====="
# P = can PRODUCE (define) a symbol with that mangling; C = can CONSUME (call) one.
# "Produce" means the toolchain natively emits the mangled name; "consume" means
# you can call/link against the symbol from that language.
#
#   ABI / mangling          C        C++       Rust      Zig            D
#   ----------------------  -------  --------  --------  -------------  -------------------------
#   Itanium C++ (_Z...)     C: nm-spelled extern  | P+C native       | P+C via #[no_mangle]+spec | P+C via @"_Z..."  | P+C via extern(C++)[,"ns"]
#   Rust v0 (_R...)         C: nm-spelled extern  | C: nm-spelled    | P native, fragile global  | C via @"_R..."    | C via pragma(mangle,"_R...")
#   D-native (_D...)        C: nm-spelled extern  | C: nm-spelled    | C: extern with sym name   | C via @"_D..."    | P native (default linkage)
#
# In short, every language can CONSUME any mangled symbol (the name is just a
# string), but only the native frontend PRODUCES a given ABI's symbols by
# default. C++/D both produce Itanium (_Z...) thanks to D's extern(C++).
cat <<'TABLE'

  ABI / mangling          | C       | C++     | Rust    | Zig     | D
  ----------------------  | ------- | ------- | ------- | ------- | -------
  Itanium C++ (_Z...)     | C only  | P + C   | C only  | P + C   | P + C  (extern(C++)[, "ns"])
  Rust v0 (_R...)         | C only  | C only  | P + C   | C only  | C only (pragma(mangle, "_R..."))
  D-native (_D...)        | C only  | C only  | C only  | C only  | P + C  (default linkage)

  Legend:
    P = can natively PRODUCE (emit) symbols in this mangling scheme.
    C = can CONSUME (call / link against) symbols of this mangling.
    "C only" entries reach the symbol by spelling its mangled name in an extern
    declaration (the mangled string is a legal C identifier).

  D-specific:
    - D PRODUCES three mangling flavours from one compiler: extern(D) -> _D...,
      extern(C++) -> _Z..., extern(C++, "ns") -> _ZN...
    - D CONSUMES Rust v0 / arbitrary external symbols via pragma(mangle, "literal")
      on an extern(C) declaration. This is the documented escape hatch and is
      the closest D analogue to Zig's @"..." identifier syntax.
    - D does NOT natively produce Rust v0 (_R...) mangling: v0 carries a
      crate-hash prefix that only rustc computes; D can only *reference* such
      symbols, not emit them under that scheme.
TABLE
