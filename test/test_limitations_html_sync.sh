#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== limitations html sync =="
python3 "$REPO_ROOT/scripts/sync-limitations-html.py"
python3 - <<'PY' "$REPO_ROOT"
import json
import re
import sys
from pathlib import Path

repo = Path(sys.argv[1])
data = json.loads((repo / "docs" / "limitations.json").read_text())
html = (repo / "docs" / "limitations.html").read_text()

json_ids = {entry["id"] for entry in data["entries"]}
html_ids = set(re.findall(r'<div class="kl-entry"[^>]*id="([^"]+)"', html))

if len(html_ids) != len(data["entries"]):
    raise SystemExit(f"expected {len(data['entries'])} html entries, found {len(html_ids)}")

missing = sorted(json_ids - html_ids)
extra = sorted(html_ids - json_ids)
if missing or extra:
    raise SystemExit(f"html/json id drift detected: missing={missing[:10]} extra={extra[:10]}")

if f'<span id="total-count">{len(data["entries"])}</span>' not in html:
    raise SystemExit("total-count does not match limitations.json")

print(f"HTML sync OK: {len(html_ids)} entries")
PY
