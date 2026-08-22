#!/bin/bash

set -euo pipefail

mkdir -p logs
chmod 700 . logs

module load R/4.5.2

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
    "addr",
    "mirai"
  ),
  upgrade = FALSE,
  ask = FALSE
)
'

