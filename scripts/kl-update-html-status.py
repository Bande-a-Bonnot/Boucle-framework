#!/usr/bin/env python3
"""Add data-status and fixed-in badges to HTML entries based on JSON status."""
import json, re

# Load JSON for status data
with open("docs/limitations.json") as f:
    data = json.load(f)

status_map = {}
for e in data["entries"]:
    eid = e["id"]
    status = e.get("status", "open")
    fixed_in = e.get("fixed_in", "")
    if status != "open":
        status_map[eid] = {"status": status, "fixed_in": fixed_in}

# Load HTML
with open("docs/limitations.html") as f:
    html = f.read()

updates = 0
for eid, info in status_map.items():
    status = info["status"]
    fixed_in = info["fixed_in"]

    # Find the entry div and add data-status attribute
    # Pattern: id="eid" data-severity="..."
    pattern = rf'id="{re.escape(eid)}" data-severity="'
    if pattern.replace("\\", "") not in html and re.escape(eid) != eid:
        # Try without escaping
        pattern = f'id="{eid}" data-severity="'

    if f'id="{eid}"' in html:
        # Add data-status attribute after data-severity
        old = f'id="{eid}" data-severity="'
        if old in html:
            new = f'id="{eid}" data-status="{status}" data-severity="'
            html = html.replace(old, new, 1)
            updates += 1

            # Add status badge after severity badge in the header
            if fixed_in:
                badge_text = f"FIXED in {fixed_in}"
            else:
                badge_text = status.upper()
            badge_html = f'<span class="kl-status {status}">{badge_text}</span>'

            # Insert after the severity span closing tag for this entry
            # Find the entry start and the first </span> after kl-sev
            entry_start = html.find(f'id="{eid}"')
            sev_span_end = html.find("</span>", html.find("kl-sev", entry_start))
            if sev_span_end > 0:
                insert_pos = sev_span_end + len("</span>")
                html = html[:insert_pos] + badge_html + html[insert_pos:]
    else:
        print(f"  WARNING: entry {eid} not found in HTML")

# Also fix the straggler category in HTML
html = html.replace('data-category="Hook behavior gaps"', 'data-category="Hook behavior &amp; events"')
html = html.replace('>Hook behavior gaps<', '>Hook behavior &amp; events<')

with open("docs/limitations.html", "w") as f:
    f.write(html)

print(f"Updated {updates} entries with status attributes and badges")
print(f"Status map: {len(status_map)} entries")
for eid, info in status_map.items():
    print(f"  {eid}: {info['status']} {info.get('fixed_in','')}")
