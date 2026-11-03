#!/bin/bash
# Shared, release-pinned experiment definition. Source after setting PROJECT_DIR.
BENCHMARK_SCHEMA=2
ADDR_VERSION=2.0.0
ADDR_RELEASE=v2.0.0-taf-v2-2025
DEGAUSS_VERSION=3.4.2
# Digests resolved from the published GHCR tags on 2026-11-03.
ADDR_IMAGE_REF=ghcr.io/geomarker-io/addr_geocoder@sha256:dcab055d5b70e299f753f07af332ccddd4723c23dd357f5063af3552beb40b83
DEGAUSS_IMAGE_REF=ghcr.io/degauss-org/geocoder@sha256:b4e3219bc93f79342c81676b59c38bed6f32e4817084cfdedda02b941c4b0473
CONTAINER_DIR=${CONTAINER_DIR:-$PROJECT_DIR/containers}
ADDR_IMAGE=$CONTAINER_DIR/addr_geocoder_${ADDR_RELEASE}.sif
DEGAUSS_IMAGE=$CONTAINER_DIR/degauss_geocoder_v${DEGAUSS_VERSION}.sif
INPUT_NAMES=(ehr_ah_cincy_10k_sample_1 ehr_ah_all_100k_sample_1)
METHODS=(degauss addr-default addr-strict addr-exact-zip addr-loose)

fail() { echo "$*" >&2; exit 2; }

load_apptainer() {
  if ! command -v apptainer >/dev/null 2>&1; then
    type module >/dev/null 2>&1 || fail "Load the apptainer module first."
    module load apptainer
  fi
}

validate_input() {
  [[ -f $1 ]] || fail "Missing input CSV: $1"
  local name=${1##*/}
  case $name in
    ehr_ah_cincy_10k_sample_1.csv|ehr_ah_all_100k_sample_1.csv) ;;
    *) fail "Choose one of the two benchmark inputs listed in benchmark_config.sh." ;;
  esac
}

verify_image() {
  local image=$1 ref=$2
  [[ -s $image && -f $image.source && -f $image.sha256 ]] ||
    fail "Missing image or provenance for $image; run bash setup_containers.sh."
  [[ $(cat "$image.source") == "$ref" ]] || fail "Unexpected source for $image."
  (cd "$(dirname "$image")" && sha256sum --check "$(basename "$image").sha256") ||
    fail "Image checksum failed: $image"
}

verify_images() {
  verify_image "$ADDR_IMAGE" "$ADDR_IMAGE_REF"
  verify_image "$DEGAUSS_IMAGE" "$DEGAUSS_IMAGE_REF"
}
