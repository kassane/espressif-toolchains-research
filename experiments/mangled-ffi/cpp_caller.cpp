// Declarations only; definitions are provided by Zig (under the mangled names).
extern "C" int printf(const char*, ...);
namespace demo { int add(int, int); }
int scale(int, int);
int main(void) {
    int r = demo::add(3, 4) + scale(3, 4);   // 7 + 12 = 19, both implemented in Zig
    printf("c++ demo::add+scale [impl in Zig] = %d (expect 19)\n", r);
    return r != 19;
}
