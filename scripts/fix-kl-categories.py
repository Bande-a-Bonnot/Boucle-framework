#!/usr/bin/env python3
"""Fix category normalization in limitations.json."""
import json

data = json.load(open("docs/limitations.json"))
fixes = {
    "Subagent behavior": "Subagent & spawned agents",
    "Hook behavior": "Hook behavior & events",
}
fixed = 0
for e in data["entries"]:
    if e.get("category") in fixes:
        e["category"] = fixes[e["category"]]
        fixed += 1

cats = {}
sevs = {}
for e in data["entries"]:
    c = e.get("category", "Unknown")
    s = e.get("severity", "unknown")
    cats[c] = cats.get(c, 0) + 1
    sevs[s] = sevs.get(s, 0) + 1
data["categories"] = cats
data["severity_counts"] = sevs

with open("docs/limitations.json", "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"Fixed {fixed} entries. Categories now:")
for k, v in sorted(cats.items(), key=lambda x: -x[1]):
    print(f"  {k}: {v}")
