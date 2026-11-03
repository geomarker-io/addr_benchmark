#!/bin/bash
set -euo pipefail
umask 077
SUBMISSION_DIR=$PWD
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_DIR"
source "$PROJECT_DIR/benchmark_config.sh"
CORE_COUNTS=${CORE_COUNTS:-"1 4 16"}
N_REPEATS=${N_REPEATS:-3}
TOTAL_MEMORY_MB=${TOTAL_MEMORY_MB:-64000}
[[ $# -le 1 ]] || fail "Usage: bash submit_repeats.sh [one-of-the-two-inputs.csv]"
[[ $N_REPEATS =~ ^[1-9][0-9]*$ ]] || fail "N_REPEATS must be a positive integer."
[[ $TOTAL_MEMORY_MB =~ ^[1-9][0-9]*$ ]] || fail "TOTAL_MEMORY_MB must be a positive integer."
read -r -a CORES <<< "$CORE_COUNTS"
[[ ${#CORES[@]} -gt 0 ]] || fail "CORE_COUNTS cannot be empty."
seen=' '
for n in "${CORES[@]}"; do
  [[ $n =~ ^(1|4|16)$ ]] || fail "Core counts must be 1, 4, or 16."
  [[ $seen != *" $n "* ]] || fail "Duplicate core count: $n"
  seen+="$n "
done
INPUTS=()
if [[ $# == 1 ]]; then
  input=$1
  [[ $input = /* ]] || input=$SUBMISSION_DIR/$input
  INPUTS+=("$input")
else
  for name in "${INPUT_NAMES[@]}"; do INPUTS+=("$PROJECT_DIR/inputs/$name.csv"); done
fi
# Check every input and both images before submitting any jobs.
for input in "${INPUTS[@]}"; do validate_input "$input"; done
verify_images
command -v bsub >/dev/null || fail "bsub is unavailable; submit from the HPC login node."
mkdir -p logs
job_count=$((${#INPUTS[@]} * ${#CORES[@]} * N_REPEATS))
echo "Submitting $job_count jobs, each running all five methods."
export CONTAINER_DIR
for input in "${INPUTS[@]}"; do
  export INPUT_CSV=$input
  name=${input##*/}
  for n in "${CORES[@]}"; do
    export N_CORES=$n
    memory_per_slot=$(((TOTAL_MEMORY_MB+n-1)/n))
    for ((repeat=1; repeat<=N_REPEATS; repeat++)); do
      export BENCHMARK_REPEAT=$repeat
      echo "Submitting ${name%.csv}: $n cores, repeat $repeat/$N_REPEATS"
      bsub -env all -J "geo_${name%.csv}_${n}c_r${repeat}" \
        -n "$n" -M "$TOTAL_MEMORY_MB" \
        -R "span[hosts=1] rusage[mem=$memory_per_slot]" < geocode_both.bat
    done
  done
done
