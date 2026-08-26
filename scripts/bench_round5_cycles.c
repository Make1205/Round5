#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <inttypes.h>

#ifdef BENCH_USE_API_H
#include "api.h"
#else
#include "kem.h"
#endif

#ifndef ITERATIONS
#define ITERATIONS 1000
#endif
#ifndef WARMUP
#define WARMUP 10
#endif

#if defined(__x86_64__) || defined(_M_X64)
#include <x86intrin.h>
static inline uint64_t bench_cycles(void) {
    unsigned int aux;
    _mm_lfence();
    uint64_t t = __rdtscp(&aux);
    _mm_lfence();
    return t;
}
#define CYCLE_COUNTER_NAME "rdtscp"
#define CYCLE_COUNTER_OK 1
#else
#define CYCLE_COUNTER_NAME "unsupported"
#define CYCLE_COUNTER_OK 0
#endif

static int cmp_u64(const void *a, const void *b) {
    const uint64_t va = *(const uint64_t *)a;
    const uint64_t vb = *(const uint64_t *)b;
    return (va > vb) - (va < vb);
}

static uint64_t median_u64(uint64_t *arr, size_t n) {
    qsort(arr, n, sizeof(uint64_t), cmp_u64);
    if (n % 2 == 1) return arr[n / 2];
    return (arr[n / 2 - 1] + arr[n / 2]) / 2;
}

static double mean_u64(const uint64_t *arr, size_t n) {
    long double sum = 0.0;
    for (size_t i = 0; i < n; i++) sum += (long double)arr[i];
    return (double)(sum / (long double)n);
}

int main(int argc, char **argv) {
    printf("cycle_counter=%s\n", CYCLE_COUNTER_NAME);
    printf("iterations=%d\n", ITERATIONS);
    printf("pk_bytes=%d\n", CRYPTO_PUBLICKEYBYTES);
    printf("sk_bytes=%d\n", CRYPTO_SECRETKEYBYTES);
    printf("ct_bytes=%d\n", CRYPTO_CIPHERTEXTBYTES);
    printf("ss_bytes=%d\n", CRYPTO_BYTES);

#if !CYCLE_COUNTER_OK
    printf("status=unsupported_cycle_counter\n");
    return 2;
#else
    unsigned char pk[CRYPTO_PUBLICKEYBYTES], sk[CRYPTO_SECRETKEYBYTES];
    unsigned char ct[CRYPTO_CIPHERTEXTBYTES], ss1[CRYPTO_BYTES], ss2[CRYPTO_BYTES];
    uint64_t keypair_cycles[ITERATIONS], enc_cycles[ITERATIONS], dec_cycles[ITERATIONS];

    if (argc > 1 && strcmp(argv[1], "--verify") == 0) {
        if (crypto_kem_keypair(pk, sk) != 0 ||
            crypto_kem_enc(ct, ss1, pk) != 0 ||
            crypto_kem_dec(ss2, ct, sk) != 0) {
            printf("correctness=failed\nstatus=run_failed\n");
            return 3;
        }
        if (memcmp(ss1, ss2, CRYPTO_BYTES) != 0) {
            printf("correctness=failed\nstatus=correctness_failed\n");
            return 4;
        }
        printf("correctness=ok\nstatus=ok\n");
        return 0;
    }

    for (int i = 0; i < WARMUP; i++) {
        if (crypto_kem_keypair(pk, sk) != 0) { printf("status=run_failed\n"); return 3; }
        if (crypto_kem_enc(ct, ss1, pk) != 0) { printf("status=run_failed\n"); return 3; }
        if (crypto_kem_dec(ss2, ct, sk) != 0) { printf("status=run_failed\n"); return 3; }
        if (memcmp(ss1, ss2, CRYPTO_BYTES) != 0) { printf("status=correctness_failed\n"); return 4; }
    }

    for (int i = 0; i < ITERATIONS; i++) {
        uint64_t s, e;
        s = bench_cycles();
        if (crypto_kem_keypair(pk, sk) != 0) { printf("status=run_failed\n"); return 3; }
        e = bench_cycles();
        keypair_cycles[i] = e - s;

        s = bench_cycles();
        if (crypto_kem_enc(ct, ss1, pk) != 0) { printf("status=run_failed\n"); return 3; }
        e = bench_cycles();
        enc_cycles[i] = e - s;

        s = bench_cycles();
        if (crypto_kem_dec(ss2, ct, sk) != 0) { printf("status=run_failed\n"); return 3; }
        e = bench_cycles();
        dec_cycles[i] = e - s;

        if (memcmp(ss1, ss2, CRYPTO_BYTES) != 0) { printf("status=correctness_failed\n"); return 4; }
    }

    uint64_t key_med = median_u64(keypair_cycles, ITERATIONS);
    uint64_t enc_med = median_u64(enc_cycles, ITERATIONS);
    uint64_t dec_med = median_u64(dec_cycles, ITERATIONS);
    double key_mean = mean_u64(keypair_cycles, ITERATIONS);
    double enc_mean = mean_u64(enc_cycles, ITERATIONS);
    double dec_mean = mean_u64(dec_cycles, ITERATIONS);

    printf("keygen_median_cycles=%" PRIu64 "\n", key_med);
    printf("encaps_median_cycles=%" PRIu64 "\n", enc_med);
    printf("decaps_median_cycles=%" PRIu64 "\n", dec_med);
    printf("keygen_mean_cycles=%.3f\n", key_mean);
    printf("encaps_mean_cycles=%.3f\n", enc_mean);
    printf("decaps_mean_cycles=%.3f\n", dec_mean);
    printf("status=ok\n");
    return 0;
#endif
}
