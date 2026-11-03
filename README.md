# Container geocoding benchmark

Compare the released DeGAUSS geocoder container with all four addr geocoding
presets on the Cincinnati Children's Research HPC cluster using IBM LSF and
Apptainer. Measure elapsed wall-clock time and GNU time maximum resident set
size (RSS). The experiment does not evaluate geocoding yield or accuracy.

The design is **2 inputs × 3 core counts × 3 repeats = 18 jobs**. Each job runs
all five methods sequentially in a newly randomized order: **90 timed runs**.

| Container | Release | Reference data |
|---|---|---|
| [addr_geocoder](https://github.com/geomarker-io/addr_geocoder/releases/tag/v2.0.0-taf-v2-2025) | `v2.0.0-taf-v2-2025` (addr 2.0.0) | Complete 2025 TAF, schema v2, baked into image |
| [DeGAUSS geocoder](https://github.com/degauss-org/geocoder/releases/tag/v3.4.2) | `v3.4.2` | Image's bundled 2021 TIGER geocoder database |

`benchmark_config.sh` pins both images to immutable GHCR manifest digests,
resolved on 2026-11-03. The DeGAUSS GHCR tag includes the leading `v`;
`ghcr.io/degauss-org/geocoder:3.4.2` is unavailable. Neither the Shiny interface
nor a host installation of addr is used.

| Method | Matching settings |
|---|---|
| `degauss` | Released defaults, including score threshold 0.5 |
| `addr-default` | All installed `geocode()` defaults |
| `addr-strict` | Input ZIP only; phonetic and fuzzy street-name distances zero |
| `addr-exact-zip` | Input ZIP only; default street matching |
| `addr-loose` | Fuzzy street-name distance three; ignore street type and directionals |

## Prepare on HPC

Run these commands from the checkout on the HPC login node. Inputs must be
available there; they are ignored by Git. No host R packages, host TAF
installation, or personal scratch/data configuration are needed to run jobs.

Only these two CSVs are part of the experiment:

| File under `inputs/` | Rows | Distinct address strings | Purpose |
|---|---:|---:|---|
| `ehr_ah_cincy_10k_sample_1.csv` | 10,000 | 10,000 | Regional workload |
| `ehr_ah_all_100k_sample_1.csv` | 100,000 | 87,409 | Larger workload with broader geographic coverage |

These existing samples come from MBHI address history as of 2026-08-17.
Addresses were assembled by joining component fields with spaces. Both tools
receive the same complete CSV, including the `address` column. Do not upload
these inputs or geocoded outputs to Git. Other local input files are outside
the experiment and are not submitted.

Pull and verify the pinned images:

```bash
bash setup_containers.sh
```

The script loads the `apptainer` module if needed, creates `logs/` and `.work/`,
and stores images in `containers/` with source and SHA-256 sidecars. Existing
images are verified instead of silently replaced. Allow space for both SIFs,
Apptainer's download/conversion cache, and per-job temporary outputs. The addr
OCI image alone is approximately 3.4 GB before SIF conversion.

To keep large images elsewhere, export an absolute path before **both** setup
and submission:

```bash
export CONTAINER_DIR=/scratch/$USER/addr-benchmark-containers
bash setup_containers.sh
```

## Submit

For the complete experiment:

```bash
bash submit_repeats.sh
```

This checks both inputs and both image checksums before submitting any jobs.
It submits three repeats at each of 1, 4, and 16 cores for each input. Each job
requests one node, 64,000 MB total memory, and a 20-hour wall-time limit on the
`normal` queue. The memory reservation per slot is adjusted to the core count.
`-env all` passes the selected input, worker count, and image directory to LSF.

For a subset of that matrix:

```bash
CORE_COUNTS="4 16" N_REPEATS=3 bash submit_repeats.sh inputs/ehr_ah_all_100k_sample_1.csv
```

`TOTAL_MEMORY_MB` optionally changes the wrapper's total memory request.

To submit one job directly with the batch script:

```bash
mkdir -p logs
export INPUT_CSV="$PWD/inputs/ehr_ah_cincy_10k_sample_1.csv"
export N_CORES=4
bsub -env all -n "$N_CORES" -M 64000 \
  -R "span[hosts=1] rusage[mem=$((64000 / N_CORES))]" \
  < geocode_both.bat
```

The batch file verifies that the LSF allocation equals `N_CORES`. With no
exported overrides, `bsub < geocode_both.bat` runs the Cincinnati 10k input at
one core. Every job runs all five methods. Additional submissions add repeats;
the job ID prevents overwriting results. `logs/` must exist before `bsub` opens
its log files.

## What is measured

GNU `/usr/bin/time -v` wraps each Apptainer invocation. Timings include container
and R startup, CSV reading, parsing and geocoding, output construction, and CSV
writing. Pulling/converting images, checksum verification, input copying, and
cleanup are outside the timed region. addr worker counts and DeGAUSS's LSF CPU
settings equal the allocated core count. OpenMP, OpenBLAS, and MKL thread counts
are explicitly limited to one in both containers.

Each method gets a fresh private working directory and private `/tmp` on the
project filesystem. Apptainer uses `--cleanenv --containall`; host R startup
files and user libraries are disabled explicitly. addr uses its image's
read-only reference data at `/opt/addr-data`; it does not mount host reference
data. DeGAUSS caches are discarded after each invocation. The OS filesystem
cache is not flushed between methods or jobs. Randomization reduces systematic
order effects but does not make these cold-cache timings.

The memory metric is **GNU time maximum RSS**, converted from KiB to GiB for
reporting. For these multiprocess workloads it is not the sum of simultaneous
RSS across all workers, nor total job memory. Treat it as the same reported
process memory metric for every method, not an estimate of the aggregate RAM
needed for an HPC allocation.

Container stdout/stderr may include addresses, so it is captured only in the
private work directory and deleted with outputs and caches after each method.
A failure does not skip the other methods; the overall job exits nonzero if any
method or cleanup fails. Exit/termination traps also attempt cleanup. SIGKILL
or a node crash can leave directories under `.work/`; inspect and remove those
after confirming the corresponding jobs have stopped.

## Results and reports

Each job retains:

```text
results/INPUT/N-cores/JOB-ID/
  metadata.tsv          # images, SIF/input hashes, code hashes, host, versions
  method_order.txt      # randomized order for all five methods
  status.tsv            # method exit and cleanup status
  complete.txt          # written after all five methods have been attempted
  degauss/time.txt
  addr-default/time.txt
  addr-strict/time.txt
  addr-exact-zip/time.txt
  addr-loose/time.txt
```

`complete.txt` records the end of the job's method loop; it does not mean every
method succeeded. Check `status.tsv` or the collected summary for failures.
Run-specific copies of inputs, geocoded outputs, caches, and container logs are
removed. Git ignores everything under results except the timing/provenance
files above. Scheduler logs remain in ignored `logs/`.

After jobs finish, use any R installation to collect results. On HPC, load an
R module first. Collection uses base R; plotting additionally requires `ggplot2`.

```bash
Rscript --vanilla collect_results.R
Rscript --vanilla plot_results.R
```

Generated files are ignored under `output/`:

- `benchmark_results.rds`: one record per method per job, including failures
  and missing/incomplete method records for interrupted jobs.
- `benchmark_summary.csv`: counts and median runtime/RSS for every cell of the
  two-input, three-core, five-method design. The default completed experiment
  should have `n_completed = 3` in all 30 cells.
- `benchmark_runtime.pdf` and `benchmark_memory.pdf`: individual completed runs
  and medians, with one panel per input.

Failed, incomplete, and cleanup-failed methods are excluded from both medians
and plots. Collection rejects conflicting statuses and mixed versions,
architectures, input contents, or runner/config revisions. It warns about
interrupted jobs and heterogeneous CPU models. Collect separate experiments
separately if any of those definitions change.

Custom collection and output locations are supported:

```bash
Rscript --vanilla collect_results.R results output/benchmark_results.rds
Rscript --vanilla plot_results.R output/benchmark_results.rds output
```

The historical host-addr experiment, its timing files, and its generated plots
have been removed. They remain recoverable in Git history before `8d4bef9`.
New results belong only to the container/preset design described here.

## Local verification

```bash
for script in benchmark_config.sh setup_containers.sh geocode_both.bat submit_repeats.sh; do
  bash -n "$script" || break
done
python3 -m unittest discover -s tests -v
```

The checks use synthetic addresses and mock LSF/Apptainer/GNU time commands to
exercise submission, isolation, cleanup, failures, and R reporting. They do not
run the real images or establish HPC performance results.
