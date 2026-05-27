#![no_std]
extern "C" { fn zig_add_u128(a: u128, b: u128) -> u128; }
// Rust builds two u128s, hands them to Zig, and checks carry across all 4 words.
#[no_mangle] pub extern "C" fn rs_check_u128() -> i32 {
    let a: u128 = 0x1111_2222_3333_4444_5555_6666_7777_8888;
    let b: u128 = 0x0000_0000_0000_0001_FFFF_FFFF_FFFF_FFFF;
    if unsafe { zig_add_u128(a, b) } == a.wrapping_add(b) { 1 } else { 0 }
}
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
