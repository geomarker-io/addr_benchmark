#!/bin/bash

set -euo pipefail
umask 077

CORE_COUNTS=${CORE_COUNTS:-"1 4 16"}
N_REPEATS=${N_REPEATS:-3}
TOTAL_MEMORY_MB=${TOTAL_MEMORY_MB:-64000}

if [[ $# -ne 1 ]]; then
  echo "Usage: bash submit_repeats.sh INPUT.csv" >&2
  echo "Optional settings: CORE_COUNTS=\"1 4 16\" N_REPEATS=3 TOTAL_MEMORY_MB=64000" >&2
  exit 2
fi

if [[ ! $N_REPEATS =~ ^[1-9][0-9]*$ ]]; then
  echo "N_REPEATS must be a positive integer; got: $N_REPEATS" >&2
  exit 2
fi

if [[ ! $TOTAL_MEMORY_MB =~ ^[1-9][0-9]*$ ]]; then
  echo "TOTAL_MEMORY_MB must be a positive integer; got: $TOTAL_MEMORY_MB" >&2
  exit 2
fi

SUBMISSION_DIR=$PWD
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BATCH_FILE=$SCRIPT_DIR/geocode_both.bat

[[ -f $BATCH_FILE ]] || {
  echo "Missing batch file: $BATCH_FILE" >&2
  exit 1
}

input_arg=$1
if [[ $input_arg = /* ]]; then
  INPUT_CSV=$input_arg
else
  INPUT_CSV=$SUBMISSION_DIR/$input_arg
fi

[[ -f $INPUT_CSV ]] || {
  echo "Missing input CSV: $INPUT_CSV" >&2
  exit 1
}
export INPUT_CSV

read -r -a CORES <<< "$CORE_COUNTS"
[[ ${#CORES[@]} -gt 0 ]] || {
  echo "CORE_COUNTS must contain at least one core count." >&2
  exit 2
}

for n_cores in "${CORES[@]}"; do
  if [[ ! $n_cores =~ ^(1|4|16)$ ]]; then
    echo "Each core count must be 1, 4, or 16; got: $n_cores" >&2
    exit 2
  fi
done

input_filename=${INPUT_CSV##*/}
input_name=${input_filename%.*}
input_name=${input_name//[^A-Za-z0-9_-]/_}
[[ -n $input_name ]] || input_name=input

mkdir -p "$SCRIPT_DIR/logs"
cd "$SCRIPT_DIR"

job_count=$((${#CORES[@]} * N_REPEATS))
echo "Input: $INPUT_CSV"
echo "Submitting $job_count jobs"

for n_cores in "${CORES[@]}"; do
  memory_per_slot_mb=$(((TOTAL_MEMORY_MB + n_cores - 1) / n_cores))
  export N_CORES=$n_cores

  for ((submission = 1; submission <= N_REPEATS; submission++)); do
    job_name=geo_${input_name}_${n_cores}c
    echo "Submitting $job_name ($submission of $N_REPEATS)"
    bsub \
      -J "$job_name" \
      -n "$n_cores" \
      -M "$TOTAL_MEMORY_MB" \
      -R "span[hosts=1] rusage[mem=$memory_per_slot_mb]" \
      < "$BATCH_FILE"
  done
done
