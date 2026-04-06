#!/usr/bin/env python3
"""Add a batch of KL entries to limitations.json."""
import json, os

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(BASE, 'docs', 'limitations.json')

new_entries = [
    {
        "id": "continue-command-burns-excessive-usage",
        "title": "Typing 'continue' after going AFK can burn 56% of 5h Pro plan with minimal output",
        "category": "Cost & usage",
        "severity": "high",
        "issues": ["#44197"],
        "description": "After typing 'continue' in a session with MCP servers (Serena, Context7) and LSP plugins, Claude can consume a disproportionate amount of the 5-hour Pro plan budget on small edits. User reported 56% usage for a few file edits after stepping away. The cost/output ratio resembles Opus high-effort planning, not Sonnet auto-effort file edits. No clear explanation for the spike.",
        "date_added": "2026-04-06",
        "version_reported": "2.1.92",
        "platform": "all",
        "status": "open"
    },
    {
        "id": "resume-continue-no-render-previous-messages",
        "title": "--resume/--continue no longer renders previous conversation messages in terminal",
        "category": "CLI & terminal",
        "severity": "high",
        "issues": ["#44193"],
        "description": "When using claude --resume or --continue, the conversation context is restored internally (Claude can reference prior messages), but the terminal starts blank with no visible history. This is a regression; previous versions rendered the full conversation when resuming. Users lose visual context of what was discussed before.",
        "date_added": "2026-04-06",
        "version_reported": "2.1.85",
        "platform": "linux",
        "status": "open"
    },
    {
        "id": "voice-ptt-hold-delay-warp-keybindings",
        "title": "Voice push-to-talk hold-detection delay swallows first words; keybindings broken in Warp terminal",
        "category": "CLI & terminal",
        "severity": "medium",
        "issues": ["#44194"],
        "description": "Two voice mode issues: (1) When push-to-talk is bound to space (default), a race condition between typing a space and holding for voice causes the first 1-2 words of speech to be lost. (2) Warp terminal intercepts most key combinations before they reach Claude Code, making voice mode effectively unusable in Warp. Tested combos that all failed: alt+space, ctrl+shift+space, ctrl+alt+v, ctrl+j.",
        "date_added": "2026-04-06",
        "version_reported": "2.1.92",
        "platform": "macos",
        "status": "open"
    },
    {
        "id": "preview-start-docker-port-mismatch",
        "title": "preview_start cannot verify Docker-managed dev servers; auto-assigns wrong port",
        "category": "Tools & permissions",
        "severity": "high",
        "issues": ["#44187"],
        "description": "When a project uses Docker Compose to run its dev server on a fixed host port, preview_start detects the port is in use and falls back to autoPort, assigning a random high port where nothing is served. Subsequent preview_eval/snapshot/screenshot calls return empty bodies or chrome-error:// pages. The Stop hook insists on calling preview_start after code edits, creating noisy warnings even when the user has verified changes via curl. No way to tell the preview system to use the existing Docker-managed port.",
        "date_added": "2026-04-06",
        "version_reported": "2.1.92",
        "platform": "wsl",
        "status": "open"
    }
]

with open(JSON_PATH) as f:
    data = json.load(f)

entries = data['entries']
existing_ids = {e['id'] for e in entries}
added = 0
for e in new_entries:
    if e['id'] not in existing_ids:
        entries.append(e)
        added += 1
        print(f"  Added: {e['id']} ({e['severity'].upper()})")
    else:
        print(f"  Skipped (exists): {e['id']}")

data['count'] = len(entries)
sev = {'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
for e in entries:
    s = e.get('severity', 'medium')
    if s in sev:
        sev[s] += 1
data['severity_counts'] = sev

with open(JSON_PATH, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')

print(f"\nTotal: {len(entries)} entries. Added: {added}. Severity: {sev}")
