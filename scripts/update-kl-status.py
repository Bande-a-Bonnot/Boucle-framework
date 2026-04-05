#!/usr/bin/env python3
"""Update KL entry statuses."""
import json
import os

script_dir = os.path.dirname(os.path.abspath(__file__))
repo_root = os.path.dirname(script_dir)
json_path = os.path.join(repo_root, "docs", "limitations.json")

with open(json_path) as f:
    data = json.load(f)

updates = {
    "teammate-hooks-bypass": {
        "status": "fixed",
        "description": "PreToolUse hooks in settings.json now fire for teammates spawned via Agent tool. Fixed as of April 2026 (issue #42385 completed). Previously, teammates ran with no PreToolUse hook coverage, allowing them to bypass all hook-based guardrails."
    },
}

for entry in data["entries"]:
    eid = entry["id"]
    if eid in updates:
        for key, val in updates[eid].items():
            old = entry.get(key)
            entry[key] = val
            print(f"Updated {eid}.{key}: {old} -> {val[:60]}...")

# Recalculate status summary
statuses = {}
for e in data["entries"]:
    s = e.get("status", "open")
    statuses[s] = statuses.get(s, 0) + 1
data["status_summary"] = statuses

# Recalculate severity counts
sevs = {}
cats = {}
for e in data["entries"]:
    sevs[e["severity"]] = sevs.get(e["severity"], 0) + 1
    cats[e["category"]] = cats.get(e["category"], 0) + 1
data["severity_counts"] = sevs
data["categories"] = cats

with open(json_path, "w") as f:
    json.dump(data, f, indent=2)

print(f"\nStatus summary: {statuses}")
print(f"Total entries: {data['count']}")
