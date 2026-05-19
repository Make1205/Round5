#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f Makefile ]] || [[ ! -d reference ]] || [[ ! -d optimized ]] || [[ ! -d configurable ]]; then
  echo "ERROR: this script must run from round5/code repo root (missing expected files/dirs)." >&2
  exit 1
fi

if ! grep -q "Makefile for the ROUND5 project software" Makefile; then
  echo "ERROR: current directory does not look like round5/code repo root." >&2
  exit 1
fi

mkdir -p results
TS="$(date -u +%Y%m%dT%H%M%SZ)"
CSV="results/round5_bench_${TS}.csv"
ENV_LOG="results/round5_env_${TS}.log"
: > "$ENV_LOG"

echo "scheme,parameter,mode,keygen_kcycles,encaps_kcycles,decaps_kcycles,pk_bytes,ct_bytes,sk_bytes,iterations,status,notes" > "$CSV"

COMMIT_HASH="$(git rev-parse HEAD 2>/dev/null || echo unknown)"

{
  echo "timestamp_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "commit_hash=${COMMIT_HASH}"
  echo "--- git status --short ---"
  git status --short || true
  echo "--- gcc --version ---"
  gcc --version 2>/dev/null | head -n 1 || echo "gcc not found"
  echo "--- clang --version ---"
  clang --version 2>/dev/null | head -n 1 || echo "clang not found"
  echo "--- CPU ---"
  (lscpu 2>/dev/null | grep -m1 'Model name' || true)
  echo "--- OS ---"
  (uname -a || true)
} | tee -a "$ENV_LOG"

main_params=(R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d)
extra_params=(R5N1_1CCA_5d R5N1_3CCA_5d R5N1_5CCA_5d)
all_params=("${main_params[@]}" "${extra_params[@]}")

declare -a RAW_LOGS=()

run_build() {
  local param="$1"
  local target="$2"
  local avx2flag="$3"
  local mode="$4"
  local log="$5"

  if ! make clean >>"$log" 2>&1; then
    return 1
  fi

  if [[ "$avx2flag" == "1" ]]; then
    make ALG="$param" "$target" STANDALONE=1 TIMING=1000 AVX2=1 >>"$log" 2>&1
  else
    make ALG="$param" "$target" STANDALONE=1 TIMING=1000 >>"$log" 2>&1
  fi
}

find_sample_kem() {
  local pref_dir="$1"
  local f
  if [[ -x "$pref_dir/build/sample_kem" ]]; then
    echo "$pref_dir/build/sample_kem"
    return 0
  fi

  f="$(find optimized configurable reference -type f -perm -111 -name 'sample_kem' 2>/dev/null | awk -v p="$pref_dir" 'index($0,p"/")==1{print; exit}')"
  if [[ -n "$f" ]]; then
    echo "$f"
    return 0
  fi

  f="$(find optimized configurable reference -type f -perm -111 -name 'sample_kem' 2>/dev/null | head -n 1)"
  [[ -n "$f" ]] && echo "$f"
}

extract_num() {
  sed -E 's/,//g' | grep -Eo '[0-9]+(\.[0-9]+)?' | head -n 1
}

extract_cycle_metric() {
  local label="$1"
  local log="$2"
  local line raw unit
  line="$(grep -Ei "$label" "$log" | grep -Ei 'cycle|kcycle' | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "NA|unit_missing"
    return
  fi
  raw="$(echo "$line" | extract_num || true)"
  if [[ -z "$raw" ]]; then
    echo "NA|unit_missing"
    return
  fi

  if echo "$line" | grep -Eiq 'kcycle'; then
    echo "${raw}|kcycles"
  elif echo "$line" | grep -Eiq 'cycle'; then
    awk -v v="$raw" 'BEGIN{printf "%.3f|cycles_to_kcycles", v/1000.0}'
  else
    echo "${raw}|unit_uncertain"
  fi
}

extract_iterations() {
  local log="$1"
  local line val
  line="$(grep -Ei 'iteration|timing' "$log" | head -n 1 || true)"
  if [[ -z "$line" ]]; then
    echo "NA"
    return
  fi
  val="$(echo "$line" | extract_num || true)"
  [[ -n "$val" ]] && echo "$val" || echo "NA"
}

extract_size() {
  local what="$1"; local log="$2"
  local line val
  line="$(grep -E "${what}" "$log" | head -n 1 || true)"
  if [[ -n "$line" ]]; then
    val="$(echo "$line" | extract_num || true)"
    [[ -n "$val" ]] && { echo "$val"; return; }
  fi
  val="$(rg -n "(CRYPTO_${what}|${what}|${what/_BYTES/KEY_BYTES}|${what/_BYTES/_KEY_BYTES})" reference configurable optimized 2>/dev/null | head -n 1 | sed -E 's/.*\b([0-9]+)\b.*/\1/' || true)"
  [[ -n "$val" ]] && echo "$val" || echo "NA"
}

for param in "${all_params[@]}"; do
  mode=""
  status="ok"
  notes="commit=${COMMIT_HASH};STANDALONE=1;TIMING=1000;AVX2=1"

  log="results/round5_raw_${param}_optimized_avx2_${TS}.log"
  RAW_LOGS+=("$log")

  if run_build "$param" optimized 1 optimized_avx2 "$log"; then
    sample="$(find_sample_kem optimized || true)"
    if [[ -n "$sample" ]] && "$sample" >>"$log" 2>&1; then
      mode="optimized_avx2"
    else
      notes+=";optimized_run_failed"
    fi
  else
    notes+=";avx2_build_failed"
  fi

  if [[ -z "$mode" ]]; then
    log="results/round5_raw_${param}_optimized_portable_${TS}.log"
    RAW_LOGS+=("$log")
    if run_build "$param" optimized 0 optimized_portable "$log"; then
      sample="$(find_sample_kem optimized || true)"
      if [[ -n "$sample" ]] && "$sample" >>"$log" 2>&1; then
        mode="optimized_portable"
        notes+=";AVX2=0"
      else
        notes+=";optimized_portable_run_failed"
      fi
    else
      notes+=";optimized_portable_build_failed"
    fi
  fi

  if [[ -z "$mode" ]]; then
    for tgt in configurable reference; do
      log="results/round5_raw_${param}_${tgt}_${TS}.log"
      RAW_LOGS+=("$log")
      if run_build "$param" "$tgt" 0 "$tgt" "$log"; then
        sample="$(find_sample_kem "$tgt" || true)"
        if [[ -n "$sample" ]] && "$sample" >>"$log" 2>&1; then
          mode="$tgt"
          notes+=";fallback_${tgt}"
          break
        else
          notes+=";${tgt}_run_failed"
        fi
      else
        notes+=";${tgt}_build_failed"
      fi
    done
  fi

  if [[ -z "$mode" ]]; then
    mode="optimized_avx2"
    status="build_failed"
    keygen="NA";encaps="NA";decaps="NA";iters="NA";pk="NA";ct="NA";sk="NA"
    notes+=";no_build_succeeded"
  else
    curr_log="results/round5_raw_${param}_${mode}_${TS}.log"
    kg_res="$(extract_cycle_metric 'keygen|key generation' "$curr_log")"
    en_res="$(extract_cycle_metric 'encap|encapsulation' "$curr_log")"
    dc_res="$(extract_cycle_metric 'decap|decapsulation' "$curr_log")"

    keygen="${kg_res%%|*}"; kg_unit="${kg_res##*|}"
    encaps="${en_res%%|*}"; en_unit="${en_res##*|}"
    decaps="${dc_res%%|*}"; dc_unit="${dc_res##*|}"
    iters="$(extract_iterations "$curr_log")"

    pk="$(extract_size 'PUBLICKEYBYTES|PUBLICKEY_BYTES|PUBLIC_KEY_BYTES' "$curr_log")"
    ct="$(extract_size 'CIPHERTEXTBYTES|CIPHERTEXT_BYTES|CIPHER_TEXT_BYTES' "$curr_log")"
    sk="$(extract_size 'SECRETKEYBYTES|SECRETKEY_BYTES|SECRET_KEY_BYTES' "$curr_log")"

    if [[ "$keygen" == "NA" || "$encaps" == "NA" || "$decaps" == "NA" ]]; then
      status="parse_partial"
      notes+=";no cycle output found"
    fi
    [[ "$kg_unit" == "unit_uncertain" || "$en_unit" == "unit_uncertain" || "$dc_unit" == "unit_uncertain" ]] && notes+=";unit_uncertain"
    [[ "$pk" == "NA" || "$ct" == "NA" || "$sk" == "NA" ]] && notes+=";size macros not found"
  fi

  extra_note=""
  if [[ ! " ${main_params[*]} " =~ " ${param} " ]]; then
    extra_note=";non_main_parameter"
  fi
  echo "Round5,${param},${mode},${keygen},${encaps},${decaps},${pk},${ct},${sk},${iters},${status},\"${notes}${extra_note}\"" >> "$CSV"
done

echo "CSV: $CSV"
echo "RAW LOGS:"
printf '%s\n' "${RAW_LOGS[@]}"
cat "$CSV"
