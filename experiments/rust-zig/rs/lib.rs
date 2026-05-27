#![no_std]
#![feature(f16, f128)]
#[no_mangle] pub extern "C" fn rs_add_u128(a: u128, b: u128) -> u128 { a.wrapping_add(b) }
#[no_mangle] pub extern "C" fn rs_add_f16(a: f16, b: f16) -> f16 { a + b }
#[no_mangle] pub extern "C" fn rs_add_f128(a: f128, b: f128) -> f128 { a + b }
#[no_mangle] pub extern "C" fn rs_not(b: bool) -> bool { !b }
#[repr(C)] pub enum E { A, B, C }
#[no_mangle] pub extern "C" fn rs_enum(e: E) -> i32 { e as i32 + 1 }
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
