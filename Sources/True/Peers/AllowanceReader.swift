import Foundation

/// `allowance_reader.py` — the one reader of this Mac's Claude plan allowance. A python3 file True writes
/// beside `true-group` in the agents' bin dir (`~/.true/bin`); `true-group allowance post`, the prompt hook (`touch`)
/// and builder's `plan_reading` all import or call it, so every consumer gets the same figure.
enum AllowanceReader {
    static func scriptPath(_ paths: AgentPaths) -> String { paths.binDir.appendingPathComponent("allowance_reader.py").path }

    static func install(paths: AgentPaths) {
        try? FileManager.default.createDirectory(at: paths.binDir, withIntermediateDirectories: true)
        let path = scriptPath(paths)
        if (try? String(contentsOfFile: path, encoding: .utf8)) != source { try? source.write(toFile: path, atomically: true, encoding: .utf8) }
        chmod(path, 0o755)
    }

    static let source: String = #"""
#!/usr/bin/env python3
"""allowance_reader.py - the one reader of a Mac's Claude plan allowance.

`read_allowance(home) -> dict` takes the newest `rate_limit_info` from two places:
  (a) builder streams  <home>/.claude/builders/*/stream.jsonl  (if this Mac has any)
  (b) its own probe file  <home>/.true/group/allowance/probe.jsonl
and returns the allowance reading {device, plan_tier, has_five_h, weekly_pct, weekly_resets_at, five_h_pct,
five_h_read_at, weekly_read_at, pooled_pts_week, lend, last_prompt_at} (device is added by the poster; percentages
are 0-100) plus `windows`, the same per-window shape builder's plan_reading returns (util is 0-1).

Staleness is per window, as in builder: weekly is stale after 6 h, the 5 h window after 30 min; a stale window is
unknown (its pct is None). A window whose reset time has passed reads 0.

Probe: when lend is on and a window the plan has is stale, one tiny Haiku turn is run
  claude -p "ok" --model haiku --max-turns 1 --output-format stream-json --verbose
keeping only the rate-limit events, at most once per 30 minutes. It costs one Haiku turn on that plan.
The probe sets TRUE_GROUP_PROBE=1 so the prompt hook does not count it as the owner typing.

CLI (used by the prompt hook and by hand):  allowance_reader.py touch | read | probe
"""
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

WINDOWS = {"five_hour": "five", "seven_day": "seven"}
STALE = {"five": ("BUILDER_PLAN_STALE", 1800), "seven": ("BUILDER_PLAN_STALE_7D", 21600)}
PROBE_EVERY = 1800
TIERS = ("pro", "max5", "max20")
DEFAULT_HOLD = 70.0
DEFAULT_CAP = 35.0


def env_float(name, default):
    try:
        return float(os.environ.get(name) or default)
    except ValueError:
        return default


# ------------------------------------------------------------ stream scanning (the same rules builder always used)
def ingest(raw, out):
    """Fold one stream line's plan-window reading (if any) into out: {short: (util, resets_at, status)}."""
    try:
        ev = raw if isinstance(raw, dict) else json.loads(raw)
    except ValueError:
        return
    if not isinstance(ev, dict):
        return
    uw = ev.get("unifiedWindows")
    if not isinstance(uw, dict):
        uw = (ev.get("rate_limit_info") or {}).get("unifiedWindows") if isinstance(ev.get("rate_limit_info"), dict) else None
    if isinstance(uw, dict):
        for wk, short in WINDOWS.items():
            w = uw.get(wk)
            if isinstance(w, dict) and w.get("utilization") is not None:
                out[short] = (float(w["utilization"]), w.get("resetsAt"), w.get("status"))
    info = ev.get("rate_limit_info") if isinstance(ev.get("rate_limit_info"), dict) else ev
    if isinstance(info, dict) and info.get("status") == "rejected" and info.get("rateLimitType") in WINDOWS:
        out[WINDOWS[info["rateLimitType"]]] = (1.0, info.get("resetsAt"), "rejected")


def scan_stream(path):
    """Newest reading per window from the last 64KB of one stream (older reports fall back to the last 32MB)."""
    out = {}
    try:
        size = path.stat().st_size
        with open(path, "rb") as f:
            f.seek(max(0, size - 65536))
            data = f.read()
    except OSError:
        return out
    lines = data.split(b"\n")
    if size > 65536:
        lines = lines[1:]
    for raw in lines:
        ingest(raw, out)
    if size > 65536 and len(out) < len(WINDOWS):
        older = {}
        try:
            with open(path, "rb") as f:
                f.seek(max(0, size - 32 * 2**20))
                for raw in f:
                    if b"unifiedWindows" in raw or b"rateLimitType" in raw:
                        ingest(raw, older)
        except OSError:
            pass
        for k, v in older.items():
            out.setdefault(k, v)
    return out


def stream_windows(builders_root):
    """Newest reading per window across the five newest builder streams: {short: {util, resets_at, status, seen_at}}."""
    streams = []
    for p in glob.glob(str(Path(builders_root) / "*" / "stream.jsonl")):
        try:
            streams.append((os.stat(p).st_mtime, Path(p)))
        except OSError:
            continue
    streams.sort(key=lambda x: -x[0])
    reading = {"five": None, "seven": None}
    for mtime, p in streams[:5]:
        for short, (util, resets, status) in scan_stream(p).items():
            cur = reading[short]
            if cur is None or mtime > cur["seen_at"]:
                reading[short] = {"util": util, "resets_at": resets, "status": status, "seen_at": mtime}
    return reading


def probe_windows(gd):
    """Newest reading per window from probe.jsonl lines {"read_at": t, "event": {...}}."""
    reading = {"five": None, "seven": None}
    try:
        lines = (Path(gd) / "allowance" / "probe.jsonl").read_text().splitlines()
    except OSError:
        return reading
    for raw in lines:
        try:
            row = json.loads(raw)
            at = float(row["read_at"])
        except (ValueError, KeyError, TypeError):
            continue
        got = {}
        ingest(row.get("event"), got)
        for short, (util, resets, status) in got.items():
            cur = reading[short]
            if cur is None or at >= cur["seen_at"]:
                reading[short] = {"util": util, "resets_at": resets, "status": status, "seen_at": at}
    return reading


def newest(a, b):
    return {k: max((x for x in (a.get(k), b.get(k)) if x), key=lambda w: w["seen_at"], default=None) for k in ("five", "seven")}


def window_view(w, short, now):
    """-> (util 0-1 or None, known). Same rules as builder_lanes.window_view."""
    if not w:
        return None, False
    resets = w.get("resets_at")
    if isinstance(resets, (int, float)) and resets < now:
        return 0.0, True
    if now - float(w.get("seen_at") or 0) > env_float(*STALE[short]):
        return None, False
    return float(w["util"]), True


# ------------------------------------------------------------ small files under ~/.true/group
def group_dir(home):
    return Path(os.environ.get("TRUE_GROUP_DIR") or (Path(home) / ".true" / "group"))


def load_config(gd):
    try:
        c = json.loads((Path(gd) / "config.json").read_text())
        return c if isinstance(c, dict) else {}
    except (OSError, ValueError):
        return {}


def read_last_prompt(gd):
    try:
        return float((Path(gd) / "last-prompt").read_text().strip())
    except (OSError, ValueError):
        return None


def pooled_pts_week(gd, resets_at, now):
    """Points pooled work spent this week: sum of `pts` in pooled.jsonl lines {"at": t, "pts": n} since the week began."""
    start = (resets_at - 7 * 86400) if isinstance(resets_at, (int, float)) and resets_at > now else now - 7 * 86400
    total = 0.0
    try:
        for raw in (Path(gd) / "pooled.jsonl").read_text().splitlines():
            try:
                row = json.loads(raw)
                if float(row["at"]) >= start:
                    total += max(0.0, float(row["pts"]))
            except (ValueError, KeyError, TypeError):
                continue
    except OSError:
        pass
    return round(total, 2)


def read_lend(gd):
    try:
        return "off" if (Path(gd) / "lend").read_text().strip() == "off" else "on"
    except OSError:
        return "on"


# ------------------------------------------------------------ the probe
def claude_bin():
    for c in (os.environ.get("ALLOWANCE_CLAUDE"), os.environ.get("CLAUDE_BIN"), shutil.which("claude"),
              str(Path.home() / ".local" / "bin" / "claude")):
        if c and os.path.exists(c):
            return c
    return None


def run_probe(gd, now, runner=None):
    """One tiny Haiku turn; keep only the rate-limit events. -> {"ran", "got_weekly", "error"}. Never raises."""
    base = Path(gd) / "allowance"
    base.mkdir(parents=True, exist_ok=True)
    last = base / "probe.last"
    try:
        if now - float(json.loads(last.read_text())["at"]) < PROBE_EVERY:
            return {"ran": False, "got_weekly": False, "error": "probed less than 30 minutes ago"}
    except (OSError, ValueError, KeyError):
        pass
    result = {"ran": True, "got_weekly": False, "error": None}
    try:
        exe = claude_bin()
        if not exe:
            raise RuntimeError("claude is not installed")
        cmd = [exe, "-p", "ok", "--model", "haiku", "--max-turns", "1", "--output-format", "stream-json", "--verbose"]
        with tempfile.TemporaryDirectory() as cwd:
            proc = (runner or subprocess.run)(cmd, capture_output=True, text=True, timeout=120, cwd=cwd, stdin=subprocess.DEVNULL,
                                              env=dict(os.environ, TRUE_GROUP_PROBE="1"))
        kept = []
        for raw in (proc.stdout or "").splitlines():
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if isinstance(ev, dict) and (ev.get("type") == "rate_limit_event" or "rate_limit_info" in ev):
                got = {}
                ingest(ev, got)
                if got:
                    slim = ({"type": "rate_limit_event", "rate_limit_info": ev["rate_limit_info"]} if isinstance(ev.get("rate_limit_info"), dict)
                            else {k: ev[k] for k in ("type", "unifiedWindows", "status", "rateLimitType", "resetsAt") if k in ev})
                    kept.append({"read_at": now, "event": slim})
                    result["got_weekly"] = result["got_weekly"] or "seven" in got
        if kept:
            path = base / "probe.jsonl"
            old = path.read_text().splitlines() if path.exists() else []
            tmp = path.with_suffix(".tmp")
            tmp.write_text("\n".join((old + [json.dumps(k) for k in kept])[-20:]) + "\n")
            os.replace(tmp, path)
        else:
            result["error"] = "the probe stream carried no rate-limit window"
    except Exception as exc:  # a failed probe is a reading that stays unknown, never a crash
        result["error"] = f"{type(exc).__name__}: {exc}"[:200]
    last.write_text(json.dumps({"at": now, "error": result["error"], "got_weekly": result["got_weekly"]}))
    return result


# ------------------------------------------------------------ the reader
def read_allowance(home=None, *, builders_root=None, now=None, probe=False, lend=None, runner=None):
    home = Path(home) if home else Path.home()
    now = time.time() if now is None else now
    gd = group_dir(home)
    root = Path(builders_root) if builders_root else home / ".claude" / "builders"
    cfg = load_config(gd)
    lend = lend or read_lend(gd)
    windows = newest(stream_windows(root), probe_windows(gd))
    has_five = cfg["has_five_h"] if isinstance(cfg.get("has_five_h"), bool) else windows["five"] is not None
    probed = None
    if probe and lend != "off":
        need = [s for s, applies in (("seven", True), ("five", has_five)) if applies and not window_view(windows[s], s, now)[1]]
        if need:
            probed = run_probe(gd, now, runner)
            if probed["ran"]:
                windows = newest(stream_windows(root), probe_windows(gd))
                if not isinstance(cfg.get("has_five_h"), bool):
                    has_five = windows["five"] is not None
    w_util, w_known = window_view(windows["seven"], "seven", now)
    f_util, f_known = window_view(windows["five"], "five", now)
    tier = cfg.get("plan_tier") if cfg.get("plan_tier") in TIERS else None
    weekly = windows["seven"]
    resets = weekly["resets_at"] if weekly and isinstance(weekly.get("resets_at"), (int, float)) else None
    reading = {
        "plan_tier": tier, "has_five_h": has_five,
        "weekly_pct": round(w_util * 100, 2) if w_known else None, "weekly_resets_at": resets,
        "five_h_pct": round(f_util * 100, 2) if (has_five and f_known) else None,
        "five_h_read_at": windows["five"]["seen_at"] if (has_five and windows["five"]) else None,
        "weekly_read_at": weekly["seen_at"] if weekly else None,
        "pooled_pts_week": pooled_pts_week(gd, resets, now), "lend": lend, "last_prompt_at": read_last_prompt(gd),
        "pooled_hold_weekly": float(cfg.get("pooled_hold_weekly", DEFAULT_HOLD)),
        "lend_cap_pts": float(cfg.get("lend_cap_pts", DEFAULT_CAP)),
        "windows": windows,
    }
    if probed:
        reading["probe"] = probed
    return reading


def main(argv):
    cmd = argv[0] if argv else "read"
    home = Path.home()
    if cmd == "touch":  # the prompt hook: the time only, never any text (stdin is not read)
        if os.environ.get("TRUE_GROUP_PROBE"):
            return 0
        gd = group_dir(home)
        gd.mkdir(parents=True, exist_ok=True)
        tmp = gd / "last-prompt.tmp"
        tmp.write_text(str(int(time.time())) + "\n")
        os.replace(tmp, gd / "last-prompt")
        return 0
    if cmd in ("read", "probe"):
        print(json.dumps(read_allowance(home, probe=(cmd == "probe")), indent=1, sort_keys=True))
        return 0
    sys.stderr.write("usage: allowance_reader.py touch | read | probe\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
"""#
}
