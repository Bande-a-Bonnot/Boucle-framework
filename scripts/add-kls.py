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
        "id": "mcp-http-server-crashes-session",
        "title": "MCP HTTP-type server can crash entire Claude Code session.",
        "category": "Hook behavior & events",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43371"],
        "description": "An HTTP-type MCP server (e.g. vibe-annotations on 127.0.0.1) causes Claude Code sessions to close/crash when the agent reads from it. Happens consistently with multiple concurrent sessions open. No graceful error handling; the session just dies."
    },
    {
        "id": "remote-trigger-mcp-connectors-not-injected",
        "title": "Remote Trigger (CCR) sessions do not receive configured MCP connectors.",
        "category": "Hook behavior & events",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43374"],
        "description": "MCP connectors (Notion, Supabase, etc.) configured on Remote Triggers are not injected into the CCR session runtime. Connectors show as connected in trigger config and claude.ai settings, but ToolSearch finds nothing. Agent falls back to degraded mode. Sub-agents in scheduled tasks DO get MCP access (#43320), making this inconsistent."
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
