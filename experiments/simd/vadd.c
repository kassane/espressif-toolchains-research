#include <stdint.h>
/* textbook auto-vectorizable loops over the esp32s3-SIMD-friendly element types */
void vadd_i8 (int8_t*  c, const int8_t*  a, const int8_t*  b, int n){ for(int i=0;i<n;i++) c[i]=(int8_t)(a[i]+b[i]); }
void vadd_i16(int16_t* c, const int16_t* a, const int16_t* b, int n){ for(int i=0;i<n;i++) c[i]=(int16_t)(a[i]+b[i]); }
void vadd_i32(int32_t* c, const int32_t* a, const int32_t* b, int n){ for(int i=0;i<n;i++) c[i]=a[i]+b[i]; }
void vmul_f32(float*   c, const float*   a, const float*   b, int n){ for(int i=0;i<n;i++) c[i]=a[i]*b[i]; }
