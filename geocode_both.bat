#!/bin/bash
#BSUB -J geocode_both
#BSUB -q normal
#BSUB -W 20:00
#BSUB -o logs/geocode_both.%J.out
#BSUB -e logs/geocode_both.%J.err

set -euo pipefail
umask 077

module load apptainer
module load R/4.5.2

N_CORES=${N_CORES:-1}
if [[ ! $N_CORES =~ ^(1|4|16)$ ]]; then
  echo "N_CORES must be 1, 4, or 16; got: $N_CORES" >&2
  exit 2
fi

ALLOCATED_CORES=${LSB_DJOB_NUMPROC:-${LSB_MAX_NUM_PROCESSORS:-}}
if [[ $ALLOCATED_CORES != "$N_CORES" ]]; then
  echo "LSF allocated $ALLOCATED_CORES cores, but N_CORES=$N_CORES." >&2
  echo "Submit with: bsub -n \"$N_CORES\" ... < geocode_both.bat" >&2
  exit 2
fi

PROJECT_DIR=${LS_SUBCWD:?LSF submission directory is unavailable}
cd "$PROJECT_DIR"

INPUT_CSV=${INPUT_CSV:-$PROJECT_DIR/my_address_file.csv}
DEGAUSS_IMAGE=${DEGAUSS_IMAGE:-$PROJECT_DIR/degauss-geocoder-3.4.1.sif}
R_USER_DATA_DIR=${R_USER_DATA_DIR:-/scratch/${USER:?USER is not set}}
export R_USER_DATA_DIR
ADDR_CLI=$(Rscript -e 'cat(system.file("exec", "addr-geocode", package = "addr"))')

[[ -f $INPUT_CSV ]] || { echo "Missing input CSV: $INPUT_CSV" >&2; exit 1; }
[[ -f $DEGAUSS_IMAGE ]] || { echo "Missing DeGAUSS image: $DEGAUSS_IMAGE" >&2; exit 1; }
[[ -n $ADDR_CLI && -f $ADDR_CLI ]] || {
  echo "Could not find addr-geocode through the addr package loaded by R." >&2
  exit 1
}

INPUT_FILENAME=${INPUT_CSV##*/}
INPUT_NAME=${INPUT_FILENAME%.*}
INPUT_NAME=${INPUT_NAME//[^A-Za-z0-9_-]/_}
[[ -n $INPUT_NAME ]] || INPUT_NAME=input


keep_time_file_only() {
  local method_dir=$1
  find "$method_dir" -depth -mindepth 1 \
    ! -path "$method_dir/time.txt" -delete
}

run_degauss() {
  echo "Starting DeGAUSS with $N_CORES cores"
  if /usr/bin/time -v -o "$DEGAUSS_DIR/time.txt" \
    apptainer run --containall --pwd /work \
    --bind "$DEGAUSS_DIR:/work" \
    "$DEGAUSS_IMAGE" /work/input.csv; then
    DEGAUSS_STATUS=0
  else
    DEGAUSS_STATUS=$?
  fi

  if ! keep_time_file_only "$DEGAUSS_DIR"; then
    echo "Could not completely clean DeGAUSS outputs: $DEGAUSS_DIR" >&2
    DEGAUSS_CLEANUP_STATUS=1
  fi
}

run_addr() {
  echo "Starting addr with $N_CORES workers"
  if /usr/bin/time -v -o "$ADDR_DIR/time.txt" \
    Rscript "$ADDR_CLI" \
    --input "$ADDR_DIR/input.csv" \
    --output-dir "$ADDR_DIR" \
    --workers "$N_CORES" \
    --taf-year 2025 \
    --data-dir "$R_USER_DATA_DIR" \
    --overwrite; then
    ADDR_STATUS=0
  else
    ADDR_STATUS=$?
  fi

  if ! keep_time_file_only "$ADDR_DIR"; then
    echo "Could not completely clean addr outputs: $ADDR_DIR" >&2
    ADDR_CLEANUP_STATUS=1
  fi
}

RUN_DIR=$PROJECT_DIR/results/$INPUT_NAME/${N_CORES}-cores/$LSB_JOBID
DEGAUSS_DIR=$RUN_DIR/degauss
ADDR_DIR=$RUN_DIR/addr
mkdir -p "$R_USER_DATA_DIR" "$DEGAUSS_DIR" "$ADDR_DIR"
cp "$INPUT_CSV" "$DEGAUSS_DIR/input.csv"
cp "$INPUT_CSV" "$ADDR_DIR/input.csv"

export OMP_NUM_THREADS=1
export OPENBLAS_NUM_THREADS=1
export MKL_NUM_THREADS=1
export APPTAINERENV_LSB_DJOB_NUMPROC=$N_CORES
export APPTAINERENV_LSB_MAX_NUM_PROCESSORS=$N_CORES
export APPTAINERENV_R_PROFILE_USER=/dev/null
export APPTAINERENV_R_ENVIRON_USER=/dev/null
export APPTAINERENV_R_LIBS=/dev/null
export APPTAINERENV_R_LIBS_USER=/dev/null

echo "addr data directory: $R_USER_DATA_DIR"
echo "Input CSV: $INPUT_CSV"
echo "Input name: $INPUT_NAME"

DEGAUSS_STATUS=0
ADDR_STATUS=0
DEGAUSS_CLEANUP_STATUS=0
ADDR_CLEANUP_STATUS=0

if ((RANDOM % 2 == 0)); then
  METHODS=(degauss addr)
else
  METHODS=(addr degauss)
fi

printf '%s\n' "${METHODS[@]}" > "$RUN_DIR/method_order.txt"
echo "Randomized method order: ${METHODS[*]}"

for method in "${METHODS[@]}"; do
  case $method in
    degauss) run_degauss ;;
    addr) run_addr ;;
  esac
done

echo "DeGAUSS exit status: $DEGAUSS_STATUS"
echo "addr exit status: $ADDR_STATUS"
echo "Results: $RUN_DIR"

if [[ $DEGAUSS_STATUS -ne 0 || $ADDR_STATUS -ne 0 ||
      $DEGAUSS_CLEANUP_STATUS -ne 0 || $ADDR_CLEANUP_STATUS -ne 0 ]]; then
  exit 1
fi
