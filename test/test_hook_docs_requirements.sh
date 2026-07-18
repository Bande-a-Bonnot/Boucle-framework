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
        "most hook slots use jq",
        "**Windows (PowerShell 7+)",
        "Project hooks skipped from subdirectories",
        "ancestor project settings warning",
        "If you use `claude -w`, also install [worktree-guard]",
        "delete unmerged or unpushed commits",
    ],
    repo / "tools" / "README.md": [
        "**macOS / Linux:** bash, python3, and jq",
        "installers use python3 to manage",
        "safety-check uses python3",
        "6 of the 8 hook slots use jq",
        "**Windows:** [PowerShell 7+]",
        "Git Bash or WSL for safety-check",
        "stderr` and exit code 2",
        'JSON `permissionDecision: "deny"`',
        "not a universal hard-block contract",
        "Ancestor project settings warning",
        "subdirectory launches can skip root project hooks",
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
}

missing = []
for path, snippets in docs.items():
    flat_text = " ".join(path.read_text().split())
    for snippet in snippets:
        if snippet not in flat_text:
            missing.append(f"{path.relative_to(repo)}: missing {snippet!r}")

if missing:
    raise SystemExit("Hook requirements docs drifted:\n" + "\n".join(missing))

print("Hook docs requirements OK")
PY
