args <- commandArgs(trailingOnly = TRUE)
script_arg <- grep("^--file=", commandArgs(), value = TRUE)[[1]]
script_dir <- dirname(normalizePath(sub("^--file=", "", script_arg)))
source(file.path(script_dir, "R", "benchmark.R"))
results_dir <- if (length(args) >= 1) args[[1]] else "results"
output_file <- if (length(args) >= 2) args[[2]] else "output/benchmark_results.rds"
metadata_files <- sort(list.files(results_dir, "^metadata[.]tsv$", recursive = TRUE, full.names = TRUE))
if (!length(metadata_files)) stop("No new benchmark jobs found under ", results_dir, ".")

elapsed_seconds <- function(value) {
  parts <- suppressWarnings(as.numeric(strsplit(value, ":", fixed = TRUE)[[1]]))
  if (length(parts) == 2 && all(is.finite(parts))) return(sum(parts * c(60, 1)))
  if (length(parts) == 3 && all(is.finite(parts))) return(sum(parts * c(3600, 60, 1)))
  NA_real_
}

read_timing <- function(path) {
  empty <- list(elapsed_seconds = NA_real_, maximum_resident_set_kb = NA_real_,
                time_exit_status = NA_integer_, time_complete = FALSE)
  if (!file.exists(path)) return(empty)
  lines <- trimws(readLines(path, warn = FALSE))
  signal <- grep("^Command terminated by signal [0-9]+$", lines, value = TRUE)
  separators <- regexpr(": ", lines, fixed = TRUE)
  lines <- lines[separators > 0]
  separators <- separators[separators > 0]
  fields <- setNames(substring(lines, separators + 2), substr(lines, 1, separators - 1))
  get <- function(name) if (name %in% names(fields)) fields[[name]] else NA_character_
  elapsed <- get("Elapsed (wall clock) time (h:mm:ss or m:ss)")
  if (!is.na(elapsed)) empty$elapsed_seconds <- elapsed_seconds(elapsed)
  empty$maximum_resident_set_kb <- suppressWarnings(as.numeric(get("Maximum resident set size (kbytes)")))
  empty$time_exit_status <- suppressWarnings(as.integer(get("Exit status")))
  # GNU time can print exit status 0 for a child terminated by a signal.
  if (length(signal) == 1L) {
    empty$time_exit_status <- 128L + as.integer(sub(".* ", "", signal))
  }
  empty$time_complete <- is.finite(empty$elapsed_seconds) && empty$elapsed_seconds >= 0 &&
    is.finite(empty$maximum_resident_set_kb) && empty$maximum_resident_set_kb > 0 &&
    !is.na(empty$time_exit_status)
  empty
}

read_job <- function(path) {
  job_dir <- dirname(path)
  metadata <- read.delim(path, colClasses = "character", quote = "", check.names = FALSE)
  if (!identical(names(metadata), c("key", "value")) || anyDuplicated(metadata$key)) {
    stop("Invalid metadata in ", path)
  }
  meta <- setNames(metadata$value, metadata$key)
  required <- c("benchmark_schema", "input", "n_cores", "job_id", "input_sha256",
                "hostname", "architecture", "cpu_model", "git_commit", "tracked_changes",
                "runner_sha256", "config_sha256", "addr_version", "addr_release",
                "addr_taf_schema", "addr_taf_year", "addr_image_ref", "addr_image_sha256",
                "degauss_version", "degauss_image_ref", "degauss_image_sha256")
  if (length(setdiff(required, names(meta)))) stop("Incomplete metadata in ", path)
  if (meta[["benchmark_schema"]] != "2" ||
      !meta[["input"]] %in% names(benchmark_inputs) ||
      !meta[["n_cores"]] %in% as.character(benchmark_cores)) stop("Unexpected experiment in ", path)
  if (basename(job_dir) != meta[["job_id"]] ||
      basename(dirname(job_dir)) != paste0(meta[["n_cores"]], "-cores") ||
      basename(dirname(dirname(job_dir))) != meta[["input"]]) stop("Metadata/path mismatch in ", path)
  order_path <- file.path(job_dir, "method_order.txt")
  method_order <- if (file.exists(order_path)) readLines(order_path, warn = FALSE) else character()
  if (length(method_order) &&
      (length(method_order) != length(benchmark_methods) ||
       !setequal(method_order, names(benchmark_methods)))) stop("Invalid ordering in ", order_path)
  status_path <- file.path(job_dir, "status.tsv")
  status <- if (file.exists(status_path)) {
    read.delim(status_path, colClasses = c("character", "integer", "integer"), quote = "")
  } else data.frame(method = character(), exit_status = integer(), cleanup_status = integer())
  if (!identical(names(status), c("method", "exit_status", "cleanup_status")) ||
      anyDuplicated(status$method) || any(!status$method %in% names(benchmark_methods))) {
    stop("Invalid method statuses in ", status_path)
  }
  job_complete <- file.exists(file.path(job_dir, "complete.txt"))
  if (job_complete && (nrow(status) != length(benchmark_methods) || !length(method_order))) {
    stop("Completion marker without all method statuses/order in ", job_dir)
  }
  rows <- lapply(names(benchmark_methods), function(method) {
    timing <- read_timing(file.path(job_dir, method, "time.txt"))
    s <- status[status$method == method, , drop = FALSE]
    exit_status <- if (nrow(s)) s$exit_status else NA_integer_
    cleanup_status <- if (nrow(s)) s$cleanup_status else NA_integer_
    if (nrow(s) && !is.na(timing$time_exit_status) && !is.na(exit_status) &&
        exit_status != timing$time_exit_status) stop("Conflicting exit statuses in ", job_dir, "/", method)
    run_status <- if (!nrow(s)) {
      "missing"
    } else if (is.na(exit_status) || is.na(cleanup_status)) {
      "incomplete"
    } else if (cleanup_status != 0L) {
      "cleanup-failed"
    } else if (exit_status != 0L) {
      "failed"
    } else if (!timing$time_complete) {
      "incomplete"
    } else "completed"
    data.frame(
      as.list(meta[required]), method = method,
      order_position = match(method, method_order), job_complete = job_complete,
      exit_status = exit_status, cleanup_status = cleanup_status, run_status = run_status,
      elapsed_seconds = timing$elapsed_seconds,
      maximum_resident_set_kb = timing$maximum_resident_set_kb,
      stringsAsFactors = FALSE, check.names = FALSE
    )
  })
  do.call(rbind, rows)
}

benchmark_results <- do.call(rbind, lapply(metadata_files, read_job))
benchmark_results$n_cores <- as.integer(benchmark_results$n_cores)
rownames(benchmark_results) <- NULL
# Prevent accidental pooling across tool versions, input revisions, or architectures.
for (field in c("benchmark_schema", "architecture", "addr_version", "addr_release",
                "addr_taf_schema", "addr_taf_year", "addr_image_ref", "degauss_version",
                "degauss_image_ref", "runner_sha256", "config_sha256")) {
  if (length(unique(benchmark_results[[field]])) != 1L) stop("Mixed ", field, " values; collect separate experiments.")
}
for (input in unique(benchmark_results$input)) {
  hashes <- benchmark_results$input_sha256[benchmark_results$input == input]
  if (length(unique(hashes)) != 1L) stop("Input contents changed between jobs: ", input)
}
if (any(!benchmark_results$job_complete)) warning("Interrupted jobs are present; inspect missing/incomplete methods.")
if (any(benchmark_results$run_status != "completed")) warning("Failed or incomplete methods are excluded from medians.")
if (length(unique(benchmark_results$cpu_model)) > 1L) warning("Jobs ran on different CPU models; inspect metadata before comparing timings.")
summary <- summarize_benchmark(benchmark_results)
dir.create(dirname(output_file), recursive = TRUE, showWarnings = FALSE)
saveRDS(benchmark_results, output_file)
summary_file <- file.path(dirname(output_file), "benchmark_summary.csv")
write.csv(summary, summary_file, row.names = FALSE, na = "")
print(summary, row.names = FALSE)
message("Saved ", nrow(benchmark_results), " method records to ", output_file)
message("Saved summary to ", summary_file)
