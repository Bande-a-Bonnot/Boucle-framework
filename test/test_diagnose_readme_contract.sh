#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Diagnose README contract =="
python3 - <<'PY' "$REPO_ROOT"
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
readme = repo / "tools" / "diagnose" / "README.md"
text = readme.read_text()

required = [
    "Built from real autonomous-agent loop logs.",
    "- Python 3.8+",
    "- No dependencies (stdlib only)",
]

missing = [snippet for snippet in required if snippet not in text]
if missing:
    raise SystemExit(
        "Diagnose README is missing required wording:\n"
        + "\n".join(repr(snippet) for snippet in missing)
    )

stale_patterns = [
    r"Built from \d+\+ real loops",
    r"\d+\+ real loops of autonomous agent operation",
]

violations = [pattern for pattern in stale_patterns if re.search(pattern, text)]
if violations:
    raise SystemExit(
        "Diagnose README contains frozen loop-count wording:\n"
        + "\n".join(violations)
    )

print("Diagnose README contract OK")
PY
