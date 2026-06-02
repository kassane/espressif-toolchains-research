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
// ---- #278 (OPEN, as of 2026-05): narrow stack-arg store width ----
// Rust caller analog of ports.c/ports.zig/ports.d's callm. 6 reg args + 5
// narrow stack args (u8/u16) — the windowed Xtensa ABI says stack args
// occupy a full 4-byte slot, so the caller MUST widen to s32i. Per the
// issue, rust historically used s16i/s8i (4-byte slot OK, but reads as
// upper-bytes-undefined). Probed in open-issues.sh §"#278".
extern "C" {
    fn fm(a: i32, b: i32, c: i32, d: i32, e: i32, f: i32,
          a1: u8, a2: u16, a3: u8, a4: u16, a5: u8) -> u32;
}
#[no_mangle]
pub unsafe extern "C" fn rs_issue278_callm(a: u8, b: u16, c: u8, d: u16, e: u8) -> u32 {
    fm(1, 2, 3, 4, 5, 6, a, b, c, d, e)
}
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }

// #277 extra attempts to trigger PCREL_WRAPPER on a [2 x float] constant pool:
#[no_mangle]
pub extern "C" fn issue277_clamp(x: f32) -> f32 { x.clamp(-1.0, 1.0) }
#[no_mangle]
pub extern "C" fn issue277_sel(c: bool) -> f32 { if c { -1.0 } else { 1.0 } }
