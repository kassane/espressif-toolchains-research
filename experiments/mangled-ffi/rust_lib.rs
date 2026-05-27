#![no_std]
// extern "C" ABI but NO #[no_mangle] -> symbol is Rust v0-mangled (_R...),
// yet the calling convention is the C ABI. So Zig can call it by its mangled
// name with callconv(.c).
pub extern "C" fn rust_triple(x: i32) -> i32 { x.wrapping_mul(3) }
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
