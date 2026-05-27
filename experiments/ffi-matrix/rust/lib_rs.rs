// lib_rs.rs - Rust implementation of the FFI contract (prefix: rs_).
//
// #![no_std] so it can target bare-metal Xtensa (xtensa-esp32-none-elf, etc.)
// and link into a -nostdlib image. Every exported symbol uses the C ABI via
// `extern "C"` + `#[no_mangle]`, and every struct is `#[repr(C)]` so the layout
// matches the C header exactly.
#![no_std]
#![allow(clippy::missing_safety_doc)]

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Point {
    pub x: i32,
    pub y: i32,
}

#[repr(C)]
#[derive(Clone, Copy)]
pub struct Blob {
    pub data: [u8; 24],
}

pub type BinOp = extern "C" fn(i32, i32) -> i32;

#[no_mangle]
pub extern "C" fn rs_add_i32(a: i32, b: i32) -> i32 {
    a.wrapping_add(b)
}

#[no_mangle]
pub extern "C" fn rs_add_i64(a: i64, b: i64) -> i64 {
    a.wrapping_add(b)
}

#[no_mangle]
pub extern "C" fn rs_mul_f32(a: f32, b: f32) -> f32 {
    a * b
}

#[no_mangle]
pub extern "C" fn rs_mul_f64(a: f64, b: f64) -> f64 {
    a * b
}

#[no_mangle]
pub extern "C" fn rs_make_point(x: i32, y: i32) -> Point {
    Point { x, y }
}

#[no_mangle]
pub extern "C" fn rs_point_dot(a: Point, b: Point) -> i32 {
    a.x.wrapping_mul(b.x).wrapping_add(a.y.wrapping_mul(b.y))
}

#[no_mangle]
pub extern "C" fn rs_make_blob(fill: u8) -> Blob {
    let mut b = Blob { data: [0u8; 24] };
    let mut i = 0;
    while i < 24 {
        b.data[i] = fill.wrapping_add(i as u8);
        i += 1;
    }
    b
}

#[no_mangle]
pub extern "C" fn rs_blob_sum(b: Blob) -> u32 {
    let mut s: u32 = 0;
    let mut i = 0;
    while i < 24 {
        s = s.wrapping_add(b.data[i] as u32);
        i += 1;
    }
    s
}

#[no_mangle]
pub extern "C" fn rs_apply(f: BinOp, a: i32, b: i32) -> i32 {
    f(a, b)
}

// no_std requires a panic handler. This object is only ever linked into a
// host test or a bare-metal image that supplies its own runtime; the handler
// is required for the crate to compile, not exercised by the FFI tests.
#[cfg(not(test))]
#[panic_handler]
fn panic(_info: &core::panic::PanicInfo) -> ! {
    loop {}
}
