#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== limitations public count references =="
python3 - <<'PY' "$REPO_ROOT"
import json
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
expected = len(json.loads((repo / "docs" / "limitations.json").read_text())["entries"])

files = [
    repo / "README.md",
    repo / "docs" / "index.html",
    repo / "docs" / "recipes.html",
    repo / "tools" / "README.md",
    repo / "tools" / "enforce" / "README.md",
]

patterns = [
    re.compile(r"(\d+)\s+known Claude Code gaps"),
    re.compile(r"(\d+)\s+Known Limitations"),
    re.compile(r"(\d+)\s+known limitations"),
    re.compile(r"full list of\s+(\d+)\s+known gaps"),
    re.compile(r"(\d+)\s+documented limitations of Claude Code"),
]

failures = []
for path in files:
    for line_no, line in enumerate(path.read_text().splitlines(), start=1):
        if "v0.13.0" in line:
            continue
        if "| Category | Count |" in line:
            failures.append(f"{path.relative_to(repo)}:{line_no}: move limitation category counts to limitations.json")
        for pattern in patterns:
            for match in pattern.finditer(line):
                found = int(match.group(1))
                if found != expected:
                    failures.append(f"{path.relative_to(repo)}:{line_no}: expected {expected}, found {found}")

if failures:
    raise SystemExit("stale public limitation counts:\n" + "\n".join(failures))

print(f"Public limitation counts OK: {expected}")
PY
