// tmp.d — D template-metaprogramming feature surface for parity vs C++/Rust.
// Compile with $LDC2 $LT $LDC_PE -betterC -O2 -c.
// Each block exercises one TMP capability; the verification target is whether
// the resulting LLVM IR shows the expected compile-time work happening.
module tmp;
extern (C):

// =============================================================================
// §(a) Template parameter forms
// =============================================================================

// Type parameter
T id(T)(T x) { return x; }
int  id_int(int  x)   { return id!int(x); }
long id_long(long x)  { return id!long(x); }

// Non-type template parameter (NTTP)
T multiply_by(T, int K)(T x) { return cast(T)(x * K); }
int mul_by_3(int x) { return multiply_by!(int, 3)(x); }
int mul_by_5(int x) { return multiply_by!(int, 5)(x); }

// Alias parameter — D's template-template equivalent
template Wrap(alias Sym) { auto Wrap(int x) { return Sym(x); } }
int dbl(int x) { return x + x; }
int wrap_dbl(int x) { return Wrap!dbl(x); }

// String NTTP — D has had this forever (C++ needed C++20 + class-type NTTP)
template Greet(string Name) {
    enum string Greet = "hello_" ~ Name;
}
extern(D) immutable string g = Greet!"esp32";

// =============================================================================
// §(b) Template constraints (D's SFINAE)
// =============================================================================

T add_only_arith(T)(T a, T b) if (__traits(isArithmetic, T)) {
    return a + b;
}
int add_int(int a, int b) { return add_only_arith!int(a, b); }

// is(...) expressions
template IsIntegralLike(T) { enum bool IsIntegralLike = is(T : int); }
bool foo_int = IsIntegralLike!int;
bool foo_pointer = IsIntegralLike!(int*);

// =============================================================================
// §(c) Specialization
// =============================================================================

// Default + constrained-specialization pattern (D's idiom)
T pow2(T)(T n) if (!is(T == double)) { return cast(T)(n << 1); }
double pow2(T : double)(double n) { return n * 2.0; }

int  pow2_int(int  n) { return pow2!int(n); }
double pow2_d(double n) { return pow2!double(n); }

// =============================================================================
// §(d) static if / static foreach / mixin
// =============================================================================

T sumdiff(T)(T a, T b) {
    static if (__traits(isFloating, T)) return a + b;        // float path
    else                                 return a - b;        // integer path
}
int  sd_i(int a, int b) { return sumdiff!int(a, b); }
float sd_f(float a, float b) { return sumdiff!float(a, b); }

// static foreach + mixin — generate N copies of a function at compile time.
// This is the canonical D "code-gen by token" pattern; C++ has no built-in
// analog (X-macros come close), Rust uses proc-macros or macro_rules!.
static foreach (i; 0 .. 3) {
    mixin("int gen_" ~ i.stringof ~ "(int x) { return x + " ~ i.stringof ~ "; }");
}
// → emits gen_0, gen_1, gen_2 at compile time.

// =============================================================================
// §(e) CTFE (compile-time function execution)
// =============================================================================

int fact(int n) @safe { return n <= 1 ? 1 : n * fact(n - 1); }
enum int fact5 = fact(5);   // CTFE'd at compile time
int get_fact5() @safe { return fact5; }      // body should be `ret i32 120`

// CTFE on a string at compile time. NOTE: -betterC rejects the `~` operator
// even in CTFE context for *functions* (the function body is checked even if
// it's only called at CT). The enum-level form below works because the enum
// initializer is folded immediately.
//   string repeat3(string s) { return s ~ s ~ s; }   // would need full druntime
enum string r3 = "ab" ~ "ab" ~ "ab";   // → "ababab" at compile time, -betterC-OK
extern(D) immutable string r3_d = r3;

// =============================================================================
// §(f) __traits introspection
// =============================================================================

struct Periph { int base; int irq; int prio; }

// Count fields at compile time
template FieldCount(T) {
    enum size_t FieldCount = __traits(allMembers, T).length;
}
int periph_n_fields() { return cast(int) FieldCount!Periph; }   // → ret i32 3

// __traits(getMember) lets you take a string and produce a field reference
int sum_periph_fields(Periph* p) {
    int s = 0;
    static foreach (m; __traits(allMembers, Periph)) {
        s += __traits(getMember, *p, m);
    }
    return s;
}

// =============================================================================
// §(g) Variadic templates
// =============================================================================

// AliasSeq parameter pack
template StaticSum(T...) {
    static if (T.length == 0) enum int StaticSum = 0;
    else static if (T.length == 1) enum int StaticSum = T[0];
    else enum int StaticSum = T[0] + StaticSum!(T[1 .. $]);
}
int variadic_42() { return StaticSum!(10, 20, 12); }    // → ret i32 42 at compile time
