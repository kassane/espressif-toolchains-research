#include <stdio.h>
extern int zig_calls_cpp(int, int);
int main(void) {
    int r = zig_calls_cpp(3, 4);              /* demo::add(3,4)=7 + scale(3,4)=12 = 19 */
    printf("zig -> mangled C++ (demo::add + scale overload): %d (expect 19)\n", r);
    return r != 19;
}
