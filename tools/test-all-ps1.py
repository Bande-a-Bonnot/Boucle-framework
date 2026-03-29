#!/usr/bin/env python3
"""Run all PowerShell hook tests.

Requires: pwsh (PowerShell 7+) and python3.
Skips gracefully if pwsh is not available.
"""

import os
import subprocess
import sys

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
HOOKS_WITH_PS1_TESTS = [
    "bash-guard",
    "branch-guard",
    "file-guard",
    "git-safe",
    "read-once",
    "session-log",
    "worktree-guard",
]

GREEN = "\033[0;32m"
RED = "\033[0;31m"
YELLOW = "\033[0;33m"
NC = "\033[0m"


def has_pwsh():
    try:
        subprocess.run(["pwsh", "--version"], capture_output=True, timeout=10)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def main():
    if not has_pwsh():
        print(f"{YELLOW}SKIP{NC}: pwsh not found, skipping all PowerShell tests")
        sys.exit(0)

    passed = 0
    failed = 0
    skipped = 0

    for hook in HOOKS_WITH_PS1_TESTS:
        test_file = os.path.join(TOOLS_DIR, hook, "test-ps1.py")
        if not os.path.exists(test_file):
            print(f"{YELLOW}SKIP{NC}: {hook}/test-ps1.py not found")
            skipped += 1
            continue

        print(f"\n{'=' * 50}")
        print(f"Running {hook} PowerShell tests...")
        print(f"{'=' * 50}")

        result = subprocess.run(
            [sys.executable, test_file],
            timeout=120,
        )

        if result.returncode == 0:
            passed += 1
        else:
            failed += 1

    print(f"\n{'=' * 50}")
    print(f"PowerShell test summary: {passed} suites passed, "
          f"{failed} failed, {skipped} skipped")
    print(f"{'=' * 50}")

    if failed > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
