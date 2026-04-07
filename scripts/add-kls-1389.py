#!/usr/bin/env python3
"""Add KLs #550-553 from loop 1389 scan."""
import json

d = json.load(open('docs/limitations.json'))
entries = d['entries']

new_entries = [
    {
        'id': 'pretooluse-updatedinput-ignored-agent-tool',
        'title': 'PreToolUse hook updatedInput silently ignored for Agent tool, preventing model tiering',
        'category': 'Hooks & automation',
        'severity': 'high',
        'issues': ['https://github.com/anthropics/claude-code/issues/44412'],
        'description': 'PreToolUse hooks that return updatedInput work for Bash and other tools but are silently discarded when the tool is Agent. Subagents always spawn with the parent model regardless of the hook output. This makes programmatic model tiering (e.g., use sonnet for subagents, not opus) impossible via hooks. See issue 44412.',
        'date_added': '2026-04-06',
        'platform': 'all',
        'version_reported': 'latest',
        'status': 'open'
    },
    {
        'id': 'mcp-streamable-http-20pct-timeout',
        'title': 'MCP Streamable HTTP intermittent 20% timeout on 300-500ms tool calls',
        'category': 'MCP & integrations',
        'severity': 'high',
        'issues': ['https://github.com/anthropics/claude-code/issues/44415'],
        'description': 'Claude Code Streamable HTTP MCP client fails ~20% of tool calls that succeed on the server side. Controlled benchmark across 10 clients: Claude Code fails 20% vs 0-8% for all other MCP clients against the same server. Failing call succeeds immediately on retry, indicating a client-side timeout or polling bug. See issue 44415.',
        'date_added': '2026-04-06',
        'platform': 'linux',
        'version_reported': 'v2.1.92',
        'status': 'open'
    },
    {
        'id': 'remote-control-oauth-prefix-false-positive',
        'title': 'remote-control rejects valid OAuth tokens -- sk-ant-oat01- prefix misidentified as long-lived',
        'category': 'Authentication & credentials',
        'severity': 'high',
        'issues': ['https://github.com/anthropics/claude-code/issues/44408'],
        'description': 'claude remote-control refuses valid short-lived OAuth tokens obtained via claude auth login, incorrectly claiming they appear to be long-lived tokens. The sk-ant-oat01- prefix is being mismatched by the remote-control validator. claude auth status confirms the token is valid. See issue 44408.',
        'date_added': '2026-04-06',
        'platform': 'macos',
        'version_reported': 'latest',
        'status': 'open'
    },
    {
        'id': 'tui-history-dropped-after-large-agent-output',
        'title': 'TUI drops earlier conversation turns after large agent/tool output (v2.1.89 regression)',
        'category': 'TUI & display',
        'severity': 'medium',
        'issues': ['https://github.com/anthropics/claude-code/issues/44411'],
        'description': 'Since v2.1.89, when a response includes large concurrent agent results plus extensive file reads, the TUI drops all earlier conversation turns from the terminal display. The session appears to begin mid-conversation. Affects Windows CLI with 1M context Opus. See issue 44411.',
        'date_added': '2026-04-06',
        'platform': 'windows',
        'version_reported': 'v2.1.89',
        'status': 'open'
    }
]

entries.extend(new_entries)

sev_counts = {'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
for e in entries:
    sev_counts[e['severity']] = sev_counts.get(e['severity'], 0) + 1

d['count'] = len(entries)
d['severity_counts'] = sev_counts

json.dump(d, open('docs/limitations.json', 'w'), indent=2)
print(f'Done. Total: {len(entries)}. Severity: {sev_counts}')
