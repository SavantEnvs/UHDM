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
# ONE CMake build (build/), every object compiled WITH $SANITIZER_FLAGS:
#   - /mayhem/uhdm-dump (the fuzz target): capnproto + the uhdm library + uhdm-dump (incl. its
#     linked-in input pre-screen) are all instrumented (ASan+UBSan, halting, default), so the whole
#     restore path the fuzzer drives is sanitized and /mayhem/uhdm-dump IS that binary.
#   - UHDM's own GoogleTest suite (UnitTests), linked against the SAME build/lib/libuhdm.a objects
#     as the graded binary. mayhem/test.sh RUNS it via ctest. Same objects, same flags, same macros:
#     there is no second "test flavor" of the library a patch could special-case (no
#     __has_feature(address_sanitizer) / __OPTIMIZE__ / NDEBUG gap between oracle and target, #1460),
#     and the library is compiled once instead of twice (#1096).
#
# Model code is REGENERATED on every run (#1789). Upstream CMakeLists.txt only declares the
# scripts/generate.py rule `if(NOT EXISTS build/generated/src/UHDM.capnp)`, i.e. on the first
# configure of a fresh build dir; on every later configure the rule is gone, so an edit to
# templates/, model/, include/ or scripts/ would never reach the (re-)built binary. build.sh runs the
# same generate.py command itself before configuring; generate.py writes a file only when its
# content changed, so ninja then recompiles exactly the generated TUs/headers a patch touched.
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

# Memory-aware cap on compile parallelism (never above $MAYHEM_JOBS). Every TU here is large and
# sanitized: the generated Serializer.cpp peaks at ~2.2 GB RSS, Serializer_restore.cpp at ~1.8 GB and
# each gtest TU at ~1.1 GB, so 16 concurrent compiles need ~20 GB and get OOM-killed under a 12 GB
# container cap (measured). Budget ~1.6 GiB per job against the container's memory limit (cgroup v2
# memory.max / v1 limit_in_bytes, else MemTotal); with no tight limit this is just $MAYHEM_JOBS.
mem_limit_bytes() {
  local m="" total
  total=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) * 1024 ))
  [ -r /sys/fs/cgroup/memory.max ] && m="$(cat /sys/fs/cgroup/memory.max)"
  { [ -z "$m" ] || [ "$m" = max ]; } && [ -r /sys/fs/cgroup/memory/memory.limit_in_bytes ] \
    && m="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes)"
  case "$m" in ''|max|*[!0-9]*) m=$total ;; esac
  [ "$m" -gt "$total" ] && m=$total
  echo "$m"
}
BUILD_JOBS=$(( $(mem_limit_bytes) / (1600 * 1024 * 1024) ))
[ "$BUILD_JOBS" -ge 1 ] || BUILD_JOBS=1
[ "$BUILD_JOBS" -le "$MAYHEM_JOBS" ] || BUILD_JOBS="$MAYHEM_JOBS"
echo "build.sh: MAYHEM_JOBS=$MAYHEM_JOBS -> $BUILD_JOBS parallel jobs (memory limit $(( $(mem_limit_bytes) / 1048576 )) MiB)"

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
# Idempotent: applied only while that call is not yet guarded (a re-run must not re-wrap it — that
# would rewrite async.c++ on every run, recompiling it and changing the capnproto key below).
if [ -f "$ASYNC_CC" ] && grep -q '&stack.impl->originalBottom, &stack.impl->originalSize);' "$ASYNC_CC" \
   && ! perl -0ne 'exit(/#if KJ_USE_FIBERS\n\s*__sanitizer_finish_switch_fiber\(nullptr,\n\s*&stack\.impl->originalBottom/ ? 0 : 1)' "$ASYNC_CC"; then
  perl -0pi -e 's/(\n)(\s*)(__sanitizer_finish_switch_fiber\(nullptr,\n\s*&stack\.impl->originalBottom, &stack\.impl->originalSize\);)/$1#if KJ_USE_FIBERS\n$2$3\n#endif/' "$ASYNC_CC"
  echo "build.sh: patched vendored capnproto async.c++ (guarded FiberStack::impl under KJ_USE_FIBERS)"
fi

# ── The build — UHDM + vendored capnproto + uhdm-dump + UnitTests, all WITH $SANITIZER_FLAGS ────
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

# Turn LeakSanitizer off at BUILD time (SPEC §6.2 item 15): compile mayhem/lsan_off.cc — the
# fleet's `extern "C" int __lsan_is_turned_off() { return 1; }` hook — with the same sanitizer
# flags and feed the object to CMake's exe link step, so it is linked into uhdm-dump. ASan
# (out-of-bounds / use-after-free / …) and UBSan stay fully ON and halting; only leak reporting is
# suppressed, which matters because uhdm-dump never tears its restored design tree down (see the
# .cc file). Only when ASan is active; the no-sanitizer off-switch build stays clean.
UHDM_BUILD_DIR="$SRC/build"
mkdir -p "$UHDM_BUILD_DIR"
EXE_LINK_FLAGS=""
if printf '%s' "$SANITIZER_FLAGS" | grep -q address; then
  $CXX $SAN_BUILD -c "$SRC/mayhem/lsan_off.cc" -o "$UHDM_BUILD_DIR/lsan_off.o"
  EXE_LINK_FLAGS="$UHDM_BUILD_DIR/lsan_off.o"
fi

# ── capnproto: an in-image prebuilt copy of the VENDORED dependency, used only if it is identical ──
# capnproto is third-party (the pinned third_party/capnproto submodule) and ~30% of the sanitized build,
# including the capnp/capnpc-c++ schema compilers that sit on the critical path in front of every
# generated UHDM TU (#1096). The image build (Dockerfile: UHDM_CAPNP_PREFILL=1) compiles it ONCE with
# exactly this build's flags ($SAN_BUILD, the same lsan_off.o exe link flag, WITH_FIBERS=OFF, Release)
# and installs it, root-owned/read-only, under $UHDM_CAPNP_PREFIX, stamped with a key over
#   compiler identity + every flag + the cmake options + a sha256 of EVERY file under
#   third_party/capnproto (after the async.c++ patch above).
# A re-run uses the prebuilt copy only when its stamp equals the key recomputed NOW from the tree
# being built; any edit to third_party/capnproto (or a different SANITIZER_FLAGS/compiler) changes
# the key and the build falls back to compiling capnproto from the tree in-place, exactly as
# upstream does (UHDM_USE_HOST_CAPNP=OFF). UHDM's own sources (templates/, model/, scripts/,
# include/, util/, tests/) are never prebuilt: they are regenerated and compiled from the tree below.
UHDM_CAPNP_PREFIX="${UHDM_CAPNP_PREFIX:-/opt/toolchains/uhdm-capnp}"
# The same settings UHDM's CMakeLists.txt gives the in-tree capnproto subdirectory (C++17, no tests,
# no fibers, Release), so the prebuilt objects compile with the in-tree command lines.
CAPNP_CMAKE_OPTS=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=17 -DCMAKE_CXX_STANDARD_REQUIRED=ON
                  -DBUILD_TESTING=OFF -DWITH_FIBERS=OFF)
capnp_key() {
  {
    echo "cc=$($CC --version | head -1) cxx=$($CXX --version | head -1)"
    echo "san_build=$SAN_BUILD"
    echo "exe_link=${EXE_LINK_FLAGS:+lsan_off.o:$(sha256sum < "$SRC/mayhem/lsan_off.cc")}"
    echo "cmake_opts=${CAPNP_CMAKE_OPTS[*]}"
    (cd "$SRC" && find third_party/capnproto -path '*/.git' -prune -o -type f -print0 \
       | LC_ALL=C sort -z | xargs -0 sha256sum)
  } | sha256sum | cut -d' ' -f1
}
CAPNP_KEY="$(capnp_key)"
if [ "${UHDM_CAPNP_PREFILL:-0}" = 1 ]; then
  echo "build.sh: prefilling sanitized capnproto into $UHDM_CAPNP_PREFIX (key $CAPNP_KEY)"
  PREFILL_BUILD="$UHDM_BUILD_DIR/capnp-prefill"
  rm -rf "$PREFILL_BUILD" "${UHDM_CAPNP_PREFIX:?}"/* "$UHDM_CAPNP_PREFIX/.mayhem-capnp-key"
  # env -u LIB_FUZZING_ENGINE: capnproto adds a libFuzzer test-case target to ALL when that env var
  # is set (the base image sets it); in-tree it is EXCLUDE_FROM_ALL and never built either.
  env -u LIB_FUZZING_ENGINE \
  cmake -S "$SRC/third_party/capnproto" -B "$PREFILL_BUILD" -G Ninja "${CAPNP_CMAKE_OPTS[@]}" \
        -DCMAKE_INSTALL_PREFIX="$UHDM_CAPNP_PREFIX" \
        -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
        -DCMAKE_C_FLAGS="$SAN_BUILD" -DCMAKE_CXX_FLAGS="$SAN_BUILD" \
        -DCMAKE_EXE_LINKER_FLAGS="$EXE_LINK_FLAGS"
  cmake --build "$PREFILL_BUILD" -j"$BUILD_JOBS" --target install
  rm -rf "$PREFILL_BUILD"
  echo "$CAPNP_KEY" > "$UHDM_CAPNP_PREFIX/.mayhem-capnp-key"
fi
CAPNP_MODE=in-tree
CAPNP_UHDM_OPTS=(-DUHDM_USE_HOST_CAPNP=OFF)
if [ "$(cat "$UHDM_CAPNP_PREFIX/.mayhem-capnp-key" 2>/dev/null)" = "$CAPNP_KEY" ] \
   && [ -f "$UHDM_CAPNP_PREFIX/lib/cmake/CapnProto/CapnProtoConfig.cmake" ]; then
  CAPNP_MODE=prebuilt
  CAPNP_UHDM_OPTS=(-DUHDM_USE_HOST_CAPNP=ON -DCapnProto_DIR="$UHDM_CAPNP_PREFIX/lib/cmake/CapnProto")
fi
echo "build.sh: capnproto: $CAPNP_MODE (key $CAPNP_KEY)"
# Switching between the two modes in an existing build dir: drop the CMake cache so no stale
# capnp paths survive (objects are still reused where their command lines are unchanged).
if [ "$(cat "$UHDM_BUILD_DIR/.mayhem-capnp-mode" 2>/dev/null)" != "$CAPNP_MODE" ]; then
  rm -f "$UHDM_BUILD_DIR/CMakeCache.txt"
fi
echo "$CAPNP_MODE" > "$UHDM_BUILD_DIR/.mayhem-capnp-mode"

# ── Regenerate the model code from templates/ + model/ + include/ + scripts/ (#1789) ─────────────
# Exactly upstream's own generator command (CMakeLists.txt add_custom_command), run unconditionally.
# Content-compared writes (scripts/file_utils.py set_content_if_changed / copy_file_if_changed) keep
# unchanged outputs' mtimes, so an already-built tree rebuilds only what the edit affects. Because
# UHDM.capnp now exists before CMake configures, upstream's `if(NOT EXISTS ...)` never declares its
# one-shot rule; generation is owned here, identically on a fresh, a git-cleaned and a re-run tree.
python3 "$SRC/scripts/generate.py" --source-dirpath="$SRC" -output-dirpath="$UHDM_BUILD_DIR/generated"

cmake -S "$SRC" -B "$UHDM_BUILD_DIR" -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DUHDM_BUILD_TESTS=ON \
      -DUHDM_WITH_PYTHON=OFF \
      "${CAPNP_UHDM_OPTS[@]}" \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$SAN_BUILD" -DCMAKE_CXX_FLAGS="$SAN_BUILD" \
      -DCMAKE_EXE_LINKER_FLAGS="$EXE_LINK_FLAGS" \
      -DCMAKE_PROJECT_UHDM_INCLUDE="$SRC/mayhem/uhdm_dump_prescreen.cmake"
# One ninja invocation for the target AND the oracle: the shared library objects are built once, and
# the gtest TUs compile in parallel with the long generated Serializer*.cpp TUs.
cmake --build "$UHDM_BUILD_DIR" -j"$BUILD_JOBS" --target uhdm-dump UnitTests

# CMake sets RUNTIME_OUTPUT_DIRECTORY to bin/, so the executable lands at build/bin/uhdm-dump.
DUMP="$UHDM_BUILD_DIR/bin/uhdm-dump"
[ -f "$DUMP" ] || DUMP="$(find "$UHDM_BUILD_DIR" -name 'uhdm-dump' -type f -print -quit)"
[ -n "$DUMP" ] && [ -f "$DUMP" ] || { echo "ERROR: uhdm-dump not produced" >&2; find "$UHDM_BUILD_DIR" -name 'uhdm-dump' -print >&2; exit 1; }

# The pre-screen (mayhem/harnesses/uhdm_dump_safe.c) is linked INTO this binary by
# mayhem/uhdm_dump_prescreen.cmake (-Wl,--wrap=main, scoped to the uhdm-dump target): before
# upstream's main() runs, it cheaply checks the packed-capnp segment-table header and returns 0 on an
# empty input or one declaring an implausibly large message. Without it the EMPTY/garbage default
# test case drives capnproto (traversalLimitInWords=ULLONG_MAX, see Serializer_restore.cpp) into a
# multi-second read/alloc — Mayhem's "target times out on the default test case". It sets no timer
# (the Mayhemfile's per-cmd timeout: bounds each test case). It is in-process and sanitized, so the
# file the Mayhemfile names is the instrumented binary (no separate uninstrumented front-end that
# would hide the instrumentation from static analysis). Additive, mayhem/-only; upstream untouched.
# (grep without -q: under pipefail, -q exiting early would SIGPIPE nm and fail the check.)
nm "$DUMP" | grep ' T __wrap_main$' >/dev/null || { echo "ERROR: uhdm-dump lacks the linked-in pre-screen (__wrap_main)" >&2; exit 1; }
cp -f "$DUMP" /mayhem/uhdm-dump
echo "build.sh: built /mayhem/uhdm-dump (sanitized restore + linked-in input pre-screen)"

echo "build.sh: built UHDM UnitTests in $UHDM_BUILD_DIR (test oracle; same sanitized libuhdm.a as uhdm-dump)"

echo "build.sh complete:"
ls -l /mayhem/uhdm-dump 2>&1 || true
