#!/usr/bin/env python3
"""Build, test, and retry named failures once. No third-party dependencies."""
import argparse
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid


def parse_tests(output):
    """Swift Testing's serial console output nests tests inside suite boundaries."""
    suites, passed, failed = [], set(), set()
    complete = False
    crashed = False
    for line in re.sub(r"\x1b\[[0-9;]*m", "", output).splitlines():
        match = re.search(r"[◇✔✘] Suite (.+?) (started\.|(?:passed|failed) after)", line)
        if match:
            name, state = match.groups()
            if state == "started.":
                suites.append(name)
            elif suites and suites[-1] == name:
                suites.pop()
        match = re.search(r"[✔✘] Test (.+?) (passed|failed) after", line)
        if match and suites:
            name, state = match.groups()
            key = "/".join(suites + [name])
            (passed if state == "passed" else failed).add(key)
        if re.search(r"[✔✘] Test run with \d+ tests? .* (?:passed|failed) after", line):
            complete = True
        if re.search(r"(?i)(exited with unexpected signal|fatal error:|signal \d+|segmentation fault|abort trap)", line):
            crashed = True
    if re.search(r"✘ Test run with", output) and not failed:
        crashed = True  # A failed summary with no attributable names cannot be retried.
    return passed, failed, complete, crashed


def test_filter(keys):
    # SwiftPM matches identifiers such as TrueTests.Suite/test(). Bound both ends;
    # escaping prevents parameter labels and regex metacharacters broadening a retry.
    # Swift Testing appends a source-location component after the function name.
    return r"(?:^|\.)(?:" + "|".join(re.escape(k) for k in sorted(keys)) + r")(?:/|$)"


def run(command, timeout, log):
    with log.open("w+") as stream:
        process = subprocess.Popen(command, shell=True, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        timed_out = False
        try:
            code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            code, timed_out = -1, True
        finally:
            # Also reap descendants left behind by a crashed command or interruption.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        stream.seek(0)
        output = stream.read()
    print(output, end="", flush=True)
    return code, timed_out, parse_tests(output)


@contextmanager
def ledger_lock(directory):
    with (directory / "flaky.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def record_flakes(directory, keys, commit, run_id, now):
    with ledger_lock(directory):
        ledger = directory / "flaky.jsonl"
        strikes = {}
        if ledger.exists():
            for line in ledger.read_text().splitlines():
                row = json.loads(line)  # Corrupt evidence must never silently allow a release.
                key = row["test"]
                if row.get("clear"):
                    strikes.pop(key, None)
                elif datetime.fromisoformat(row["date"]) > now - timedelta(days=7):
                    strikes.setdefault(key, set()).add(row["run_id"])
        with ledger.open("a") as stream:
            for key in sorted(keys):
                strikes.setdefault(key, set()).add(run_id)
                stream.write(json.dumps(dict(date=now.isoformat(), test=key,
                                             commit=commit, run_id=run_id)) + "\n")
        blocked = {key for key, runs in strikes.items() if len(runs) >= 2}
    return blocked


def snapshot():
    """The commit and the uncommitted work that this run compiles and tests."""
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    forced = os.environ.get("TRUE_GATE_DIRTY")  # tests only: "0" or "1"
    if forced in ("0", "1"):
        return commit, "forced dirty" if forced == "1" else ""
    # Untracked files are compiled too, so they count as uncommitted work.
    return commit, subprocess.check_output(["git", "status", "--porcelain"], text=True).strip()


def write_result(path, result):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
        temporary = stream.name
    os.replace(temporary, path)


def main():
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--clear", metavar="TEST")
    parser.add_argument("--build-cmd", default="swift build")
    parser.add_argument("--test-cmd", default="swift test --no-parallel",
                        help="Retry appends --filter and the exact failure pattern")
    parser.add_argument("--timeout", type=float, default=1200,
                        help="Seconds per command (default: 20 minutes)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("timeout must be positive")
    directory = Path(os.environ.get("TRUE_GATE_DIR", "~/.true/gate")).expanduser()
    directory.mkdir(parents=True, exist_ok=True)
    before = snapshot()
    commit = before[0]
    # Uncommitted work is compiled too, so its result is not that commit's result.
    dirty = bool(before[1])
    now = datetime.now(timezone.utc)
    run_id = uuid.uuid4().hex
    if args.clear:
        with ledger_lock(directory):
            with (directory / "flaky.jsonl").open("a") as stream:
                stream.write(json.dumps(dict(date=now.isoformat(), test=args.clear,
                                             commit=commit, run_id=run_id, clear=True)) + "\n")
        print("Cleared: " + args.clear)
        return 0
    started = time.monotonic()
    result = dict(passed=False, failed=[], flaky=[], reason="", duration=0,
                  commit=commit, run_id=run_id, dirty=dirty)
    logs = directory / run_id
    logs.mkdir()
    try:
        code, timeout, _ = run(args.build_cmd, args.timeout, logs / "build.log")
        if timeout or code:
            result["reason"] = "Build timed out" if timeout else "Build failed"
        else:
            code, timeout, (passed, failed, complete, crashed) = run(
                args.test_cmd, args.timeout, logs / "test.log")
            result["failed"] = sorted(failed)
            if timeout:
                result["reason"] = "Tests timed out"
            elif crashed:
                result["reason"] = "Tests crashed"
            elif not complete:
                result["reason"] = "Tests stopped before finishing"
            elif failed:
                retry = args.test_cmd + " --filter " + shlex.quote(test_filter(failed))
                rc, timeout, (retry_passed, retry_failed, complete, crashed) = run(
                    retry, args.timeout, logs / "retry.log")
                flaky = failed & retry_passed - retry_failed
                result["flaky"] = sorted(flaky)
                result["failed"] = sorted((failed - flaky) | retry_failed)
                for key in sorted(flaky):
                    print("Flaky: " + key)
                if timeout:
                    result["reason"] = "Retry timed out"
                elif crashed:
                    result["reason"] = "Retry crashed"
                elif not complete:
                    result["reason"] = "Retry stopped before finishing"
                elif result["failed"] or rc:
                    result["reason"] = "Tests failed on retry"
                else:
                    result["passed"] = True
            elif code or not passed:
                result["reason"] = "Tests failed without named failures"
            else:
                result["passed"] = True
        blocked = record_flakes(directory, result["flaky"], commit, run_id, now)
        if blocked:
            result["passed"] = False
            result["failed"] = sorted(set(result["failed"]) | blocked)
            if not result["reason"]:
                result["reason"] = "Second flaky strike: " + ", ".join(sorted(blocked))
    except (OSError, ValueError, KeyError, TypeError) as error:
        result["passed"] = False
        result["reason"] = "Gate could not finish"
        print(str(error), file=sys.stderr)
    except KeyboardInterrupt:
        result["passed"] = False
        result["reason"] = "Gate interrupted"
    result["duration"] = round(time.monotonic() - started, 3)
    # Check again right before publishing. A commit, checkout or edit during the run means
    # the tested code matches neither snapshot, so the result certifies nothing.
    try:
        after = snapshot()
    except (OSError, subprocess.CalledProcessError):
        after = None
    if after != before:
        result["passed"] = False
        result["changed"] = True
        result["reason"] = "Code changed during the run"
        if after:
            result["commit_after"] = after[0]
    # Keep each run as evidence as well as the latest result for the commit.
    write_result(logs / "result.json", result)
    destination = directory / (commit + ".json")
    if result.get("changed"):
        destination = logs / "result.json"
        print("Not filed for " + commit[:7] + ": the code changed during the run")
    elif dirty:
        destination = logs / "result.json"
        print("Not filed for " + commit[:7] + ": the tree has uncommitted changes")
    else:
        write_result(destination, result)
    print("Checks passed" if result["passed"] else result["reason"])
    for key in result["failed"]:
        print("Failed: " + key)
    print("Result: " + str(destination))
    print("Run result: " + str(logs / "result.json"))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
