#![no_std]
// ---- #277 (OPEN): does a [2 x float] constant pool ICE with PCREL_WRAPPER? ----
#[no_mangle]
pub extern "C" fn issue277_pick(i: usize) -> f32 {
    static T: [f32; 2] = [-1.0, 1.0];
    T[i % 2]
}
// ---- #95 (CLOSED): enum/match "Not supported instr" ----
pub enum Enum<'a> { A(&'a str), B { ptr: usize, len: usize }, C(&'a [u8]), D(u8) }
#[no_mangle]
pub extern "C" fn issue95_tag(e: &Enum<'_>) -> u8 {
    match e { Enum::A(_) => 0, Enum::B { .. } => 1, Enum::C(_) => 2, Enum::D(_) => 3 }
}
// ---- #137 (CLOSED): u128 multiply at opt-level=z ----
#[no_mangle]
pub extern "C" fn issue137_u128(a: u32) -> u128 { (a as u128).wrapping_mul(10) }
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }

// #277 extra attempts to trigger PCREL_WRAPPER on a [2 x float] constant pool:
#[no_mangle]
pub extern "C" fn issue277_clamp(x: f32) -> f32 { x.clamp(-1.0, 1.0) }
#[no_mangle]
pub extern "C" fn issue277_sel(c: bool) -> f32 { if c { -1.0 } else { 1.0 } }
