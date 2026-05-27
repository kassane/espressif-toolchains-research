// NOT extern "C": these get Itanium-mangled names (_Z...).
namespace demo {
int add(int a, int b) { return a + b; }
}
// overload, to show mangling disambiguates
int scale(int x) { return x * 2; }
int scale(int x, int k) { return x * k; }
