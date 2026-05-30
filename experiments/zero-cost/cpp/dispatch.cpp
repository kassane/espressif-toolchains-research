// dispatch.cpp — static (CRTP-like) vs dynamic (virtual) dispatch.

// (1) Static: template instantiates against the concrete type, so the body
//     of `Counter::step()` is visible at call site → inlined.
template <int Step>
struct StaticCounter {
    int v;
    int tick() { v += Step; return v; }
};

extern "C" int use_static_cpp(int n) {
    StaticCounter<3> c{0};
    int last = 0;
    for (int i = 0; i < n; i++) last = c.tick();
    return last;
}

// (2) Dynamic: virtual call goes through the vtable on every iteration.
//     Even for a known-concrete `Counter` the compiler typically can't
//     devirtualize at -Os (would need LTO + visibility hints).
struct Ticker {
    virtual int tick() = 0;
    virtual ~Ticker() = default;
};
struct DynCounter : Ticker {
    int v;
    int step;
    DynCounter(int s) : v(0), step(s) {}
    int tick() override { v += step; return v; }
};

extern "C" int use_virtual_cpp(int n, Ticker *t) {
    int last = 0;
    for (int i = 0; i < n; i++) last = t->tick();
    return last;
}
