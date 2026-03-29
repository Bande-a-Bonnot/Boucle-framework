#!/usr/bin/env python3
"""Tests for worktree-guard PowerShell hook (hook.ps1).

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
    for key in ["WORKTREE_GUARD_DISABLED", "WORKTREE_GUARD_LOG",
                "WORKTREE_GUARD_CONFIG"]:
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


def make_input(tool_name):
    return {"tool_name": tool_name, "tool_input": {}}


def assert_blocked(desc, json_input, substring=None, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            if substring and substring not in stdout:
                FAIL += 1
                print(f"  {RED}FAIL{NC}: {desc} (blocked but missing '{substring}' in: {stdout!r})")
            else:
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


def git(args, cwd, check=True):
    """Run a git command."""
    result = subprocess.run(
        ["git"] + args,
        capture_output=True, text=True, cwd=cwd,
    )
    if check and result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {result.stderr}")
    return result.stdout.strip()


def make_repo(tmpdir, name="repo"):
    """Create a bare repo + clone with initial commit and main branch."""
    bare = os.path.join(tmpdir, f"{name}-bare")
    clone = os.path.join(tmpdir, name)
    os.makedirs(bare)
    git(["init", "--bare", bare], cwd=tmpdir)
    git(["clone", bare, clone], cwd=tmpdir)
    # Configure git identity for CI environments
    git(["config", "user.name", "test"], cwd=clone)
    git(["config", "user.email", "test@test.local"], cwd=clone)
    # Initial commit so main exists
    filepath = os.path.join(clone, "README.md")
    with open(filepath, "w") as f:
        f.write("# Test\n")
    git(["add", "README.md"], cwd=clone)
    git(["commit", "-m", "initial"], cwd=clone)
    git(["push", "origin", "main"], cwd=clone)
    return clone


# ============================================================
# Tests
# ============================================================

def test_non_exit_worktree_ignored():
    """Non-ExitWorktree tools should be ignored."""
    for tool in ["Bash", "Read", "Write", "Edit", "EnterWorktree"]:
        assert_allowed(
            f"ignores {tool} tool",
            make_input(tool),
        )


def test_disabled_env():
    """WORKTREE_GUARD_DISABLED=1 disables the hook."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # Create dirty state
        with open(os.path.join(repo, "dirty.txt"), "w") as f:
            f.write("dirty")
        git(["add", "dirty.txt"], cwd=repo)
        # Should be allowed because disabled
        assert_allowed(
            "disabled via env",
            make_input("ExitWorktree"),
            env_overrides={"WORKTREE_GUARD_DISABLED": "1"},
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_clean_repo_allowed():
    """Clean repo should allow ExitWorktree."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        assert_allowed(
            "clean repo allows exit",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_uncommitted_staged_blocked():
    """Staged but uncommitted changes should block."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, "new.txt"), "w") as f:
            f.write("staged")
        git(["add", "new.txt"], cwd=repo)
        assert_blocked(
            "staged changes block",
            make_input("ExitWorktree"),
            substring="uncommitted",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_uncommitted_unstaged_blocked():
    """Modified but unstaged changes should block."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, "README.md"), "a") as f:
            f.write("modified\n")
        assert_blocked(
            "unstaged changes block",
            make_input("ExitWorktree"),
            substring="uncommitted",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_untracked_files_blocked():
    """Untracked files should block."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, "orphan.txt"), "w") as f:
            f.write("untracked")
        assert_blocked(
            "untracked files block",
            make_input("ExitWorktree"),
            substring="untracked",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_unmerged_commits_blocked():
    """Commits not merged into base should block."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        git(["checkout", "-b", "feature"], cwd=repo)
        with open(os.path.join(repo, "feature.txt"), "w") as f:
            f.write("feature work")
        git(["add", "feature.txt"], cwd=repo)
        git(["commit", "-m", "feature commit"], cwd=repo)
        assert_blocked(
            "unmerged commits block",
            make_input("ExitWorktree"),
            substring="unmerged",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_unpushed_commits_blocked():
    """Commits not pushed to upstream should block."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # main tracks origin/main, add a commit without pushing
        with open(os.path.join(repo, "local.txt"), "w") as f:
            f.write("local only")
        git(["add", "local.txt"], cwd=repo)
        git(["commit", "-m", "local commit"], cwd=repo)
        assert_blocked(
            "unpushed commits block",
            make_input("ExitWorktree"),
            substring="unpushed",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_allow_uncommitted():
    """Config 'allow: uncommitted' skips that check."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # Write config
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("allow: uncommitted\nallow: untracked\n")
        # Create dirty state
        with open(os.path.join(repo, "dirty.txt"), "w") as f:
            f.write("dirty")
        git(["add", "dirty.txt"], cwd=repo)
        assert_allowed(
            "config allows uncommitted + untracked",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_allow_untracked():
    """Config 'allow: untracked' skips that check."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("allow: untracked\n")
        with open(os.path.join(repo, "orphan.txt"), "w") as f:
            f.write("untracked")
        assert_allowed(
            "config allows untracked",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_allow_unmerged():
    """Config 'allow: unmerged' skips that check."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        git(["checkout", "-b", "feature"], cwd=repo)
        with open(os.path.join(repo, "feature.txt"), "w") as f:
            f.write("feature")
        git(["add", "feature.txt"], cwd=repo)
        git(["commit", "-m", "feature"], cwd=repo)
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("allow: unmerged\n")
        assert_allowed(
            "config allows unmerged",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_allow_unpushed():
    """Config 'allow: unpushed' skips that check."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("allow: unpushed\n")
        with open(os.path.join(repo, "local.txt"), "w") as f:
            f.write("local")
        git(["add", "local.txt"], cwd=repo)
        git(["commit", "-m", "local"], cwd=repo)
        assert_allowed(
            "config allows unpushed",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_base_override():
    """Config 'base: develop' uses that as base branch."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # Create develop branch with the feature merged
        git(["checkout", "-b", "develop"], cwd=repo)
        with open(os.path.join(repo, "feature.txt"), "w") as f:
            f.write("feature")
        git(["add", "feature.txt"], cwd=repo)
        git(["commit", "-m", "feature on develop"], cwd=repo)
        # Create feature branch from develop (same content)
        git(["checkout", "-b", "feature"], cwd=repo)
        # Config points base to develop, not main
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("base: develop\n")
        assert_allowed(
            "base override to develop allows matching branch",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_squash_merge_detected():
    """Squash-merged branches should be allowed (tier 2 detection)."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # Create feature branch with multiple commits
        git(["checkout", "-b", "feature"], cwd=repo)
        with open(os.path.join(repo, "a.txt"), "w") as f:
            f.write("a")
        git(["add", "a.txt"], cwd=repo)
        git(["commit", "-m", "add a"], cwd=repo)
        with open(os.path.join(repo, "a.txt"), "w") as f:
            f.write("a-final")
        git(["add", "a.txt"], cwd=repo)
        git(["commit", "-m", "update a"], cwd=repo)
        # Squash merge into main
        git(["checkout", "main"], cwd=repo)
        git(["merge", "--squash", "feature"], cwd=repo)
        git(["commit", "-m", "squash merge feature"], cwd=repo)
        # Go back to feature branch — tier 2 should detect content match
        git(["checkout", "feature"], cwd=repo)
        assert_allowed(
            "squash-merged branch allowed (tier 2)",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_not_git_repo():
    """Non-git directory should allow (nothing to protect)."""
    tmpdir = tempfile.mkdtemp()
    try:
        assert_allowed(
            "non-git directory allows exit",
            make_input("ExitWorktree"),
            cwd=tmpdir,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_config_comments_ignored():
    """Comments in config are ignored."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        with open(os.path.join(repo, ".worktree-guard"), "w") as f:
            f.write("# This is a comment\nallow: untracked  # inline comment\n")
        with open(os.path.join(repo, "orphan.txt"), "w") as f:
            f.write("untracked")
        assert_allowed(
            "config comments handled correctly",
            make_input("ExitWorktree"),
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_multiple_issues_first_blocks():
    """Multiple issues present — first check that triggers wins."""
    tmpdir = tempfile.mkdtemp()
    try:
        repo = make_repo(tmpdir)
        # Uncommitted + untracked
        with open(os.path.join(repo, "README.md"), "a") as f:
            f.write("dirty\n")
        with open(os.path.join(repo, "orphan.txt"), "w") as f:
            f.write("untracked")
        assert_blocked(
            "multiple issues: uncommitted blocks first",
            make_input("ExitWorktree"),
            substring="uncommitted",
            cwd=repo,
        )
    finally:
        shutil.rmtree(tmpdir)


# ============================================================

if __name__ == "__main__":
    if not has_pwsh():
        print("SKIP: pwsh not found, skipping worktree-guard PS1 tests")
        sys.exit(0)

    print("worktree-guard PS1 tests")
    print("=" * 40)

    test_non_exit_worktree_ignored()
    test_disabled_env()
    test_clean_repo_allowed()
    test_uncommitted_staged_blocked()
    test_uncommitted_unstaged_blocked()
    test_untracked_files_blocked()
    test_unmerged_commits_blocked()
    test_unpushed_commits_blocked()
    test_config_allow_uncommitted()
    test_config_allow_untracked()
    test_config_allow_unmerged()
    test_config_allow_unpushed()
    test_config_base_override()
    test_squash_merge_detected()
    test_not_git_repo()
    test_config_comments_ignored()
    test_multiple_issues_first_blocks()

    print("=" * 40)
    print(f"Results: {PASS}/{TOTAL} passed, {FAIL} failed")
    sys.exit(1 if FAIL > 0 else 0)
