args <- commandArgs(trailingOnly = TRUE)
script_arg <- grep("^--file=", commandArgs(), value = TRUE)[[1]]
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg)))
source(file.path(script_dir, "R", "benchmark.R"))
input_file <- if (length(args) >= 1) args[[1]] else "output/benchmark_results.rds"
output_dir <- if (length(args) >= 2) args[[2]] else "output"
if (!requireNamespace("ggplot2", quietly = TRUE)) stop("Install ggplot2 to plot the benchmark.")
if (!file.exists(input_file)) stop("Run collect_results.R first; missing ", input_file)
results <- readRDS(input_file)
required <- c("benchmark_schema", "input", "n_cores", "method", "run_status",
              "elapsed_seconds", "maximum_resident_set_kb")
if (length(setdiff(required, names(results))) || any(results$benchmark_schema != "2")) {
  stop("Expected schema-2 container benchmark results.")
}
completed <- results[results$run_status == "completed", ]
if (!nrow(completed)) stop("No completed methods to plot.")
summary <- summarize_benchmark(results)
summary <- summary[summary$n_completed > 0, ]
prepare <- function(x) {
  x$input <- factor(x$input, levels = names(benchmark_inputs), labels = unname(benchmark_inputs))
  x$method <- factor(x$method, levels = names(benchmark_methods))
  x$n_cores <- factor(x$n_cores, levels = benchmark_cores)
  x
}
completed <- prepare(completed)
summary <- prepare(summary)
completed$memory_gib <- completed$maximum_resident_set_kb / 1024^2
colors <- c(degauss = "#D55E00", `addr-default` = "#0072B2", `addr-strict` = "#009E73",
            `addr-exact-zip` = "#CC79A7", `addr-loose` = "#6A51A3")

make_plot <- function(metric, median_metric, label) {
  points <- completed
  points$value <- points[[metric]]
  medians <- summary
  medians$value <- medians[[median_metric]]
  ggplot2::ggplot(points, ggplot2::aes(x = n_cores, y = value, color = method, group = method)) +
    ggplot2::geom_point(size = 1.7, alpha = 0.55,
      position = ggplot2::position_jitterdodge(jitter.width = 0.08, dodge.width = 0.7, seed = 1)) +
    ggplot2::geom_line(data = medians, linewidth = 0.6,
      position = ggplot2::position_dodge(width = 0.7)) +
    ggplot2::geom_point(data = medians, size = 2.5, shape = 18,
      position = ggplot2::position_dodge(width = 0.7)) +
    ggplot2::facet_wrap(ggplot2::vars(input), ncol = 2, scales = "free_y") +
    ggplot2::scale_color_manual(values = colors, breaks = names(benchmark_methods),
      labels = unname(benchmark_methods), drop = FALSE) +
    ggplot2::scale_y_continuous(limits = c(0, NA)) +
    ggplot2::labs(x = "Allocated cores", y = label, color = NULL,
      caption = "Points: completed runs. Diamonds and lines: medians. Failed/incomplete runs excluded; see benchmark_summary.csv.") +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(legend.position = "top", panel.grid.minor = ggplot2::element_blank(),
      strip.text = ggplot2::element_text(face = "bold"))
}

dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
plots <- list(
  runtime = make_plot("elapsed_seconds", "median_elapsed_seconds", "Elapsed wall-clock time (seconds)"),
  memory = make_plot("memory_gib", "median_maximum_resident_set_gib", "GNU time maximum RSS (GiB)")
)
for (name in names(plots)) {
  path <- file.path(output_dir, paste0("benchmark_", name, ".pdf"))
  ggplot2::ggsave(path, plots[[name]], width = 12, height = 5, units = "in")
  message("Saved ", path)
}
