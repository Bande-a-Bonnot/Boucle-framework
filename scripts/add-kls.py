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
        "id": "permission-relay-all-channels",
        "title": "Permission prompts relay to all channels, not just the originating channel.",
        "category": "Permission system",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43625"],
        "description": "When running Claude Code with a channel plugin (e.g. --channels plugin:telegram), permission prompts are relayed to all connected channels regardless of which channel the message originated from. Reply routing correctly targets the originating channel, but permission dialogs broadcast to every channel. This can expose sensitive tool approval prompts to unintended channels."
    },
    {
        "id": "plan-mode-allows-code-modification",
        "title": "Agent modifies code while in plan mode (plan mode not enforced as read-only).",
        "category": "Permission system",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43623"],
        "description": "Plan mode is expected to be read-only (no file writes or tool executions), but the agent can still modify code while in plan mode. Reported on v2.1.92. This undermines the safety guarantee that plan mode lets you review before any changes are made. Needs independent reproduction."
    },
    {
        "id": "plugin-channel-notifications-not-injected",
        "title": "Channel plugin receives messages but notifications are never injected into the conversation.",
        "category": "MCP & plugin issues",
        "severity": "medium",
        "issues": ["https://github.com/anthropics/claude-code/issues/43627"],
        "description": "The official Telegram channels plugin (telegram@claude-plugins-official v0.0.4) connects and polls successfully, but MCP notifications/claude/channel messages are never injected into the conversation as channel source tags. The plugin logs show messages received, but Claude never sees them. Affects Windows with bun 1.3.11 on v2.1.92."
    }
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
