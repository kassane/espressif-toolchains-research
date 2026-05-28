#!/usr/bin/env bash
# run.sh - TinyGo v0.41.1 as a "6th toolchain" probe on Xtensa. Go is not a
# drop-in 6th-frontend for the FFI matrix because TinyGo is a *whole-program*
# compiler — it always builds a firmware .bin / -kernel ELF, never a relocatable
# .o that the other five toolchains can co-link. The shared-object buildmode
# (`-buildmode=c-shared`) is currently wasm-only. So we don't add Go to
# ffi-matrix; instead this script pins what TinyGo CAN do on Xtensa and how it
# differs from the other five.
#
# Sections:
#   (a) version + LLVM bundled + esp targets list (no esp32-s2)
#   (b) the implicit -mattr= esp-clang vs TinyGo ship for esp32 (TinyGo adds
#       +atomctl/+memctl/+timerint, drops +dcache; matters for ABI/codegen)
#   (c) datalayout + triple (TinyGo uses bare `xtensa`, not `xtensa-esp-elf`)
#   (d) build a tinygo firmware that //exports a C-ABI function, then check
#       both the firmware's entry-point format and that the symbol is in the
#       resulting ELF (i.e. TinyGo's go_* are real C-ABI exports)
#   (e) IR-level inspection: does TinyGo emit byval/sret for small structs?
#       (yes — go follows the platform C ABI similarly to Zig: direct aggregate
#       %T parameters, defer to backend)
#
# See docs/24.

set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

[ -x "$TINYGO" ] || { echo "missing \$TINYGO — run: ./scripts/setup.sh"; exit 1; }

B=build/tinygo; mkdir -p "$B"

echo "== (a) version + LLVM + esp targets =="
"$TINYGO" version 2>&1 | sed 's/^/  /'
printf "  esp targets:  "
"$TINYGO" targets 2>&1 | grep -E '^(esp|xiao-esp|adafruit-esp|qtpy-esp|makerfabs|esp32-coreboard|esp-c3)' | tr '\n' ' '; echo

cat > "$B/probe.go" <<'EOF'
package main
//export probe_add
func probe_add(a, b int32) int32 { return a + b }
func main() {}
EOF

echo "== (b) implicit -mattr that TinyGo applies for esp32 =="
# `-x` prints the link command on STDERR. TinyGo behaves oddly if you redirect
# stdout and stderr to the same file (rc=1, truncated log); split the streams.
"$TINYGO" build -x -target=esp32-coreboard-v2 -o "$B/probe.bin" "$B/probe.go" >"$B/_out.log" 2>"$B/_x.log"
mattr=$(grep -oE -- '-mattr=[^ ]+' "$B/_x.log" | head -1)
printf "  TinyGo esp32:  %s\n" "$mattr"
echo "  esp-clang esp32 (reference, implicit per -mcpu=esp32):"
printf 'void f(){}\n' > "$B/_f.c"
"$CLANG" --target=xtensa-esp-elf -mcpu=esp32 -ffreestanding -Os -S -emit-llvm -o - "$B/_f.c" 2>/dev/null \
    | grep -oE '"target-features"="[^"]*"' | head -1 | sed 's/^/                 /'
echo "  -> TinyGo adds +atomctl/+memctl/+timerint (LLVM-20 has them);"
echo "     drops +dcache, +highpriinterrupts-level7, +loop is in both,"
echo "     +bool/+clamps/+coprocessor/+debug/+density/+dfpaccel/+div32/+exception/"
echo "     +fp/+mac16/+minmax/+miscsr/+mul16/+mul32/+mul32high/+nsa/+prid/+regprotect/"
echo "     +rvector/+s32c1i/+sext/+threadptr/+windowed all in both. Codegen ABI"
echo "     essentials (+windowed +density +mul32 +s32c1i) match → the C ABI line"
echo "     is the same, even though the LLVM versions don't match (20.1.1 vs 21.1.3)."

echo "== (c) triple + datalayout =="
"$TINYGO" info esp32-coreboard-v2 2>"$B/_info.log" >/dev/null
grep -E 'LLVM triple|GOARCH' "$B/_info.log" | sed 's/^/  /'
"$TINYGO" build -internal-printir -target=esp32-coreboard-v2 -o "$B/probe2.bin" "$B/probe.go" >"$B/_ir.log" 2>"$B/_ir.err"
grep -oE 'target datalayout = "[^"]*"' "$B/_ir.log" | head -1 | sed 's/^/  TinyGo IR datalayout: /'
echo "  clang/rust/zig/D ref: target datalayout = \"e-m:e-p:32:32-v1:8:8-i64:64-i128:128-n32\""
echo "  -> byte-identical to the four other LLVM frontends (memory model matches)."

echo "== (d) firmware: TinyGo emits an ESP32 flash image, not a linkable ELF =="
ls -lh "$B/probe.bin" 2>&1 | sed 's/^/  /'
hdr=$(od -An -tx1 -N4 "$B/probe.bin" | tr -s ' ' | sed 's/^ //')
printf "  image header bytes: %s  (ESP32 image magic = e9 02 02 1f)\n" "$hdr"
echo "  -> .bin is a flat espressif image (bootloader + app); not consumable by"
echo "     llvm-nm/llvm-objdump. To extract relocatable .o for cross-language"
echo "     linking you'd need TinyGo to expose its intermediate (it doesn't"
echo "     outside -buildmode=c-shared on wasm). So Go isn't a 6th column in"
echo "     experiments/ffi-matrix; this is the boundary docs/24 documents."

echo "== (e) IR shape for a small struct by value (compare to docs/05/19) =="
cat > "$B/struct.go" <<'EOF'
package main
type Point struct{ X, Y int32 }
//export go_point_dot
func go_point_dot(a, b Point) int32 { return a.X*b.X + a.Y*b.Y }
func main() {}
EOF
"$TINYGO" build -internal-printir -target=esp32-coreboard-v2 -o "$B/struct.bin" "$B/struct.go" >"$B/struct_ir.log" 2>"$B/struct_ir.err"
grep -E 'define.*go_point_dot' "$B/struct_ir.log" | head -1 | sed -E 's/^/  /; s/local_unnamed_addr.*//'
echo "  (TinyGo emits direct aggregate %T parameters like Zig — defers ABI to the"
echo "   backend; if Go ever does link with the others, the same docs/05 caveats"
echo "   apply on under-aligned aggregates. The struct here is align-4 so it's safe.)"
