// Zig defines the Itanium-mangled symbol `_ZN2ns2fnEv` (ns::fn()).
// D's `extern(C++, "ns") int fn();` consumes this symbol by the same name.
export fn @"_ZN2ns2fnEv"() callconv(.c) i32 { return 99; }
