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
        "id": "mcp-server-instructions-silently-truncated-multiple-servers",
        "title": "MCP server instructions silently truncated when multiple servers are configured.",
        "category": "Hook system design constraints",
        "severity": "medium",
        "issues": ["https://github.com/anthropics/claude-code/issues/43474"],
        "description": "When multiple MCP servers are configured (e.g. context7 + deepwiki + serena), the MCP server instructions block in the system prompt is silently truncated. The last server's instructions get cut off mid-sentence with no warning or error. Users have no way to know their MCP configuration is partially ignored. Affects hook authors who rely on MCP server instructions for context. See #43474."
    },
    {
        "id": "cowork-chrome-operates-unintended-device-parsec",
        "title": "Cowork Chrome extension operates unintended device's browser in multi-device Parsec sessions.",
        "category": "Security & trust boundaries",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43480"],
        "description": "In multi-device environments using Parsec remote desktop, Claude's Cowork Chrome extension can operate the Chrome instance on the wrong device. The extension targets a Chrome browser that the user did not intend, potentially executing actions on a different machine. This is a trust boundary violation: the agent acts on resources the user did not authorize. See #43480."
    },
    {
        "id": "remote-trigger-destructive-force-push-data-loss",
        "title": "Remote triggers can execute destructive git operations (force-push) causing data loss.",
        "category": "Security & trust boundaries",
        "severity": "critical",
        "issues": ["https://github.com/anthropics/claude-code/issues/43461"],
        "description": "Remote triggers (scheduled Claude Code agents) can execute force-push operations that delete tracked files. One user reported 17 tracked files deleted by a trigger-initiated force-push. The 90% MCP tool failure rate in triggers compounds this: when MCP tools fail, the agent may fall back to destructive git operations as a workaround. Hooks do not run in remote trigger sessions, so PreToolUse guards cannot prevent this. See #43461."
    },
    {
        "id": "cowork-sandbox-blocks-mcp-subprocess-google-apis",
        "title": "Cowork sandbox network allowlist blocks MCP subprocess connections to Google APIs.",
        "category": "Hook behavior & events",
        "severity": "medium",
        "issues": ["https://github.com/anthropics/claude-code/issues/43472"],
        "description": "MCP servers running inside Cowork's sandbox cannot connect to Google APIs due to network allowlist restrictions. Any MCP server requiring Google OAuth (e.g. mcp-gsheets) fails silently. The sandbox's network policy does not expose which domains are allowed, so debugging requires trial and error. Affects any Cowork user with Google-dependent MCP servers. See #43472."
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
