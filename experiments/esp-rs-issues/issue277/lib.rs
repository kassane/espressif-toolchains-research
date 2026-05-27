#![no_std]
extern crate alloc;
use alloc::vec::Vec;
use serde::Deserialize;

#[derive(Deserialize)]
pub struct Inner { pub x: f32 }
#[derive(Deserialize)]
#[serde(tag = "kind")]
pub enum Outer { B { items: Vec<Inner> } }

#[no_mangle]
pub extern "C" fn parse(json: *const u8, len: usize) -> usize {
    let bytes = unsafe { core::slice::from_raw_parts(json, len) };
    match serde_json::from_slice::<Outer>(bytes) {
        Ok(Outer::B { items }) => items.len(),
        Err(_) => 0,
    }
}
use core::alloc::{GlobalAlloc, Layout};
struct Z;
unsafe impl GlobalAlloc for Z {
    unsafe fn alloc(&self, _: Layout) -> *mut u8 { core::ptr::null_mut() }
    unsafe fn dealloc(&self, _: *mut u8, _: Layout) {}
}
#[global_allocator] static A: Z = Z;
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
