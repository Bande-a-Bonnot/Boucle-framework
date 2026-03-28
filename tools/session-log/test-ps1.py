#!/usr/bin/env python3
"""Tests for session-log PowerShell hook (hook.ps1).

Requires: pwsh (PowerShell 7+).
Skips all tests if pwsh is not found.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook.ps1")
PASS = 0
FAIL = 0
TOTAL = 0
GREEN = "\033[0;32m"
RED = "\033[0;31m"
NC = "\033[0m"


def has_pwsh():
    try:
        subprocess.run(["pwsh", "--version"], capture_output=True, timeout=10)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def run_hook(json_input, env_overrides=None):
    env = os.environ.copy()
    for key in ["SESSION_LOG_DISABLED", "SESSION_LOG_DIR",
                "CLAUDE_SESSION_ID", "CLAUDE_CODE_SESSION"]:
        env.pop(key, None)
    if env_overrides:
        env.update(env_overrides)
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", HOOK],
        input=json.dumps(json_input),
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    return result.stdout.strip(), result.returncode


def make_input(tool_name, tool_input=None, tool_response=None):
    payload = {"tool_name": tool_name, "tool_input": tool_input or {}}
    if tool_response is not None:
        payload["tool_response"] = tool_response
    return payload


def assert_test(desc, condition, detail=""):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    if condition:
        PASS += 1
        print(f"  {GREEN}PASS{NC}: {desc}")
    else:
        FAIL += 1
        extra = f" ({detail})" if detail else ""
        print(f"  {RED}FAIL{NC}: {desc}{extra}")


def read_log_entries(log_dir):
    """Read all JSONL entries from today's log file."""
    date_str = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    log_file = os.path.join(log_dir, f"{date_str}.jsonl")
    if not os.path.exists(log_file):
        return []
    entries = []
    with open(log_file, "r") as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))
    return entries


def main():
    global PASS, FAIL, TOTAL

    if not has_pwsh():
        print("SKIP: pwsh not found, skipping PowerShell tests")
        sys.exit(0)

    print("session-log PowerShell hook tests")
    print("=" * 40)

    # --- Basic logging ---
    print("\nBasic logging:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "CLAUDE_SESSION_ID": "test-session-1"}

        # Log a Bash command
        run_hook(make_input("Bash", {"command": "echo hello"}), env_overrides=env)
        entries = read_log_entries(log_dir)
        assert_test("logs Bash command", len(entries) >= 1,
                     f"got {len(entries)} entries")
        if entries:
            e = entries[-1]
            assert_test("entry has timestamp", "ts" in e)
            assert_test("entry has session", e.get("session") == "test-session-1")
            assert_test("entry has tool=Bash", e.get("tool") == "Bash")
            assert_test("entry has detail", e.get("detail") == "echo hello")

        # Log a Read tool
        run_hook(make_input("Read", {"file_path": "/tmp/test.txt"}),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("Read: tool=Read", e.get("tool") == "Read")
        assert_test("Read: detail is file_path", e.get("detail") == "/tmp/test.txt")

        # Log a Write tool
        run_hook(make_input("Write", {"file_path": "/tmp/out.txt"}),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("Write: tool=Write", e.get("tool") == "Write")
        assert_test("Write: detail is file_path", e.get("detail") == "/tmp/out.txt")

        # Log a Grep tool
        run_hook(make_input("Grep", {"pattern": "TODO", "path": "src/"}),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("Grep: tool=Grep", e.get("tool") == "Grep")
        assert_test("Grep: detail has pattern", "TODO" in e.get("detail", ""))

        # Log a Glob tool
        run_hook(make_input("Glob", {"pattern": "**/*.rs"}),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("Glob: tool=Glob", e.get("tool") == "Glob")

    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    # --- Error detection ---
    print("\nError detection:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "CLAUDE_SESSION_ID": "test-session-2"}

        # Bash error (exit code)
        run_hook(make_input("Bash", {"command": "false"},
                            tool_response="Exit code 1\ncommand not found"),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("detects exit code", e.get("exit_code") == 1)
        assert_test("detects error status", e.get("status") == "error")

        # Bash success (no error)
        run_hook(make_input("Bash", {"command": "echo ok"},
                            tool_response="ok"),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("success: exit_code=0", e.get("exit_code") == 0)
        assert_test("success: no error status", e.get("status") is None)

        # Permission denied
        run_hook(make_input("Read", {"file_path": "/etc/shadow"},
                            tool_response="error: Permission denied"),
                 env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("detects permission denied", e.get("status") == "error")

    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    # --- Command truncation ---
    print("\nCommand truncation:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "CLAUDE_SESSION_ID": "test-session-3"}
        long_cmd = "echo " + "x" * 300
        run_hook(make_input("Bash", {"command": long_cmd}), env_overrides=env)
        entries = read_log_entries(log_dir)
        e = entries[-1]
        assert_test("truncates long commands to 200 chars",
                     len(e.get("detail", "")) <= 200,
                     f"detail length: {len(e.get('detail', ''))}")
    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    # --- Disabled ---
    print("\nDisabled:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "SESSION_LOG_DISABLED": "1",
               "CLAUDE_SESSION_ID": "test-disabled"}
        run_hook(make_input("Bash", {"command": "echo hello"}), env_overrides=env)
        entries = read_log_entries(log_dir)
        assert_test("SESSION_LOG_DISABLED=1 writes nothing", len(entries) == 0,
                     f"got {len(entries)} entries")
    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    # --- Session ID fallback ---
    print("\nSession ID:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir,
               "CLAUDE_CODE_SESSION": "fallback-session"}
        run_hook(make_input("Bash", {"command": "echo test"}), env_overrides=env)
        entries = read_log_entries(log_dir)
        if entries:
            assert_test("CLAUDE_CODE_SESSION as fallback",
                         entries[-1].get("session") == "fallback-session")
        else:
            assert_test("CLAUDE_CODE_SESSION as fallback", False, "no entries")
    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    # --- Log directory creation ---
    print("\nLog directory:")
    base = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    log_dir = os.path.join(base, "deep", "nested", "dir")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "CLAUDE_SESSION_ID": "test-mkdir"}
        run_hook(make_input("Bash", {"command": "echo test"}), env_overrides=env)
        assert_test("creates nested log directory", os.path.isdir(log_dir))
        entries = read_log_entries(log_dir)
        assert_test("writes to created directory", len(entries) >= 1)
    finally:
        shutil.rmtree(base, ignore_errors=True)

    # --- JSONL format ---
    print("\nJSONL format:")
    log_dir = tempfile.mkdtemp(prefix="session-log-ps1-test-")
    try:
        env = {"SESSION_LOG_DIR": log_dir, "CLAUDE_SESSION_ID": "test-jsonl"}
        run_hook(make_input("Bash", {"command": "echo 1"}), env_overrides=env)
        run_hook(make_input("Read", {"file_path": "/tmp/a.txt"}), env_overrides=env)
        run_hook(make_input("Write", {"file_path": "/tmp/b.txt"}), env_overrides=env)
        entries = read_log_entries(log_dir)
        assert_test("multiple entries in JSONL", len(entries) == 3,
                     f"got {len(entries)}")
        if len(entries) == 3:
            assert_test("entries have different tools",
                         entries[0]["tool"] == "Bash" and
                         entries[1]["tool"] == "Read" and
                         entries[2]["tool"] == "Write")
    finally:
        shutil.rmtree(log_dir, ignore_errors=True)

    print(f"\n{'=' * 40}")
    print(f"Results: {PASS} passed, {FAIL} failed, {TOTAL} total")
    if FAIL > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
