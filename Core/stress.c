#include "stress.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

#define MAX_THREADS 64
#define CHAINS 16          // independent chains, so every FP unit stays busy
#define ITERS_PER_BLOCK 50000

const double STRESS_CPU_FLOPS_PER_BLOCK = 2.0 * CHAINS * ITERS_PER_BLOCK; // FMA = 2 flops

static pthread_t threads[MAX_THREADS];
static int n_threads;
static atomic_bool running;
// One counter per thread on its own cache line, so threads don't slow each other down.
static struct { _Atomic uint64_t blocks; char pad[120]; } counters[MAX_THREADS];
static volatile double sink;

static void *worker(void *arg) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    int idx = (int)(intptr_t)arg;
    double x[CHAINS];
    for (int i = 0; i < CHAINS; i++) x[i] = 1.0 + idx * 0.01 + i * 0.001;

    while (atomic_load_explicit(&running, memory_order_relaxed)) {
        for (int k = 0; k < ITERS_PER_BLOCK; k++) {
            for (int i = 0; i < CHAINS; i++) x[i] = x[i] * 0.999999 + 0.000001;
        }
        atomic_fetch_add_explicit(&counters[idx].blocks, 1, memory_order_relaxed);
    }
    double s = 0;
    for (int i = 0; i < CHAINS; i++) s += x[i];
    sink = s; // keeps the compiler from discarding the work
    return NULL;
}

void stress_cpu_start(int threads_wanted) {
    if (atomic_load(&running)) return;
    n_threads = threads_wanted < 1 ? 1 : threads_wanted > MAX_THREADS ? MAX_THREADS : threads_wanted;
    for (int i = 0; i < n_threads; i++) atomic_store(&counters[i].blocks, 0);
    atomic_store(&running, true);
    for (int i = 0; i < n_threads; i++) pthread_create(&threads[i], NULL, worker, (void *)(intptr_t)i);
}

void stress_cpu_stop(void) {
    if (!atomic_load(&running)) return;
    atomic_store(&running, false);
    for (int i = 0; i < n_threads; i++) pthread_join(threads[i], NULL);
    n_threads = 0;
}

uint64_t stress_cpu_blocks(void) {
    uint64_t total = 0;
    for (int i = 0; i < MAX_THREADS; i++) total += atomic_load_explicit(&counters[i].blocks, memory_order_relaxed);
    return total;
}
