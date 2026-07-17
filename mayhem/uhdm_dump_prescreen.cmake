# Injected by mayhem/build.sh via -DCMAKE_PROJECT_UHDM_INCLUDE (runs at the end of UHDM's top-level
# project() call; upstream CMakeLists.txt is untouched). Deferred to the end of the top-level
# directory so the uhdm-dump target exists, then links mayhem/harnesses/uhdm_dump_safe.c INTO that
# one executable and routes the CRT's main() through it (-Wl,--wrap=main -> __wrap_main, which calls
# upstream's main as __real_main). Scoped to uhdm-dump only: capnp's in-tree tools and the other
# UHDM utilities link exactly as upstream builds them. Sources pick up CMAKE_C_FLAGS, i.e. the
# fuzz build's $SANITIZER_FLAGS, so the pre-screen is instrumented like everything else.
# (Deferred-call arguments are expanded when the call runs, in CMakeLists.txt scope — hence
# PROJECT_SOURCE_DIR rather than CMAKE_CURRENT_LIST_DIR.)
cmake_language(DEFER CALL target_sources uhdm-dump PRIVATE
               "${PROJECT_SOURCE_DIR}/mayhem/harnesses/uhdm_dump_safe.c")
cmake_language(DEFER CALL target_link_options uhdm-dump PRIVATE "-Wl,--wrap=main")
