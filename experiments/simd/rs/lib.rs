#![no_std]
#![feature(portable_simd)]
#![feature(asm_experimental_arch)]
use core::simd::i8x16;

// (1) autovectorizable loop -> expect scalar (0 EE.*) on esp32s3
#[no_mangle]
pub extern "C" fn rs_vadd_i8(c: *mut i8, a: *const i8, b: *const i8, n: usize) {
    let c = unsafe { core::slice::from_raw_parts_mut(c, n) };
    let a = unsafe { core::slice::from_raw_parts(a, n) };
    let b = unsafe { core::slice::from_raw_parts(b, n) };
    for i in 0..n { c[i] = a[i].wrapping_add(b[i]); }
}

// (2) portable_simd i8x16 add -> expect scalarized (0 EE.*)
#[no_mangle]
pub extern "C" fn rs_simd_add(a: i8x16, b: i8x16) -> i8x16 { a + b }

// (3) inline asm EE.* -> the only real path (q regs hardcoded; no `qreg` class, #265)
#[cfg(target_arch = "xtensa")]
#[no_mangle]
pub unsafe extern "C" fn rs_ee_vadd(d: *mut i8, a: *const i8, b: *const i8) {
    core::arch::asm!(
        "ee.vld.128.ip q0, {a}, 0",
        "ee.vld.128.ip q1, {b}, 0",
        "ee.vadds.s8   q2, q0, q1",
        "ee.vst.128.ip q2, {d}, 0",
        a = in(reg) a, b = in(reg) b, d = in(reg) d,
    );
}

// (4) ESP32-P4 (RISC-V) vendor PIE/ESPV vector ops via inline asm.
// Same q-reg model as xtensa s3 EE.*, just renamed `esp.*` and on rv32imafc.
// Mnemonics shown belong to ESPV 2.1 (esp32p4eco4 CPU); ESPV 2.2 (plain
// esp32p4) uses different opcode encodings whose spellings aren't public.
#[cfg(target_arch = "riscv32")]
#[no_mangle]
pub unsafe extern "C" fn rs_esp_vadd(d: *mut i8, a: *const i8, b: *const i8) {
    core::arch::asm!(
        "esp.vld.128.ip q0, {a}, 0",
        "esp.vld.128.ip q1, {b}, 0",
        "esp.vadd.s8    q2, q0, q1",
        "esp.vst.128.ip q2, {d}, 0",
        a = in(reg) a, b = in(reg) b, d = in(reg) d,
    );
}
#[panic_handler] fn ph(_: &core::panic::PanicInfo) -> ! { loop {} }
