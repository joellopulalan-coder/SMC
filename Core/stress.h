// CPU stress test: one worker thread per core, each computing independent FMA chains.
#pragma once
#include <stdint.h>

// Floating-point operations per block counted by stress_cpu_blocks() (for a GFLOPS estimate).
extern const double STRESS_CPU_FLOPS_PER_BLOCK;

void stress_cpu_start(int threads);
void stress_cpu_stop(void);
// Total number of completed blocks since start, across all threads.
uint64_t stress_cpu_blocks(void);
