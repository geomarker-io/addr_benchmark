#!/bin/bash
set -euo pipefail
umask 077
PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$PROJECT_DIR"
source "$PROJECT_DIR/benchmark_config.sh"
load_apptainer
mkdir -p "$CONTAINER_DIR" logs .work
CONTAINER_DIR=$(cd "$CONTAINER_DIR" && pwd)
pull_dir=$(mktemp -d "$CONTAINER_DIR/.pull.XXXXXX")
trap 'rm -rf -- "$pull_dir"' EXIT

pull_image() {
  local image=$1 ref=$2
  if [[ -e $image ]]; then
    verify_image "$image" "$ref"
    return
  fi
  echo "Pulling $ref"
  apptainer pull "$pull_dir/image.sif" "docker://$ref"
  mv "$pull_dir/image.sif" "$image"
  printf '%s\n' "$ref" > "$image.source"
  (cd "$(dirname "$image")" && sha256sum "$(basename "$image")") > "$image.sha256"
}

pull_image "$ADDR_IMAGE" "$ADDR_IMAGE_REF"
pull_image "$DEGAUSS_IMAGE" "$DEGAUSS_IMAGE_REF"
echo "Containers ready. Submit the experiment with: bash submit_repeats.sh"
