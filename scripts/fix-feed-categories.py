#!/usr/bin/env python3
"""Fix category terms in limitations-feed.xml to match consolidated taxonomy."""
import subprocess

FEED_PATH = "docs/limitations-feed.xml"

# In XML, & must be &amp;, so canonical names use &amp;
MERGE_MAP_XML = {
    "Hook system design constraints": "Hook behavior &amp; events",
    "Permissions &amp; security": "Permission system",
    "Subagents &amp; isolation": "Subagent &amp; spawned agents",
    "Authentication &amp; configuration": "Configuration behavior",
    "MCP &amp; plugins": "MCP &amp; plugin issues",
    "Environment &amp; shell": "Platform &amp; compatibility",
    "Bash &amp; shell execution": "Platform &amp; compatibility",
    "Bash & shell execution": "Platform &amp; compatibility",
    "Desktop &amp; Cowork": "Desktop &amp; IDE integration",
    "Desktop & Cowork": "Desktop &amp; IDE integration",
    "CLAUDE.md &amp; memory": "Context &amp; memory",
    "Context management": "Context &amp; memory",
    "Model behavior &amp; instructions": "Context &amp; memory",
    "Model behavior & instructions": "Context &amp; memory",
    "plugin-management": "MCP &amp; plugin issues",
}

# Also normalize bare & to &amp; in existing canonical names
NORMALIZE = {
    "Hook behavior & events": "Hook behavior &amp; events",
    "Hook bypass & evasion": "Hook bypass &amp; evasion",
    "Subagent & spawned agents": "Subagent &amp; spawned agents",
    "MCP & plugin issues": "MCP &amp; plugin issues",
    "Platform & compatibility": "Platform &amp; compatibility",
    "Desktop & IDE integration": "Desktop &amp; IDE integration",
    "Context & memory": "Context &amp; memory",
    "Security & trust boundaries": "Security &amp; trust boundaries",
    "Scheduling & remote triggers": "Scheduling &amp; remote triggers",
    "Performance & cost": "Performance &amp; cost",
}

with open(FEED_PATH) as f:
    content = f.read()

changes = 0

# First apply merges
for old, new in MERGE_MAP_XML.items():
    pattern = f'term="{old}"'
    replacement = f'term="{new}"'
    if pattern in content:
        count = content.count(pattern)
        content = content.replace(pattern, replacement)
        changes += count
        print(f"  merge: {old} -> {new} ({count}x)")

# Then normalize bare & to &amp;
for old, new in NORMALIZE.items():
    pattern = f'term="{old}"'
    replacement = f'term="{new}"'
    if pattern in content and old != new:
        count = content.count(pattern)
        content = content.replace(pattern, replacement)
        changes += count
        print(f"  normalize: {old} -> {new} ({count}x)")

with open(FEED_PATH, "w") as f:
    f.write(content)

print(f"\nTotal fixes: {changes}")

# Verify
result = subprocess.run(
    ["grep", "-o", 'term="[^"]*"', FEED_PATH],
    capture_output=True, text=True
)
terms = set()
for line in result.stdout.strip().split("\n"):
    if line.startswith('term="') and line not in ['term="critical"', 'term="high"', 'term="medium"', 'term="low"']:
        terms.add(line)
print("\nCategory terms in feed:")
for t in sorted(terms):
    print(f"  {t}")
print(f"  Total: {len(terms)}")
