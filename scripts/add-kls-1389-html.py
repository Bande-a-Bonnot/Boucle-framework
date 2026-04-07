#!/usr/bin/env python3
"""Add KLs #550-553 HTML blocks to limitations.html."""
import json
import os
import sys
import re

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML_PATH = os.path.join(BASE, 'docs', 'limitations.html')
JSON_PATH = os.path.join(BASE, 'docs', 'limitations.json')

SEV_COLORS = {
    'critical': '#dc2626',
    'high': '#ea580c',
    'medium': '#d97706',
    'low': '#65a30d'
}

new_entries = [
    {
        'id': 'pretooluse-updatedinput-ignored-agent-tool',
        'kl_num': 550,
        'title': 'PreToolUse hook updatedInput silently ignored for Agent tool, preventing model tiering',
        'category': 'Hooks & automation',
        'severity': 'high',
        'issues': ['#44412'],
        'description': 'PreToolUse hooks that return updatedInput work for Bash and other tools but are silently discarded when the tool is Agent. Subagents always spawn with the parent model regardless of the hook output. This makes programmatic model tiering (e.g., use sonnet for subagents, not opus) impossible via hooks.',
    },
    {
        'id': 'mcp-streamable-http-20pct-timeout',
        'kl_num': 551,
        'title': 'MCP Streamable HTTP intermittent 20% timeout on 300-500ms tool calls',
        'category': 'MCP & integrations',
        'severity': 'high',
        'issues': ['#44415'],
        'description': 'Claude Code Streamable HTTP MCP client fails ~20% of tool calls that succeed on the server side. Controlled benchmark across 10 clients: Claude Code fails 20% vs 0-8% for all other MCP clients against the same server. Failing call succeeds immediately on retry, indicating a client-side timeout or polling bug.',
    },
    {
        'id': 'remote-control-oauth-prefix-false-positive',
        'kl_num': 552,
        'title': 'remote-control rejects valid OAuth tokens -- sk-ant-oat01- prefix misidentified as long-lived',
        'category': 'Authentication & credentials',
        'severity': 'high',
        'issues': ['#44408'],
        'description': 'claude remote-control refuses valid short-lived OAuth tokens obtained via claude auth login, incorrectly claiming they appear to be long-lived tokens. The sk-ant-oat01- prefix is being mismatched by the remote-control validator. claude auth status confirms the token is valid.',
    },
    {
        'id': 'tui-history-dropped-after-large-agent-output',
        'kl_num': 553,
        'title': 'TUI drops earlier conversation turns after large agent/tool output (v2.1.89 regression)',
        'category': 'TUI & display',
        'severity': 'medium',
        'issues': ['#44411'],
        'description': 'Since v2.1.89, when a response includes large concurrent agent results plus extensive file reads, the TUI drops all earlier conversation turns from the terminal display. The session appears to begin mid-conversation. Affects Windows CLI with 1M context Opus.',
    },
]

def make_html(entry):
    eid = entry['id']
    num = entry['kl_num']
    title = entry['title']
    desc = entry['description']
    sev = entry['severity']
    cat = entry['category']
    color = SEV_COLORS.get(sev, '#888')
    issues = entry['issues']
    issue_links = ' '.join(
        f'<a href="https://github.com/anthropics/claude-code/issues/{i.lstrip("#")}" style="font-size:0.8rem;color:var(--accent);">{i}</a>'
        for i in issues
    )
    return f'''            <div class="kl-entry" data-severity="{sev}" data-category="{cat}" id="{eid}">
                <span class="kl-num">#{num}</span>
                <span class="kl-sev" style="font-size:0.7rem;background:{color};color:white;padding:0.1rem 0.4rem;border-radius:12px;margin-left:0.3rem;font-weight:600;text-transform:uppercase;">{sev}</span>
                <span class="kl-cat" style="font-size:0.7rem;color:var(--text-muted);margin-left:0.3rem;">{cat}</span>
                <a href="#{eid}" class="kl-permalink" title="Permalink" style="margin-left:0.3rem;color:var(--text-muted);text-decoration:none;font-size:0.8rem;opacity:0.5;">&#128279;</a>
                <h3 style="margin:0.3rem 0 0.2rem;font-size:0.95rem;font-weight:600;">{title}</h3>
                <p style="font-size:0.85rem;color:var(--text-muted);margin-bottom:0.3rem;">{desc}</p>
                {issue_links}
            </div>'''

# Check which are already in HTML
with open(HTML_PATH) as f:
    content = f.read()

missing = [e for e in new_entries if e['id'] not in content]
if not missing:
    print("All entries already in HTML.")
    sys.exit(0)

html_snippets = [make_html(e) for e in missing]
new_html = '\n'.join(html_snippets)

MARKER = '<footer>'
if MARKER not in content:
    print("ERROR: footer marker not found")
    sys.exit(1)

updated = content.replace(MARKER, new_html + '\n' + MARKER, 1)

# Update stats
data = json.load(open(JSON_PATH))
total = data['count']
sev_counts = data['severity_counts']
crit = sev_counts.get('critical', 0)
high = sev_counts.get('high', 0)
med = sev_counts.get('medium', 0)
low = sev_counts.get('low', 0)

# Update stat spans (pattern: <span id="stat-total">NNN</span>)
updated = re.sub(r'(<span id="stat-total">)\d+(</span>)', rf'\g<1>{total}\2', updated)
updated = re.sub(r'(<span id="stat-critical">)\d+(</span>)', rf'\g<1>{crit}\2', updated)
updated = re.sub(r'(<span id="stat-high">)\d+(</span>)', rf'\g<1>{high}\2', updated)
updated = re.sub(r'(<span id="stat-medium">)\d+(</span>)', rf'\g<1>{med}\2', updated)
updated = re.sub(r'(<span id="stat-low">)\d+(</span>)', rf'\g<1>{low}\2', updated)

with open(HTML_PATH, 'w') as f:
    f.write(updated)

print(f"Inserted {len(missing)} entries into limitations.html. Total: {total}")
