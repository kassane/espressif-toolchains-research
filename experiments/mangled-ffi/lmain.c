extern int printf(const char*, ...);
extern int zig_libcxx_roundtrip(unsigned long);
int main(void) {
    int r = zig_libcxx_roundtrip(16);
    printf("zig -> libc++ operator new/delete (extern \"c++\" + -lc++): %d (expect 42)\n", r);
    return r != 42;
}
