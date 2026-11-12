/* Weak SanCov callbacks so the -standalone reproducers link when SANITIZER_FLAGS is empty. */
#include <stdint.h>
__attribute__((weak)) void __sanitizer_cov_trace_pc_guard_init(uint32_t *start, uint32_t *stop) { (void)start; (void)stop; }
__attribute__((weak)) void __sanitizer_cov_trace_pc_guard(uint32_t *guard) { (void)guard; }
__attribute__((weak)) void __sanitizer_cov_8bit_counters_init(char *start, char *stop) { (void)start; (void)stop; }
__attribute__((weak)) void __sanitizer_cov_pcs_init(const uintptr_t *beg, const uintptr_t *end) { (void)beg; (void)end; }
