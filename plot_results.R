args <- commandArgs(trailingOnly = TRUE)

input_file <- if (length(args) >= 1) args[[1]] else "benchmark_results.rds"
output_file <- if (length(args) >= 2) {
  args[[2]]
} else {
  file.path("output", "pdf", "benchmark_results.pdf")
}

required_packages <- c("ggplot2", "knitr", "scales")
missing_packages <- required_packages[
  !vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)
]

if (length(missing_packages) > 0) {
  stop(
    "Install the following packages before plotting: ",
    paste(missing_packages, collapse = ", ")
  )
}

if (!file.exists(input_file)) {
  stop("Results file does not exist: ", input_file)
}

benchmark_results <- readRDS(input_file)
required_columns <- c(
  "input",
  "n_cores",
  "job_id",
  "method",
  "elapsed_seconds",
  "exit_status"
)
missing_columns <- setdiff(required_columns, names(benchmark_results))

if (length(missing_columns) > 0) {
  stop(
    "Missing required columns in ", input_file, ": ",
    paste(missing_columns, collapse = ", ")
  )
}

plot_results <- benchmark_results[is.finite(benchmark_results$elapsed_seconds), ]
excluded_results <- nrow(benchmark_results) - nrow(plot_results)

numbered_samples <- grepl("_sample_[0-9]+$", plot_results$input)
keep_input <-
  plot_results$input != "my_address_file" &
  plot_results$input != "ehr_ah_10k_45011" &
  (!numbered_samples | grepl("_sample_1$", plot_results$input))
excluded_inputs <- sort(unique(plot_results$input[!keep_input]))
plot_results <- plot_results[keep_input, ]

input_labels <- c(
  ehr_ah_all = "All addresses (1.03M total)",
  ehr_ah_unique = "Unique addresses (533.1k total)",
  ehr_ah_all_100k_sample_1 = "100k sample from all",
  ehr_ah_unique_10_per_zip_replace = "10 per ZIP (83.9k total)",
  ehr_ah_cincy_10k_sample_1 = "10k sample from Cincy",
  ehr_ah_10k_45211 = "10k from single ZIP"
)
unexpected_inputs <- setdiff(unique(plot_results$input), names(input_labels))
if (length(unexpected_inputs) > 0) {
  stop("Missing display labels for ", paste(unexpected_inputs, collapse = ", "))
}
plot_results$input <- unname(input_labels[plot_results$input])
input_order <- unname(input_labels)
plot_results$input <- factor(plot_results$input, levels = input_order)

if (length(excluded_inputs) > 0) {
  message(
    "Excluded ", length(excluded_inputs),
    " input file(s) based on plotting filters."
  )
}

if (nrow(plot_results) == 0) {
  stop("No benchmark results with finite elapsed times were found.")
}

if (excluded_results > 0) {
  warning(
    "Excluded ", excluded_results,
    " result(s) without a finite elapsed time."
  )
}

failed_results <- plot_results[plot_results$exit_status != 0, ]
if (nrow(failed_results) > 0) {
  warning(
    nrow(failed_results),
    " unsuccessful result(s) are shown as x marks and excluded from ",
    "boxplots and median completion times."
  )
}

expected_methods <- c("addr", "degauss")
unexpected_methods <- setdiff(unique(plot_results$method), expected_methods)
if (length(unexpected_methods) > 0) {
  stop("Unexpected methods: ", paste(unexpected_methods, collapse = ", "))
}

expected_cores <- c(1L, 4L, 16L)
missing_cores <- setdiff(expected_cores, unique(plot_results$n_cores))
if (length(missing_cores) > 0) {
  warning("No results found for core count(s): ", paste(missing_cores, collapse = ", "))
}

replicate_counts <- aggregate(
  job_id ~ input + n_cores + method,
  data = plot_results,
  FUN = length
)
names(replicate_counts)[names(replicate_counts) == "job_id"] <- "n_replicates"

completed_results <- plot_results[plot_results$exit_status == 0, ]
completed_counts <- aggregate(
  job_id ~ input + n_cores + method,
  data = completed_results,
  FUN = length
)
names(completed_counts)[names(completed_counts) == "job_id"] <- "n_completed"

median_times <- aggregate(
  elapsed_seconds ~ input + n_cores + method,
  data = completed_results,
  FUN = median,
  na.rm = TRUE
)
names(median_times)[names(median_times) == "elapsed_seconds"] <-
  "median_elapsed_seconds"

results_summary <- merge(
  replicate_counts,
  completed_counts,
  by = c("input", "n_cores", "method"),
  all.x = TRUE,
  sort = FALSE
)
results_summary <- merge(
  results_summary,
  median_times,
  by = c("input", "n_cores", "method"),
  all.x = TRUE,
  sort = FALSE
)
results_summary$n_completed[is.na(results_summary$n_completed)] <- 0L
results_summary$n_failed <-
  results_summary$n_replicates - results_summary$n_completed
results_summary <- results_summary[c(
  "input",
  "n_cores",
  "method",
  "n_replicates",
  "n_completed",
  "n_failed",
  "median_elapsed_seconds"
)]
results_summary <- results_summary[
  order(
    results_summary$input,
    results_summary$n_cores,
    results_summary$method
  ),
]
rownames(results_summary) <- NULL

cat("## Benchmark results summary\n\n")
cat(
  knitr::kable(
    results_summary,
    format = "pipe",
    digits = 2,
    align = c("l", "r", "l", "r", "r", "r", "r"),
    row.names = FALSE
  ),
  sep = "\n"
)
cat("\n\n")

plot_results$n_cores <- factor(
  plot_results$n_cores,
  levels = expected_cores,
  ordered = TRUE
)
plot_results$method <- factor(
  plot_results$method,
  levels = expected_methods
)
plot_results$input <- factor(
  plot_results$input,
  levels = input_order
)
plot_results$run_status <- factor(
  ifelse(plot_results$exit_status == 0, "Completed", "Failed"),
  levels = c("Completed", "Failed")
)
completed_results <- plot_results[plot_results$run_status == "Completed", ]

method_colors <- c(addr = "#0072B2", degauss = "#D55E00")
method_labels <- c(addr = "addr", degauss = "DeGAUSS")

results_plot <- ggplot2::ggplot(
  plot_results,
  ggplot2::aes(
    x = n_cores,
    y = elapsed_seconds,
    color = method,
    fill = method
  )
) +
  ggplot2::geom_boxplot(
    data = completed_results,
    width = 0.65,
    alpha = 0.18,
    linewidth = 0.6,
    outlier.shape = NA,
    position = ggplot2::position_dodge2(width = 0.75, preserve = "single")
  ) +
  ggplot2::geom_point(
    ggplot2::aes(shape = run_status),
    size = 1.5,
    alpha = 0.7,
    position = ggplot2::position_jitterdodge(
      jitter.width = 0.08,
      dodge.width = 0.75
    )
  ) +
  ggplot2::facet_wrap(
    ggplot2::vars(input),
    ncol = 2,
    scales = "fixed"
  ) +
  ggplot2::scale_color_manual(
    values = method_colors,
    breaks = names(method_labels),
    labels = method_labels
  ) +
  ggplot2::scale_fill_manual(
    values = method_colors,
    breaks = names(method_labels),
    labels = method_labels
  ) +
  ggplot2::scale_shape_manual(
    values = c(Completed = 16, Failed = 4),
    name = NULL
  ) +
  ggplot2::scale_y_log10(
    breaks = c(30, 100, 300, 1000, 3000, 10000),
    labels = scales::label_number(accuracy = 1, big.mark = ","),
    expand = ggplot2::expansion(mult = c(0.04, 0.1))
  ) +
  ggplot2::labs(
    x = "Allocated cores",
    y = "Elapsed wall-clock time (seconds, log scale)",
    color = NULL,
    fill = NULL
  ) +
  ggplot2::theme_minimal(base_size = 10) +
  ggplot2::theme(
    legend.position = "top",
    legend.justification = "left",
    panel.grid.minor = ggplot2::element_blank(),
    panel.border = ggplot2::element_rect(
      color = "grey45",
      fill = NA,
      linewidth = 0.6
    ),
    strip.text = ggplot2::element_text(face = "bold", size = 8.5)
  )

output_dir <- dirname(output_file)
if (!dir.exists(output_dir)) {
  dir.create(output_dir, recursive = TRUE)
}

ggplot2::ggsave(
  filename = output_file,
  plot = results_plot,
  device = "pdf",
  width = 11,
  height = 8.5,
  units = "in"
)
message("Saved results figure to ", output_file, ".")
