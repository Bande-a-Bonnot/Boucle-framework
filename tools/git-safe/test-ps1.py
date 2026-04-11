#!/usr/bin/env python3
"""Tests for git-safe PowerShell hook (hook.ps1).

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
    for key in ["GIT_SAFE_DISABLED", "GIT_SAFE_CONFIG", "GIT_SAFE_LOG"]:
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
    return result.stdout.strip(), result.stderr.strip(), result.returncode


def make_input(tool_name, command=None):
    payload = {"tool_name": tool_name, "tool_input": {}}
    if command is not None:
        payload["tool_input"]["command"] = command
    return payload


def assert_blocked(desc, json_input, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, stderr, rc = run_hook(json_input, **kwargs)
        if rc == 2 and not stdout and "git-safe:" in stderr:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(
                f"  {RED}FAIL{NC}: {desc} "
                f"(expected rc=2 with stderr reason, got rc={rc} stdout={stdout!r} stderr={stderr!r})"
            )
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def assert_allowed(desc, json_input, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, stderr, rc = run_hook(json_input, **kwargs)
        if rc == 0 and not stdout and not stderr:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(
                f"  {RED}FAIL{NC}: {desc} "
                f"(expected clean allow, got rc={rc} stdout={stdout!r} stderr={stderr!r})"
            )
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def main():
    global PASS, FAIL, TOTAL

    if not has_pwsh():
        print("SKIP: pwsh not found, skipping PowerShell tests")
        sys.exit(0)

    tmpdir = tempfile.mkdtemp(prefix="git-safe-ps1-test-")

    print("git-safe PowerShell hook tests")
    print("=" * 40)

    try:
        # --- Force push ---
        print("\nForce push:")
        assert_blocked("block git push --force",
                       make_input("Bash", "git push --force origin main"))
        assert_blocked("block git push -f",
                       make_input("Bash", "git push -f origin main"))
        assert_allowed("allow --force-with-lease",
                       make_input("Bash", "git push --force-with-lease origin main"))
        assert_allowed("allow normal git push",
                       make_input("Bash", "git push origin main"))

        # Force push to main/master always blocked
        print("\nForce push to main/master (extra protection):")
        assert_blocked("block force push to main",
                       make_input("Bash", "git push --force origin main"))
        assert_blocked("block force push to master",
                       make_input("Bash", "git push --force origin master"))

        # --- Reset --hard ---
        print("\nReset --hard:")
        assert_blocked("block git reset --hard",
                       make_input("Bash", "git reset --hard"))
        assert_blocked("block git reset --hard HEAD~1",
                       make_input("Bash", "git reset --hard HEAD~1"))
        assert_allowed("allow git reset --soft",
                       make_input("Bash", "git reset --soft HEAD~1"))
        assert_allowed("allow git reset (no flags)",
                       make_input("Bash", "git reset"))

        # --- Checkout destructive ---
        print("\nCheckout (destructive):")
        assert_blocked("block git checkout .",
                       make_input("Bash", "git checkout ."))
        assert_blocked("block git checkout -- file",
                       make_input("Bash", "git checkout -- src/main.rs"))
        assert_blocked("block git checkout HEAD -- file",
                       make_input("Bash", "git checkout HEAD -- src/main.rs"))
        assert_allowed("allow git checkout -b new-branch",
                       make_input("Bash", "git checkout -b new-branch"))
        assert_allowed("allow git checkout existing-branch",
                       make_input("Bash", "git checkout feature/test"))

        # --- Restore ---
        print("\nRestore:")
        assert_blocked("block git restore (no --staged)",
                       make_input("Bash", "git restore src/main.rs"))
        assert_blocked("block git restore --source",
                       make_input("Bash", "git restore --source HEAD~1 src/main.rs"))
        assert_blocked("block git restore -s",
                       make_input("Bash", "git restore -s HEAD~1 src/main.rs"))
        assert_blocked("block git restore --worktree",
                       make_input("Bash", "git restore --worktree src/main.rs"))
        assert_blocked("block git restore -W",
                       make_input("Bash", "git restore -W src/main.rs"))
        assert_allowed("allow git restore --staged",
                       make_input("Bash", "git restore --staged src/main.rs"))

        # --- Clean ---
        print("\nClean:")
        assert_blocked("block git clean -f",
                       make_input("Bash", "git clean -f"))
        assert_blocked("block git clean -fd",
                       make_input("Bash", "git clean -fd"))
        assert_blocked("block git clean -fdx",
                       make_input("Bash", "git clean -fdx"))
        assert_allowed("allow git clean -n (dry run)",
                       make_input("Bash", "git clean -n"))

        # --- Branch -D ---
        print("\nBranch -D:")
        assert_blocked("block git branch -D",
                       make_input("Bash", "git branch -D feature/old"))
        assert_allowed("allow git branch -d (lowercase)",
                       make_input("Bash", "git branch -d feature/old"))

        # --- Stash drop/clear ---
        print("\nStash drop/clear:")
        assert_blocked("block git stash drop",
                       make_input("Bash", "git stash drop"))
        assert_blocked("block git stash clear",
                       make_input("Bash", "git stash clear"))
        assert_allowed("allow git stash",
                       make_input("Bash", "git stash"))
        assert_allowed("allow git stash pop",
                       make_input("Bash", "git stash pop"))

        # --- No-verify ---
        print("\nNo-verify detection:")
        assert_blocked("block git commit --no-verify",
                       make_input("Bash", 'git commit --no-verify -m "skip"'))
        assert_blocked("block git commit -n (shorthand)",
                       make_input("Bash", 'git commit -n -m "skip"'))
        assert_blocked("block git commit -an (combined)",
                       make_input("Bash", 'git commit -an -m "skip"'))
        assert_blocked("block git merge --no-verify",
                       make_input("Bash", "git merge --no-verify feature"))
        assert_blocked("block git push --no-verify",
                       make_input("Bash", "git push --no-verify origin main"))
        assert_blocked("block git cherry-pick --no-verify",
                       make_input("Bash", "git cherry-pick --no-verify abc123"))
        assert_blocked("block git revert --no-verify",
                       make_input("Bash", "git revert --no-verify HEAD"))
        assert_blocked("block git am --no-verify",
                       make_input("Bash", "git am --no-verify patch.mbox"))
        assert_allowed("allow git commit (normal)",
                       make_input("Bash", 'git commit -m "normal"'))
        assert_allowed("allow git commit -a (not -n)",
                       make_input("Bash", 'git commit -a -m "normal"'))
        assert_allowed("allow git commit --amend (no skip)",
                       make_input("Bash", 'git commit --amend -m "amend"'))

        # --- Push --delete ---
        print("\nPush --delete:")
        assert_blocked("block git push --delete",
                       make_input("Bash", "git push origin --delete feature/old"))
        assert_blocked("block git push origin :branch",
                       make_input("Bash", "git push origin :feature/old"))
        assert_allowed("allow normal push",
                       make_input("Bash", "git push origin feature/new"))

        # --- Reflog ---
        print("\nReflog:")
        assert_blocked("block git reflog expire",
                       make_input("Bash", "git reflog expire --expire=now --all"))
        assert_blocked("block git reflog delete",
                       make_input("Bash", "git reflog delete HEAD@{1}"))
        assert_allowed("allow git reflog (read-only)",
                       make_input("Bash", "git reflog"))

        # --- Non-git / non-Bash ---
        print("\nPassthrough:")
        assert_allowed("allow non-Bash tool",
                       make_input("Write"))
        assert_allowed("allow non-git command",
                       make_input("Bash", "echo hello"))
        assert_allowed("allow empty command",
                       make_input("Bash", ""))

        # --- Disabled ---
        print("\nDisabled:")
        assert_allowed("GIT_SAFE_DISABLED=1 allows destructive op",
                       make_input("Bash", "git push --force origin main"),
                       env_overrides={"GIT_SAFE_DISABLED": "1"})

        # --- Config allowlist ---
        print("\nConfig allowlist:")
        config_path = os.path.join(tmpdir, ".git-safe")
        with open(config_path, "w") as f:
            f.write("# Allow force push for this project\nallow: push --force\n")
        assert_allowed("config allows push --force",
                       make_input("Bash", "git push --force origin feature"),
                       env_overrides={"GIT_SAFE_CONFIG": config_path})
        # No-verify allowed by config
        with open(config_path, "a") as f:
            f.write("allow: no-verify\n")
        assert_allowed("config allows no-verify",
                       make_input("Bash", 'git commit --no-verify -m "allowed"'),
                       env_overrides={"GIT_SAFE_CONFIG": config_path})
        # Force push to main still blocked even with allowlist
        assert_blocked("config: force push to main still blocked",
                       make_input("Bash", "git push --force origin main"),
                       env_overrides={"GIT_SAFE_CONFIG": config_path})

    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)

    print(f"\n{'=' * 40}")
    print(f"Results: {PASS} passed, {FAIL} failed, {TOTAL} total")
    if FAIL > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
