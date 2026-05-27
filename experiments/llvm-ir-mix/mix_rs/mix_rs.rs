#![no_std]
#[no_mangle]
pub extern "C" fn rs_sq(x: i32) -> i32 { x.wrapping_mul(x) }
#[panic_handler]
fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
