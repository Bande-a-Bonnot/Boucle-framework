#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== limitations feed sync =="
python3 "$REPO_ROOT/scripts/sync-limitations-artifacts.py"
python3 - <<'PY' "$REPO_ROOT"
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ATOM = {"atom": "http://www.w3.org/2005/Atom"}
repo = Path(sys.argv[1])
data = json.loads((repo / "docs" / "limitations.json").read_text())
root = ET.fromstring((repo / "docs" / "limitations-feed.xml").read_text())

entries = root.findall("atom:entry", ATOM)
expected_entries = list(reversed(data["entries"][-20:]))

if len(entries) != len(expected_entries):
    raise SystemExit(f"expected {len(expected_entries)} feed entries, found {len(entries)}")

feed_updated = root.findtext("atom:updated", namespaces=ATOM)
expected_updated = f"{data['last_updated']}T00:00:00Z"
if feed_updated != expected_updated:
    raise SystemExit(f"feed updated mismatch: expected {expected_updated}, found {feed_updated}")

for xml_entry, json_entry in zip(entries, expected_entries):
    expected_id = f"https://framework.boucle.sh/limitations.html#{json_entry['id']}"
    entry_id = xml_entry.findtext("atom:id", namespaces=ATOM)
    if entry_id != expected_id:
        raise SystemExit(f"feed id mismatch: expected {expected_id}, found {entry_id}")

print(f"Feed sync OK: {len(entries)} entries")
PY
