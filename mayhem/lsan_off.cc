/* Build-time LeakSanitizer off-switch for the sanitized uhdm-dump binary (SPEC §6.2 item 15).
 *
 * uhdm-dump is a run-once-per-input CLI: it calls UHDM::Serializer::Restore() to reconstruct an
 * entire UHDM design tree from the input .uhdm file, walks it, and exits WITHOUT tearing the tree
 * down (the Serializer/arena owns thousands of nodes that are intentionally not freed before
 * process exit — UHDM relies on process teardown). Under leak detection those benign at-exit
 * "leaks" fire on essentially EVERY input, which would drown out the real memory-safety bugs
 * Mayhem is meant to find in the capnproto-backed deserialize path.
 *
 * -fsanitize=address always bundles LeakSanitizer in and there is no flag to keep ASan while
 * dropping just the leak checks, so this TU is compiled with $SANITIZER_FLAGS and linked into the
 * fuzz binary: ASan's heap/stack/global out-of-bounds and use-after-free checks and all of UBSan
 * stay ON and halting; only leak reporting is suppressed. Nothing here touches the runtime option
 * set — Mayhem alone owns that.
 */
extern "C" int __lsan_is_turned_off() { return 1; }
