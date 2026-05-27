#![no_std]
use core::ptr::NonNull;
extern "C" { fn zig_opt(p: Option<NonNull<u8>>) -> usize; } // Zig ?*const u8
static X: u8 = 0xAB;
// Rust's Option<NonNull<T>> is FFI-safe (a nullable pointer); pass Some/None to Zig.
#[no_mangle] pub extern "C" fn rs_check_opt() -> i32 {
    let some = unsafe { zig_opt(Some(NonNull::from(&X))) };
    let none = unsafe { zig_opt(None) };
    if some == (&X as *const u8 as usize) && none == 0 { 1 } else { 0 }
}
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
