# Base-R plotting fallback when ggplot2 is unavailable.
source("R/benchmark.R")
x <- readRDS("output/benchmark_results.rds")
s <- summarize_benchmark(x)
cols <- c("#D55E00", "#0072B2", "#009E73", "#CC79A7", "#6A51A3")
for (metric in c("runtime", "memory")) {
  png(paste0("output/benchmark_", metric, ".png"), width = 1800, height = 850, res = 150)
  par(mfrow = c(1, 2), mar = c(5, 5, 4, 1), oma = c(3, 0, 0, 0))
  for (inp in names(benchmark_inputs)) {
    z <- s[s$input == inp, ]
    runs <- x[x$input == inp & x$run_status == "completed", ]
    value <- if (metric == "runtime") runs$elapsed_seconds / 60 else runs$maximum_resident_set_kb / 1024^2
    plot(NA, xlim = c(.8, 3.2), ylim = c(0, max(value) * 1.1), xaxt = "n",
         xlab = "Allocated cores", ylab = if (metric == "runtime") "Elapsed time (minutes)" else "GNU time maximum RSS (GiB)",
         main = benchmark_inputs[[inp]])
    axis(1, 1:3, benchmark_cores)
    for (i in seq_along(benchmark_methods)) {
      zz <- z[z$method == names(benchmark_methods)[i], ]
      vv <- if (metric == "runtime") zz$median_elapsed_seconds / 60 else zz$median_maximum_resident_set_gib
      rr <- runs$method == names(benchmark_methods)[i]
      offset <- (i - 3) * .035
      points(match(runs$n_cores[rr], benchmark_cores) + offset, value[rr], col = adjustcolor(cols[i], .45), pch = 1)
      lines(match(zz$n_cores, benchmark_cores) + offset, vv, type = "b", col = cols[i], pch = 18)
    }
    legend("topright", legend = unname(benchmark_methods), col = cols, lty = 1, pch = 18, cex = .75, bty = "n")
  }
  mtext("Circles: individual runs; diamonds: medians. CPU models differ; nine measurements were run as separate replacement jobs.", side = 1, outer = TRUE, line = 1, cex = .8)
  dev.off()
}
