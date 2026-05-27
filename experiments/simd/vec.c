#include <stdint.h>
// Explicit GCC/clang vector type — on esp32s3 it SCALARIZES (no q-reg codegen).
typedef int8_t v16i8 __attribute__((vector_size(16)));
v16i8 vadd16(v16i8 a, v16i8 b) { return a + b; }
