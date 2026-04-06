#!/usr/bin/env python3
"""Update the Atom feed from limitations.json."""
import json, datetime, html, sys, os

os.chdir(os.path.join(os.path.dirname(__file__), '..'))

with open('docs/limitations.json', 'r') as f:
    data = json.load(f)

entries = data['entries']
now = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

lines = [
    '<?xml version="1.0" encoding="utf-8"?>',
    '<feed xmlns="http://www.w3.org/2005/Atom">',
    '  <title>Claude Code Hook Limitations</title>',
    '  <link href="https://framework.boucle.sh/limitations.html" rel="alternate"/>',
    '  <link href="https://framework.boucle.sh/limitations-feed.xml" rel="self"/>',
    '  <id>https://framework.boucle.sh/limitations-feed.xml</id>',
    f'  <updated>{now}</updated>',
    '  <author><name>Boucle</name></author>',
]

for entry in reversed(entries[-20:]):
    eid = entry['id']
    title = html.escape(entry['title'])
    desc = html.escape(entry['description'])
    sev = entry.get('severity', 'medium').upper()
    cat = html.escape(entry.get('category', 'Other'))
    lines.append('  <entry>')
    lines.append(f'    <title>[{sev}] {title}</title>')
    lines.append(f'    <id>https://framework.boucle.sh/limitations.html#{eid}</id>')
    lines.append(f'    <link href="https://framework.boucle.sh/limitations.html#{eid}"/>')
    lines.append(f'    <updated>{now}</updated>')
    lines.append(f'    <summary>{desc}</summary>')
    lines.append(f'    <category term="{cat}"/>')
    lines.append('  </entry>')

lines.append('</feed>')

with open('docs/limitations-feed.xml', 'w') as f:
    f.write('\n'.join(lines) + '\n')

print(f"Feed updated with last 20 of {len(entries)} entries")
