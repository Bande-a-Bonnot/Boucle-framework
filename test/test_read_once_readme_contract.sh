#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
README="$REPO_ROOT/tools/read-once/README.md"

echo "== read-once README contract =="
python3 - <<'PY' "$README"
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
flat = " ".join(text.split())

required = [
    'default warn mode, the response uses `permissionDecision: "allow"`',
    'so the Read still runs',
    'In deny mode, the same reason is returned with `permissionDecision: "deny"`',
    'Cross-session cache hits are always allowed for the first read in the current session',
    "Claude Code's Edit precondition",
]

missing = [snippet for snippet in required if snippet not in flat]
if missing:
    raise SystemExit(
        "read-once README no longer documents warn/deny behavior:\n"
        + "\n".join(missing)
    )

banned = [
    "Claude then proceeds without the redundant read",
    "No loss of information",
]

violations = [snippet for snippet in banned if snippet in text]
if violations:
    raise SystemExit(
        "read-once README contains ambiguous deny-mode wording:\n"
        + "\n".join(violations)
    )

print("read-once README contract OK")
PY
