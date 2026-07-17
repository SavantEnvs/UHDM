#!/usr/bin/env bash
# UHDM/mayhem/build.sh — build chipsalliance/UHDM (the Universal Hardware Data Model: a
# Verilog/SystemVerilog AST serialization library) and its `uhdm-dump` utility as the FILE-INPUT
# fuzz target, plus a clean normal-flags build of UHDM's own GoogleTest suite for mayhem/test.sh.
#
# The fuzzed surface is the DESERIALIZER on attacker bytes: `uhdm-dump <file>` calls
# UHDM::Serializer::Restore(file) — the capnproto-backed reader that reconstructs a whole UHDM
# design tree from a serialized .uhdm binary — then walks it (visit_designs). The whole restore +
# tree-walk runs on the fuzz input. This matches the OLD mayhemheroes target (`uhdm-dump @@`), kept
# for Mayhem run-history parity. Not libFuzzer: the natural fuzz surface is the CLI on a file.
#
# UHDM is a CMake project that VENDORS capnproto + googletest as git submodules
# (third_party/capnproto, third_party/googletest). With UHDM_USE_HOST_CAPNP/GTEST=OFF (the default)
# CMake builds capnproto FROM SOURCE in-tree and runs capnp's own schema compiler to generate
# UHDM.capnp.{h,c++}; googletest is built the same way for the unit tests. We init both submodules
# from .gitmodules below (they are committed as gitlinks, not populated in the build context).
# Model code generation needs the Python `orderedmultidict` package (installed in the Dockerfile).
#
# Two CMake builds from the same source (separate build dirs):
#   (1) FUZZ build  (-DUHDM_BUILD_TESTS=OFF) WITH $SANITIZER_FLAGS -> /mayhem/uhdm-dump (the target).
#       capnproto + the uhdm library + uhdm-dump are all compiled sanitized, so the entire restore
#       path the fuzzer drives is instrumented (ASan+UBSan, halting, default).
#   (2) TEST build  (-DUHDM_BUILD_TESTS=ON) with NORMAL flags -> build-tests/ (honest PATCH oracle;
#       no sanitizer noise). build.sh only BUILDS it; mayhem/test.sh RUNS it via ctest.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (the program's natural crash).
# DEBUG_FLAGS: -gdwarf-3 forces DWARF ≤ 3 (clang-19 emits DWARF-5 with plain -g; Mayhem triage needs
# DWARF < 4). Threaded into EVERY fuzz/harness/standalone compile alongside $SANITIZER_FLAGS.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
export DEBUG_FLAGS
: "${CC:=clang}" ; : "${CXX:=clang++}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS CC CXX MAYHEM_JOBS

cd "$SRC"

# ── Populate the vendored submodules (capnproto + googletest) ────────────────────────────────────
# They land as gitlinks (empty dirs) from the COPY context; UHDM's CMake builds both from source.
for sm in third_party/capnproto third_party/googletest; do
  if [ -z "$(ls -A "$sm" 2>/dev/null)" ]; then
    echo "build.sh: initializing submodule $sm"
    git submodule update --init --recursive "$sm"
  fi
done

# ── Patch the vendored capnproto for ASan + KJ_USE_FIBERS=0 ───────────────────────────────────────
# UHDM pins an OLD capnproto (8c7e0fd) and builds it with fibers OFF (WITH_FIBERS=OFF). In that
# config, FiberStack::StartRoutine::run() — a dead makeContext() callback only used WHEN fibers are
# on — still references `stack.impl->originalBottom/originalSize` inside the
# `#if KJ_HAS_COMPILER_FEATURE(address_sanitizer)` block, but the `impl` member itself is declared
# only under `#if KJ_USE_FIBERS`. So building capnproto's kj-async with ASan AND fibers-off fails to
# compile ("no member named 'impl' in kj::_::FiberStack") — a genuine upstream capnproto bug exposed
# only by this exact (ASan, no-fibers) combination. We surgically guard that one sanitizer call with
# `#if KJ_USE_FIBERS` so the no-fibers build compiles; the code is unreachable when fibers are off,
# and capnproto stays otherwise fully sanitized. (Vendored third-party source, fetched at build time
# — not an upstream-UHDM file; patched here, in build.sh, only.)
ASYNC_CC="$SRC/third_party/capnproto/c++/src/kj/async.c++"
if [ -f "$ASYNC_CC" ] && grep -q '&stack.impl->originalBottom, &stack.impl->originalSize);' "$ASYNC_CC"; then
  perl -0pi -e 's/(\n)(\s*)(__sanitizer_finish_switch_fiber\(nullptr,\n\s*&stack\.impl->originalBottom, &stack\.impl->originalSize\);)/$1#if KJ_USE_FIBERS\n$2$3\n#endif/' "$ASYNC_CC"
  echo "build.sh: patched vendored capnproto async.c++ (guarded FiberStack::impl under KJ_USE_FIBERS)"
fi

# ── 1) FUZZ build — UHDM + vendored capnproto + uhdm-dump, all WITH $SANITIZER_FLAGS ──────────────
# UHDM_BUILD_TESTS=OFF: skip the gtest unit binaries in the sanitized tree (built separately below).
# UHDM_WITH_PYTHON stays OFF (no python bindings). We thread $SANITIZER_FLAGS into BOTH C and CXX
# flags so capnproto (C/C++) AND the uhdm library/uhdm-dump (the fuzzed restore path) are instrumented.
#
# NOTE: -fno-sanitize=vptr. capnproto's KJ runtime performs downcasts (kj::downcast / dynamicCast)
# on objects whose construction UBSan's vptr check cannot always see across the capnp arena, which
# fires on essentially every restore. We relax ONLY the vptr UBSan check (keeping ASan + the rest of
# UBSan ON and HALTING) so the fuzzer halts on REAL memory/UB defects in the deserializer rather than
# aborting on this benign capnp RTTI pattern on every input. Applied only when UBSan is active, so
# the empty-sanitizer off-switch stays a clean build. (PORTING.md "benign UB that floods under UBSan".)
SAN_BUILD="$SANITIZER_FLAGS $DEBUG_FLAGS"
if printf '%s' "$SANITIZER_FLAGS" | grep -q undefined; then
  SAN_BUILD="$SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=vptr"
fi

# Bake __asan_default_options(detect_leaks=0) into uhdm-dump (only when ASan is active — see the
# .c file). Compile it to an object and feed it to CMake's exe link step as a linker input so the
# weak symbol overrides ASan's default; harmless / no-op when ASan is off.
EXE_LINK_FLAGS=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  $CC $DEBUG_FLAGS -c "$SRC/mayhem/asan_default_options.c" -o "$SRC/asan_default_options.o"
  EXE_LINK_FLAGS="$SRC/asan_default_options.o"
fi

cmake -S "$SRC" -B "$SRC/build" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DUHDM_BUILD_TESTS=OFF \
      -DUHDM_WITH_PYTHON=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SAN_BUILD" -DCMAKE_CXX_FLAGS="$SAN_BUILD" \
      -DCMAKE_EXE_LINKER_FLAGS="$EXE_LINK_FLAGS"
cmake --build "$SRC/build" -j"$MAYHEM_JOBS" --target uhdm-dump

# CMake sets RUNTIME_OUTPUT_DIRECTORY to bin/, so the executable lands at build/bin/uhdm-dump.
DUMP="$SRC/build/bin/uhdm-dump"
[ -f "$DUMP" ] || DUMP="$(find "$SRC/build" -name 'uhdm-dump' -type f -print -quit)"
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "ERROR: uhdm-dump not produced" >&2; find "$SRC/build" -name 'uhdm-dump' -print >&2; exit 1; }

# Place the real sanitized restore binary as uhdm-dump.real, and put a tiny fast-terminating wrapper
# at the canonical /mayhem/uhdm-dump (the Mayhemfile cmd). The wrapper (mayhem/harnesses/
# uhdm_dump_safe.c) installs a wall-clock SIGALRM watchdog and cheaply pre-screens the packed-capnp
# segment-table header, so the EMPTY/garbage/huge-segment default input — which otherwise drives
# capnproto (built here with traversalLimitInWords=ULLONG_MAX, see Serializer_restore.cpp) into a
# multi-second read/alloc and then an uncaught-kj-exception SIGABRT — returns cleanly in
# milliseconds. Plausible inputs are exec()'d straight into uhdm-dump.real in place, so the sanitized
# restore path and Mayhem's instrumentation are unchanged and real crashes still surface. This is the
# fix for the Mayhem "target times out on the default test case" failure; additive (mayhem/-only),
# upstream UHDM source untouched.
cp -f "$DUMP" /mayhem/uhdm-dump.real
$CC -O2 $DEBUG_FLAGS "$SRC/mayhem/harnesses/uhdm_dump_safe.c" -o /mayhem/uhdm-dump
echo "build.sh: built /mayhem/uhdm-dump (fast-terminating wrapper) + /mayhem/uhdm-dump.real (sanitized restore)"

# ── 2) TEST build — UHDM's OWN GoogleTest suite with NORMAL flags (clean, separate tree) ──────────
# Built so test.sh only RUNS it (via ctest). No sanitizer flags → honest PATCH oracle, no UB noise.
env -u CFLAGS -u CXXFLAGS \
cmake -S "$SRC" -B "$SRC/build-tests" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DUHDM_BUILD_TESTS=ON \
      -DUHDM_WITH_PYTHON=OFF \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX"
cmake --build "$SRC/build-tests" -j"$MAYHEM_JOBS" --target UnitTests
echo "build.sh: built UHDM UnitTests in $SRC/build-tests (test oracle)"

echo "build.sh complete:"
ls -l /mayhem/uhdm-dump /mayhem/uhdm-dump.real 2>&1 || true
