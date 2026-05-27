#include <stdint.h>
typedef struct { uint8_t data[24]; } Blob;
extern uint32_t ext_blob_sum(Blob);
uint32_t caller(Blob b) { return ext_blob_sum(b); }
