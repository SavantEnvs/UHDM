#!/usr/bin/env bash
# UHDM/mayhem/test.sh — RUN UHDM's OWN GoogleTest suite (built by mayhem/build.sh with normal flags
# in build-tests/) via ctest AND a golden-output check on uhdm-dump.real, then emit a CTRF summary.
# exit 0 iff no test failed. This script only RUNS pre-built binaries; it NEVER compiles.
#
# BEHAVIORAL oracle (anti-reward-hacking, §6.3): Two complementary checks:
#
#   (A) ctest / GoogleTest: UHDM's unit tests assert KNOWN ANSWERS on the serializer + object model.
#       E.g. vpi_get_test asserts vpi_get_str(vpiFile,...) == "hello.v" and vpi_get(vpiLineNo,...) == 42;
#       vpi_value_conversion_test asserts integer/real/string round-trips; expr_reduce_test asserts that
#       constant-folded expressions evaluate to specific integer results; classes_test's
#       DesignSaveRestoreRoundtrip Save()s+Restore()s a design and asserts the tree matches.
#
#   (B) Golden-output check on uhdm-dump.real: run the sanitized deserializer on a known .uhdm seed
#       and grep for specific output tokens that can only appear if the capnproto restore + tree-walk
#       ran successfully. A neutered/no-op binary exits 0 but produces NO output → grep fails →
#       this test FAILS. This is the layer the sabotage check (LD_PRELOAD _exit(0)) cannot defeat:
#       even if ctest marks neutered gtest binaries as "Passed" (exit 0), the output check catches it.
#
# Together they ensure: a PATCH that no-ops the program (exit(0)) FAILS this oracle. "Ran without
# crashing" is NOT sufficient.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# ── (A) ctest / GoogleTest suite ─────────────────────────────────────────────────────────────────
BUILD_DIR="$SRC/build-tests"
[ -d "$BUILD_DIR" ] || { echo "missing $BUILD_DIR — run mayhem/build.sh first" >&2; emit_ctrf "uhdm-tests" 0 1 0; exit 2; }
command -v ctest >/dev/null 2>&1 || { echo "ctest not found" >&2; emit_ctrf "uhdm-tests" 0 1 0; exit 2; }

# ctest discovers the gtest cases (gtest_discover_tests) registered against the build-tests tree.
# --output-on-failure surfaces failing test output; the summary line is "X% tests passed, F failed
# out of T".
out="$(cd "$BUILD_DIR" && ctest --output-on-failure -C Release 2>&1)"; ctest_rc=$?
echo "$out"

# Parse ctest's final summary: "NN% tests passed, F tests failed out of T".
summary="$(printf '%s\n' "$out" | grep -E '[0-9]+% tests passed,' | tail -1)"
ctest_total=$(  printf '%s\n' "$summary" | sed -n 's/.*out of \([0-9]\{1,\}\).*/\1/p')
ctest_failed=$( printf '%s\n' "$summary" | sed -n 's/.*passed, \([0-9]\{1,\}\) tests* failed.*/\1/p')
: "${ctest_total:=0}" "${ctest_failed:=0}"

# If we couldn't parse a summary at all, fail loudly with the run's exit code as the verdict.
if [ -z "$summary" ]; then
  echo "test.sh: could not parse ctest summary (rc=$ctest_rc)" >&2
  emit_ctrf "uhdm-tests" 0 1 0
  exit 1
fi

ctest_passed=$(( ctest_total - ctest_failed )); [ "$ctest_passed" -lt 0 ] && ctest_passed=0
echo "UHDM ctest: total=$ctest_total passed=$ctest_passed failed=$ctest_failed" >&2

# ── (B) Golden-output check: uhdm-dump.real on the bundled seed ──────────────────────────────────
# Run the REAL sanitized deserializer on a known .uhdm binary and verify specific output tokens.
# The seed encodes a small UHDM design (the "classes_test" fixture: design "design1" with module M1,
# class Base with parameter P1 and function f1/f2, derived class Child). Each token below appears in
# the human-readable dump iff the capnproto Restore() + tree-walk actually ran:
#   "design1"      — the design's VpiName (DesignSaveRestoreRoundtrip uses this exact string)
#   "M1"           — the top-level module name
#   "vpiName:Base" — a class_defn node the listener emits only after a full walk
# A neutered binary (LD_PRELOAD _exit(0)) exits 0 but produces NO output → all greps fail.
SEED="$SRC/mayhem/uhdm-dump/testsuite/classes_test.uhdm"
DUMP_BIN="/mayhem/uhdm-dump.real"
golden_passed=0; golden_failed=0

if [ ! -f "$SEED" ]; then
  echo "GOLDEN FAIL: seed file missing: $SEED" >&2
  golden_failed=$(( golden_failed + 1 ))
elif [ ! -x "$DUMP_BIN" ]; then
  echo "GOLDEN FAIL: $DUMP_BIN missing or not executable — run mayhem/build.sh first" >&2
  golden_failed=$(( golden_failed + 1 ))
else
  dump_out="$($DUMP_BIN "$SEED" 2>&1)"
  dump_rc=$?

  # Check 1: binary must exit cleanly and produce non-empty output
  if [ $dump_rc -ne 0 ] || [ -z "$dump_out" ]; then
    echo "GOLDEN FAIL: uhdm-dump.real exited $dump_rc with empty/no output (expected successful restore)" >&2
    golden_failed=$(( golden_failed + 1 ))
  else
    golden_passed=$(( golden_passed + 1 ))
    echo "GOLDEN PASS: uhdm-dump.real exited 0 with output" >&2
  fi

  # Check 2: design name "design1" must appear in the dump
  if printf '%s\n' "$dump_out" | grep -q "design1"; then
    golden_passed=$(( golden_passed + 1 ))
    echo "GOLDEN PASS: output contains 'design1'" >&2
  else
    echo "GOLDEN FAIL: output does not contain 'design1' — restore did not run" >&2
    golden_failed=$(( golden_failed + 1 ))
  fi

  # Check 3: module name "M1" must appear (top-level module of the encoded design)
  if printf '%s\n' "$dump_out" | grep -q "M1"; then
    golden_passed=$(( golden_passed + 1 ))
    echo "GOLDEN PASS: output contains 'M1'" >&2
  else
    echo "GOLDEN FAIL: output does not contain 'M1' — tree walk did not run" >&2
    golden_failed=$(( golden_failed + 1 ))
  fi

  # Check 4: class node "Base" must appear (the class_defn the tree-walker visits)
  if printf '%s\n' "$dump_out" | grep -q "vpiName:Base"; then
    golden_passed=$(( golden_passed + 1 ))
    echo "GOLDEN PASS: output contains 'vpiName:Base'" >&2
  else
    echo "GOLDEN FAIL: output does not contain 'vpiName:Base' — VPI visitor did not run" >&2
    golden_failed=$(( golden_failed + 1 ))
  fi
fi

# ── Combine results ───────────────────────────────────────────────────────────────────────────────
total_passed=$(( ctest_passed + golden_passed ))
total_failed=$(( ctest_failed + golden_failed ))
echo "UHDM tests: ctest=$ctest_total (failed=$ctest_failed) golden=$(( golden_passed + golden_failed )) (failed=$golden_failed)" >&2
emit_ctrf "uhdm-tests" "$total_passed" "$total_failed" 0
