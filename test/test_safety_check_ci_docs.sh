#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Safety-check CI docs =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
path = repo / "tools" / "safety-check" / "CI.md"
text = path.read_text()
flat_text = " ".join(text.split())

snippets = [
    "Native PowerShell hooks in CI",
    "pwsh -File ./hooks/git-safe.ps1",
    "The Ubuntu workflow above does not install",
    "install.ps1 verify",
    "Git Bash, WSL, or a runner with bash",
]

missing = [snippet for snippet in snippets if snippet not in text]
if "without bash or jq" not in flat_text:
    missing.append("without bash or jq")
if missing:
    raise SystemExit(
        "Safety-check CI docs drifted:\n"
        + "\n".join(f"{path.relative_to(repo)}: missing {snippet!r}" for snippet in missing)
    )

print("Safety-check CI docs OK")
PY
