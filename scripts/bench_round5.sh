#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f Makefile ]] || [[ ! -d optimized ]] || [[ ! -d configurable ]] || [[ ! -d reference ]]; then
  echo "ERROR: must run from round5/code repo root" >&2
  exit 1
fi

mkdir -p results
TS="$(date -u +%Y%m%dT%H%M%SZ)"
CSV="results/round5_cycles_bench_${TS}.csv"
ENV_LOG="results/round5_cycles_env_${TS}.log"

commit_hash="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
cpu_model="$(lscpu 2>/dev/null | awk -F: '/Model name/{gsub(/^ +/,"",$2); print $2; exit}')"
os_info="$(uname -a)"
gcc_ver="$(gcc --version 2>/dev/null | head -n1 || true)"
clang_ver="$(clang --version 2>/dev/null | head -n1 || true)"

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit_hash=$commit_hash"
  echo "git_status_short:"; git status --short || true
  echo "gcc=$gcc_ver"
  echo "clang=$clang_ver"
  echo "cpu_model=$cpu_model"
  echo "os=$os_info"
  echo "-- cycle implementation scan --"
  rg -n "cpucycles|rdtsc|rdtscp|__rdtsc|__rdtscp|TIMING|CLOCKS_PER_SEC|clock_gettime|gettimeofday" optimized/src configurable/src reference/src || true
} | tee "$ENV_LOG"

echo "scheme,parameter,mode,keygen_kcycles,encaps_kcycles,decaps_kcycles,pk_bytes,ct_bytes,sk_bytes,iterations,status,notes" > "$CSV"

params=(R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d)
raw_logs=()

extract_kv(){ awk -F= -v k="$1" '$1==k{print $2; exit}' "$2"; }

run_one_mode(){
  local param="$1" impl="$2" mode="$3" avx2="$4" log="$5"
  local notes="commit=${commit_hash};STANDALONE=1;AVX2=${avx2};median_cycles=true;cycle_counter=rdtscp"
  local status="ok"

  {
    echo "commit_hash=$commit_hash"
    echo "gcc=$gcc_ver"
    echo "clang=$clang_ver"
    echo "cpu_model=$cpu_model"
    echo "os=$os_info"
    echo "parameter=$param"
    echo "mode=$mode"
    echo "make clean"
  } > "$log"

  if ! make clean >>"$log" 2>&1; then
    echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,build_failed,\"${notes};make_clean_failed\"" >> "$CSV"
    return 0
  fi

  if [[ "$avx2" == "1" ]]; then
    if ! make ALG="$param" "$impl" STANDALONE=1 AVX2=1 >>"$log" 2>&1; then
      echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,build_failed,\"${notes};build_failed\"" >> "$CSV"; return 0
    fi
  else
    if ! make ALG="$param" "$impl" STANDALONE=1 >>"$log" 2>&1; then
      echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,build_failed,\"${notes};build_failed\"" >> "$CSV"; return 0
    fi
  fi

  local obj_list
  obj_list="$(find "$impl/build/.o" -type f -name '*.o' | rg -v '/examples/' | tr '\n' ' ')"
  if [[ -z "$obj_list" ]]; then
    echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,link_failed,\"${notes};no_objects_found\"" >> "$CSV"; return 0
  fi

  local cflags="-std=c99 -O3 -march=native -mtune=native -fomit-frame-pointer -fwrapv -w -D${param} -DSTANDALONE"
  [[ "$avx2" == "1" ]] && cflags+=" -DAVX2"
  local incs="-I${impl}/src -I${impl}/src/common/rng -I${impl}/src/common/drbg -I${impl}/src/common/fips202 -I${impl}/src/common/fips202/1x -I${impl}/src/common/fips202/4x -I${impl}/src/common/aesctr -I${impl}/src/common/hash"
  local exe="results/bench_round5_cycles_${param}_${mode}_${TS}"
  local compile_cmd="gcc ${cflags} ${incs} scripts/bench_round5_cycles.c ${obj_list} -lcrypto -lm -o ${exe}"
  echo "compile_cmd=${compile_cmd}" >> "$log"

  if ! eval "$compile_cmd" >>"$log" 2>&1; then
    echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,link_failed,\"${notes};link_failed\"" >> "$CSV"; return 0
  fi

  if ! "$exe" >>"$log" 2>&1; then
    status_line="$(extract_kv status "$log" || true)"
    if [[ "$status_line" == "unsupported_cycle_counter" ]]; then
      echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,unsupported_cycle_counter,\"${notes}\"" >> "$CSV"
    elif [[ "$status_line" == "correctness_failed" ]]; then
      echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,correctness_failed,\"${notes}\"" >> "$CSV"
    else
      echo "Round5,$param,$mode,NA,NA,NA,NA,NA,NA,1000,run_failed,\"${notes}\"" >> "$CSV"
    fi
    return 0
  fi

  local cycle_counter="$(extract_kv cycle_counter "$log" || true)"
  [[ -n "$cycle_counter" ]] && notes="${notes/rdtscp/$cycle_counter}"

  local kg ec dc pk ct sk it
  kg="$(extract_kv keygen_median_cycles "$log" || true)"
  ec="$(extract_kv encaps_median_cycles "$log" || true)"
  dc="$(extract_kv decaps_median_cycles "$log" || true)"
  pk="$(extract_kv pk_bytes "$log" || true)"
  ct="$(extract_kv ct_bytes "$log" || true)"
  sk="$(extract_kv sk_bytes "$log" || true)"
  it="$(extract_kv iterations "$log" || echo 1000)"

  if [[ -z "$kg" || -z "$ec" || -z "$dc" ]]; then
    echo "Round5,$param,$mode,NA,NA,NA,${pk:-NA},${ct:-NA},${sk:-NA},${it},parse_partial,\"${notes}\"" >> "$CSV"; return 0
  fi

  local kgk eck dck suspicious=""
  kgk="$(awk -v v="$kg" 'BEGIN{printf "%.3f", v/1000.0}')"
  eck="$(awk -v v="$ec" 'BEGIN{printf "%.3f", v/1000.0}')"
  dck="$(awk -v v="$dc" 'BEGIN{printf "%.3f", v/1000.0}')"

  if awk -v v="$kgk" 'BEGIN{exit !(v<10)}'; then suspicious=";suspicious_timing"; fi
  echo "median_kcycles_keygen=$kgk" >> "$log"
  echo "median_kcycles_encaps=$eck" >> "$log"
  echo "median_kcycles_decaps=$dck" >> "$log"
  echo "correctness=ok" >> "$log"
  echo "Round5,$param,$mode,$kgk,$eck,$dck,${pk:-NA},${ct:-NA},${sk:-NA},${it},ok,\"${notes}${suspicious}\"" >> "$CSV"
}

for p in "${params[@]}"; do
  attempted=0
  for spec in "optimized optimized_avx2 1" "optimized optimized_portable 0" "configurable configurable 0" "reference reference 0"; do
    set -- $spec
    impl="$1"; mode="$2"; avx2="$3"
    log="results/round5_cycles_raw_${p}_${mode}_${TS}.log"
    raw_logs+=("$log")
    before_lines=$(wc -l < "$CSV")
    run_one_mode "$p" "$impl" "$mode" "$avx2" "$log"
    after_line=$(tail -n1 "$CSV")
    status=$(echo "$after_line" | awk -F, '{print $11}')
    attempted=1
    if [[ "$status" == "ok" || "$status" == "correctness_failed" || "$status" == "unsupported_cycle_counter" ]]; then
      break
    fi
  done
  [[ $attempted -eq 0 ]] && true
 done

echo "CSV: $CSV"
echo "RAW LOGS:"
printf '%s\n' "${raw_logs[@]}"
cat "$CSV"
