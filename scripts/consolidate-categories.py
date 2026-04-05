#!/usr/bin/env python3
"""Consolidate fragmented KL categories from 21 down to ~12."""
import json
import sys

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
}

def main():
    with open("docs/limitations.json") as f:
        data = json.load(f)

    # Show before state
    cats_before = {}
    for e in data["entries"]:
        c = e.get("category", "Unknown")
        cats_before[c] = cats_before.get(c, 0) + 1

    print("BEFORE:")
    for c, n in sorted(cats_before.items(), key=lambda x: -x[1]):
        merged_to = MERGE_MAP.get(c)
        suffix = f"  -> {merged_to}" if merged_to else ""
        print(f"  {n:>4}  {c}{suffix}")
    print(f"  Total categories: {len(cats_before)}")

    if "--dry-run" in sys.argv:
        print("\n(dry run, no changes written)")
        return

    # Apply merges
    changed = 0
    for e in data["entries"]:
        old_cat = e.get("category", "")
        if old_cat in MERGE_MAP:
            e["category"] = MERGE_MAP[old_cat]
            changed += 1

    # Rebuild category counts
    cats_after = {}
    for e in data["entries"]:
        c = e.get("category", "Unknown")
        cats_after[c] = cats_after.get(c, 0) + 1

    data["categories"] = cats_after

    print(f"\nAFTER ({changed} entries recategorized):")
    for c, n in sorted(cats_after.items(), key=lambda x: -x[1]):
        print(f"  {n:>4}  {c}")
    print(f"  Total categories: {len(cats_after)}")

    with open("docs/limitations.json", "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"\nWritten to docs/limitations.json")

if __name__ == "__main__":
    main()
