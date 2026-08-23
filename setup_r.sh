#!/bin/bash

set -euo pipefail

mkdir -p logs
chmod 700 . logs

module load R/4.5.2

EXPECTED_ADDR_VERSION=1.3.0
export EXPECTED_ADDR_VERSION

Rscript -e '
if (!requireNamespace("pak", quietly = TRUE)) {
  install.packages(
    "pak",
    repos = sprintf(
      "https://r-lib.github.io/p/pak/stable/%s/%s/%s",
      .Platform$pkgType,
      R.Version()$os,
      R.Version()$arch
    )
  )
}
pak::repo_add(
  cole_brokamp = "https://cole-brokamp.r-universe.dev",
  geomarker = "https://geomarker-io.r-universe.dev",
  CRAN = "PPM@latest"
)
pak::pkg_install(
  c(
    "needenv",
    "geomarker::addr",
    "mirai"
  ),
  upgrade = FALSE,
  ask = FALSE
)

installed_addr_version <- as.character(utils::packageVersion("addr"))
expected_addr_version <- Sys.getenv("EXPECTED_ADDR_VERSION")

if (!identical(installed_addr_version, expected_addr_version)) {
  stop(
    "Installed addr ", installed_addr_version,
    " from the geomarker R-universe, but this benchmark expects addr ",
    expected_addr_version, ". Update EXPECTED_ADDR_VERSION and the Methods ",
    "Note together after validating the new release."
  )
}

message(
  "Verified addr ", installed_addr_version,
  " from the geomarker R-universe."
)
'
