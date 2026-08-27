#!/usr/bin/env bash
set -euo pipefail

[[ -f Makefile && -d scripts_kats/.apifilesrefcon ]] || {
  echo "ERROR: run from the round5/code repository root" >&2; exit 1;
}

mkdir -p results
TS="$(date -u +%Y%m%dT%H%M%SZ)"
CSV="results/round5_cycles_bench_${TS}.csv"
INV="results/round5_impl_inventory_${TS}.md"
UPSTREAM_COMMIT="35e97f07c313ecd651ac66fb55127218f7933dba"
HARNESS_COMMIT="$(git rev-parse HEAD)"
PARAMS=(R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d)
MODES=(reference configurable optimized_portable optimized_avx2_ct)
TMP_ROOT="$(mktemp -d /tmp/round5-bench.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT

cpu="$(lscpu 2>/dev/null | awk -F: '/Model name/{sub(/^ +/,"",$2);print $2;exit}')"
os="$(uname -a)"
cc_version="$(gcc --version | head -n1)"

echo 'scheme,parameter,mode,keygen_kcycles,encaps_kcycles,decaps_kcycles,pk_bytes,ct_bytes,sk_bytes,ss_bytes,iterations,status,notes' > "$CSV"
{
  echo '# Round5 implementation inventory'
  echo
  echo "- upstream_round5_commit: $UPSTREAM_COMMIT"
  echo "- benchmark_harness_commit: $HARNESS_COMMIT"
  for impl in optimized configurable reference; do
    echo "- $impl directory: $([[ -d $impl ]] && echo present || echo missing)"
    echo "- $impl Makefile target: $(awk -v x="$impl" '/^implementations =/{for(i=3;i<=NF;i++)if($i==x)f=1}END{print f?"present":"missing"}' Makefile)"
    echo "- $impl sample_kem source: $impl/src/examples/sample_kem.c"
    echo "- $impl KEM API source: $impl/src/kem.c"
  done
  echo '- reference/configurable CCA staging: scripts_kats/.apifilesrefcon/kem_cca.{c,h} and api_KEM_<scheme>.h'
  echo '- non-ring TAU: 2 (matching scripts_kats/check_kats.sh)'
  echo
  echo '## Per-build results'
} > "$INV"

kv() { awk -F= -v key="$1" '$1==key{print $2;exit}' "$2"; }
csv_fail() {
  local p="$1" m="$2" status="$3" notes="$4"
  echo "Round5,$p,$m,NA,NA,NA,NA,NA,NA,NA,$CURRENT_ITERATIONS,$status,\"$notes\"" >> "$CSV"
}

for param in "${PARAMS[@]}"; do
  for mode in "${MODES[@]}"; do
    log="results/round5_cycles_raw_${param}_${mode}_${TS}.log"
    workbase="$TMP_ROOT/${param}_${mode}"
    case "$mode" in
      reference|configurable) impl="$mode"; avx=0; ct=0; sparse=yes; CURRENT_ITERATIONS=10 ;;
      optimized_portable) impl=optimized; avx=0; ct=0; sparse=yes; CURRENT_ITERATIONS=1000 ;;
      optimized_avx2_ct) impl=optimized; avx=1; ct=1; sparse=no; CURRENT_ITERATIONS=1000 ;;
    esac
    mkdir -p "$workbase"
    # configurable contains relative links into reference, so preserve the
    # upstream sibling layout even when benchmarking only one implementation.
    cp -a reference configurable optimized "$workbase/"
    work="$workbase/$impl"

    staged=0
    if [[ "$impl" != optimized ]]; then
      rm -f "$work/src/kem.c" "$work/src/kem.h" "$work/src/api.h"
      cp scripts_kats/.apifilesrefcon/kem_cca.c "$work/src/kem.c"
      cp scripts_kats/.apifilesrefcon/kem_cca.h "$work/src/kem.h"
      cp "scripts_kats/.apifilesrefcon/api_KEM_${param}.h" "$work/src/api.h"
      staged=1
    fi

    flags="ALG=$param TAU=2 STANDALONE=1"
    [[ $avx == 1 ]] && flags+=" AVX2=1 CM_CT=1"
    notes="upstream_round5_commit=$UPSTREAM_COMMIT;benchmark_harness_commit=$HARNESS_COMMIT;TAU=2;STANDALONE=1;AVX2=$avx;CM_CT=$ct;CM_CACHE=0;cycle_counter=rdtscp;median_cycles=true;iterations=$CURRENT_ITERATIONS;cca_api_staged=$staged;sparse_secret_representation=$sparse"
    {
      echo "upstream_round5_commit=$UPSTREAM_COMMIT"
      echo "benchmark_harness_commit=$HARNESS_COMMIT"
      echo "compiler=$cc_version"; echo "cpu=$cpu"; echo "os=$os"
      echo "parameter=$param"; echo "mode=$mode"; echo "compiler_flags=$flags"
      echo "kem_c=$work/src/kem.c"; echo "kem_h=$work/src/kem.h"
      echo "api_h=$([[ -f $work/src/api.h ]] && echo "$work/src/api.h" || echo not_used)"
      echo "ROUND5_CCA_PKE=$([[ $staged == 1 ]] && echo defined || echo selected_by_optimized_parameters)"
      echo "ALG=$param"; echo 'TAU=2'; echo 'STANDALONE=1'
      echo "AVX2=$avx"; echo "CM_CT=$ct"; echo 'CM_CACHE=0'
      echo "build_cmd=make -C $work $flags"
    } > "$log"

    if ! make -C "$work" clean >> "$log" 2>&1 || ! make -C "$work" $flags >> "$log" 2>&1; then
      csv_fail "$param" "$mode" build_failed "$notes;build_failed"; echo "- $param / $mode: build_failed" >> "$INV"; continue
    fi

    objs="$(find "$work/build/.o" -type f -name '*.o' | awk '!/\/examples\// && !/\/createAfixed\//{printf "%s ",$0}')"
    api_define=""; [[ $staged == 1 ]] && api_define="-DBENCH_USE_API_H"
    compile_flags="-std=c99 -O3 -march=native -mtune=native -fomit-frame-pointer -fwrapv -D${param} -DROUND5_API_TAU=2 -DSTANDALONE -DITERATIONS=$CURRENT_ITERATIONS $api_define"
    [[ $avx == 1 ]] && compile_flags+=" -DAVX2 -DCM_CT"
    includes="-I$work/src -I$work/src/common/rng -I$work/src/common/drbg -I$work/src/common/fips202 -I$work/src/common/fips202/1x -I$work/src/common/fips202/4x -I$work/src/common/hash"
    exe="$work/bench_round5_cycles"
    echo "harness_compiler_flags=$compile_flags" >> "$log"
    echo "link_cmd=gcc $compile_flags $includes scripts/bench_round5_cycles.c $objs -lcrypto -lm -o $exe" >> "$log"
    if ! gcc $compile_flags $includes scripts/bench_round5_cycles.c $objs -lcrypto -lm -o "$exe" >> "$log" 2>&1; then
      csv_fail "$param" "$mode" link_failed "$notes;link_failed"; echo "- $param / $mode: link_failed" >> "$INV"; continue
    fi

    echo 'linked_crypto_kem_targets:' >> "$log"
    nm -u "$work/build/.o/kem.o" 2>/dev/null | rg 'r5_(cca|cpa)_kem' >> "$log" || true
    linked="$(nm -u "$work/build/.o/kem.o" 2>/dev/null | awk '/r5_(cca|cpa)_kem/{printf "%s ",$2}')"
    echo "linked_kem_backend=${linked:-inlined_or_not_visible}" >> "$log"

    echo 'correctness_validation:' >> "$log"
    if ! "$exe" --verify >> "$log" 2>&1; then
      status="$(kv status "$log" || true)"; [[ "$status" == correctness_failed ]] || status=run_failed
      csv_fail "$param" "$mode" "$status" "$notes;correctness_validation_failed;linked_backend=${linked:-unknown}"
      echo "- $param / $mode: $status (backend ${linked:-unknown})" >> "$INV"; continue
    fi

    echo 'benchmark:' >> "$log"
    if ! "$exe" >> "$log" 2>&1; then
      csv_fail "$param" "$mode" run_failed "$notes;benchmark_run_failed"; echo "- $param / $mode: run_failed" >> "$INV"; continue
    fi
    kg="$(kv keygen_median_cycles "$log")"; en="$(kv encaps_median_cycles "$log")"; de="$(kv decaps_median_cycles "$log")"
    pk="$(kv pk_bytes "$log")"; ctbytes="$(kv ct_bytes "$log")"; sk="$(kv sk_bytes "$log")"; ss="$(kv ss_bytes "$log")"; it="$(kv iterations "$log")"
    kgk="$(awk -v x="$kg" 'BEGIN{printf "%.3f",x/1000}')"; enk="$(awk -v x="$en" 'BEGIN{printf "%.3f",x/1000}')"; dek="$(awk -v x="$de" 'BEGIN{printf "%.3f",x/1000}')"
    [[ $(awk -v x="$kgk" 'BEGIN{print x<10}') == 1 ]] && notes+=";suspicious_timing"
    echo "keygen_median_kcycles=$kgk" >> "$log"; echo "encaps_median_kcycles=$enk" >> "$log"; echo "decaps_median_kcycles=$dek" >> "$log"
    echo "Round5,$param,$mode,$kgk,$enk,$dek,$pk,$ctbytes,$sk,$ss,$it,ok,\"$notes;linked_backend=${linked:-inlined_or_not_visible}\"" >> "$CSV"
    echo "- $param / $mode: build=ok, link=ok, correctness=ok, benchmark=ok; backend ${linked:-inlined_or_not_visible}" >> "$INV"
  done
done

echo "CSV: $CSV"; echo "INVENTORY: $INV"; printf 'RAW LOG: %s\n' results/round5_cycles_raw_*_"$TS".log; cat "$CSV"
