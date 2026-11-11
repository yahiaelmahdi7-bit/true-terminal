import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shlex
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone


ROOT = Path(__file__).resolve().parents[2]
SAMPLES = Path(__file__).parent / "samples"
spec = importlib.util.spec_from_file_location("gate", ROOT / "scripts/gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
KEY = "AgentHooksTests/preToolUseBashCarriesTheCommand()"


class GateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.env = dict(os.environ, TRUE_GATE_DIR=str(self.directory / "results"), TRUE_GATE_DIRTY="0")
        self.fake = self.directory / "fake.py"
        self.fake.write_text('''import pathlib, sys, time
samples = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
retry = "--filter" in sys.argv
with pathlib.Path(sys.argv[3]).open("a") as f:
    f.write(repr(sys.argv[4:]) + "\\n")
sample = {"pass": "all-pass", "fail": "one-fail", "flaky": "retry-pass" if retry else "one-fail",
          "crash": "crash", "hang": "hang", "empty": "hang", "zero": "zero-tests",
          "retry-crash": "crash" if retry else "one-fail",
          "wrong": "all-pass" if retry else "one-fail"}[mode]
print((samples / (sample + ".log")).read_text(), flush=True)
if mode == "hang":
    import threading
    threading.Event().wait(30)
sys.exit(1 if sample in ("one-fail", "crash") else 0)
''')

    def command(self, mode):
        return shlex.join([sys.executable, str(self.fake), str(SAMPLES), mode,
                           str(self.directory / "calls")])

    def run_gate(self, mode="pass", extra=(), build="true"):
        done = subprocess.run([str(ROOT / "scripts/gate.sh"), "--build-cmd", build,
                               "--test-cmd", self.command(mode), *extra],
                              env=self.env, capture_output=True, text=True, timeout=10)
        files = list((self.directory / "results").glob("*.json"))
        self.assertEqual(len(files), 1, done.stdout + done.stderr)
        return done, json.loads(files[0].read_text())

    def calls(self):
        path = self.directory / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_pass(self):
        done, result = self.run_gate()
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertTrue(result["passed"])
        self.assertEqual(result["failed"], [])
        self.assertEqual(len(self.calls()), 1)
        self.assertGreater(result["duration"], 0)
        self.assertEqual(len(result["commit"]), 40)

    def test_dirty_tree_is_not_filed_as_the_commit_result(self):
        self.env["TRUE_GATE_DIRTY"] = "1"
        done = subprocess.run([str(ROOT / "scripts/gate.sh"), "--build-cmd", "true",
                               "--test-cmd", self.command("pass")],
                              env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertEqual(list((self.directory / "results").glob("*.json")), [])
        self.assertIn("uncommitted changes", done.stdout)
        runs = list((self.directory / "results").glob("*/result.json"))
        self.assertEqual(len(runs), 1)
        self.assertTrue(json.loads(runs[0].read_text())["dirty"])

    def test_failure_reruns_once_with_exact_filter(self):
        done, result = self.run_gate("fail")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["failed"], [KEY])
        self.assertEqual(result["reason"], "Tests failed on retry")
        self.assertEqual(len(self.calls()), 2)
        self.assertIn("--filter", self.calls()[1])
        pattern = gate.test_filter({KEY})
        self.assertRegex("TrueTests." + KEY + "/AgentHooksTests.swift:33", pattern)
        self.assertIsNone(re.search(pattern, "TrueTests." + KEY + "Extra"))
        self.assertIsNone(re.search(pattern, "Other" + KEY))

    def test_flaky_two_strikes_remain_red_until_clear(self):
        done, result = self.run_gate("flaky")
        self.assertEqual(done.returncode, 0, done.stdout)
        self.assertEqual(result["flaky"], [KEY])
        self.assertIn("Flaky: " + KEY, done.stdout)
        first = result["run_id"]
        done, result = self.run_gate("flaky")
        self.assertEqual(done.returncode, 1)
        self.assertIn("Second flaky strike", result["reason"])
        self.assertNotEqual(first, result["run_id"])
        done, result = self.run_gate("pass")
        self.assertEqual(done.returncode, 1)
        cleared = subprocess.run([str(ROOT / "scripts/gate.sh"), "--clear", KEY],
                                 env=self.env, capture_output=True, text=True, timeout=10)
        self.assertEqual(cleared.returncode, 0, cleared.stderr)
        done, result = self.run_gate("flaky")
        self.assertEqual(done.returncode, 0, done.stdout)
        rows = [json.loads(l) for l in (self.directory / "results/flaky.jsonl").read_text().splitlines()]
        self.assertTrue(rows[2]["clear"])
        self.assertEqual(set(rows[0]), {"date", "test", "commit", "run_id"})

    def test_expired_strike_and_duplicate_run_do_not_count(self):
        folder = self.directory / "ledger"
        folder.mkdir()
        now = datetime.now(timezone.utc)
        gate.record_flakes(folder, {KEY}, "commit", "old", now - timedelta(days=8))
        self.assertEqual(gate.record_flakes(folder, {KEY}, "commit", "new", now), set())
        self.assertEqual(gate.record_flakes(folder, {KEY}, "commit", "new", now), set())
        self.assertEqual(gate.record_flakes(folder, {KEY}, "commit", "next", now), {KEY})
        self.assertEqual(gate.record_flakes(folder, set(), "commit", "later", now + timedelta(days=8)), set())

    def test_crash_never_retries(self):
        done, result = self.run_gate("crash")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["reason"], "Tests crashed")
        self.assertEqual(len(self.calls()), 1)

    def test_cap_never_retries(self):
        done, result = self.run_gate("hang", ("--timeout", "0.2"))
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["reason"], "Tests timed out")
        self.assertEqual(len(self.calls()), 1)

    def test_build_failure_never_runs_tests(self):
        command = "cat " + shlex.quote(str(SAMPLES / "build-failure.log")) + "; exit 1"
        done, result = self.run_gate(build=command)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["reason"], "Build failed")
        self.assertEqual(self.calls(), [])

    def test_partial_output_is_not_success(self):
        done, result = self.run_gate("empty")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(len(self.calls()), 1)

    def test_retry_must_pass_the_failed_test(self):
        done, result = self.run_gate("wrong")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["failed"], [KEY])

    def test_zero_matching_tests_are_red(self):
        done, result = self.run_gate("zero")
        self.assertEqual(done.returncode, 1)
        self.assertFalse(result["passed"])

    def test_retry_crash_is_red_without_third_attempt(self):
        done, result = self.run_gate("retry-crash")
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["reason"], "Retry crashed")
        self.assertEqual(len(self.calls()), 2)

    def test_build_cap_never_runs_tests(self):
        command = shlex.join([sys.executable, "-c", "import threading; threading.Event().wait(30)"])
        done, result = self.run_gate(extra=("--timeout", "0.2"), build=command)
        self.assertEqual(done.returncode, 1)
        self.assertEqual(result["reason"], "Build timed out")
        self.assertEqual(self.calls(), [])

    def test_termination_stops_command_and_writes_red_result(self):
        fifo = self.directory / "ready"
        os.mkfifo(fifo)
        descriptor = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
        self.addCleanup(lambda: os.close(descriptor))
        code = ("import os, threading; "
                "f=open(" + repr(str(fifo)) + ", 'w'); "
                "f.write(str(os.getpid())); f.flush(); threading.Event().wait(30)")
        command = shlex.join([sys.executable, "-c", code])
        process = subprocess.Popen([str(ROOT / "scripts/gate.sh"), "--build-cmd", command],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True)
        try:
            self.assertTrue(select.select([descriptor], [], [], 5)[0], "command did not start")
            self.assertTrue(os.read(descriptor, 100).decode().isdigit())
            os.close(descriptor)
            descriptor = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
            process.terminate()
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 1, stdout + stderr)
            result = json.loads(next((self.directory / "results").glob("*.json")).read_text())
            self.assertEqual(result["reason"], "Gate interrupted")
            self.assertFalse(result["passed"])
            self.assertTrue(select.select([descriptor], [], [], 5)[0], "command still holds its pipe")
            self.assertEqual(os.read(descriptor, 100), b"", "command did not close its pipe")
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)

    def run_in_repo(self, build):
        """Run the gate inside a real throwaway repository whose build step may change it."""
        repo = self.directory / "repo"
        repo.mkdir()
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
               "-c", "core.hooksPath=/dev/null"]
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        (repo / "a.txt").write_text("a\n")
        subprocess.run(git + ["add", "a.txt"], cwd=repo, check=True)
        subprocess.run(git + ["commit", "-qm", "a"], cwd=repo, check=True)
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
        env = dict(self.env)
        env.pop("TRUE_GATE_DIRTY")
        build = build.replace("GIT", shlex.join(git))
        done = subprocess.run([sys.executable, str(ROOT / "scripts/gate.py"), "--build-cmd", build,
                               "--test-cmd", self.command("pass")],
                              cwd=repo, env=env, capture_output=True, text=True, timeout=10)
        filed = self.directory / "results" / (commit + ".json")
        run = json.loads(next((self.directory / "results").glob("*/result.json")).read_text())
        return done, filed, run, commit

    def test_unchanged_clean_repo_is_filed(self):
        done, filed, run, commit = self.run_in_repo("true")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertTrue(json.loads(filed.read_text())["passed"])
        self.assertNotIn("changed", run)

    def test_new_file_during_run_is_not_certified(self):
        done, filed, run, commit = self.run_in_repo("echo b > b.txt")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertFalse(filed.exists())
        self.assertFalse(run["passed"])
        self.assertEqual(run["reason"], "Code changed during the run")
        self.assertIn("the code changed during the run", done.stdout)

    def test_commit_during_run_is_not_certified(self):
        done, filed, run, commit = self.run_in_repo("GIT commit -q --allow-empty -m b")
        self.assertEqual(done.returncode, 1, done.stdout + done.stderr)
        self.assertFalse(filed.exists())
        self.assertEqual(list((self.directory / "results").glob("*.json")), [])
        self.assertTrue(run["changed"])
        self.assertNotEqual(run["commit_after"], commit)

    def test_samples(self):
        _, failed, complete, crashed = gate.parse_tests((SAMPLES / "one-fail.log").read_text())
        self.assertEqual(failed, {KEY})
        self.assertTrue(complete)
        self.assertFalse(crashed)
        passed, _, complete, _ = gate.parse_tests((SAMPLES / "retry-pass.log").read_text())
        self.assertIn(KEY, passed)
        self.assertTrue(complete)

    def test_corrupt_ledger_fails_closed(self):
        folder = self.directory / "results"
        folder.mkdir()
        (folder / "flaky.jsonl").write_text("broken\n")
        done, result = self.run_gate()
        self.assertEqual(done.returncode, 1)
        self.assertFalse(result["passed"])

    def test_release_default_gate_survives_temporary_checkout_cleanup(self):
        """Exercise the real release script; fake only git checkout and Swift processes."""
        binaries = self.directory / "bin"
        binaries.mkdir()
        git = binaries / "git"
        git.write_text("#!" + sys.executable + "\n" + '''import pathlib, shutil, sys
args = sys.argv[1:]
if args[0] == "rev-parse":
    print("a" * (7 if "--short=7" in args else 40))
elif args[:2] == ["worktree", "add"]:
    tree = pathlib.Path(args[-2])
    (tree / "scripts").mkdir(parents=True)
    for name in ("gate.sh", "gate.py"):
        shutil.copy2(''' + repr(str(ROOT / "scripts")) + ''' + "/" + name, tree / "scripts" / name)
elif "remove" in args:
    shutil.rmtree(args[-1])
else:
    sys.exit(2)
''')
        swift = binaries / "swift"
        swift.write_text("#!/bin/sh\nif [ \"$1\" = test ]; then cat " + shlex.quote(str(SAMPLES / "all-pass.log")) + "; fi\n")
        security = binaries / "security"
        security.write_text("#!/bin/sh\nexit 1\n")
        for path in (git, swift, security):
            path.chmod(0o755)
        env = dict(self.env, PATH=str(binaries) + ":" + os.environ["PATH"])
        env.pop("TRUE_GATE_CMD", None)
        done = subprocess.run([str(ROOT / "scripts/release-team.sh"), "--dry-run", "HEAD"],
                              env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("gate: scripts/gate.sh", done.stdout)
        self.assertIn("dry run: stopping after the gate", done.stdout)
        result = Path(env["TRUE_GATE_DIR"]) / ("a" * 40 + ".json")
        self.assertTrue(json.loads(result.read_text())["passed"])
        checkout = re.search(r"checked out a+ in (.*)", done.stdout).group(1)
        self.assertFalse(Path(checkout).exists())
        # The existing override is still authoritative.
        env["TRUE_GATE_CMD"] = "echo overridden"
        result.unlink()
        done = subprocess.run([str(ROOT / "scripts/release-team.sh"), "--dry-run", "HEAD"],
                              env=env, capture_output=True, text=True, timeout=10)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertIn("gate: echo overridden", done.stdout)
        self.assertFalse(result.exists())


if __name__ == "__main__":
    unittest.main()
