// Non-inlined C++ to expose the Itanium C++ ABI surface (mangling + vtable)
// for the zig c++ / esp-clang++ / esp-g++ parity check.
namespace demo { __attribute__((noinline)) int add(int a, int b) { return a + b; } }
struct Base { virtual int f(int); virtual ~Base(); };
struct Derived : Base { int f(int x) override { return x + 1; } };
int Base::f(int x) { return x; }
Base::~Base() {}
__attribute__((used)) Base* mk() { static Derived d; return &d; }
