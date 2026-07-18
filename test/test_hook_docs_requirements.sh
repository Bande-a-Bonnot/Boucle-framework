#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Hook docs requirements =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])

docs = {
    repo / "README.md": [
        "**macOS / Linux requirements:** bash, python3, and jq",
        "installer uses python3 to manage",
        "safety-check uses python3",
        "most standalone shell hooks use jq",
        "No hook installation required for the audit",
        "**Windows (PowerShell 7+)",
        "tools/install.ps1) } recommended",
        "Or install all standalone hooks at once",
        "Project hooks skipped from subdirectories",
        "ancestor project settings warning",
        "If you use `claude -w`, also install [worktree-guard]",
        "delete unmerged or unpushed commits",
    ],
    repo / "tools" / "README.md": [
        "**macOS / Linux:** bash, python3, and jq",
        "installers use python3 to manage",
        "safety-check uses python3",
        "6 of the 7 standalone shell hooks use jq",
        "**Windows:** [PowerShell 7+]",
        "Git Bash or WSL for safety-check",
        "tools/install.ps1) } recommended",
        "To choose hooks interactively instead",
        "stderr` and exit code 2",
        'JSON `permissionDecision: "deny"`',
        "not a universal hard-block contract",
        "Ancestor project settings warning",
        "subdirectory launches can skip root project hooks",
    ],
    repo / "tools" / "safety-check" / "README.md": [
        "No hook installation required for the audit",
        "## Requirements",
        "Bash 4+",
        "Python 3 (for JSON parsing of settings.json)",
    ],
    repo / "tools" / "safety-check" / "check.sh": [
        "No hook installation required for the audit",
        "Requires bash and python3",
    ],
    repo / "tools" / "safety-check" / "SUPPORT_EVIDENCE.md": [
        "Do not paste raw hook stderr from a live Claude Code session",
        "prefix hook stderr with the hook command path",
        "safety-check summary is the safer public artifact",
    ],
    repo / "tools" / "safety-check" / "QUICKSTART.md": [
        "Do not paste raw hook stderr from a live Claude Code session",
        "platform can prefix it with the hook command path",
        "safe support evidence guide",
    ],
    repo / "docs" / "index.html": [
        "bash, python3, and jq",
        "No hook installation required for the audit",
        "github.com/anthropics/claude-code/issues/37550",
    ],
}

missing = []
for path, snippets in docs.items():
    flat_text = " ".join(path.read_text().split())
    for snippet in snippets:
        if snippet not in flat_text:
            missing.append(f"{path.relative_to(repo)}: missing {snippet!r}")

if missing:
    raise SystemExit("Hook requirements docs drifted:\n" + "\n".join(missing))

hook_files = sorted((repo / "tools").glob("*/hook.sh"))
jq_hooks = [path for path in hook_files if "jq" in path.read_text()]
expected_count = f"{len(jq_hooks)} of the {len(hook_files)} standalone shell hooks use jq"
if expected_count != "6 of the 7 standalone shell hooks use jq":
    raise SystemExit(
        "Hook jq dependency count changed; update requirements docs and this "
        f"contract together (actual: {expected_count})"
    )

banned = {
    repo / "tools" / "safety-check" / "README.md": [
        "## No dependencies",
    ],
    repo / "tools" / "safety-check" / "check.sh": [
        "No installation, no dependencies",
    ],
}

violations = []
for path, snippets in banned.items():
    text = path.read_text()
    for snippet in snippets:
        if snippet in text:
            violations.append(f"{path.relative_to(repo)}: remove stale {snippet!r}")

if violations:
    raise SystemExit("Hook requirements docs contain stale wording:\n" + "\n".join(violations))

print("Hook docs requirements OK")
PY
