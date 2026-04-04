#!/usr/bin/env python3
"""Sync limitations.json from limitations.html — extracts all entries from HTML source of truth."""
import json
import re
import sys

html = open("docs/limitations.html").read()
existing = json.load(open("docs/limitations.json"))
existing_ids = {e["id"] for e in existing["entries"]}

# Parse entries from HTML
# Format: <div class="kl-entry" data-category="..." data-issues="..." id="..." data-severity="...">
pattern = re.compile(
    r'class="kl-entry"\s+data-category="([^"]+)"\s+data-issues="([^"]*)"\s+id="([^"]+)"\s+data-severity="([^"]+)"'
)
# Title: <h3>...</h3> right after the entry div
title_pattern = re.compile(r'<h3[^>]*>(.*?)</h3>', re.DOTALL)
# Description: <p> after the title
desc_pattern = re.compile(r'<p>(.*?)</p>', re.DOTALL)

entries_html = list(pattern.finditer(html))
missing = []

for match in entries_html:
    cat, issues_str, entry_id, severity = match.groups()
    if entry_id not in existing_ids:
        # Find title after this match
        after = html[match.end():match.end() + 2000]
        t = title_pattern.search(after)
        title = t.group(1).strip() if t else entry_id
        # Clean HTML from title
        title = re.sub(r'<[^>]+>', '', title).strip()
        # Find description
        d = desc_pattern.search(after)
        desc = d.group(1).strip() if d else ""
        desc = re.sub(r'<[^>]+>', '', desc).strip()
        # Parse issues
        issue_links = []
        if issues_str:
            for num in issues_str.split(","):
                num = num.strip()
                if num:
                    issue_links.append(f"https://github.com/anthropics/claude-code/issues/{num}")

        entry = {
            "id": entry_id,
            "title": title,
            "category": cat,
            "severity": severity,
            "issues": issue_links,
            "description": desc[:500] if desc else title,
        }
        missing.append(entry)

if not missing:
    print(f"JSON is in sync with HTML ({len(existing['entries'])} entries)")
    sys.exit(0)

print(f"Found {len(missing)} entries in HTML missing from JSON:")
for e in missing:
    print(f"  + {e['id']} [{e['severity']}] [{e['category']}]")

# Add missing entries
existing["entries"].extend(missing)
existing["count"] = len(existing["entries"])

# Rebuild category and severity counts
cats = {}
sevs = {}
for e in existing["entries"]:
    c = e.get("category", "Unknown")
    s = e.get("severity", "unknown")
    cats[c] = cats.get(c, 0) + 1
    sevs[s] = sevs.get(s, 0) + 1
existing["categories"] = cats
existing["severity_counts"] = sevs

with open("docs/limitations.json", "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")

print(f"\nJSON updated: {existing['count']} entries total ({len(missing)} added)")
