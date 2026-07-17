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
    ],
    repo / "tools" / "README.md": [
        "**macOS / Linux:** bash, python3, and jq",
        "installers use python3 to manage",
        "safety-check uses python3",
        "6 of the 8 hook slots use jq",
        "**Windows:** [PowerShell 7+]",
        "Git Bash or WSL for safety-check",
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
