/* Weak __asan_default_options baked into the sanitized uhdm-dump binary.
 *
 * uhdm-dump is a run-once-per-input CLI: it calls UHDM::Serializer::Restore() to reconstruct an
 * entire UHDM design tree from the input .uhdm file, walks it, and exits WITHOUT tearing the tree
 * down (the Serializer/arena owns thousands of nodes that are intentionally not freed before
 * process exit — UHDM relies on process teardown). Under ASan's default leak detection those
 * benign at-exit "leaks" fire on essentially EVERY input, which would drown out the real
 * memory-safety bugs Mayhem is meant to find in the capnproto-backed deserialize path. Disable leak
 * detection (detect_leaks=0) while keeping all of ASan's heap/stack/global out-of-bounds and
 * use-after-free checks ON and halting. Linked as a weak symbol so it stays a default that can still
 * be overridden at runtime via ASAN_OPTIONS if ever needed.
 *
 * NOTE: we do NOT set ASAN_OPTIONS in the Mayhemfile (Mayhem owns the runtime option set); baking
 * the default into the binary is the supported way to turn leak detection off for fuzzing.
 */
const char *__asan_default_options(void) {
    return "detect_leaks=0";
}
