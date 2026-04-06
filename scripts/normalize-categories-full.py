#!/usr/bin/env python3
"""Normalize KL categories in both HTML and JSON - merge near-duplicates."""
import json
import re
import subprocess

CATEGORY_MAP = {
    "hooks": "Hook behavior & events",
    "Hooks": "Hook behavior & events",
    "Hook behavior": "Hook behavior & events",
    "Hook event lifecycle": "Hook behavior & events",
    "Permissions & security": "Permission system",
    "agents": "Subagent & spawned agents",
    "Agent & subagent": "Subagent & spawned agents",
    "Multi-agent & subprocesses": "Subagent & spawned agents",
    "MCP & plugins": "MCP & plugin issues",
    "Platform & environment": "Platform & compatibility",
    "Configuration": "Configuration behavior",
    "Safety & guardrails": "Security & trust boundaries",
    "Performance": "Performance & cost",
    "CLI & flags": "CLI & terminal",
    "Memory & instructions": "Context & memory",
    "Model behavior": "Tool behavior",
    "CLAUDE.md enforcement": "Tool behavior",
    "Stability": "Data integrity",
    "Networking": "Platform & compatibility",
}

# Also need HTML-encoded versions
CATEGORY_MAP_AMP = {}
for old, new in CATEGORY_MAP.items():
    CATEGORY_MAP_AMP[old.replace("&", "&amp;")] = new.replace("&", "&amp;")

# --- Fix HTML ---
HTML_PATH = "docs/limitations.html"
with open(HTML_PATH) as f:
    html = f.read()

html_changes = 0
for old, new in CATEGORY_MAP.items():
    # data-category attribute (may use & or &amp;)
    for old_v, new_v in [(old, new), (old.replace("&", "&amp;"), new.replace("&", "&amp;"))]:
        attr_old = f'data-category="{old_v}"'
        attr_new = f'data-category="{new_v}"'
        if attr_old in html:
            count = html.count(attr_old)
            html = html.replace(attr_old, attr_new)
            html_changes += count
            print(f"  HTML attr: {old_v} -> {new_v} ({count}x)")

        span_old = f'<span class="kl-cat">{old_v}</span>'
        span_new = f'<span class="kl-cat">{new_v}</span>'
        if span_old in html:
            count = html.count(span_old)
            html = html.replace(span_old, span_new)
            html_changes += count
            print(f"  HTML span: {old_v} -> {new_v} ({count}x)")

with open(HTML_PATH, "w") as f:
    f.write(html)

print(f"\nHTML: {html_changes} replacements")

# --- Fix JSON ---
JSON_PATH = "docs/limitations.json"
with open(JSON_PATH) as f:
    data = json.load(f)

json_changes = 0
for entry in data["entries"]:
    old_cat = entry.get("category", "")
    if old_cat in CATEGORY_MAP:
        entry["category"] = CATEGORY_MAP[old_cat]
        json_changes += 1

# Rebuild category counts
cats = {}
for entry in data["entries"]:
    c = entry.get("category", "unknown")
    cats[c] = cats.get(c, 0) + 1
data["categories"] = dict(sorted(cats.items(), key=lambda x: -x[1]))

with open(JSON_PATH, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print(f"JSON: {json_changes} entries re-categorized")
print(f"\nFinal categories ({len(cats)}):")
for c, n in sorted(cats.items(), key=lambda x: -x[1]):
    print(f"  {n:>4}  {c}")
