#!/usr/bin/env python3
"""Fix category names in limitations.html to match consolidated JSON."""
import re

MERGE_MAP = {
    "Hook system design constraints": "Hook behavior & events",
    "Permissions & security": "Permission system",
    "Subagents & isolation": "Subagent & spawned agents",
    "Authentication & configuration": "Configuration behavior",
    "MCP & plugins": "MCP & plugin issues",
    "Environment & shell": "Platform & compatibility",
    "Bash & shell execution": "Platform & compatibility",
    "Desktop & Cowork": "Desktop & IDE integration",
    "CLAUDE.md & memory": "Context & memory",
    "Context management": "Context & memory",
    "Model behavior & instructions": "Context & memory",
    "plugin-management": "MCP & plugin issues",
}

# Also handle &amp; encoded versions
MERGE_MAP_ENCODED = {}
for k, v in MERGE_MAP.items():
    MERGE_MAP_ENCODED[k.replace("&", "&amp;")] = v.replace("&", "&amp;")

HTML_PATH = "docs/limitations.html"

with open(HTML_PATH) as f:
    content = f.read()

changes = 0

# Fix data-category attributes (both & and &amp; encoded)
for old, new in {**MERGE_MAP, **MERGE_MAP_ENCODED}.items():
    pattern_attr = f'data-category="{old}"'
    replacement_attr = f'data-category="{new}"'
    if pattern_attr in content:
        count = content.count(pattern_attr)
        content = content.replace(pattern_attr, replacement_attr)
        changes += count
        print(f"  data-category: {old} -> {new} ({count}x)")

# Fix kl-cat span text (both & and &amp; encoded)
for old, new in {**MERGE_MAP, **MERGE_MAP_ENCODED}.items():
    pattern_span = f'<span class="kl-cat">{old}</span>'
    replacement_span = f'<span class="kl-cat">{new}</span>'
    if pattern_span in content:
        count = content.count(pattern_span)
        content = content.replace(pattern_span, replacement_span)
        changes += count
        print(f"  kl-cat span: {old} -> {new} ({count}x)")

with open(HTML_PATH, "w") as f:
    f.write(content)

print(f"\nTotal replacements: {changes}")

# Verify
import subprocess
result = subprocess.run(
    ["grep", "-o", 'data-category="[^"]*"', HTML_PATH],
    capture_output=True, text=True
)
cats = {}
for line in result.stdout.strip().split("\n"):
    cats[line] = cats.get(line, 0) + 1
print("\nFinal category distribution:")
for c, n in sorted(cats.items(), key=lambda x: -x[1]):
    print(f"  {n:>4}  {c}")
print(f"  Total categories: {len(cats)}")
