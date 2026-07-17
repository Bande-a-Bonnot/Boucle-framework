#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Windows safety-check docs =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])

checks = [
    (
        repo / "README.md",
        [
            "install.ps1 verify` and `install.ps1 doctor` use native PowerShell hooks",
            "install.ps1 check` command runs the bash-based safety-check audit",
            "Git Bash, WSL, or another `bash` on PATH",
        ],
    ),
    (
        repo / "tools" / "README.md",
        [
            "No bash or jq is required for the standalone Windows hooks",
            "install.ps1 check",
            "similar. The safety-check summary",
            "Git Bash or WSL for safety-check",
        ],
    ),
    (
        repo / "tools" / "safety-check" / "README.md",
        [
            "On Windows, run under WSL or Git Bash",
            "check",
            "bash-based safety-check script",
        ],
    ),
]

failures = []
for path, snippets in checks:
    text = path.read_text()
    for snippet in snippets:
        if snippet not in text:
            failures.append(f"{path.relative_to(repo)}: missing {snippet!r}")

if failures:
    raise SystemExit("Windows safety-check docs drifted:\n" + "\n".join(failures))

print("Windows safety-check docs OK")
PY
