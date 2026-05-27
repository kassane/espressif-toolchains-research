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
