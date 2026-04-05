#!/usr/bin/env python3
"""Normalize data-category and kl-cat to use & (not &amp;) consistently."""
import re
import subprocess

HTML_PATH = "docs/limitations.html"

CANONICAL = [
    "Hook behavior & events",
    "Hook bypass & evasion",
    "Permission system",
    "Subagent & spawned agents",
    "Configuration behavior",
    "MCP & plugin issues",
    "Platform & compatibility",
    "Desktop & IDE integration",
    "Context & memory",
    "Security & trust boundaries",
    "Scheduling & remote triggers",
    "Performance & cost",
]

with open(HTML_PATH) as f:
    content = f.read()

# For each canonical name, replace the &amp; variant with the & variant
changes = 0
for name in CANONICAL:
    amp_name = name.replace("&", "&amp;")
    if amp_name == name:
        continue  # no & in this name

    # Fix data-category
    old = f'data-category="{amp_name}"'
    new = f'data-category="{name}"'
    if old in content:
        count = content.count(old)
        content = content.replace(old, new)
        changes += count
        print(f"  attr: {amp_name} -> {name} ({count}x)")

    # Fix kl-cat span
    old_span = f'<span class="kl-cat">{amp_name}</span>'
    new_span = f'<span class="kl-cat">{name}</span>'
    if old_span in content:
        count = content.count(old_span)
        content = content.replace(old_span, new_span)
        changes += count
        print(f"  span: {amp_name} -> {name} ({count}x)")

with open(HTML_PATH, "w") as f:
    f.write(content)

print(f"\nTotal fixes: {changes}")

# Verify
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
