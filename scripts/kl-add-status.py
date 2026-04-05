#!/usr/bin/env python3
"""Add status and fixed_in fields to KL entries. Also merge straggler categories."""
import json

FIXED_MAP = {
    "pretooluse-hook-allow-no-longer-bypasses-deny-rules": "v2.1.77",
    "managed-policy-ask-rules-no-longer-bypassed-by-user-allow-ru": "v2.1.74",
    "disableallhooks-now-respects-managed-settings-hierarchy": "v2.1.49",
    "find-command-injection-cve": "v2.0.72",
    "posttooluse-format-on-save-breaks-consecutive-edits": "v2.1.90",
    "powershell-trailing-ampersand-bypass": "v2.1.90",
    "subagent-spawning-fails-after-tmux-window-kill": "v2.1.92",
    "stop-hooks-fail-on-small-model-ok-false": "v2.1.92",
    "plugin-mcp-stuck-connecting-duplicate-connector": "v2.1.92",
    "stop-hooks-fail-on-small-model-rejection-preventcontinuation-broken": "v2.1.92",
}

MITIGATED = {
    "context-compaction-invalidates-stateful-hooks": "PostCompact hook available since v2.1.89",
}

CATEGORY_MERGE = {
    "Hook behavior gaps": "Hook behavior & events",
}

with open("docs/limitations.json") as f:
    data = json.load(f)

entries = data["entries"]
fixed_count = 0
mitigated_count = 0
merged_count = 0

for e in entries:
    eid = e["id"]

    # Add status and fixed_in
    if eid in FIXED_MAP:
        e["status"] = "fixed"
        e["fixed_in"] = FIXED_MAP[eid]
        fixed_count += 1
    elif eid in MITIGATED:
        e["status"] = "mitigated"
        e["mitigation_note"] = MITIGATED[eid]
        mitigated_count += 1
    else:
        e["status"] = "open"

    # Merge straggler categories
    cat = e.get("category", "")
    if cat in CATEGORY_MERGE:
        e["category"] = CATEGORY_MERGE[cat]
        merged_count += 1

# Update category counts in header
cats = {}
for e in entries:
    c = e.get("category", "unknown")
    cats[c] = cats.get(c, 0) + 1
data["categories"] = dict(sorted(cats.items(), key=lambda x: -x[1]))

# Add status summary
data["status_summary"] = {
    "open": sum(1 for e in entries if e.get("status") == "open"),
    "fixed": sum(1 for e in entries if e.get("status") == "fixed"),
    "mitigated": sum(1 for e in entries if e.get("status") == "mitigated"),
}

with open("docs/limitations.json", "w") as f:
    json.dump(data, f, indent=2)

print(f"Updated {len(entries)} entries:")
print(f"  {fixed_count} marked FIXED")
print(f"  {mitigated_count} marked MITIGATED")
print(f"  {merged_count} categories merged")
print(f"  {len(entries) - fixed_count - mitigated_count} remain OPEN")
print(f"Categories now: {len(cats)}")
for k, v in sorted(cats.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")
