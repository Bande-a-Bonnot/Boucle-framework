#!/usr/bin/env python3
"""Tests for session-report."""
import json
import os
import subprocess
import sys
import tempfile

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPORT = os.path.join(SCRIPT_DIR, "report.sh")

passed = 0
failed = 0

def run_report(home_dir, args=None):
    cmd = ["bash", REPORT] + (args or [])
    env = os.environ.copy()
    env["HOME"] = home_dir
    result = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return result.stdout + result.stderr

def check(condition, name):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS: {name}")
    else:
        failed += 1
        print(f"  FAIL: {name}")

def write_jsonl(path, entries):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        for e in entries:
            f.write(json.dumps(e) + "\n")


with tempfile.TemporaryDirectory() as tmpdir:
    # Test 1: No log directory
    print("Test: No log directory")
    home = os.path.join(tmpdir, "nohome")
    os.makedirs(home)
    out = run_report(home)
    check("No session logs found" in out, "reports missing log dir")

    # Test 2: No logs for date
    print("Test: No logs for date")
    home = os.path.join(tmpdir, "emptyhome")
    os.makedirs(os.path.join(home, ".claude", "session-logs"), exist_ok=True)
    out = run_report(home, ["2026-01-01"])
    check("No logs found" in out, "reports no logs for date")

    # Test 3: Empty file
    print("Test: Empty log file")
    home = os.path.join(tmpdir, "emptyfile")
    log_dir = os.path.join(home, ".claude", "session-logs")
    os.makedirs(log_dir, exist_ok=True)
    open(os.path.join(log_dir, "2026-01-01.jsonl"), "w").close()
    out = run_report(home, ["2026-01-01"])
    check("No entries found" in out, "handles empty file")

    # Test 4: Basic report
    print("Test: Basic report")
    home = os.path.join(tmpdir, "basic")
    log_dir = os.path.join(home, ".claude", "session-logs")
    entries = [
        {"ts": "2026-03-07T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/src/main.rs", "cwd": "/project"},
        {"ts": "2026-03-07T10:00:01Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/project"},
        {"ts": "2026-03-07T10:00:05Z", "session": "s1", "tool": "Write", "detail": "/src/lib.rs", "cwd": "/project"},
        {"ts": "2026-03-07T10:01:00Z", "session": "s1", "tool": "Read", "detail": "/Cargo.toml", "cwd": "/project"},
        {"ts": "2026-03-07T10:01:30Z", "session": "s1", "tool": "Edit", "detail": "/src/main.rs", "cwd": "/project"},
    ]
    write_jsonl(os.path.join(log_dir, "2026-03-07.jsonl"), entries)
    out = run_report(home, ["2026-03-07"])
    check("Session Report: 2026-03-07" in out, "shows date label")
    check("Total tool calls: 5" in out, "counts total calls")
    check("Sessions: 1" in out, "counts sessions")
    check("Read" in out, "shows Read tool")
    check("Bash" in out, "shows Bash tool")
    check("Write" in out, "shows Write tool")
    check("Files read: 2" in out, "counts files read")
    check("/src/lib.rs" in out, "shows written file")
    check("cargo test" in out, "shows command")
    check("10:00" in out, "shows hour in distribution")

    # Test 5: Multiple sessions
    print("Test: Multiple sessions")
    home = os.path.join(tmpdir, "multi")
    log_dir = os.path.join(home, ".claude", "session-logs")
    entries = [
        {"ts": "2026-03-07T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/a.rs", "cwd": "/p"},
        {"ts": "2026-03-07T14:00:00Z", "session": "s2", "tool": "Read", "detail": "/b.rs", "cwd": "/p"},
        {"ts": "2026-03-07T14:00:05Z", "session": "s2", "tool": "Grep", "detail": "TODO in /p", "cwd": "/p"},
    ]
    write_jsonl(os.path.join(log_dir, "2026-03-07.jsonl"), entries)
    out = run_report(home, ["2026-03-07"])
    check("Sessions: 2" in out, "counts multiple sessions")
    check("Total tool calls: 3" in out, "counts all calls")

    # Test 6: --all flag
    print("Test: --all flag")
    home = os.path.join(tmpdir, "alltime")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-03-06.jsonl"), [
        {"ts": "2026-03-06T08:00:00Z", "session": "s0", "tool": "Bash", "detail": "ls", "cwd": "/"},
    ])
    write_jsonl(os.path.join(log_dir, "2026-03-07.jsonl"), [
        {"ts": "2026-03-07T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/a", "cwd": "/"},
        {"ts": "2026-03-07T10:00:01Z", "session": "s1", "tool": "Write", "detail": "/b", "cwd": "/"},
    ])
    out = run_report(home, ["--all"])
    check("Session Report: all time" in out, "shows all time label")
    check("Total tool calls: 3" in out, "counts across days")
    check("Sessions: 2" in out, "counts all sessions")

    # Test 7: Invalid JSON lines skipped
    print("Test: Invalid JSON skipped")
    home = os.path.join(tmpdir, "invalid")
    log_dir = os.path.join(home, ".claude", "session-logs")
    os.makedirs(log_dir, exist_ok=True)
    with open(os.path.join(log_dir, "2026-02-01.jsonl"), "w") as f:
        f.write("not valid json\n")
        f.write(json.dumps({"ts": "2026-02-01T12:00:00Z", "session": "s1", "tool": "Read", "detail": "/foo", "cwd": "/"}) + "\n")
        f.write("also bad\n")
        f.write(json.dumps({"ts": "2026-02-01T12:00:01Z", "session": "s1", "tool": "Write", "detail": "/bar", "cwd": "/"}) + "\n")
    out = run_report(home, ["2026-02-01"])
    check("Total tool calls: 2" in out, "skips invalid JSON")

    # Test 8: Repeated commands frequency
    print("Test: Command frequency")
    home = os.path.join(tmpdir, "cmds")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-02.jsonl"), [
        {"ts": "2026-02-02T09:00:00Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/p"},
        {"ts": "2026-02-02T09:00:01Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/p"},
        {"ts": "2026-02-02T09:00:02Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/p"},
        {"ts": "2026-02-02T09:00:03Z", "session": "s1", "tool": "Bash", "detail": "git status", "cwd": "/p"},
    ])
    out = run_report(home, ["2026-02-02"])
    check("Commands run: 4" in out, "counts total commands")
    check("3x" in out, "shows repeated command count")

    # Test 9: Files written list
    print("Test: Written files list")
    home = os.path.join(tmpdir, "writes")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-03.jsonl"), [
        {"ts": "2026-02-03T09:00:00Z", "session": "s1", "tool": "Write", "detail": "/a.txt", "cwd": "/p"},
        {"ts": "2026-02-03T09:00:01Z", "session": "s1", "tool": "Edit", "detail": "/b.txt", "cwd": "/p"},
        {"ts": "2026-02-03T09:00:02Z", "session": "s1", "tool": "Write", "detail": "/c.txt", "cwd": "/p"},
    ])
    out = run_report(home, ["2026-02-03"])
    check("Files written/edited: 3" in out, "counts unique written files")
    check("/a.txt" in out, "lists written file a")
    check("/b.txt" in out, "lists edited file b")
    check("/c.txt" in out, "lists written file c")

print()
print(f"Results: {passed} passed, {failed} failed out of {passed + failed} tests")
sys.exit(0 if failed == 0 else 1)
