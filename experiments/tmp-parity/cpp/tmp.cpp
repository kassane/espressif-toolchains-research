// tmp.cpp — C++ template-metaprogramming feature parity vs D and Rust.
// Compile with $CLANGXX --target=xtensa-esp-elf -mcpu=esp32 -ffreestanding
// -fno-exceptions -fno-rtti -std=c++26 -Os.

// =============================================================================
// §(a) Template parameter forms
// =============================================================================

template <typename T> T id(T x) { return x; }
extern "C" int  id_int(int x)   { return id(x); }
extern "C" long id_long(long x) { return id(x); }

// NTTP
template <typename T, int K> T multiply_by(T x) { return T(x * K); }
extern "C" int mul_by_3(int x) { return multiply_by<int, 3>(x); }
extern "C" int mul_by_5(int x) { return multiply_by<int, 5>(x); }

// Template-template parameter
template <template<class> class Container, typename T>
int unused_template_template() { return 0; }

// String NTTP — C++20+ class-type NTTP. Custom literal-class for compile-time
// string. Probe whether clang 21 -std=c++26 accepts it.
template <unsigned N>
struct FixedString {
    char data[N];
    constexpr FixedString(const char (&s)[N]) { for (unsigned i = 0; i < N; i++) data[i] = s[i]; }
};

template <FixedString S>
struct Greeter {
    static constexpr auto value = S;
};
extern "C" char greet_first_char_cpp() { return Greeter<FixedString("hello")>{}.value.data[0]; }

// =============================================================================
// §(b) Concepts / constraints (C++20)
// =============================================================================

template <typename T> concept Arithmetic = __is_arithmetic(T);

template <Arithmetic T>
T add_only_arith(T a, T b) { return a + b; }
extern "C" int add_int_cpp(int a, int b) { return add_only_arith(a, b); }

// requires-expression
template <typename T>
constexpr bool IsIntegralLike_cpp =
    requires (T x) { x + 1; static_cast<int>(x); };

extern "C" int is_int_int_cpp()   { return IsIntegralLike_cpp<int>; }
extern "C" int is_int_voidstar()  { return IsIntegralLike_cpp<void*>; }

// =============================================================================
// §(c) Specialization
// =============================================================================

template <typename T> T pow2_cpp(T n) { return T(n << 1); }
template <>           double pow2_cpp<double>(double n) { return n * 2.0; }    // full spec

extern "C" int    pow2_int_cpp(int n)    { return pow2_cpp(n); }
extern "C" double pow2_double_cpp(double n) { return pow2_cpp(n); }

// =============================================================================
// §(d) if constexpr — C++17 analog of D's `static if`
// =============================================================================

template <typename T>
T sumdiff_cpp(T a, T b) {
    if constexpr (__is_floating_point(T)) return a + b;
    else                                  return a - b;
}
extern "C" int   sd_i_cpp(int a, int b)     { return sumdiff_cpp(a, b); }
extern "C" float sd_f_cpp(float a, float b) { return sumdiff_cpp(a, b); }

// No `mixin("code")` analog in C++. P2996/P3068 reflection would close this gap
// when shipped (not in clang 21/22 mainline). The closest is X-macros:
#define FOR_EACH_GEN(X)  X(0) X(1) X(2)
#define DECL_GEN(N)  extern "C" int gen_##N##_cpp(int x) { return x + N; }
FOR_EACH_GEN(DECL_GEN)
#undef DECL_GEN
#undef FOR_EACH_GEN

// =============================================================================
// §(e) Compile-time computation
// =============================================================================

constexpr int fact_cpp(int n) { return n <= 1 ? 1 : n * fact_cpp(n - 1); }
constexpr int fact5_cpp = fact_cpp(5);
extern "C" int get_fact5_cpp() { return fact5_cpp; }   // → ret i32 120

// =============================================================================
// §(f) Type introspection
// =============================================================================

// C++ has no in-language reflection for struct fields. P2996 (declared in C++26
// but not landed in clang 21/22) is the future. Today: type_traits + manual
// enumeration. The "count fields" trick uses aggregate init + structured bindings
// but requires the field count be known at compile time — circular for
// arbitrary types. Common workaround: PFR (Boost), reflexpr (defunct).
// We document the gap without a code probe.

// =============================================================================
// §(g) Variadic templates / fold expressions
// =============================================================================

template <typename... Ts>
constexpr auto static_sum_cpp(Ts... vs) { return (vs + ...); }
constexpr auto sum42_cpp = static_sum_cpp(10, 20, 12);
extern "C" int variadic_42_cpp() { return sum42_cpp; }   // → ret i32 42
