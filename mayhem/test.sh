#!/usr/bin/env bash
# UHDM/mayhem/test.sh — RUN UHDM's OWN GoogleTest suite (built by mayhem/build.sh in build/, linked
# against the SAME sanitized libuhdm.a objects as the graded /mayhem/uhdm-dump) via ctest AND a
# golden-output check on uhdm-dump, then emit a CTRF summary.
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
#   (B) Golden-output check on uhdm-dump: run the graded binary on the bundled seed and on freshly
#       RENAMED copies of it, and compare its WHOLE output byte-for-byte with the expected dump
#       (mayhem/golden/: a template of upstream's exact output for this design + a fixture tool that
#       writes the renamed copies and their expected dumps — test.sh decides pass/fail, never the
#       program). The renamed copies carry new random symbol names on every run, so a binary only
#       passes by really restoring the file: a no-op/neutered binary prints nothing, and a canned dump
#       (e.g. util/uhdm-dump.cpp patched to print the seed's golden text and return 0) prints the
#       wrong names. This is the layer the sabotage check (LD_PRELOAD _exit(0)) cannot defeat either.
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
BUILD_DIR="$SRC/build"
[ -d "$BUILD_DIR" ] || { echo "missing $BUILD_DIR — run mayhem/build.sh first" >&2; emit_ctrf "uhdm-tests" 0 1 0; exit 2; }
command -v ctest >/dev/null 2>&1 || { echo "ctest not found" >&2; emit_ctrf "uhdm-tests" 0 1 0; exit 2; }

# ctest discovers the gtest cases (gtest_discover_tests) registered against the build/ tree.
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

# ── (B) Golden-output check: uhdm-dump on the bundled seed + renamed copies of it ────────────────
# The seed encodes a small UHDM design (the "classes_test" fixture: design "design1" with module M1,
# class Base with parameter P1 and functions f1/f2, derived class Child with f3).
#   1-4. on the seed itself: exit 0 with output, and the tokens "design1", "M1", "vpiName:Base"
#   5.   on the seed itself: the WHOLE dump equals the golden dump exactly
#   6-8. on three renamed copies (fresh random names per run): each WHOLE dump equals the golden
#        dump filled with that copy's names exactly
SEED="$SRC/mayhem/uhdm-dump/testsuite/classes_test.uhdm"
GOLDEN_DIR="$SRC/mayhem/golden"
GOLDEN_TMPL="$GOLDEN_DIR/classes_test.uhdm-dump.tmpl"
GOLDEN_TOOL="$GOLDEN_DIR/uhdm_golden.py"
DUMP_BIN="/mayhem/uhdm-dump"
N_VARIANTS=3
golden_passed=0; golden_failed=0
gpass() { golden_passed=$(( golden_passed + 1 )); echo "GOLDEN PASS: $*" >&2; }
gfail() { golden_failed=$(( golden_failed + 1 )); echo "GOLDEN FAIL: $*" >&2; }

if [ ! -f "$SEED" ] || [ ! -f "$GOLDEN_TMPL" ] || [ ! -f "$GOLDEN_TOOL" ]; then
  gfail "seed/golden fixture missing ($SEED, $GOLDEN_TMPL, $GOLDEN_TOOL)"
  golden_failed=$(( golden_failed + 4 + N_VARIANTS ))   # count every check below as failed
elif [ ! -x "$DUMP_BIN" ]; then
  gfail "$DUMP_BIN missing or not executable — run mayhem/build.sh first"
  golden_failed=$(( golden_failed + 4 + N_VARIANTS ))
else
  GTMP="$(mktemp -d)"; trap 'rm -rf "$GTMP"' EXIT
  "$DUMP_BIN" "$SEED" > "$GTMP/seed.out" 2>"$GTMP/seed.err"; dump_rc=$?
  dump_out="$(cat "$GTMP/seed.out")"

  # Check 1: binary must exit cleanly and produce non-empty output
  if [ $dump_rc -ne 0 ] || [ -z "$dump_out" ]; then
    gfail "uhdm-dump exited $dump_rc with empty/no output (expected successful restore)"; sed 's/^/    /' "$GTMP/seed.err" >&2
  else
    gpass "uhdm-dump exited 0 with output"
  fi
  # Checks 2-4: tokens of the encoded design must appear
  printf '%s\n' "$dump_out" | grep -q "design1"      && gpass "output contains 'design1'"      || gfail "output does not contain 'design1' — restore did not run"
  printf '%s\n' "$dump_out" | grep -q "M1"           && gpass "output contains 'M1'"           || gfail "output does not contain 'M1' — tree walk did not run"
  printf '%s\n' "$dump_out" | grep -q "vpiName:Base" && gpass "output contains 'vpiName:Base'" || gfail "output does not contain 'vpiName:Base' — VPI visitor did not run"

  # Check 5: the whole dump of the seed is exactly the golden dump
  if python3 "$GOLDEN_TOOL" expect "$GOLDEN_TMPL" "$SEED" "$GTMP/seed.expected" \
     && [ $dump_rc -eq 0 ] && cmp -s "$GTMP/seed.out" "$GTMP/seed.expected"; then
    gpass "seed dump matches the golden dump exactly ($(wc -l < "$GTMP/seed.expected") lines)"
  else
    gfail "seed dump differs from the golden dump:"; diff "$GTMP/seed.expected" "$GTMP/seed.out" 2>&1 | head -20 | sed 's/^/    /' >&2
  fi

  # Checks 6..: renamed copies — the dump must carry THIS copy's fresh names, in the golden structure
  for i in $(seq 1 "$N_VARIANTS"); do
    v="$GTMP/variant$i.uhdm"
    if ! names="$(python3 "$GOLDEN_TOOL" variant "$SEED" "$GOLDEN_TMPL" "$v" "$v" "$v.expected")"; then
      gfail "variant $i: could not build the renamed copy of the seed"; continue
    fi
    "$DUMP_BIN" "$v" > "$v.out" 2>"$v.err"; vrc=$?
    if [ $vrc -eq 0 ] && cmp -s "$v.out" "$v.expected"; then
      gpass "renamed copy $i ($names) dump matches exactly"
    else
      gfail "renamed copy $i ($names): rc=$vrc, dump differs from expected:"
      diff "$v.expected" "$v.out" 2>&1 | head -20 | sed 's/^/    /' >&2; sed 's/^/    /' "$v.err" | head -5 >&2
    fi
  done
fi

# ── Combine results ───────────────────────────────────────────────────────────────────────────────
total_passed=$(( ctest_passed + golden_passed ))
total_failed=$(( ctest_failed + golden_failed ))
echo "UHDM tests: ctest=$ctest_total (failed=$ctest_failed) golden=$(( golden_passed + golden_failed )) (failed=$golden_failed)" >&2
emit_ctrf "uhdm-tests" "$total_passed" "$total_failed" 0
