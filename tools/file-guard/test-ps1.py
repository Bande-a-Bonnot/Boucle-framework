#!/usr/bin/env python3
"""Tests for file-guard PowerShell hook (hook.ps1).

Requires: pwsh (PowerShell 7+).
Skips all tests if pwsh is not found.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

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


def run_hook(json_input, env_overrides=None, cwd=None):
    env = os.environ.copy()
    for key in ["FILE_GUARD_CONFIG", "FILE_GUARD_DISABLED", "FILE_GUARD_LOG"]:
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
        cwd=cwd,
    )
    return result.stdout.strip(), result.returncode


def make_input(tool_name, tool_input=None):
    payload = {"tool_name": tool_name, "tool_input": tool_input or {}}
    return payload


def assert_blocked(desc, json_input, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected block, got: {stdout!r})")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def assert_allowed(desc, json_input, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected allow, got: {stdout!r})")
        else:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def main():
    global PASS, FAIL, TOTAL

    if not has_pwsh():
        print("SKIP: pwsh not found, skipping PowerShell tests")
        sys.exit(0)

    print("file-guard PowerShell hook tests")
    print("=" * 40)

    # --- Relative path rejection (always active, no config needed) ---
    print("\nRelative path rejection:")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        assert_blocked("block Write with relative path",
                       make_input("Write", {"file_path": "src/main.rs"}),
                       cwd=tmpdir)
        assert_blocked("block Edit with relative path",
                       make_input("Edit", {"file_path": "config.toml",
                                           "old_string": "a", "new_string": "b"}),
                       cwd=tmpdir)
        assert_allowed("allow Write with absolute path",
                       make_input("Write", {"file_path": "/tmp/test.txt"}),
                       cwd=tmpdir)
        assert_allowed("allow Read with relative path (read not blocked)",
                       make_input("Read", {"file_path": "src/main.rs"}),
                       cwd=tmpdir)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- Write protection ---
    print("\nWrite protection (default section):")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        config = os.path.join(tmpdir, ".file-guard")
        with open(config, "w") as f:
            f.write("# Protected files\n.env\nsecrets/\n*.pem\ncredentials.*\n")

        env = {"FILE_GUARD_CONFIG": config}

        # Write-protect .env
        assert_blocked("block Write to .env",
                       make_input("Write", {"file_path": "/project/.env"}),
                       env_overrides=env, cwd=tmpdir)
        assert_blocked("block Edit of .env",
                       make_input("Edit", {"file_path": "/project/.env",
                                           "old_string": "a", "new_string": "b"}),
                       env_overrides=env, cwd=tmpdir)

        # Read should be allowed (write-protect, not deny)
        assert_allowed("allow Read of .env (write-protect only)",
                       make_input("Read", {"file_path": "/project/.env"}),
                       env_overrides=env, cwd=tmpdir)

        # Directory prefix: secrets/ — use path under CWD so normalization works
        secrets_path = os.path.join(tmpdir, "secrets", "api-key.txt")
        assert_blocked("block Write to secrets/ dir",
                       make_input("Write", {"file_path": secrets_path}),
                       env_overrides=env, cwd=tmpdir)

        # Glob: *.pem
        assert_blocked("block Write to *.pem",
                       make_input("Write", {"file_path": "/project/server.pem"}),
                       env_overrides=env, cwd=tmpdir)

        # Glob: credentials.*
        assert_blocked("block Write to credentials.json",
                       make_input("Write", {"file_path": "/project/credentials.json"}),
                       env_overrides=env, cwd=tmpdir)

        # Non-protected file should pass
        assert_allowed("allow Write to unprotected file",
                       make_input("Write", {"file_path": "/project/src/main.rs"}),
                       env_overrides=env, cwd=tmpdir)

        # Bash commands that modify protected files
        assert_blocked("block bash rm of .env",
                       make_input("Bash", {"command": "rm .env"}),
                       env_overrides=env, cwd=tmpdir)
        assert_blocked("block bash cat > .env",
                       make_input("Bash", {"command": "cat > .env"}),
                       env_overrides=env, cwd=tmpdir)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- Deny section ---
    print("\nDeny section (blocks all access):")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        config = os.path.join(tmpdir, ".file-guard")
        with open(config, "w") as f:
            f.write(".env\n[deny]\n.ssh/\nid_rsa\n")

        env = {"FILE_GUARD_CONFIG": config}

        # Deny blocks reads — use CWD-relative paths so normalization works
        ssh_id = os.path.join(tmpdir, ".ssh", "id_rsa")
        assert_blocked("block Read of .ssh/ file",
                       make_input("Read", {"file_path": ssh_id}),
                       env_overrides=env, cwd=tmpdir)
        id_rsa_path = os.path.join(tmpdir, "id_rsa")
        assert_blocked("block Read of id_rsa",
                       make_input("Read", {"file_path": id_rsa_path}),
                       env_overrides=env, cwd=tmpdir)

        # Deny also blocks writes
        ssh_config = os.path.join(tmpdir, ".ssh", "config")
        assert_blocked("block Write to denied file",
                       make_input("Write", {"file_path": ssh_config}),
                       env_overrides=env, cwd=tmpdir)

        # Deny blocks bash access
        assert_blocked("block bash cat of denied file",
                       make_input("Bash", {"command": "cat ~/.ssh/id_rsa"}),
                       env_overrides=env, cwd=tmpdir)

        # Write-protected file still readable
        assert_allowed("allow Read of .env (write section)",
                       make_input("Read", {"file_path": "/project/.env"}),
                       env_overrides=env, cwd=tmpdir)

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- No config file ---
    print("\nNo config file:")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        # With no .file-guard, only relative path rejection is active
        assert_allowed("allow Write when no config",
                       make_input("Write", {"file_path": "/project/.env"}),
                       cwd=tmpdir)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- Disabled ---
    print("\nDisabled:")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        config = os.path.join(tmpdir, ".file-guard")
        with open(config, "w") as f:
            f.write(".env\n")
        env = {"FILE_GUARD_CONFIG": config, "FILE_GUARD_DISABLED": "1"}
        assert_allowed("FILE_GUARD_DISABLED=1 allows everything",
                       make_input("Write", {"file_path": "/project/.env"}),
                       env_overrides=env, cwd=tmpdir)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    # --- Comments and blank lines in config ---
    print("\nConfig parsing:")
    tmpdir = tempfile.mkdtemp(prefix="file-guard-ps1-test-")
    try:
        config = os.path.join(tmpdir, ".file-guard")
        with open(config, "w") as f:
            f.write("# This is a comment\n\n  \n.env  # inline comment\n\nsecrets/\n")
        env = {"FILE_GUARD_CONFIG": config}
        assert_blocked("handles comments and blank lines",
                       make_input("Write", {"file_path": "/project/.env"}),
                       env_overrides=env, cwd=tmpdir)
        secrets_key = os.path.join(tmpdir, "secrets", "key.txt")
        assert_blocked("handles trailing comment after pattern",
                       make_input("Write", {"file_path": secrets_key}),
                       env_overrides=env, cwd=tmpdir)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print(f"\n{'=' * 40}")
    print(f"Results: {PASS} passed, {FAIL} failed, {TOTAL} total")
    if FAIL > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
