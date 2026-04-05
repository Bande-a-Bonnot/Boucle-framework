#!/usr/bin/env python3
"""Find KL entries that mention fixes or specific versions."""
import json, re

with open("docs/limitations.json") as f:
    data = json.load(f)

entries = data["entries"]

for e in entries:
    desc = str(e.get("description", "")) + " " + str(e.get("workaround", ""))
    lower = desc.lower()
    if any(kw in lower for kw in ["fixed in", "resolved in", "patched in", "v2.1.9", "v2.0.", "mitigated"]):
        versions = re.findall(r"v2\.\d+\.\d+", desc)
        fix_mentions = re.findall(r"(?i)(fixed|resolved|patched|mitigated)\s+(?:in\s+)?v[\d.]+", desc)
        print(f"KL#{e['id']}: {e['title'][:75]}")
        if versions:
            print(f"  Versions: {versions}")
        if fix_mentions:
            print(f"  Fix refs: {fix_mentions}")
        excerpt = desc[:250].replace("\n", " ")
        print(f"  Excerpt: {excerpt}")
        print()

# Also find the straggler category
straggler = [e for e in entries if e.get("category") == "Hook behavior gaps"]
if straggler:
    print(f"--- Straggler category 'Hook behavior gaps': {len(straggler)} entries ---")
    for e in straggler:
        print(f"  KL#{e['id']}: {e['title'][:75]}")
