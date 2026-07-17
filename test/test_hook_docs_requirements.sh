#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Hook docs requirements =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
path = repo / "tools" / "README.md"
text = path.read_text()
flat_text = " ".join(text.split())

snippets = [
    "**macOS / Linux:** bash, python3, and jq",
    "installers use python3 to manage",
    "safety-check uses python3",
    "6 of the 8 hook slots use jq",
    "**Windows:** [PowerShell 7+]",
    "Git Bash or WSL for safety-check",
]

missing = [snippet for snippet in snippets if snippet not in flat_text]
if missing:
    raise SystemExit(
        "Hook requirements docs drifted:\n"
        + "\n".join(f"{path.relative_to(repo)}: missing {snippet!r}" for snippet in missing)
    )

print("Hook docs requirements OK")
PY
