#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Broca init README contract =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
runner = repo / "src" / "runner" / "mod.rs"
text = runner.read_text()

required = [
    "## Requirements",
    "`boucle` to run the agent loop and memory commands",
    "`git` if you want the audit trail and history features",
    "**No database service**",
]

missing = [snippet for snippet in required if snippet not in text]
if missing:
    raise SystemExit(
        "Generated Broca README contract drifted:\n"
        + "\n".join(f"missing {snippet!r}" for snippet in missing)
    )

stale = [
    "**Zero dependencies**",
]

violations = [snippet for snippet in stale if snippet in text]
if violations:
    raise SystemExit(
        "Generated Broca README contains stale dependency wording:\n"
        + "\n".join(f"remove {snippet!r}" for snippet in violations)
    )

print("Broca init README contract OK")
PY
