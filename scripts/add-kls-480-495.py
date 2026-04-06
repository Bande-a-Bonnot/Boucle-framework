#!/usr/bin/env python3
"""Add KL #495 to JSON and generate HTML snippets for #480-495."""
import json, os, sys

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
JSON_PATH = os.path.join(BASE, 'docs', 'limitations.json')
HTML_PATH = os.path.join(BASE, 'docs', 'limitations.html')

# New KL #495
new_entry = {
    "id": "custom-skill-name-shadows-native-slash-command",
    "title": "Custom skills with reserved words in their name shadow native slash commands",
    "category": "Skills & commands",
    "severity": "medium",
    "issues": ["#44199"],
    "description": "Skills deployed to .claude/skills/ whose name contains a reserved command word (e.g., 'mcp-vector-search') can shadow or interfere with native slash commands like /mcp. Namespace precedence is incomplete for substring matches. Workaround: rename skills to avoid reserved words (mcp, help, clear, exit, login, logout). A validation step on skill load that warns about name collisions would prevent this.",
    "date_added": "2026-04-06",
    "version_reported": "latest",
    "platform": "macos",
    "status": "open"
}

# Load JSON and add entry
with open(JSON_PATH) as f:
    data = json.load(f)

# Check if already added
ids = [e['id'] for e in data['entries']]
if new_entry['id'] not in ids:
    data['entries'].append(new_entry)
    data['count'] = len(data['entries'])
    # Update severity counts
    sev = new_entry['severity']
    data['severity_counts'][sev] = data['severity_counts'].get(sev, 0) + 1
    with open(JSON_PATH, 'w') as f:
        json.dump(data, f, indent=2)
    print(f"Added KL #495 to JSON. Total: {data['count']}")
else:
    print("KL #495 already in JSON, skipping")

# Now generate HTML for entries #480-495 (indices 479-494)
entries = data['entries']
missing_entries = entries[479:]  # #480 onwards (0-indexed: 479 = entry #480)

SEV_COLORS = {
    'critical': '#dc2626',
    'high': '#f97316',
    'medium': '#ca8a04',
    'low': '#16a34a',
}

def make_html(num, entry):
    sev = entry['severity']
    color = SEV_COLORS.get(sev, '#6b7280')
    eid = entry['id']
    title = entry['title']
    desc = entry['description']
    issues = entry.get('issues', [])
    cat = entry.get('category', '')

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

html_snippets = []
for i, entry in enumerate(missing_entries):
    kl_num = 480 + i
    html_snippets.append(make_html(kl_num, entry))

new_html = '\n'.join(html_snippets)

# Insert before footer
with open(HTML_PATH) as f:
    content = f.read()

MARKER = '<footer>'
if MARKER not in content:
    print("ERROR: footer marker not found in HTML")
    sys.exit(1)

updated = content.replace(MARKER, new_html + '\n' + MARKER, 1)

with open(HTML_PATH, 'w') as f:
    f.write(updated)

print(f"Inserted {len(missing_entries)} entries (#480-#495) into limitations.html")

# Update stats in HTML header
total = data['count']
sev_counts = data['severity_counts']
crit = sev_counts.get('critical', 0)
high = sev_counts.get('high', 0)
med = sev_counts.get('medium', 0)
low = sev_counts.get('low', 0)

print(f"Stats: {total} total | {crit} CRITICAL | {high} HIGH | {med} MEDIUM | {low} LOW")
