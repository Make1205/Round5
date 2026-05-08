#!/usr/bin/env bash
# Benchmark the three non-ring (unstructured LWE) R5N1 CCA KEM parameter sets
# for both the reference implementation and the optimized implementation.
#
# Examples:
#   scripts_timing/bench_r5n1.sh
#   scripts_timing/bench_r5n1.sh --timing 10000 --ref-runs 5 --avx2 both
#   scripts_timing/bench_r5n1.sh --schemes "R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SCHEMES="${SCHEMES:-R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d}"
TIMING_REPS="${TIMING_REPS:-1000}"
REF_RUNS="${REF_RUNS:-3}"
AVX2_MODE="${AVX2_MODE:-auto}"
OUT_FILE=""
KEEP_BUILDS=0

usage() {
    cat <<USAGE
Usage: $0 [options]

Options:
  --schemes "LIST"     Space-separated Round5 parameter sets to test.
                       Default: "R5N1_1CCA_0d R5N1_3CCA_0d R5N1_5CCA_0d"
  --timing N           Optimized TIMING repetitions. Default: $TIMING_REPS
  --ref-runs N         Reference wall-clock repetitions per scheme. Default: $REF_RUNS
  --avx2 MODE          MODE is auto, on, off, or both. Default: $AVX2_MODE
                       auto = run scalar and AVX2 when this CPU advertises AVX2,
                              otherwise scalar only.
  --out FILE           Write the detailed report to FILE. Default: scripts_timing/r5n1_perf_<timestamp>.txt
  --keep-builds        Do not clean build directories when the script finishes.
  -h, --help           Show this help.

Notes:
  * Builds use STANDALONE=1 so no external libkeccak installation is required.
  * Reference sample_kem has no internal cycle timer; this script measures its
    end-to-end wall-clock runtime and verifies "Comparing shared secrets: OK".
  * Optimized sample_kem is built with TIMING=N and prints keygen/enc/dec means
    in milliseconds and K CPU cycles.
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --schemes)
            SCHEMES="$2"
            shift 2
            ;;
        --timing)
            TIMING_REPS="$2"
            shift 2
            ;;
        --ref-runs)
            REF_RUNS="$2"
            shift 2
            ;;
        --avx2)
            AVX2_MODE="$2"
            shift 2
            ;;
        --out)
            OUT_FILE="$2"
            shift 2
            ;;
        --keep-builds)
            KEEP_BUILDS=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$AVX2_MODE" in
    auto|on|off|both) ;;
    *) echo "--avx2 must be one of: auto, on, off, both" >&2; exit 2 ;;
esac

case "$TIMING_REPS" in
    ''|*[!0-9]*) echo "--timing must be a positive integer" >&2; exit 2 ;;
esac
case "$REF_RUNS" in
    ''|*[!0-9]*) echo "--ref-runs must be a positive integer" >&2; exit 2 ;;
esac
if [ "$TIMING_REPS" -lt 1 ] || [ "$REF_RUNS" -lt 1 ]; then
    echo "--timing and --ref-runs must be positive integers" >&2
    exit 2
fi

if [ -z "$OUT_FILE" ]; then
    OUT_FILE="$SCRIPT_DIR/r5n1_perf_$(date +%Y%m%d_%H%M%S).txt"
fi
mkdir -p "$(dirname "$OUT_FILE")"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"; if [ "$KEEP_BUILDS" -eq 0 ]; then make -s -C "$REPO_ROOT/reference" clean >/dev/null 2>&1 || true; make -s -C "$REPO_ROOT/optimized" clean >/dev/null 2>&1 || true; fi' EXIT

have_avx2=0
if [ -r /proc/cpuinfo ] && rg -qi '\bavx2\b' /proc/cpuinfo; then
    have_avx2=1
fi

OPT_VARIANTS="scalar"
case "$AVX2_MODE" in
    off) OPT_VARIANTS="scalar" ;;
    on)
        if [ "$have_avx2" -ne 1 ]; then
            echo "Requested --avx2 on, but /proc/cpuinfo does not advertise AVX2." >&2
            exit 1
        fi
        OPT_VARIANTS="avx2"
        ;;
    both)
        if [ "$have_avx2" -eq 1 ]; then
            OPT_VARIANTS="scalar avx2"
        else
            echo "Warning: --avx2 both requested, but this CPU does not advertise AVX2; running scalar only." >&2
            OPT_VARIANTS="scalar"
        fi
        ;;
    auto)
        if [ "$have_avx2" -eq 1 ]; then
            OPT_VARIANTS="scalar avx2"
        else
            OPT_VARIANTS="scalar"
        fi
        ;;
esac

log() {
    printf '%s\n' "$*" | tee -a "$OUT_FILE"
}

run_logged() {
    log "+ $*"
    "$@" 2>&1 | tee -a "$OUT_FILE"
}

ref_bench_one() {
    local scheme="$1"
    local json_file="$TMP_DIR/ref_${scheme}.json"
    local stdout_file="$TMP_DIR/ref_${scheme}.out"

    SCHEME="$scheme" RUNS="$REF_RUNS" EXE="$REPO_ROOT/reference/build/sample_kem" OUT="$stdout_file" python3 - <<'PY' > "$json_file"
import json
import os
import subprocess
import time

scheme = os.environ["SCHEME"]
runs = int(os.environ["RUNS"])
exe = os.environ["EXE"]
out_path = os.environ["OUT"]
values = []
last_stdout = ""
for _ in range(runs):
    start = time.perf_counter()
    proc = subprocess.run([exe, "-a", scheme], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    elapsed_ms = (time.perf_counter() - start) * 1000.0
    last_stdout = proc.stdout
    if proc.returncode != 0:
        raise SystemExit(f"reference run failed for {scheme} with exit code {proc.returncode}\n{proc.stdout}")
    if "Comparing shared secrets: OK" not in proc.stdout:
        raise SystemExit(f"reference run did not report matching shared secrets for {scheme}")
    values.append(elapsed_ms)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(last_stdout)
mean = sum(values) / len(values)
minimum = min(values)
maximum = max(values)
print(json.dumps({"scheme": scheme, "runs": runs, "mean_ms": mean, "min_ms": minimum, "max_ms": maximum}))
PY
    python3 - <<'PY' "$json_file" | tee -a "$OUT_FILE"
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    data = json.load(fh)
print(f"reference,{data['scheme']},runs={data['runs']},mean_ms={data['mean_ms']:.3f},min_ms={data['min_ms']:.3f},max_ms={data['max_ms']:.3f}")
PY
}

extract_timing_lines() {
    rg '^(CRYPTO_ALGNAME|Success|Failures|KeyGen|Enc   |Dec   |Total)' || true
}

check_avx2_object() {
    local object="$REPO_ROOT/optimized/build/.o/matmul_avx2.o"
    if [ -f "$object" ] && nm "$object" 2>/dev/null | rg -q ' T matmul_as_q| T inner1'; then
        echo "yes"
    else
        echo "no"
    fi
}

: > "$OUT_FILE"
log "Round5 R5N1 benchmark report"
log "Repository: $REPO_ROOT"
log "Date: $(date -Is)"
log "Schemes: $SCHEMES"
log "Optimized TIMING repetitions: $TIMING_REPS"
log "Reference wall-clock runs: $REF_RUNS"
log "CPU AVX2 advertised: $([ "$have_avx2" -eq 1 ] && echo yes || echo no)"
log "Optimized variants: $OPT_VARIANTS"
log ""

log "== Building reference implementation (STANDALONE=1) =="
run_logged make -s -C "$REPO_ROOT/reference" clean
run_logged make -s -C "$REPO_ROOT/reference" STANDALONE=1
log ""

log "== Reference wall-clock results =="
for scheme in $SCHEMES; do
    ref_bench_one "$scheme"
done
log ""

for variant in $OPT_VARIANTS; do
    log "== Optimized results: $variant =="
    for scheme in $SCHEMES; do
        log "-- $scheme / optimized-$variant --"
        run_logged make -s -C "$REPO_ROOT/optimized" clean
        make_args=(-s -C "$REPO_ROOT/optimized" STANDALONE=1 "ALG=$scheme" "TIMING=$TIMING_REPS")
        if [ "$variant" = "avx2" ]; then
            make_args+=(AVX2=1)
        fi
        run_logged make "${make_args[@]}"
        used_avx2="$(check_avx2_object)"
        log "optimized-$variant AVX2 matmul object active: $used_avx2"
        "$REPO_ROOT/optimized/build/sample_kem" > "$TMP_DIR/optimized_${variant}_${scheme}.out"
        if ! rg -q "Success in all $TIMING_REPS KEM executions" "$TMP_DIR/optimized_${variant}_${scheme}.out"; then
            cat "$TMP_DIR/optimized_${variant}_${scheme}.out" | tee -a "$OUT_FILE"
            echo "optimized run failed or did not report success for $scheme / $variant" >&2
            exit 1
        fi
        extract_timing_lines < "$TMP_DIR/optimized_${variant}_${scheme}.out" | tee -a "$OUT_FILE"
        log ""
    done
done

log "Report written to: $OUT_FILE"
