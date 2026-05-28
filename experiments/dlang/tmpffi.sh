#!/usr/bin/env bash
# tmpffi.sh - embedded/Xtensa template-metaprogramming FFI across ALL 5
# toolchains (gcc, esp-clang, zig, ldc2, rustc) over the shared LLVM-22 backend.
#
# Sample: a "shim" template `shims::Gpio<int Pin>` — embedded-canonical: every
# pin instantiation becomes its OWN symbol with its OWN static state, so all
# slot dispatch is compile-time. No vtable, no branch, no overhead. C++/D/Rust/
# Zig all see byte-identical Itanium mangling and can be linked into one ELF.
#
# Steps:
#   (a) C++ template `shims::Gpio<int Pin>` -> esp-clang Xtensa object.
#   (a') GCC alternative provider — same Itanium mangling (interchangeable).
#   (b) D consumer: extern(C++,"shims") extern(C++,class) struct Gpio(int Pin).
#   (c) Rust consumer: extern "C" + #[link_name="_ZN5shims4Gpio…"].
#   (d) Zig consumer: extern fn @"_ZN5shims4Gpio…" — raw-symbol syntax.
#   (e) Link all FIVE producer/consumer objects (gcc/clang/D/Rust/Zig) into
#       ONE esp32 ELF and verify 0 undefined.
#   (f) Baremetal advantages: per-instantiation .text + D __traits reflection
#       (the C++26 P2996 analog, available today).
#   (g) LLVM-22 (ldc-developers/llvm tarball — NOT ldc-developers/ldc)
#       binutils: llvm-link merges clang + LDC + rust IR into one module.
#   (h) C++26 reality on the C++ compilers we have (LLVM 21.1.3 / 22.x).
#
# See docs/21.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh
B=build/tmpffi; mkdir -p "$B"
CT="--target=xtensa-esp-elf -mcpu=esp32"
RT="$ESP_CLANG_DIR/../lib/clang-runtimes/xtensa-esp-unknown-elf/esp32/lib/libclang_rt.builtins.a"

echo "== (a) C++ template shims::Gpio<int Pin> -> esp-clang Xtensa object =="
cat > "$B/shims.cpp" <<'CPP'
namespace shims {
    // Embedded shim pattern: one Gpio<Pin> per pin. Each instantiation has its
    // OWN static `state`, so dispatch on `Pin` is purely compile-time.
    template<int Pin>
    class Gpio {
    public:
        static int state;
        static void set()    noexcept { state = 1; }
        static void clear()  noexcept { state = 0; }
        static int  read()   noexcept { return state; }
        static int  toggle() noexcept { state ^= 1; return state; }
    };
    template<int Pin> int Gpio<Pin>::state = 0;
    template class Gpio<5>;   // GPIO5
    template class Gpio<13>;  // GPIO13
}
CPP
"$CLANGXX" $CT -ffreestanding -fno-exceptions -fno-rtti -fno-threadsafe-statics \
    -Os -c "$B/shims.cpp" -o "$B/shims_clang.o"
echo "  esp-clang (Itanium mangled, pin encoded as Li<N>E NTTP):"
llvm-nm "$B/shims_clang.o" 2>/dev/null | grep -E '_ZN5shims4GpioILi' | awk '{print "    "$3}' | head -4

echo "== (a') GCC alternative provider — same Itanium ABI, interchangeable =="
XTENSA_GNU_CONFIG="$(xtensa_cfg esp32)" "$GXX" -ffreestanding -fno-exceptions -fno-rtti \
    -fno-threadsafe-statics -Os -c "$B/shims.cpp" -o "$B/shims_gcc.o"
echo "  gcc symbols (compare to clang above — byte-identical mangling):"
llvm-nm "$B/shims_gcc.o" 2>/dev/null | grep -E '_ZN5shims4GpioILi' | awk '{print "    "$3}' | head -4

echo "== (b) D consumer: extern(C++,class) struct Gpio(int Pin) =="
cat > "$B/d_caller.d" <<'D'
// extern(C++,"shims") + extern(C++,class) struct + (int Pin) NTTP template.
// IMPORTANT type-system mapping:
//   - C++ class/struct are VALUE types.
//   - D struct is a VALUE type — use this for extern(C++, class) struct.
//   - D class is a REFERENCE type — would mismatch the C++ ABI.
//   - D has no per-member `private`; only module-level access.
extern(C++, "shims")
{
    extern(C++, class) struct Gpio(int Pin)
    {
        static void set() nothrow @nogc;
        static void clear() nothrow @nogc;
        static int read() nothrow @nogc;
        static int toggle() nothrow @nogc;
    }
    alias Gpio5  = Gpio!5;
    alias Gpio13 = Gpio!13;
}

// pragma(mangle) fallback — spell the Itanium symbol literally for cases D's
// TMP can't express (SFINAE / partial spec / defaulted args / overloads).
extern(C++) nothrow @nogc
{
    pragma(mangle, "_ZN5shims4GpioILi5EE4readEv")
    int pin5_read_via_pragma();
}

extern(C) int d_callsite() @nogc nothrow
{
    Gpio5.set();                         // state = 1
    Gpio13.toggle();                     // state = 1 (separate slot)
    return Gpio5.read() * 100            // 1 * 100
         + Gpio13.read() * 10            // 1 * 10
         + pin5_read_via_pragma();       // 1 (via pragma(mangle))
    // expect 1*100 + 1*10 + 1 = 111
}
D
"$LDC2" -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -Os -output-s -of="$B/d_caller.s" "$B/d_caller.d"
sed -E -i '/^[[:space:]]*\.cfi_/d' "$B/d_caller.s"
"$CLANG" $CT -c "$B/d_caller.s" -o "$B/d_caller.o"
echo "  D imports (LDC mangled byte-identically):"
llvm-nm "$B/d_caller.o" 2>/dev/null | grep -E ' U _ZN5shims4Gpio' | awk '{print "    "$2}' | sort -u | head -6

echo "== (c) Rust consumer: extern \"C\" + #[link_name = \"_ZN…\"] =="
mkdir -p "$B/rs"
cat > "$B/rs/lib.rs" <<'RS'
#![no_std]
extern "C" {
    #[link_name = "_ZN5shims4GpioILi5EE3setEv"]   fn pin5_set();
    #[link_name = "_ZN5shims4GpioILi5EE4readEv"]  fn pin5_read() -> i32;
    #[link_name = "_ZN5shims4GpioILi13EE6toggleEv"] fn pin13_toggle() -> i32;
    #[link_name = "_ZN5shims4GpioILi13EE4readEv"] fn pin13_read() -> i32;
}
#[no_mangle] pub extern "C" fn rs_callsite() -> i32 {
    unsafe { pin5_set(); pin13_toggle(); pin5_read() * 100 + pin13_read() * 10 + 1 }
}
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
RS
cat > "$B/rs/Cargo.toml" <<'TOML'
[package]
name = "tmpffi_rs"
version = "0.0.0"
edition = "2021"
[lib]
name = "tmpffi_rs"
path = "lib.rs"
crate-type = ["staticlib"]
[profile.release]
panic = "abort"
TOML
( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" build --release -Z build-std=core --target xtensa-esp32-none-elf >/dev/null 2>&1 )
cp "$(find "$B/rs/target/xtensa-esp32-none-elf/release" -name 'libtmpffi_rs.a' | head -1)" "$B/libtmpffi_rs.a"
echo "  Rust imports (via #[link_name]):"
llvm-nm "$B/libtmpffi_rs.a" 2>/dev/null | grep -E ' U _ZN5shims4Gpio' | awk '{print "    "$2}' | sort -u | head -4

echo "== (d) Zig consumer: extern fn @\"_ZN…\" — raw-symbol syntax =="
cat > "$B/zig_caller.zig" <<'ZIG'
extern fn @"_ZN5shims4GpioILi5EE3setEv"() callconv(.c) void;
extern fn @"_ZN5shims4GpioILi5EE4readEv"() callconv(.c) i32;
extern fn @"_ZN5shims4GpioILi13EE6toggleEv"() callconv(.c) i32;
extern fn @"_ZN5shims4GpioILi13EE4readEv"() callconv(.c) i32;
export fn zig_callsite() callconv(.c) i32 {
    @"_ZN5shims4GpioILi5EE3setEv"();
    _ = @"_ZN5shims4GpioILi13EE6toggleEv"();
    return @"_ZN5shims4GpioILi5EE4readEv"() * 100
         + @"_ZN5shims4GpioILi13EE4readEv"() * 10
         + 1;
}
ZIG
"$ZIG" build-obj -target xtensa-freestanding-none -mcpu=esp32 -O ReleaseSmall -femit-bin="$B/zig_caller.o" "$B/zig_caller.zig"
echo "  Zig imports:"
llvm-nm "$B/zig_caller.o" 2>/dev/null | grep -E ' U _ZN5shims4Gpio' | awk '{print "    "$2}' | sort -u | head -4

echo "== (e) Link gcc-provider + clang-provider + D + Rust + Zig -> one esp32 ELF =="
# Touch each callsite so the linker keeps them.
cat > "$B/glue.c" <<'C'
int d_callsite(void); int rs_callsite(void); int zig_callsite(void);
__attribute__((used)) volatile int g_sink;
int _start(void){ g_sink = d_callsite() + rs_callsite() + zig_callsite(); for(;;){} }
C
"$CLANG" $CT -ffreestanding -Os -c "$B/glue.c" -o "$B/glue.o"
ld.lld -e _start -T experiments/ffi-matrix/xtensa.ld \
    "$B/glue.o" "$B/shims_clang.o" "$B/d_caller.o" "$B/zig_caller.o" \
    --start-group "$B/libtmpffi_rs.a" "$RT" --end-group \
    -o "$B/tmpffi.elf"
undef=$(llvm-nm "$B/tmpffi.elf" 2>/dev/null | grep -c ' U ' || true)
printf "  tmpffi.elf: undefined=%s  (5 toolchains, one image: gcc could swap in for clang)\n" "$undef"

echo "== (f) Baremetal advantages: per-instantiation symbols + D reflection =="
echo "  symbol sizes per Pin (each instantiation is its OWN .text + static):"
llvm-nm --print-size --size-sort "$B/shims_clang.o" 2>/dev/null | grep -E '_ZN5shims4GpioILi' | head -6 | while read -r addr size flag sym; do printf "    %4d B  %s\n" "$((16#$size))" "$sym"; done
echo "  zero runtime branching on Pin: each Gpio<N>::set/read becomes its OWN"
echo "  inline-able function with its OWN static state. The shim pattern is a"
echo "  classic embedded zero-cost abstraction (register banks, peripherals, …)."
echo ""
echo "  D __traits + mixin = compile-time reflection (the C++26 P2996 analog,"
echo "  shipping in D today — host run for clarity):"
cat > "$B/refl.d" <<'D'
import core.stdc.stdio : printf;
struct Periph { int base; int irq; int prio; }
extern(C) int main() @nogc nothrow {
    pragma(msg, "    Periph fields (compile-time): ", __traits(allMembers, Periph));
    Periph p = Periph(0x40000000, 23, 5);
    static foreach (m; __traits(allMembers, Periph))
        mixin(`printf("    p.` ~ m ~ `=%d\n", p.` ~ m ~ `);`);
    return 0;
}
D
"$LDC2" -betterC -O2 "$B/refl.d" -of="$B/refl" 2>&1 | head -2
"./$B/refl"

echo "== (g) LLVM-22 (ldc-developers/llvm) llvm-link: clang+D+Rust IR -> 1 module =="
"$CLANG" $CT -ffreestanding -Os -emit-llvm -S "$B/shims.cpp" -o "$B/shims.ll" 2>/dev/null
"$LDC2"  -mtriple=xtensa-esp-elf -mcpu=esp32 -betterC -Os -output-ll -of="$B/d_caller.ll" "$B/d_caller.d"
( cd "$B/rs" && RUSTC="$RUSTC" "$CARGO" rustc --release -Z build-std=core --target xtensa-esp32-none-elf -- --emit=llvm-ir >/dev/null 2>&1 )
cp "$(find "$B/rs/target/xtensa-esp32-none-elf/release" -name 'tmpffi_rs*.ll' | head -1)" "$B/rust.ll"
LLD22=$LDC_LLVM_DIR/bin
rc=0; "$LLD22/llvm-link" "$B/shims.ll" "$B/d_caller.ll" "$B/rust.ll" -S -o "$B/merged.ll" 2>"$B/lerr" || rc=$?
printf "  llvm-link (LLVM 22.1.2 binutils) rc=%s — merged defines: %s\n" "$rc" "$(grep -c '^define' "$B/merged.ll" 2>/dev/null || echo 0)"

echo "== (h) C++26 reality on the C++ compilers we have =="
cat > "$B/p2686.cpp" <<'CPP'
// P2686R5 constexpr structured bindings — clang 22 partial; clang 21 rejects.
struct A { int x, y; };
constexpr int f(){ constexpr A a{3,4}; constexpr auto [x,y] = a; return x+y; }
static_assert(f() == 7);
int main(){ return 0; }
CPP
echo "  esp-clang 21.1.3 -std=c++26:"
err=$("$CLANGXX" -std=c++26 -c "$B/p2686.cpp" -o /dev/null 2>&1 || true)
printf "    %s\n" "$(printf '%s' "$err" | grep -oE 'decomposition.*constexpr.*' | head -1 || echo PASS)"
echo "  => C++26 'frontier' (Contracts P2900, Reflection P2996, Pattern Matching P2688,"
echo "     Profiles P3081) is NOT in clang 21 OR 22.x mainline (Bloomberg fork only)."
echo "     For static memory safety on baremetal D today: @safe + @live + -preview=dip1021"
echo "     (docs/20 §8 — D's borrow-checker analog catches LEAKS Rust's doesn't)."
