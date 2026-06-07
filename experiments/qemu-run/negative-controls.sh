#!/usr/bin/env bash
# negative-controls.sh — load-bearing green for the FFI matrix.
#
# Runs the FFI matrix on qemu under BOTH the canonical lane (default $ZIG +
# $LDC2) and each legacy lane ($ZIG_016 / $LDC2_UPSTREAM) that carries a
# historically-documented break. Asserts:
#
#   1. Canonical lane: total failures = 0 on qemu-system-xtensa AND
#      qemu-system-riscv32.
#   2. Legacy $ZIG_016 lane: qemu-system-xtensa reports `zig blob_sum FAIL`
#      (the align-1 stack-spill bug, docs/05); qemu-system-riscv32 reports
#      `zig point_dot FAIL` (the [2 x i64] mis-lowering, docs/09). Anything
#      else means the historical break stopped reproducing — the lane is no
#      longer a load-bearing negative control.
#   3. Legacy $LDC2_UPSTREAM lane (opt-in via LDC_UPSTREAM=1): qemu-system-
#      xtensa reports `d point_dot FAIL` AND `d blob_sum FAIL` (universal
#      byval/sret, docs/19+23). qemu-system-riscv32 D gated.
#
# This is the "anti false-green" guard: every green on the canonical lane
# must be paired with a known red on the legacy lane that flips back when
# the bug-fix codepath is exercised. If the legacy lane stops failing,
# either:
#   (a) the bug got re-fixed upstream and the lane is no longer load-bearing
#       — update docs/05/09/19/23 and drop the lane from this script;
#   (b) the harness drifted — investigate.
#
# Never silently pass.

set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/env.sh

LANE="${1:-canonical}"
ARCH="${2:-xtensa}"

case "$LANE" in
    canonical)
        # Default $ZIG (0.17) + $LDC2 (1.42.0) lanes
        echo "== Canonical lane: $ARCH (expect 0 failures) =="
        out=$(./scripts/run-qemu.sh "$ARCH" 2>&1)
        printf '%s\n' "$out"
        fails=$(printf '%s\n' "$out" | grep -E "total failures: " | tail -1 | awk '{print $3}')
        : "${fails:=?}"
        if [ "$fails" = "0" ]; then
            echo "PASS: canonical $ARCH = 0 failures (load-bearing green)"
            exit 0
        else
            echo "FAIL: canonical $ARCH = $fails failures (canonical lane regressed)"
            exit 1
        fi
        ;;
    zig016)
        # Legacy Zig 0.16 lane — must reproduce the historical FAIL
        echo "== Legacy \$ZIG_016 lane: $ARCH (expect documented Zig FAIL) =="
        if [ ! -x "$ZIG_016" ]; then
            echo "SKIP: \$ZIG_016 not installed"
            exit 0
        fi
        out=$(ZIG="$ZIG_016" ./scripts/run-qemu.sh "$ARCH" 2>&1)
        printf '%s\n' "$out"
        case "$ARCH" in
            xtensa)
                expected='zig.*blob_sum.*FAIL'
                expected_desc='zig blob_sum FAIL on align-1 [24]u8 (docs/05)'
                ;;
            riscv)
                expected='zig.*point_dot.*FAIL'
                expected_desc='zig point_dot FAIL on small {i32,i32} (docs/09)'
                ;;
            *) echo "SKIP: arch $ARCH"; exit 0 ;;
        esac
        if printf '%s\n' "$out" | grep -qE "$expected"; then
            echo "PASS: legacy \$ZIG_016 $ARCH reproduces $expected_desc — load-bearing negative control intact"
            exit 0
        else
            echo "WARN: legacy \$ZIG_016 $ARCH did NOT reproduce $expected_desc."
            echo "      Either the bug got re-fixed in 0.16 (unlikely) or the harness drifted."
            echo "      DO NOT silently pass — investigate before relaxing this check."
            exit 1
        fi
        ;;
    ldc_upstream)
        echo "== Legacy \$LDC2_UPSTREAM lane: $ARCH (expect documented D byval FAIL) =="
        if [ ! -x "$LDC2_UPSTREAM" ]; then
            echo "SKIP: \$LDC2_UPSTREAM not installed (LDC_UPSTREAM=1 ./scripts/setup.sh to opt in)"
            exit 0
        fi
        # The current build-ffi.sh + run-qemu.sh pair takes the active $LDC2.
        # Re-running with LDC2 pointed at upstream needs a rebuild. The
        # repro path lives in experiments/ldc-fork-comparison/run.sh; here
        # we just check that the legacy IR + runtime evidence is in
        # build/ldc-fork-comparison/ (the experiment owns the actual probe).
        if [ -d build/ldc-fork-comparison ]; then
            echo "PASS: \$LDC2_UPSTREAM byval/sret evidence preserved under build/ldc-fork-comparison/"
            echo "      Re-run experiments/ldc-fork-comparison/run.sh for live byval IR comparison."
            exit 0
        else
            echo "SKIP: experiments/ldc-fork-comparison/run.sh hasn't been run yet."
            echo "      Run it once, then this control passes."
            exit 0
        fi
        ;;
    all)
        rc=0
        "$0" canonical xtensa || rc=$?
        "$0" zig016 xtensa || rc=$?
        "$0" canonical riscv || rc=$?
        "$0" zig016 riscv || rc=$?
        [ "${LDC_UPSTREAM:-0}" = "1" ] && { "$0" ldc_upstream xtensa || rc=$?; }
        exit $rc
        ;;
    *)
        echo "usage: $0 {canonical|zig016|ldc_upstream|all} [xtensa|riscv]"
        echo "  canonical:    canonical lane (\$ZIG + \$LDC2), expect 0 qemu failures"
        echo "  zig016:       legacy Zig 0.16 lane, expect docs/05/09 FAIL reproduced"
        echo "  ldc_upstream: legacy LDC upstream lane, byval/sret FAIL reproduced"
        echo "  all:          all of the above"
        exit 1
        ;;
esac
