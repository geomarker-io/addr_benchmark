"""Exercise the submission/runner contract without LSF, Linux, or large images."""
import csv
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]


class BenchmarkFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="addr-benchmark-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for name in ("benchmark_config.sh", "setup_containers.sh", "geocode_both.bat", "submit_repeats.sh"):
            shutil.copy(REPO / name, self.root / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.events = self.root / "events.jsonl"
        self.env = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                        MOCK_EVENTS=str(self.events), LS_SUBCWD=str(self.root),
                        LSB_JOBID="123", LSB_DJOB_NUMPROC="4", N_CORES="4",
                        TIME_BIN=str(self.bin / "time"))
        # Ignore caller overrides so these fixtures always describe the default matrix.
        for name in ("CORE_COUNTS", "N_REPEATS", "TOTAL_MEMORY_MB", "INPUT_CSV", "CONTAINER_DIR",
                     "MOCK_FAIL_METHOD"):
            self.env.pop(name, None)
        self.stub("apptainer", '''
import json, os, pathlib, sys
args=sys.argv[1:]
if args == ['--version']:
    print('apptainer version mock'); sys.exit(0)
with open(os.environ['MOCK_EVENTS'],'a') as f: f.write(json.dumps(['apptainer', args])+'\\n')
if args[0]=='pull':
    pathlib.Path(args[1]).write_text('mock image '+args[2]); sys.exit(0)
binds=[args[i+1] for i,a in enumerate(args) if a=='--bind']
work=pathlib.Path(next(b[:-6] for b in binds if b.endswith(':/work')))
assert (work/'input.csv').exists()
assert not (work/'geocoding_cache').exists()
(work/'geocoding_cache').mkdir()
(work/'output.csv').write_text('private synthetic geocodes')
method='addr-'+args[args.index('--preset')+1] if '--preset' in args else 'degauss'
sys.exit(7 if os.environ.get('MOCK_FAIL_METHOD')==method else 0)
''')
        self.stub("time", '''
import pathlib, subprocess, sys
if sys.argv[1:]==['--version']:
    print('time (GNU Time) mock'); sys.exit(0)
assert sys.argv[1:3]==['-v','-o']
path=pathlib.Path(sys.argv[3])
status=subprocess.run(sys.argv[4:]).returncode
text='Elapsed (wall clock) time (h:mm:ss or m:ss): 0:05.25\\nMaximum resident set size (kbytes): 204800\\n'
text+='Exit status: '+str(status)+'\\n'
path.write_text(text)
sys.exit(status)
''')
        self.stub("bsub", '''
import json, os, sys
assert '#BSUB -J geocode_both' in sys.stdin.read()
with open(os.environ['MOCK_EVENTS'],'a') as f:
    f.write(json.dumps(['bsub',sys.argv[1:],{k:os.environ[k] for k in ['N_CORES','INPUT_CSV','BENCHMARK_REPEAT']}])+'\\n')
print('Job <mock> submitted')
''')
        self.stub("git", "import sys\nif sys.argv[1]=='rev-parse': print('a'*40)\n")
        self.stub("awk", "import sys\nprint('mock CPU' if sys.argv[-1]=='/proc/cpuinfo' else '67108864')\n")
        (self.root / "inputs").mkdir()
        for name in ("ehr_ah_cincy_10k_sample_1", "ehr_ah_all_100k_sample_1"):
            (self.root / "inputs" / (name + ".csv")).write_text('address\n123 TEST ST TEST OH 45229\n')
        self.run_script("setup_containers.sh")
        for kind, args in self.read_events():
            self.assertEqual(kind, "apptainer")
            self.assertEqual(args[0], "pull")
            self.assertRegex(args[2], r"^docker://ghcr\.io/[^@]+@sha256:[0-9a-f]{64}$")
        self.events.unlink()

    def stub(self, name, code):
        p = self.bin / name
        p.write_text("#!/usr/bin/env python3\n" + code)
        p.chmod(0o755)

    def run_script(self, name, *args, ok=True):
        result = subprocess.run(["bash", str(self.root / name), *args], cwd=self.root,
                                env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def read_events(self):
        return [json.loads(line) for line in self.events.read_text().splitlines()] if self.events.exists() else []

    @property
    def job(self):
        return self.root / "results/ehr_ah_cincy_10k_sample_1/4-cores/123"


class WorkflowTests(BenchmarkFixture):
    def test_setup_uses_digests_and_verifies_existing_images(self):
        self.run_script("setup_containers.sh")
        self.assertEqual(self.read_events(), [])
        image = next((self.root / "containers").glob("*.sif"))
        image.write_text("corrupted")
        self.run_script("setup_containers.sh", ok=False)

    def test_default_submission_matrix(self):
        self.run_script("submit_repeats.sh")
        jobs = self.read_events()
        self.assertEqual(len(jobs), 18)
        combinations = set()
        for kind, args, env in jobs:
            self.assertEqual(kind, "bsub")
            n = env["N_CORES"]
            self.assertEqual(args[args.index("-n") + 1], n)
            self.assertEqual(args[args.index("-env") + 1], "all")
            self.assertIn(f"rusage[mem={64000 // int(n)}]", args[args.index("-R") + 1])
            combinations.add((Path(env["INPUT_CSV"]).name, n, env["BENCHMARK_REPEAT"]))
        self.assertEqual(len(combinations), 18)

    def test_preflight_prevents_partial_submission(self):
        (self.root / "inputs/ehr_ah_all_100k_sample_1.csv").unlink()
        self.run_script("submit_repeats.sh", ok=False)
        self.assertEqual(self.read_events(), [])

    def test_invalid_submission_settings(self):
        for name, value in (("CORE_COUNTS", "1 1"), ("CORE_COUNTS", "2"), ("N_REPEATS", "0")):
            env = self.env.copy()
            self.env[name] = value
            self.run_script("submit_repeats.sh", ok=False)
            self.env = env
        self.assertEqual(self.read_events(), [])

    def test_all_methods_use_isolated_containers_and_cleanup(self):
        self.run_script("geocode_both.bat")
        events = self.read_events()
        self.assertEqual(len(events), 5)
        order = (self.job / "method_order.txt").read_text().splitlines()
        self.assertCountEqual(order, ["degauss", "addr-default", "addr-strict", "addr-exact-zip", "addr-loose"])
        for method, (_, args) in zip(order, events):
            self.assertIn("--cleanenv", args)
            self.assertIn("--containall", args)
            self.assertIn("LSB_DJOB_NUMPROC=4,LSB_MAX_NUM_PROCESSORS=4", args)
            if method.startswith("addr-"):
                self.assertEqual(args[args.index("--workers") + 1], "4")
                self.assertEqual(args[args.index("--preset") + 1], method[5:])
            self.assertTrue((self.job / method / "time.txt").exists())
        self.assertEqual(list((self.root / ".work").iterdir()), [])
        self.assertTrue((self.job / "complete.txt").exists())
        self.assertFalse(any(p.suffix == ".csv" for p in self.job.rglob("*")))
        # The same job ID cannot overwrite existing timings.
        self.run_script("geocode_both.bat", ok=False)
        self.assertEqual(len(self.read_events()), 5)

    def test_method_failure_does_not_skip_other_methods(self):
        self.env["MOCK_FAIL_METHOD"] = "addr-strict"
        self.run_script("geocode_both.bat", ok=False)
        self.assertEqual(len(self.read_events()), 5)
        with (self.job / "status.tsv").open() as f:
            statuses = {r["method"]: r["exit_status"] for r in csv.DictReader(f, delimiter="\t")}
        self.assertEqual(statuses["addr-strict"], "7")
        self.assertEqual(sum(v == "0" for v in statuses.values()), 4)
        self.assertEqual(list((self.root / ".work").iterdir()), [])

    def test_core_mismatch_fails_before_running(self):
        self.env["LSB_DJOB_NUMPROC"] = "1"
        self.run_script("geocode_both.bat", ok=False)
        self.assertEqual(self.read_events(), [])


@unittest.skipUnless(shutil.which("Rscript"), "Rscript is needed for report checks")
class ReportingTests(BenchmarkFixture):
    # Use the same runner fixtures to test the actual files consumed by R.
    def setUp(self):
        super().setUp()
        for name in ("collect_results.R", "plot_results.R"):
            shutil.copy(REPO / name, self.root / name)
        shutil.copytree(REPO / "R", self.root / "R")

    def run_r(self, script, ok=True):
        result = subprocess.run(["Rscript", "--vanilla", str(self.root / script)],
                                cwd=self.root, env=self.env, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def summary(self):
        with (self.root / "output/benchmark_summary.csv").open() as f:
            return {r["method"]: r for r in csv.DictReader(f)
                    if r["input"] == "ehr_ah_cincy_10k_sample_1" and r["n_cores"] == "4"}

    def test_reports_exclude_failures_and_convert_memory(self):
        self.env["MOCK_FAIL_METHOD"] = "addr-loose"
        self.run_script("geocode_both.bat", ok=False)
        self.run_r("collect_results.R")
        summary = self.summary()
        self.assertEqual(summary["addr-loose"]["n_failed"], "1")
        self.assertEqual(summary["addr-loose"]["median_elapsed_seconds"], "")
        self.assertEqual(float(summary["degauss"]["median_elapsed_seconds"]), 5.25)
        self.assertAlmostEqual(float(summary["degauss"]["median_maximum_resident_set_gib"]), 0.1953125)
        self.run_r("plot_results.R")
        for name in ("runtime", "memory"):
            self.assertTrue((self.root / f"output/benchmark_{name}.pdf").read_bytes().startswith(b"%PDF"))

    def test_interrupted_job_retains_missing_and_incomplete_methods(self):
        self.run_script("geocode_both.bat")
        (self.job / "complete.txt").unlink()
        (self.job / "status.tsv").write_text("method\texit_status\tcleanup_status\naddr-default\t0\t0\n")
        (self.job / "addr-default/time.txt").write_text("Elapsed (wall clock) time (h:mm:ss or m:ss): 0:05.25\n")
        self.run_r("collect_results.R")
        self.assertEqual(self.summary()["addr-default"]["n_incomplete"], "1")
        self.assertEqual(self.summary()["degauss"]["n_incomplete"], "1")
        self.assertTrue(all(r["n_completed"] == "0" for r in self.summary().values()))
        self.run_r("plot_results.R", ok=False)

    def test_conflicting_exit_status_is_rejected(self):
        self.run_script("geocode_both.bat")
        time = self.job / "addr-default/time.txt"
        time.write_text(time.read_text().replace("Exit status: 0", "Exit status: 7"))
        result = self.run_r("collect_results.R", ok=False)
        self.assertIn("Conflicting exit statuses", result.stderr)

    def test_signaled_process_is_reported_as_failed(self):
        self.run_script("geocode_both.bat")
        time = self.job / "degauss/time.txt"
        time.write_text("Command terminated by signal 9\n" + time.read_text())
        status = self.job / "status.tsv"
        status.write_text(status.read_text().replace("degauss\t0\t0", "degauss\t137\t0"))
        self.run_r("collect_results.R")
        self.assertEqual(self.summary()["degauss"]["n_failed"], "1")
        self.assertEqual(self.summary()["degauss"]["median_elapsed_seconds"], "")

    def test_mixed_versions_are_rejected(self):
        self.run_script("geocode_both.bat")
        other = self.job.with_name("124")
        shutil.copytree(self.job, other)
        meta = other / "metadata.tsv"
        meta.write_text(meta.read_text().replace("job_id\t123", "job_id\t124").replace("addr_version\t2.0.0", "addr_version\t2.1.0"))
        result = self.run_r("collect_results.R", ok=False)
        self.assertIn("Mixed addr_version", result.stderr)


if __name__ == "__main__":
    unittest.main()
