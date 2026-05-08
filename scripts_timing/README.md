To obtain timing results do the following:

1. Run `./timing.sh`. This will run the optimized code through all configurations and place the results in the file `timing_results.txt`.
2. Run `python timing_table.py` to obtain the table containing performance results as included in the Round5 specification.

Note that it is possible to obtain timing results of a specific Round5 configurations by running `make` with the compiler flag `TIMING=1`.

## R5N1 reference vs optimized benchmark

For the three unstructured/non-ring LWE R5N1 CCA parameter sets, run:

```sh
./bench_r5n1.sh
```

The script benchmarks `R5N1_1CCA_0d`, `R5N1_3CCA_0d`, and `R5N1_5CCA_0d` with:

* the `reference` implementation, measured as end-to-end wall-clock time because the reference `sample_kem` does not include the internal `TIMING` cycle timer;
* the `optimized` implementation, built with `TIMING=N`, which reports key generation, encapsulation, decapsulation, and total means in milliseconds and K CPU cycles.

By default the script builds with `STANDALONE=1` so it uses the in-tree TupleHash/FIPS202 code instead of requiring an external `libkeccak`. On CPUs that advertise AVX2, the script runs both optimized scalar and optimized AVX2 builds. Use `--avx2 off`, `--avx2 on`, or `--avx2 both` to override this behavior.

Useful examples:

```sh
./bench_r5n1.sh --timing 10000 --ref-runs 5
./bench_r5n1.sh --avx2 off --out /tmp/r5n1_scalar.txt
./bench_r5n1.sh --schemes "R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d" --avx2 both
```
