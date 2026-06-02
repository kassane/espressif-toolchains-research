/* rt_callee.c — opaque callee TU for the #278 runtime probe.
 *
 * Declared with FULL u32 params so the function reads each stack slot with
 * l32i (the upper bytes are visible). Lives in its own TU so frontends'
 * caller-side optimizers cannot see through the type and "fix" the narrow
 * stores. This is the actual hazard from esp-rs/rust#278: the callee was
 * a C function from a third-party C library (declared as the wider type),
 * but the Rust binding declared the same function with narrow types. */
unsigned fm_u32_callee(int x1, int x2, int x3, int x4, int x5, int x6,
                       unsigned a1, unsigned a2, unsigned a3,
                       unsigned a4, unsigned a5) {
    (void)x1; (void)x2; (void)x3; (void)x4; (void)x5; (void)x6;
    return a1 + a2 + a3 + a4 + a5;
}
