// heap.cpp — C++ class on operator new (which calls malloc on bare-metal).

#include <stddef.h>
extern "C" void *malloc(size_t);
extern "C" void  free(void *);

// Inline placement-new operator so we don't need <new> (which pulls
// libsupc++/libstdc++ on bare-metal). The expression `new (p) T(args)`
// resolves to this.
inline void *operator new(size_t, void *p) noexcept { return p; }

struct Counter {
    int v;
    int step;
    Counter(int s) : v(0), step(s) {}
    int tick() { v += step; return v; }
};

// Allocate + construct in one step. With placement-new on a malloc'd buffer
// this is what `new Counter(s)` would do if the global new were available.
extern "C" Counter *make_counter_cpp(int step) {
    void *m = malloc(sizeof(Counter));
    if (!m) return nullptr;
    return new (m) Counter(step);
}
