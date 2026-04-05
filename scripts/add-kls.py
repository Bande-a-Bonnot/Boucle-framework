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
        "id": "teamcreate-drops-1m-context-window-variant",
        "title": "TeamCreate spawns teammates with base model name, dropping context window variant suffix.",
        "category": "Multi-agent & subprocesses",
        "severity": "high",
        "issues": ["https://github.com/anthropics/claude-code/issues/43782"],
        "description": "When spawning teammates via TeamCreate, the model parameter strips the context window variant suffix (e.g. claude-opus-4-6[1m] becomes claude-opus-4-6). Teammates get the default 200K context window instead of the parent 1M window. This causes premature compaction on large files that would fit in the parent context. Affects Claude Max subscribers using multi-agent workflows. See issue 43782."
    },
    {
        "id": "mcp-server-allowed-dirs-overwritten-by-code-cwd",
        "title": "Opening Claude Code overwrites a running MCP server allowed directories from Claude Desktop config.",
        "category": "MCP & plugins",
        "severity": "medium",
        "issues": ["https://github.com/anthropics/claude-code/issues/43783"],
        "description": "When Claude Code opens in directory B while Claude Desktop has an MCP filesystem server configured for directory A, the running server process scope is silently overwritten to directory B. Desktop UI still shows the original config but the server now operates on the wrong directory. Cross-surface trust boundary issue between Code and Desktop sharing MCP server processes. Breaks Cowork scheduled tasks that depend on Desktop MCP config. See issue 43783.",
        "workaround": "Restart the MCP server from Claude Desktop after opening Claude Code in a different directory. Alternatively, avoid running Code and Desktop simultaneously with different MCP filesystem configurations."
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
