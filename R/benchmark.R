# Shared definitions for collection and plotting; no addr installation required.
benchmark_inputs <- c(
  ehr_ah_cincy_10k_sample_1 = "Cincinnati: 10,000 addresses",
  ehr_ah_all_100k_sample_1 = "All-address sample: 100,000 addresses"
)
benchmark_methods <- c(
  degauss = "DeGAUSS",
  `addr-default` = "addr default",
  `addr-strict` = "addr strict",
  `addr-exact-zip` = "addr exact-zip",
  `addr-loose` = "addr loose"
)
benchmark_cores <- c(1L, 4L, 16L)

summarize_benchmark <- function(results) {
  # Include unobserved cells so a partial submission cannot look complete.
  grid <- expand.grid(
    input = names(benchmark_inputs),
    n_cores = benchmark_cores,
    method = names(benchmark_methods),
    stringsAsFactors = FALSE
  )
  rows <- lapply(seq_len(nrow(grid)), function(i) {
    cell <- grid[i, ]
    x <- results[
      results$input == cell$input & results$n_cores == cell$n_cores &
        results$method == cell$method,
    ]
    good <- x[x$run_status == "completed", ]
    cell$n_runs <- nrow(x)
    cell$n_completed <- nrow(good)
    cell$n_failed <- sum(x$run_status == "failed")
    cell$n_incomplete <- sum(!x$run_status %in% c("completed", "failed"))
    cell$median_elapsed_seconds <- if (nrow(good)) median(good$elapsed_seconds) else NA_real_
    cell$median_maximum_resident_set_gib <- if (nrow(good)) {
      median(good$maximum_resident_set_kb) / 1024^2
    } else NA_real_
    cell
  })
  do.call(rbind, rows)
}
