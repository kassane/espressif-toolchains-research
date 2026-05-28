// d_calls_rust.d - D references a Rust v0-mangled symbol via pragma(mangle, ...).
//
//   pragma(mangle, "literal_symbol_name") on a declaration replaces the symbol
//   that would otherwise be computed from D's name+linkage. Calling convention
//   is still chosen by `extern(...)` — here `extern(C)` because Rust's
//   `pub extern "C" fn` uses the C ABI even though its name is v0-mangled.
//
//   This is the D analogue of Zig's `extern fn @"_R..." callconv(.c)`.
//
// The v0 symbol carries an unstable crate hash, so run.sh extracts it from
// the Rust object with `nm` and code-generates this file's declaration line.

extern(C) int d_calls_rust(int x);  // forward decl (defined below)

// %V0% is replaced by run.sh with the actual extracted symbol name.
extern(C) pragma(mangle, "%V0%") int rust_triple_v0(int x);

extern(C) int d_calls_rust(int x) { return rust_triple_v0(x); }
