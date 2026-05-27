#include <stdint.h>
/* #95 port: tagged-union switch (the codegen pattern that ICE'd on LLVM 12) */
enum Tag { A, B, C, D };
struct E { enum Tag tag; };
uint8_t c_issue95_tag(const struct E* e) {
    switch (e->tag) { case A: return 0; case B: return 1; case C: return 2; default: return 3; }
}
/* #277 port: [2 x float] constant pool referenced by value */
float c_issue277_pick(unsigned i) { static const float t[2] = {-1.0f, 1.0f}; return t[i % 2]; }
/* NOTE: #137's u128 is OMITTED -- __int128 is unsupported by clang/gcc on xtensa. */
