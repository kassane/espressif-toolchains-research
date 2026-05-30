// lib.rs — Rust generic + macro feature surface for TMP parity vs D and C++.
#![no_std]
#![allow(clippy::missing_safety_doc)]

use core::ops::{Add, Mul};

#[panic_handler]
fn p(_: &core::panic::PanicInfo) -> ! { loop {} }

// =============================================================================
// §(a) Generic parameter forms
// =============================================================================

// Type parameter
fn id_rs<T>(x: T) -> T { x }
#[no_mangle] pub extern "C" fn id_int_rs(x: i32) -> i32 { id_rs(x) }
#[no_mangle] pub extern "C" fn id_long_rs(x: i64) -> i64 { id_rs(x) }

// Const generic (Rust's NTTP) — stable for primitive types since 1.51
fn multiply_by_rs<T: Mul<Output = T> + Copy + From<i32>, const K: i32>(x: T) -> T {
    x * T::from(K)
}
#[no_mangle] pub extern "C" fn mul_by_3_rs(x: i32) -> i32 { multiply_by_rs::<i32, 3>(x) }
#[no_mangle] pub extern "C" fn mul_by_5_rs(x: i32) -> i32 { multiply_by_rs::<i32, 5>(x) }

// Higher-order: function as parameter (like D's `alias Sym`). Use Rust calling
// convention through the chain so the type system unifies — the C-linkage entry
// is the outermost `wrap_dbl_rs`.
fn wrap_rs(sym: fn(i32) -> i32, x: i32) -> i32 { sym(x) }
fn dbl_rs(x: i32) -> i32 { x.wrapping_add(x) }
#[no_mangle] pub extern "C" fn wrap_dbl_rs(x: i32) -> i32 { wrap_rs(dbl_rs, x) }

// String NTTP — *NOT YET STABLE*. Custom struct-as-NTTP requires the unstable
// `adt_const_params` feature (compiler suggested it above), which is nightly-
// only. Demonstrate the limitation by leaving this commented out.
//
// #![feature(adt_const_params)]
// #[derive(PartialEq, Eq)]
// struct Str<const N: usize>([u8; N]);
// fn greet_rs<const S: Str<5>>() -> u8 { S.0[0] }

// =============================================================================
// §(b) Trait bounds (Rust's C++ concepts analog) and `where` clauses
// =============================================================================

fn add_only_arith_rs<T>(a: T, b: T) -> T
where T: Add<Output = T> + Copy {
    a + b
}
#[no_mangle] pub extern "C" fn add_int_rs(a: i32, b: i32) -> i32 { add_only_arith_rs(a, b) }

// =============================================================================
// §(c) Specialization — Rust has NONE on stable
// =============================================================================

// Workaround: trait method default + per-type override. NOT the same thing as
// template specialization (the compiler can't pick a more specific impl based
// on a generic argument constraint at the call site).
trait Pow2Rs { fn pow2(self) -> Self; }
impl Pow2Rs for i32   { fn pow2(self) -> Self { self << 1 } }
impl Pow2Rs for f64   { fn pow2(self) -> Self { self * 2.0 } }

#[no_mangle] pub extern "C" fn pow2_int_rs(n: i32) -> i32 { n.pow2() }
#[no_mangle] pub extern "C" fn pow2_double_rs(n: f64) -> f64 { n.pow2() }

// =============================================================================
// §(d) Compile-time if (Rust's `if constexpr` analog)
// =============================================================================

// Rust has no `if constexpr`. The closest is `core::any::TypeId` checks (runtime)
// or using trait bounds to select via the trait method. Or `cfg!()` macro for
// build-time constants. None of these are language-level `static if`.
//
// Workaround using trait dispatch (similar to specialization workaround):
trait SumDiff { fn sumdiff_rs(a: Self, b: Self) -> Self; }
impl SumDiff for i32   { fn sumdiff_rs(a: Self, b: Self) -> Self { a - b } }
impl SumDiff for f32   { fn sumdiff_rs(a: Self, b: Self) -> Self { a + b } }

#[no_mangle] pub extern "C" fn sd_i_rs(a: i32, b: i32) -> i32 { SumDiff::sumdiff_rs(a, b) }
#[no_mangle] pub extern "C" fn sd_f_rs(a: f32, b: f32) -> f32 { SumDiff::sumdiff_rs(a, b) }

// Token mixin via macro_rules! — declarative, hygienic. The natural form would
// be `${concat(gen_, $n, _rs)}` to programmatically build identifiers, but
// `macro_metavar_expr_concat` is *nightly* (issue #124225). On stable, the
// crate `paste!()` does it; without a dependency we expand manually here. The
// gap: Rust cannot synthesize identifiers from compile-time integer values
// declaratively, whereas D can with `mixin("...")` + `i.stringof`.
#[no_mangle] pub extern "C" fn gen_0_rs(x: i32) -> i32 { x.wrapping_add(0) }
#[no_mangle] pub extern "C" fn gen_1_rs(x: i32) -> i32 { x.wrapping_add(1) }
#[no_mangle] pub extern "C" fn gen_2_rs(x: i32) -> i32 { x.wrapping_add(2) }

// =============================================================================
// §(e) Compile-time computation (Rust `const fn`)
// =============================================================================

const fn fact_rs(n: i32) -> i32 {
    if n <= 1 { 1 } else { n * fact_rs(n - 1) }
}
const FACT5_RS: i32 = fact_rs(5);   // const-evaluated
#[no_mangle] pub extern "C" fn get_fact5_rs() -> i32 { FACT5_RS }

// =============================================================================
// §(f) Type introspection — Rust has NONE in-language
// =============================================================================

// `core::mem::size_of::<T>()` works at compile time, but there's no way to
// iterate the fields of a struct or generate code for each one in stable Rust.
// The procedural-macro path (syn + quote) does it, but at HOST compile time,
// not in-language. So the §f section is a deliberate gap — see docs/26.
//
// Closest stable Rust approximation: the `Default::default()` + manual field
// iteration in code. For comparison-only purposes:
#[repr(C)]
pub struct PeriphRs { pub base: i32, pub irq: i32, pub prio: i32 }

#[no_mangle] pub extern "C" fn periph_n_fields_rs() -> i32 {
    3   // hand-coded, NOT computed from the type — Rust limitation
}

#[no_mangle] pub unsafe extern "C" fn sum_periph_fields_rs(p: *const PeriphRs) -> i32 {
    let p = &*p;
    p.base.wrapping_add(p.irq).wrapping_add(p.prio)
}

// =============================================================================
// §(g) Variadic generics — Rust has NONE
// =============================================================================

// `template<typename... Ts>` and D's `T(T...)` have no Rust equivalent.
// The standard workaround is a macro_rules! that emits one impl per arity.
// Show the macro pattern (declarative, hygienic, compile-time) emitting
// `static_sum_3()` etc.:
macro_rules! make_static_sum {
    ($name:ident, $($v:expr),+) => {
        #[no_mangle] pub extern "C" fn $name() -> i32 {
            0 $( + $v )+
        }
    };
}
make_static_sum!(variadic_42_rs, 10, 20, 12);  // → ret i32 42 (folded)

// Compare to D's recursive variadic template `StaticSum!(10, 20, 12)`. The Rust
// macro_rules! works token-level (gives you `0 + 10 + 20 + 12` literally and
// the const-folder collapses it), while D's variadic recurses at the type
// system level. Both reach the same IR. The capability gap: Rust can't pass
// variadic *types*, only variadic *expressions*.

// Subtract function to demonstrate the macro doesn't only do sums:
macro_rules! make_static_op {
    ($name:ident, $op:tt, $($v:expr),+) => {
        #[no_mangle] pub extern "C" fn $name() -> i32 {
            0 $( $op $v )+
        }
    };
}
make_static_op!(variadic_neg42_rs, -, 10, 20, 12);   // → -42
