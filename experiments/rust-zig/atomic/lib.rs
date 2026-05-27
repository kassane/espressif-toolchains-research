#![no_std]
use core::sync::atomic::{AtomicU32, Ordering};
#[no_mangle] pub extern "C" fn rs_atomic_add(p: &AtomicU32) -> u32 { p.fetch_add(1, Ordering::SeqCst) }
#[no_mangle] pub extern "C" fn rs_atomic_cas(p: &AtomicU32, e: u32, n: u32) -> u32 {
    match p.compare_exchange(e, n, Ordering::SeqCst, Ordering::SeqCst) { Ok(v) | Err(v) => v }
}
#[panic_handler] fn p(_: &core::panic::PanicInfo) -> ! { loop {} }
