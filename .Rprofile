local({
  project_library <- file.path(getwd(), ".R-library")
  dir.create(project_library, recursive = TRUE, showWarnings = FALSE)
  Sys.setenv(R_LIBS_USER = project_library)
  .libPaths(c(project_library, .libPaths()))
})
