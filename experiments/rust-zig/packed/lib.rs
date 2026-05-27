#![no_std]
// Rust #[repr(packed)] = byte-packed (no padding, align 1); NO sub-byte fields.
// For C-ABI interop use #[repr(C)] <-> Zig `extern struct`.
#[repr(packed)] pub struct Pp { a: u8, b: u8 }  // size 2, align 1
#[repr(C)]      pub struct Ec { a: u8, b: u8 }   // size 2, C layout
#[no_mangle] pub extern "C" fn r_size_packed() -> usize { core::mem::size_of::<Pp>() }
#[no_mangle] pub extern "C" fn r_size_extern() -> usize { core::mem::size_of::<Ec>() }
#[no_mangle] pub extern "C" fn r_take_extern(s: Ec) -> u8 { s.a.wrapping_add(s.b) }
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
