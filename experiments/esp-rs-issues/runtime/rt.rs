#![no_std]
#![feature(c_variadic)]
use core::ffi::c_int;
// #177: a Rust C-variadic function. C calls this; on Xtensa the args were
// reported as garbage. Sums `n` int varargs.
#[no_mangle]
pub unsafe extern "C" fn rs_vsum(n: c_int, mut args: ...) -> c_int {
    let mut s: c_int = 0;
    let mut i = 0;
    while i < n { s += args.arg::<c_int>(); i += 1; }
    s
}
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }

// #161: Iterator::position miscompiled at opt-level=s (returned wrong index).
#[no_mangle]
pub extern "C" fn rs_find_pos(needle: u32, ptr: *const u32, n: usize) -> i32 {
    let s = unsafe { core::slice::from_raw_parts(ptr, n) };
    match s.iter().position(|&c| c == needle) { Some(i) => i as i32, None => -1 }
}

// #278: narrow stack-arg store hazard. We declare fm with narrow types so
// the Rust caller emits s8i/s16i (the actual bug). The C-side fm in rt_main.c
// is declared with FULL u32 params so it reads the slots with l32i — that's
// the exact "callee reads the full 32-bit slot" scenario the upstream report
// described. If Rust narrowed, the upper bytes are whatever was on the stack
// (garbage). The reported sum will be huge instead of the expected small one.
extern "C" {
    fn fm_u32_callee(x1: i32, x2: i32, x3: i32, x4: i32, x5: i32, x6: i32,
                     a1: u8, a2: u16, a3: u8, a4: u16, a5: u8) -> u32;
}
#[no_mangle]
pub unsafe extern "C" fn rs_issue278_callm(a: u8, b: u16, c: u8, d: u16, e: u8) -> u32 {
    fm_u32_callee(1, 2, 3, 4, 5, 6, a, b, c, d, e)
}
