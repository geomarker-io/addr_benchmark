args <- commandArgs(trailingOnly = TRUE)

results_dir <- if (length(args) >= 1) args[[1]] else "results"
output_file <- if (length(args) >= 2) args[[2]] else "benchmark_results.rds"

time_files <- list.files(
  results_dir,
  pattern = "^time[.]txt$",
  recursive = TRUE,
  full.names = TRUE
)

if (length(time_files) == 0) {
  stop("No time.txt files found under ", results_dir, ".")
}

elapsed_seconds <- function(value) {
  parts <- as.numeric(strsplit(value, ":", fixed = TRUE)[[1]])
  if (length(parts) == 2 && all(!is.na(parts))) {
    return(parts[[1]] * 60 + parts[[2]])
  }
  if (length(parts) == 3 && all(!is.na(parts))) {
    return(parts[[1]] * 3600 + parts[[2]] * 60 + parts[[3]])
  }
  NA_real_
}

parse_time_file <- function(path) {
  lines <- trimws(readLines(path, warn = FALSE))
  separators <- regexpr(": ", lines, fixed = TRUE)
  lines <- lines[separators > 0]
  separators <- separators[separators > 0]

  fields <- substr(lines, 1, separators - 1)
  values <- substring(lines, separators + 2)
  values <- stats::setNames(values, fields)

  required_fields <- c(
    "Command being timed",
    "User time (seconds)",
    "System time (seconds)",
    "Percent of CPU this job got",
    "Elapsed (wall clock) time (h:mm:ss or m:ss)",
    "Average shared text size (kbytes)",
    "Average unshared data size (kbytes)",
    "Average stack size (kbytes)",
    "Average total size (kbytes)",
    "Maximum resident set size (kbytes)",
    "Average resident set size (kbytes)",
    "Major (requiring I/O) page faults",
    "Minor (reclaiming a frame) page faults",
    "Voluntary context switches",
    "Involuntary context switches",
    "Swaps",
    "File system inputs",
    "File system outputs",
    "Socket messages sent",
    "Socket messages received",
    "Signals delivered",
    "Page size (bytes)",
    "Exit status"
  )

  missing_fields <- setdiff(required_fields, names(values))
  if (length(missing_fields) > 0) {
    stop(
      "Missing fields in ",
      path,
      ": ",
      paste(missing_fields, collapse = ", ")
    )
  }

  method_dir <- dirname(path)
  job_dir <- dirname(method_dir)
  cores_dir <- dirname(job_dir)
  input_dir <- dirname(cores_dir)
  cores_name <- basename(cores_dir)
  order_file <- file.path(job_dir, "method_order.txt")

  if (!grepl("^[0-9]+-cores$", cores_name)) {
    stop("Unexpected results path: ", path)
  }

  first_method <- NA_character_
  if (file.exists(order_file)) {
    method_order <- trimws(readLines(order_file, warn = FALSE))
    method_order <- method_order[nzchar(method_order)]

    if (
      length(method_order) != 2 ||
        !setequal(method_order, c("addr", "degauss"))
    ) {
      stop("Unexpected method ordering in ", order_file, ".")
    }

    first_method <- method_order[[1]]
  }

  numeric_value <- function(field) as.numeric(values[[field]])

  list(
    input = basename(input_dir),
    n_cores = as.integer(sub("-cores$", "", cores_name)),
    job_id = basename(job_dir),
    method = basename(method_dir),
    first_method = first_method,
    command = sub('^"(.*)"$', "\\1", values[["Command being timed"]]),
    user_seconds = numeric_value("User time (seconds)"),
    system_seconds = numeric_value("System time (seconds)"),
    cpu_percent = as.numeric(sub(
      "%$",
      "",
      values[["Percent of CPU this job got"]]
    )),
    elapsed_seconds = elapsed_seconds(
      values[["Elapsed (wall clock) time (h:mm:ss or m:ss)"]]
    ),
    average_shared_text_kb = numeric_value("Average shared text size (kbytes)"),
    average_unshared_data_kb = numeric_value(
      "Average unshared data size (kbytes)"
    ),
    average_stack_kb = numeric_value("Average stack size (kbytes)"),
    average_total_size_kb = numeric_value("Average total size (kbytes)"),
    maximum_resident_set_kb = numeric_value(
      "Maximum resident set size (kbytes)"
    ),
    average_resident_set_kb = numeric_value(
      "Average resident set size (kbytes)"
    ),
    major_page_faults = numeric_value("Major (requiring I/O) page faults"),
    minor_page_faults = numeric_value("Minor (reclaiming a frame) page faults"),
    voluntary_context_switches = numeric_value("Voluntary context switches"),
    involuntary_context_switches = numeric_value(
      "Involuntary context switches"
    ),
    swaps = numeric_value("Swaps"),
    file_system_inputs = numeric_value("File system inputs"),
    file_system_outputs = numeric_value("File system outputs"),
    socket_messages_sent = numeric_value("Socket messages sent"),
    socket_messages_received = numeric_value("Socket messages received"),
    signals_delivered = numeric_value("Signals delivered"),
    page_size_bytes = numeric_value("Page size (bytes)"),
    exit_status = as.integer(values[["Exit status"]]),
    time_file = path
  )
}

rows <- lapply(sort(time_files), parse_time_file)
benchmark_results <- tibble::as_tibble(
  do.call(
    rbind,
    lapply(rows, as.data.frame, stringsAsFactors = FALSE, optional = TRUE)
  )
)

benchmark_results <- benchmark_results[
  order(
    benchmark_results$input,
    benchmark_results$n_cores,
    benchmark_results$job_id,
    benchmark_results$method
  ),
]

missing_order <- benchmark_results[is.na(benchmark_results$first_method), ]
if (nrow(missing_order) > 0) {
  missing_jobs <- unique(paste(
    missing_order$input,
    paste0(missing_order$n_cores, "-cores"),
    missing_order$job_id,
    sep = "/"
  ))
  warning(
    "Missing method_order.txt for ",
    length(missing_jobs),
    " job(s); first_method is NA: ",
    paste(missing_jobs, collapse = ", ")
  )
}

replicate_counts <- aggregate(
  job_id ~ input + n_cores + method,
  data = benchmark_results,
  FUN = length
)
names(replicate_counts)[names(replicate_counts) == "job_id"] <- "n_replicates"

median_times <- aggregate(
  elapsed_seconds ~ input + n_cores + method,
  data = benchmark_results,
  FUN = median,
  na.rm = TRUE
)
names(median_times)[names(median_times) == "elapsed_seconds"] <-
  "median_elapsed_seconds"

results_summary <- merge(
  replicate_counts,
  median_times,
  by = c("input", "n_cores", "method"),
  sort = FALSE
)
results_summary <- tibble::as_tibble(results_summary)
results_summary <- results_summary[
  order(
    results_summary$input,
    results_summary$n_cores,
    results_summary$method
  ),
]

cat("Results summary by input, core count, and method:\n")
print(results_summary, n = Inf, width = Inf)

saveRDS(benchmark_results, output_file)
message("Saved ", nrow(benchmark_results), " rows to ", output_file, ".")
