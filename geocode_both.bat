#!/bin/bash
#BSUB -J geocode_both
#BSUB -q normal
#BSUB -W 20:00
#BSUB -n 1
#BSUB -M 64000
#BSUB -R "span[hosts=1] rusage[mem=64000]"
#BSUB -o logs/geocode_both.%J.out
#BSUB -e logs/geocode_both.%J.err

set -euo pipefail
umask 077
export LC_ALL=C
PROJECT_DIR=${LS_SUBCWD:?Submit this script with bsub from the project directory.}
cd "$PROJECT_DIR"
PROJECT_DIR=$PWD
source "$PROJECT_DIR/benchmark_config.sh"
N_CORES=${N_CORES:-1}
[[ $N_CORES =~ ^(1|4|16)$ ]] || fail "N_CORES must be 1, 4, or 16."
ALLOCATED_CORES=${LSB_DJOB_NUMPROC:-${LSB_MAX_NUM_PROCESSORS:-}}
[[ $ALLOCATED_CORES == "$N_CORES" ]] ||
  fail "LSF allocated $ALLOCATED_CORES cores, but N_CORES=$N_CORES. Pass bsub -n and -R as shown in README.md."
[[ ${LSB_JOBID:-} =~ ^[0-9]+$ ]] || fail "Missing or invalid LSF job ID."
INPUT_CSV=${INPUT_CSV:-$PROJECT_DIR/inputs/ehr_ah_cincy_10k_sample_1.csv}
validate_input "$INPUT_CSV"
INPUT_NAME=${INPUT_CSV##*/}
INPUT_NAME=${INPUT_NAME%.csv}
TIME_BIN=${TIME_BIN:-/usr/bin/time}
"$TIME_BIN" --version | head -1 | grep -q 'GNU' || fail "GNU time is required."
load_apptainer
verify_images

# mkdir without -p refuses to overwrite an earlier run with the same job ID.
RUN_PARENT=$PROJECT_DIR/results/$INPUT_NAME/${N_CORES}-cores
mkdir -p "$RUN_PARENT" "$PROJECT_DIR/.work"
RUN_DIR=$RUN_PARENT/$LSB_JOBID
mkdir "$RUN_DIR"
WORK_ROOT=$(mktemp -d "$PROJECT_DIR/.work/job-${LSB_JOBID}.XXXXXX")
cleanup() { rm -rf -- "$WORK_ROOT"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Shuffle all five methods using Fisher-Yates, recording the full order.
for ((i=${#METHODS[@]}-1; i>0; i--)); do
  j=$((RANDOM % (i+1)))
  tmp=${METHODS[i]}
  METHODS[i]=${METHODS[j]}
  METHODS[j]=$tmp
done
printf '%s\n' "${METHODS[@]}" > "$RUN_DIR/method_order.txt"
printf 'method\texit_status\tcleanup_status\n' > "$RUN_DIR/status.tsv"

metadata() { printf '%s\t%s\n' "$1" "$2"; }
{
  printf 'key\tvalue\n'
  metadata benchmark_schema "$BENCHMARK_SCHEMA"
  metadata started_utc "$(date -u +%FT%TZ)"
  metadata input "$INPUT_NAME"
  metadata input_sha256 "$(sha256sum "$INPUT_CSV" | cut -d ' ' -f1)"
  metadata n_cores "$N_CORES"
  metadata job_id "$LSB_JOBID"
  metadata repeat "${BENCHMARK_REPEAT:-manual}"
  metadata hostname "$(hostname)"
  metadata architecture "$(uname -m)"
  metadata cpu_model "$(awk -F ': ' '/model name/ {print $2; exit}' /proc/cpuinfo)"
  metadata host_memory_kb "$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  metadata apptainer_version "$(apptainer --version)"
  metadata time_version "$("$TIME_BIN" --version | head -1)"
  metadata git_commit "$(git rev-parse HEAD)"
  if git diff --quiet HEAD --; then metadata tracked_changes false; else metadata tracked_changes true; fi
  metadata runner_sha256 "$(sha256sum geocode_both.bat | cut -d ' ' -f1)"
  metadata config_sha256 "$(sha256sum benchmark_config.sh | cut -d ' ' -f1)"
  metadata addr_version "$ADDR_VERSION"
  metadata addr_release "$ADDR_RELEASE"
  metadata addr_taf_schema v2
  metadata addr_taf_year 2025
  metadata addr_image_ref "$ADDR_IMAGE_REF"
  metadata addr_image_sha256 "$(cut -d ' ' -f1 "$ADDR_IMAGE.sha256")"
  metadata degauss_version "$DEGAUSS_VERSION"
  metadata degauss_image_ref "$DEGAUSS_IMAGE_REF"
  metadata degauss_image_sha256 "$(cut -d ' ' -f1 "$DEGAUSS_IMAGE.sha256")"
} > "$RUN_DIR/metadata.tsv"

# Do not inherit host startup files, package libraries, or data directories.
# Explicit --env values also override stray APPTAINERENV_* settings on the host.
CONTAINER_ENV=(
  --env "LSB_DJOB_NUMPROC=$N_CORES,LSB_MAX_NUM_PROCESSORS=$N_CORES"
  --env 'OMP_NUM_THREADS=1,OPENBLAS_NUM_THREADS=1,MKL_NUM_THREADS=1'
  --env 'R_PROFILE_USER=/dev/null,R_ENVIRON_USER=/dev/null,R_LIBS=/dev/null,R_LIBS_USER=/dev/null'
)
overall_status=0
for method in "${METHODS[@]}"; do
  echo "Starting $method with $N_CORES cores"
  method_dir=$RUN_DIR/$method
  work_dir=$WORK_ROOT/$method
  mkdir -p "$method_dir" "$work_dir/tmp"
  cp "$INPUT_CSV" "$work_dir/input.csv"
  command=(apptainer run --cleanenv --containall --pwd /work
    --bind "$work_dir:/work" --bind "$work_dir/tmp:/tmp"
    "${CONTAINER_ENV[@]}")
  if [[ $method == degauss ]]; then
    command+=("$DEGAUSS_IMAGE" /work/input.csv)
  else
    command+=(--env "R_USER_DATA_DIR=/opt/addr-data,ADDR_GEOCODE_RELEASE_TAG=$ADDR_RELEASE"
      "$ADDR_IMAGE" --input /work/input.csv --output-dir /work
      --workers "$N_CORES" --preset "${method#addr-}")
  fi
  # Container logs can contain addresses; keep them only in the private work dir.
  status=0
  "$TIME_BIN" -v -o "$method_dir/time.txt" "${command[@]}" \
    > "$work_dir/container.log" 2>&1 || status=$?
  cleanup_status=0
  rm -rf -- "$work_dir" || cleanup_status=$?
  printf '%s\t%s\t%s\n' "$method" "$status" "$cleanup_status" >> "$RUN_DIR/status.tsv"
  echo "$method: exit=$status cleanup=$cleanup_status"
  if ((status != 0 || cleanup_status != 0)); then overall_status=1; fi
done
# The marker means all methods were attempted; individual failures remain in status.tsv.
if ! cleanup; then overall_status=1; fi
printf '%s\n' "$(date -u +%FT%TZ)" > "$RUN_DIR/complete.txt"
echo "Results: $RUN_DIR"
exit "$overall_status"
