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

    # Test 10: Failure tracking - no failures
    print("Test: No failures")
    home = os.path.join(tmpdir, "nofail")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-04.jsonl"), [
        {"ts": "2026-02-04T09:00:00Z", "session": "s1", "tool": "Bash", "detail": "ls", "cwd": "/p", "exit_code": 0},
        {"ts": "2026-02-04T09:00:01Z", "session": "s1", "tool": "Read", "detail": "/a.rs", "cwd": "/p"},
    ])
    out = run_report(home, ["2026-02-04"])
    check("Errors: none" in out, "reports no errors when clean")

    # Test 11: Failure tracking - with failures
    print("Test: With failures")
    home = os.path.join(tmpdir, "withfail")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-05.jsonl"), [
        {"ts": "2026-02-05T09:00:00Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/p", "exit_code": 0},
        {"ts": "2026-02-05T09:00:10Z", "session": "s1", "tool": "Bash", "detail": "git push origin main", "cwd": "/p", "exit_code": 128, "status": "error"},
        {"ts": "2026-02-05T09:00:20Z", "session": "s1", "tool": "Read", "detail": "/missing.rs", "cwd": "/p", "status": "error"},
        {"ts": "2026-02-05T09:00:30Z", "session": "s1", "tool": "Bash", "detail": "cargo build", "cwd": "/p", "exit_code": 0},
    ])
    out = run_report(home, ["2026-02-05"])
    check("Errors: 2/4 (50%)" in out, "counts error rate")
    check("git push origin main" in out, "lists failed command")
    check("exit 128" in out, "shows exit code")
    check("Failed operations:" in out, "shows failure section header")

    # Test 12: Failure tracking - exit_code 1 without status field
    print("Test: Exit code without status field")
    home = os.path.join(tmpdir, "exitonly")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-06.jsonl"), [
        {"ts": "2026-02-06T09:00:00Z", "session": "s1", "tool": "Bash", "detail": "npm test", "cwd": "/p", "exit_code": 1},
        {"ts": "2026-02-06T09:00:10Z", "session": "s1", "tool": "Bash", "detail": "ls", "cwd": "/p", "exit_code": 0},
    ])
    out = run_report(home, ["2026-02-06"])
    check("Errors: 1/2 (50%)" in out, "detects non-zero exit code as error")
    check("npm test" in out, "shows failed npm test")
    check("exit 1" in out, "shows exit code 1")

    # Test 13: Failure tracking - status error without exit_code
    print("Test: Status error without exit code")
    home = os.path.join(tmpdir, "statusonly")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, "2026-02-07.jsonl"), [
        {"ts": "2026-02-07T09:00:00Z", "session": "s1", "tool": "Read", "detail": "/nonexistent", "cwd": "/p", "status": "error"},
        {"ts": "2026-02-07T09:00:10Z", "session": "s1", "tool": "Read", "detail": "/exists.rs", "cwd": "/p"},
        {"ts": "2026-02-07T09:00:20Z", "session": "s1", "tool": "Read", "detail": "/also.rs", "cwd": "/p"},
    ])
    out = run_report(home, ["2026-02-07"])
    check("Errors: 1/3 (33%)" in out, "detects status-only error")
    check("/nonexistent" in out, "shows failed read path")

    # Test 14: --week mode with data
    print("Test: --week trend mode")
    home = os.path.join(tmpdir, "weekmode")
    log_dir = os.path.join(home, ".claude", "session-logs")
    # Create 3 days of data at fixed dates
    from datetime import datetime, timedelta
    today = datetime.utcnow().date()
    day0 = today.isoformat()
    day1 = (today - timedelta(days=1)).isoformat()
    day2 = (today - timedelta(days=2)).isoformat()
    write_jsonl(os.path.join(log_dir, f"{day0}.jsonl"), [
        {"ts": f"{day0}T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/a.rs", "cwd": "/p"},
        {"ts": f"{day0}T10:01:00Z", "session": "s1", "tool": "Bash", "detail": "cargo test", "cwd": "/p", "exit_code": 0},
        {"ts": f"{day0}T10:02:00Z", "session": "s1", "tool": "Write", "detail": "/b.rs", "cwd": "/p"},
    ])
    write_jsonl(os.path.join(log_dir, f"{day1}.jsonl"), [
        {"ts": f"{day1}T08:00:00Z", "session": "s2", "tool": "Read", "detail": "/c.rs", "cwd": "/p"},
        {"ts": f"{day1}T08:01:00Z", "session": "s2", "tool": "Bash", "detail": "npm test", "cwd": "/p", "exit_code": 1},
    ])
    write_jsonl(os.path.join(log_dir, f"{day2}.jsonl"), [
        {"ts": f"{day2}T14:00:00Z", "session": "s3", "tool": "Read", "detail": "/d.rs", "cwd": "/p"},
        {"ts": f"{day2}T14:00:01Z", "session": "s3", "tool": "Edit", "detail": "/e.rs", "cwd": "/p"},
        {"ts": f"{day2}T14:00:02Z", "session": "s4", "tool": "Bash", "detail": "ls", "cwd": "/p", "exit_code": 0},
        {"ts": f"{day2}T14:00:03Z", "session": "s4", "tool": "Bash", "detail": "make", "cwd": "/p", "exit_code": 2, "status": "error"},
    ])
    out = run_report(home, ["--week"])
    check("Session Trends: Last 7 days" in out, "shows week header")
    check(day0 in out, "shows today's date")
    check(day1 in out, "shows yesterday's date")
    check(day2 in out, "shows day before yesterday")
    check("--" in out, "shows dashes for inactive days")
    check("Total" in out, "shows totals row")
    check("Avg/day" in out, "shows averages row")
    check("Busiest" in out, "shows busiest day")
    check("Quietest" in out, "shows quietest day")
    check("Active days:" in out, "shows active day count")

    # Test 15: --week with no data at all
    print("Test: --week with no data")
    home = os.path.join(tmpdir, "weekempty")
    os.makedirs(os.path.join(home, ".claude", "session-logs"), exist_ok=True)
    out = run_report(home, ["--week"])
    check("Session Trends: Last 7 days" in out, "shows header even with no data")
    check("No activity in this period" in out, "reports no activity")

    # Test 16: --days N custom range
    print("Test: --days custom range")
    home = os.path.join(tmpdir, "daysmode")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, f"{day0}.jsonl"), [
        {"ts": f"{day0}T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/a.rs", "cwd": "/p"},
    ])
    out = run_report(home, ["--days", "3"])
    check("Session Trends: Last 3 days" in out, "shows custom day count in header")
    check(day0 in out, "shows today in custom range")

    # Test 17: --week error rate calculation
    print("Test: --week error rates")
    home = os.path.join(tmpdir, "weekerr")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, f"{day0}.jsonl"), [
        {"ts": f"{day0}T09:00:00Z", "session": "s1", "tool": "Bash", "detail": "test", "cwd": "/p", "exit_code": 1},
        {"ts": f"{day0}T09:01:00Z", "session": "s1", "tool": "Bash", "detail": "test2", "cwd": "/p", "exit_code": 0},
        {"ts": f"{day0}T09:02:00Z", "session": "s1", "tool": "Bash", "detail": "test3", "cwd": "/p", "exit_code": 0},
        {"ts": f"{day0}T09:03:00Z", "session": "s1", "tool": "Bash", "detail": "test4", "cwd": "/p", "exit_code": 0},
    ])
    out = run_report(home, ["--week"])
    check("25.0%" in out, "shows correct error rate (1/4 = 25%)")

    # Test 18: --week sessions and file counts
    print("Test: --week column accuracy")
    home = os.path.join(tmpdir, "weekcols")
    log_dir = os.path.join(home, ".claude", "session-logs")
    write_jsonl(os.path.join(log_dir, f"{day0}.jsonl"), [
        {"ts": f"{day0}T10:00:00Z", "session": "s1", "tool": "Read", "detail": "/x.rs", "cwd": "/p"},
        {"ts": f"{day0}T10:00:01Z", "session": "s1", "tool": "Read", "detail": "/y.rs", "cwd": "/p"},
        {"ts": f"{day0}T10:00:02Z", "session": "s2", "tool": "Write", "detail": "/z.rs", "cwd": "/p"},
        {"ts": f"{day0}T10:00:03Z", "session": "s2", "tool": "Edit", "detail": "/w.rs", "cwd": "/p"},
        {"ts": f"{day0}T10:00:04Z", "session": "s2", "tool": "Bash", "detail": "ls", "cwd": "/p", "exit_code": 0},
    ])
    out = run_report(home, ["--week"])
    # 5 calls, 2 sessions, 0 errors, 2 reads, 2 writes, 1 command
    lines = out.strip().split("\n")
    today_line = [l for l in lines if day0 in l][0] if any(day0 in l for l in lines) else ""
    check("5" in today_line, "correct call count in trend line")
    check("2" in today_line, "shows session/file counts")

print()
print(f"Results: {passed} passed, {failed} failed out of {passed + failed} tests")
sys.exit(0 if failed == 0 else 1)
