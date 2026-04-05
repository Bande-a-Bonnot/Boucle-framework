#!/usr/bin/env python3
"""Add new KL entries to limitations.json."""
import json

import os
script_dir = os.path.dirname(os.path.abspath(__file__))
repo_root = os.path.dirname(script_dir)
json_path = os.path.join(repo_root, "docs", "limitations.json")
data = json.load(open(json_path))
entries = data["entries"]

# Track existing issue URLs to avoid dupes
existing_issues = set()
for e in entries:
    for u in e.get("issues", []):
        existing_issues.add(u)

new_entries = [
    {
        "id": "cowork-dispatch-tasks-hang-desktop-windows",
        "title": "Dispatch tasks reach Desktop app but hang indefinitely on 'thinking' and never respond (Windows).",
        "category": "Desktop & Cowork",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43726"],
        "description": "On Windows, tasks dispatched via the mobile Dispatch feature appear in the Desktop app Code tab but hang indefinitely on 'thinking' and never produce a response. The CLI works fine independently. Re-pairing devices and restarting the Desktop app do not fix it. Confirmed on Windows 11 with Claude Code CLI 2.1.92 and latest Desktop app."
    },
    {
        "id": "worktree-accumulation-no-auto-cleanup",
        "title": "Desktop app creates a new git worktree per session with no automatic cleanup, causing orphaned worktree accumulation.",
        "category": "Desktop & Cowork",
        "severity": "medium",
        "issues": ["https://github.com/anthropics/claude-code/issues/43730"],
        "description": "Every new Desktop app session automatically creates a fresh git worktree under .claude/worktrees/ with a random name. When the session ends, the worktree is left behind permanently. Over days/weeks, the directory fills with orphaned worktrees consuming disk space and adding git state complexity. There is no option to reuse existing worktrees, opt out of worktree creation, or run a cleanup command. Also breaks single-branch + submodule workflows since submodules are not initialized in the new worktree."
    },
]

added = 0
for ne in new_entries:
    issue_url = ne["issues"][0] if ne["issues"] else None
    if issue_url and issue_url in existing_issues:
        print(f"SKIP (dupe): {ne['id']}")
        continue
    entries.append(ne)
    added += 1
    print(f"ADDED: {ne['id']} [{ne['severity'].upper()}]")

data["count"] = len(entries)

cats = {}
sevs = {}
for e in entries:
    cats[e["category"]] = cats.get(e["category"], 0) + 1
    sevs[e["severity"]] = sevs.get(e["severity"], 0) + 1
data["categories"] = cats
data["severity_counts"] = sevs

with open(json_path, "w") as f:
    json.dump(data, f, indent=2)

print(f"\nAdded {added} entries. Total: {data['count']}")
