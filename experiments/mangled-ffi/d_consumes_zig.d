// d_consumes_zig.d - D declares an extern(C++, "ns") function. Its mangled
// symbol is `_ZN2ns2fnEv` — the SAME symbol Zig exports via
// `export fn @"_ZN2ns2fnEv"`. So D links against the Zig-supplied definition
// without a wrapper, purely via matching Itanium mangling.
extern(C++, "ns") int fn();

extern(C) int d_consumes_zig_ns() { return fn(); }
