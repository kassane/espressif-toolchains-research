# 12 — Calling mangled C++/Rust symbols from Zig (`@"…"`)

FFI normally goes through `extern "C"` (unmangled). But Zig can reference *any*
symbol by its exact name using the `@"…"` identifier syntax, so it can call
**non-`extern "C"`, name-mangled** C++ and Rust functions directly — no wrapper.
Runnable demo: `experiments/mangled-ffi/run.sh` (host x86_64).

TinyGo isn't a peer here: its symbols mangle as `<package>.<func>` (see
docs/22 §g, docs/24), `//export name` adds a bare-C alias, and TinyGo's `.o`
needs Go runtime undefs supplied (docs/24 §d) so the cross-language matrix
this doc demonstrates is not the natural way to call into Go.

```zig
// the symbol name is literally the mangled string; callconv(.c) sets the ABI
extern fn @"_ZN4demo3addEii"(a: i32, b: i32) callconv(.c) i32; // demo::add(int,int)
export fn zig_calls_cpp(a: i32, b: i32) i32 { return @"_ZN4demo3addEii"(a, b); }
```

## C++ — clean and practical

Itanium-mangled C++ symbols (`_Z…`) are **global and stable**, and a free
function's C++ ABI **is** the C ABI, so `callconv(.c)` is correct. Zig calls them
directly — and you can even pick a specific **overload** by its mangled name:

```
_ZN4demo3addEii  -> demo::add(int,int)
_Z5scalei        -> scale(int)
_Z5scaleii       -> scale(int,int)
$ run.sh  →  zig -> mangled C++ (demo::add + scale overload): 19 (expect 19)
```

Useful for calling a C++ library that doesn't provide `extern "C"` entry points,
without writing wrappers. (Member functions, `this`, exceptions, and non-trivial
types are another matter — those involve the full C++ ABI, not just the name.)

## Rust — works, but fragile; prefer `#[no_mangle] extern "C"`

Zig can also call a Rust v0-mangled symbol (`_R…`), but two conditions bite:

1. **ABI:** the Rust fn must be `extern "C"` (the default Rust ABI is unstable and
   not C-compatible). A `pub extern "C" fn` *without* `#[no_mangle]` keeps a
   mangled name **and** the C ABI — that's the callable case.
2. **The symbol must be exported as GLOBAL.** This is the easy part to miss
   ("missing link"). A standalone `pub extern "C" fn` is *internalized* (local
   binding, or DCE'd) by:
   - `--crate-type=staticlib` (only `#[no_mangle]` is exported),
   - `-O` / `opt-level>0` (the optimizer internalizes the unreferenced symbol),
   - **legacy** mangling (internalized in every standalone combo tested).

   The combination that yields a **global** mangled symbol is **v0 mangling +
   `--crate-type=lib` (rlib) + `opt-level=0`**:

   | mangling | opt | crate-type | `rust_triple` symbol |
   |----------|-----|------------|----------------------|
   | legacy | 0/2 | lib/staticlib | internalized (absent) |
   | v0 | 2 | lib/staticlib | internalized |
   | v0 | 0 | staticlib | internalized |
   | **v0** | **0** | **lib (rlib)** | **`T` global** ✓ |

```
$ run.sh  →  extracted global v0 symbol: _RNvCs25TilF4s7Dm_8rust_lib11rust_triple
             zig -> v0-mangled Rust rust_triple(7): 21 (expect 21)
```

3. **The v0 name carries an unstable crate hash** (`Cs25TilF4s7Dm_` — changes
   per build), so it must be *extracted* (e.g. `nm`), never hardcoded.

**Takeaway:** the `@"…"` trick is genuinely useful for **C++** (stable, global,
C-ABI free functions). For **Rust**, the practical FFI path remains
`#[no_mangle] extern "C"` (stable name, guaranteed global, C ABI) — exactly what
the rest of this repo uses. Calling Rust by its mangled name works only under a
narrow, build-fragile set of conditions.

## `@"…"` also works on `export fn` (Zig *provides* a mangled symbol)

The same syntax defines symbols, so Zig can **implement** a C++ (or Rust-mangled)
function that other code links against — no `extern "C"` on either side:

```zig
export fn @"_ZN4demo3addEii"(a: i32, b: i32) callconv(.c) i32 { return a +% b; }
export fn @"_Z5scaleii"(x: i32, k: i32) callconv(.c) i32 { return x *% k; }
```
```cpp
namespace demo { int add(int, int); }   int scale(int, int);   // declarations only
int main(){ return demo::add(3,4) + scale(3,4); }               // -> 19, computed in Zig
```
`run.sh` →  `c++ demo::add+scale [impl in Zig] = 19`. Zig masquerades as the C++
functions — handy for implementing/overriding a C++ interface in Zig.

## Calling a real library (libc++, or any named lib)

To call into a *library* (not just an object you link yourself), tag the import
with the library name:

```zig
extern "c++" fn @"_Znwm"(n: usize) callconv(.c) ?*anyopaque; // libc++ operator new
extern "c++" fn @"_ZdlPv"(p: ?*anyopaque) callconv(.c) void; // libc++ operator delete
```

- `extern "c++"` **names** the libc++ dependency, but Zig still **requires** it to
  be confirmed on the build command with **`-lc++`** (on *both* `build-obj` and
  the final link) — otherwise: *"dependency on libc++ must be explicitly
  specified"*. So you need **both** `extern "c++"` **and** `-lc++`.
  `run.sh` →  `zig -> libc++ operator new/delete … = 42`.
- The same applies to any library: `extern "<name>" fn @"…"` declares a
  dependency on `lib<name>` (e.g. `extern "rust"` for a Rust `dylib`), satisfied
  with `-l<name>` at link (arbitrary names are treated as **dynamic** libs and
  also want `-fPIC`). `extern "c"` likewise needs `-lc`.

> Bare-metal ESP note: the firmware C++ here is built `-nostdlib -fno-exceptions
> -fno-rtti` and never touches libc++, so `-lc++` is neither needed nor wanted on
> target. The libc++ demo above is host-context, to show the mechanism.
