// lib.rs — Rust zero-cost-abstraction probes (no_std, panic=abort).
#![no_std]
#![allow(clippy::missing_safety_doc)]

use core::ops::Add;

#[panic_handler]
fn p(_: &core::panic::PanicInfo) -> ! { loop {} }

extern "C" {
    fn malloc(size: usize) -> *mut u8;
}

// -----------------------------------------------------------------------------
// §(a) Generic accumulator — three Rust forms

// (a.1) Hand-rolled for-loop (lowest level / closest to C)
#[no_mangle]
pub unsafe extern "C" fn sum_rs_loop(p: *const i32, n: i32) -> i32 {
    let mut s = 0i32;
    let mut i = 0i32;
    while i < n {
        s = s.wrapping_add(*p.offset(i as isize));
        i += 1;
    }
    s
}

// (a.2) Idiomatic iterator chain — `.iter().sum()`
#[no_mangle]
pub unsafe extern "C" fn sum_rs_iter(p: *const i32, n: i32) -> i32 {
    let slice = core::slice::from_raw_parts(p, n as usize);
    slice.iter().copied().fold(0i32, |a, b| a.wrapping_add(b))
}

// (a.3) Generic over `T: Add<Output=T> + Copy + Default` — instantiated at i32
fn sum_rs_generic<T: Add<Output = T> + Copy + Default>(p: *const T, n: i32) -> T {
    let mut s = T::default();
    let mut i = 0i32;
    while i < n {
        s = s + unsafe { *p.offset(i as isize) };
        i += 1;
    }
    s
}

#[no_mangle]
pub unsafe extern "C" fn sum_rs_generic_i32(p: *const i32, n: i32) -> i32 {
    sum_rs_generic::<i32>(p, n)
}

// -----------------------------------------------------------------------------
// §(b) Higher-order function

extern "C" fn doubler_rs(x: i32) -> i32 { x.wrapping_add(x) }

// (b.1) Raw function pointer — indirect call
#[no_mangle]
pub extern "C" fn apply_rs_fnptr(f: extern "C" fn(i32) -> i32, x: i32) -> i32 { f(x) }

#[no_mangle]
pub extern "C" fn call_apply_rs_fnptr(x: i32) -> i32 { apply_rs_fnptr(doubler_rs, x) }

// (b.2) Generic over `F: Fn(i32) -> i32` — monomorphizes, body visible, inlines
fn apply_rs_generic<F: Fn(i32) -> i32>(f: F, x: i32) -> i32 { f(x) }

#[no_mangle]
pub extern "C" fn call_apply_rs_generic(x: i32) -> i32 {
    apply_rs_generic(|y| y.wrapping_add(y), x)
}

// -----------------------------------------------------------------------------
// §(c) Static vs dynamic dispatch

trait Tick { fn tick(&mut self) -> i32; }

struct CounterRs { v: i32, step: i32 }
impl Tick for CounterRs {
    fn tick(&mut self) -> i32 { self.v = self.v.wrapping_add(self.step); self.v }
}

// (c.1) Static: generic over T: Tick — monomorphized, inlined
fn static_loop<T: Tick>(t: &mut T, n: i32) -> i32 {
    let mut last = 0;
    let mut i = 0;
    while i < n { last = t.tick(); i += 1; }
    last
}

#[no_mangle]
pub extern "C" fn use_static_rs(n: i32) -> i32 {
    let mut c = CounterRs { v: 0, step: 3 };
    static_loop(&mut c, n)
}

// (c.2) Dynamic: dyn Tick — vtable, indirect call per iteration
#[no_mangle]
pub extern "C" fn use_dynamic_rs(n: i32, t: &mut dyn Tick) -> i32 {
    let mut last = 0;
    let mut i = 0;
    while i < n { last = t.tick(); i += 1; }
    last
}

// -----------------------------------------------------------------------------
// §(d) Heap allocation via raw malloc (parity with C++ new and D malloc-class)

// Rust's `Box::new` requires a global allocator. On bare-metal with `no_std`
// you'd register a #[global_allocator]; instead we just call malloc directly
// to mirror the C++ + D-betterC pattern. The point is to compare instruction
// counts, not to demonstrate idiomatic Rust embedded patterns.
#[repr(C)]
pub struct CounterRsHeap { pub v: i32, pub step: i32 }

#[no_mangle]
pub unsafe extern "C" fn make_counter_rs(step: i32) -> *mut CounterRsHeap {
    let p = malloc(core::mem::size_of::<CounterRsHeap>()) as *mut CounterRsHeap;
    if p.is_null() { return p; }
    (*p).v = 0;
    (*p).step = step;
    p
}
