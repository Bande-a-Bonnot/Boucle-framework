#!/usr/bin/env python3
"""Tests for branch-guard PowerShell hook (hook.ps1).

Requires: pwsh (PowerShell 7+) and git.
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
    """Run the PS1 hook with JSON piped to stdin. Returns (stdout, returncode)."""
    env = os.environ.copy()
    # Clean up env vars that might interfere
    for key in ["BRANCH_GUARD_DISABLED", "BRANCH_GUARD_PROTECTED",
                "BRANCH_GUARD_CONFIG", "BRANCH_GUARD_LOG"]:
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


def make_hook_input(tool_name, command=None):
    """Build a Claude Code hook input payload."""
    payload = {"tool_name": tool_name, "tool_input": {}}
    if command is not None:
        payload["tool_input"]["command"] = command
    return payload


def assert_blocked(desc, json_input, env_overrides=None, cwd=None):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, env_overrides, cwd)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected block, got: {stdout!r})")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def assert_allowed(desc, json_input, env_overrides=None, cwd=None):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, rc = run_hook(json_input, env_overrides, cwd)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected allow, got: {stdout!r})")
        else:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def setup_git_repo():
    """Create a temp git repo on 'main' branch with one commit."""
    tmpdir = tempfile.mkdtemp(prefix="branch-guard-ps1-test-")
    subprocess.run(["git", "init", "-q", tmpdir], check=True, capture_output=True)
    subprocess.run(["git", "config", "user.email", "test@test.local"],
                   cwd=tmpdir, check=True, capture_output=True)
    subprocess.run(["git", "config", "user.name", "Test"],
                   cwd=tmpdir, check=True, capture_output=True)
    subprocess.run(["git", "checkout", "-q", "-b", "main"],
                   cwd=tmpdir, capture_output=True)
    subprocess.run(["git", "commit", "-q", "--allow-empty", "-m", "init"],
                   cwd=tmpdir, check=True, capture_output=True)
    return tmpdir


def main():
    global PASS, FAIL, TOTAL

    if not has_pwsh():
        print("SKIP: pwsh not found, skipping PowerShell tests")
        sys.exit(0)

    print("branch-guard PowerShell hook tests")
    print("=" * 40)

    repo = setup_git_repo()
    try:
        # --- Basic blocking ---
        print("\nDefault protected branches:")
        assert_blocked(
            "block git commit on main",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # Switch to master
        subprocess.run(["git", "checkout", "-q", "-b", "master"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "block git commit on master",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # Switch to production
        subprocess.run(["git", "checkout", "-q", "-b", "production"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "block git commit on production",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # Switch to release
        subprocess.run(["git", "checkout", "-q", "-b", "release"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "block git commit on release",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # --- Allowing ---
        print("\nAllowed operations:")
        subprocess.run(["git", "checkout", "-q", "-b", "feature/test"],
                       cwd=repo, capture_output=True)
        assert_allowed(
            "allow git commit on feature branch",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # Amend on main should be allowed
        subprocess.run(["git", "checkout", "-q", "main"],
                       cwd=repo, capture_output=True)
        assert_allowed(
            "allow git commit --amend on main",
            make_hook_input("Bash", "git commit --amend -m 'fix'"),
            cwd=repo,
        )

        # Non-Bash tools should pass through
        assert_allowed(
            "allow non-Bash tool (Write)",
            make_hook_input("Write", None),
            cwd=repo,
        )

        assert_allowed(
            "allow non-Bash tool (Read)",
            make_hook_input("Read", None),
            cwd=repo,
        )

        # Non-git commands should pass through
        assert_allowed(
            "allow non-git bash command",
            make_hook_input("Bash", "echo hello"),
            cwd=repo,
        )

        assert_allowed(
            "allow git status (not a commit)",
            make_hook_input("Bash", "git status"),
            cwd=repo,
        )

        assert_allowed(
            "allow git push (not a commit)",
            make_hook_input("Bash", "git push origin main"),
            cwd=repo,
        )

        # --- Env var override ---
        print("\nEnvironment variable overrides:")
        subprocess.run(["git", "checkout", "-q", "main"],
                       cwd=repo, capture_output=True)
        assert_allowed(
            "BRANCH_GUARD_DISABLED=1 allows commit on main",
            make_hook_input("Bash", "git commit -m 'test'"),
            env_overrides={"BRANCH_GUARD_DISABLED": "1"},
            cwd=repo,
        )

        assert_blocked(
            "BRANCH_GUARD_PROTECTED=main blocks commit on main",
            make_hook_input("Bash", "git commit -m 'test'"),
            env_overrides={"BRANCH_GUARD_PROTECTED": "main"},
            cwd=repo,
        )

        subprocess.run(["git", "checkout", "-q", "feature/test"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "BRANCH_GUARD_PROTECTED=feature/test blocks custom branch",
            make_hook_input("Bash", "git commit -m 'test'"),
            env_overrides={"BRANCH_GUARD_PROTECTED": "feature/test"},
            cwd=repo,
        )

        # --- Config file ---
        print("\nConfig file:")
        config_path = os.path.join(repo, ".branch-guard")
        with open(config_path, "w") as f:
            f.write("# Custom config\nprotect: staging\nprotect: main\n")

        subprocess.run(["git", "checkout", "-q", "-b", "staging"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "config file: block commit on staging",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        subprocess.run(["git", "checkout", "-q", "main"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "config file: block commit on main",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # production not in config, should be allowed
        subprocess.run(["git", "checkout", "-q", "production"],
                       cwd=repo, capture_output=True)
        assert_allowed(
            "config file: allow commit on production (not in config)",
            make_hook_input("Bash", "git commit -m 'test'"),
            cwd=repo,
        )

        # --- Edge cases ---
        print("\nEdge cases:")
        subprocess.run(["git", "checkout", "-q", "main"],
                       cwd=repo, capture_output=True)
        assert_blocked(
            "git commit with heredoc message",
            make_hook_input("Bash", "git commit -m \"$(cat <<'EOF'\ntest message\nEOF\n)\""),
            cwd=repo,
        )

        assert_allowed(
            "empty command",
            make_hook_input("Bash", ""),
            cwd=repo,
        )

    finally:
        shutil.rmtree(repo, ignore_errors=True)

    # --- Summary ---
    print(f"\n{'=' * 40}")
    print(f"Results: {PASS} passed, {FAIL} failed, {TOTAL} total")
    if FAIL > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
