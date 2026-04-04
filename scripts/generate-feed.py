#!/usr/bin/env python3
"""Generate Atom feed from limitations.json for the Known Limitations page.

People tracking Claude Code hook issues can subscribe to this feed
and get notified when new entries are added.

Usage: python3 scripts/generate-feed.py > docs/limitations-feed.xml
"""
import json
import sys
from datetime import datetime, timezone

def escape_xml(s):
    """Escape XML special characters."""
    return (s
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
        .replace("'", "&apos;"))

def main():
    data = json.load(open("docs/limitations.json"))
    entries = data["entries"]
    count = data["count"]
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    feed = []
    feed.append('<?xml version="1.0" encoding="utf-8"?>')
    feed.append('<feed xmlns="http://www.w3.org/2005/Atom">')
    feed.append(f'  <title>Claude Code Hook Limitations ({count} entries)</title>')
    feed.append(f'  <subtitle>Documented limitations of Claude Code\'s hook system, with severity ratings and workarounds.</subtitle>')
    feed.append(f'  <link href="https://framework.boucle.sh/limitations.html" rel="alternate"/>')
    feed.append(f'  <link href="https://framework.boucle.sh/limitations-feed.xml" rel="self"/>')
    feed.append(f'  <id>https://framework.boucle.sh/limitations.html</id>')
    feed.append(f'  <updated>{now}</updated>')
    feed.append(f'  <author><name>Boucle</name><uri>https://boucle.sh/</uri></author>')
    feed.append(f'  <generator>generate-feed.py</generator>')

    # Most recent entries first (they're appended chronologically)
    for entry in reversed(entries):
        eid = entry["id"]
        title = escape_xml(entry["title"])
        category = escape_xml(entry["category"])
        severity = entry["severity"].upper()
        desc = escape_xml(entry["description"])
        issues = entry.get("issues", [])
        issue_links = " ".join(f'<a href="{escape_xml(u)}">{escape_xml(u.split("/")[-1])}</a>' for u in issues) if issues else "none"

        content = (
            f'&lt;p&gt;&lt;strong&gt;Severity:&lt;/strong&gt; {severity} | '
            f'&lt;strong&gt;Category:&lt;/strong&gt; {category}&lt;/p&gt;'
            f'&lt;p&gt;{desc}&lt;/p&gt;'
            f'&lt;p&gt;&lt;strong&gt;Issues:&lt;/strong&gt; {escape_xml(", ".join(issues))}&lt;/p&gt;'
        )

        permalink = f"https://framework.boucle.sh/limitations.html#{eid}"

        feed.append(f'  <entry>')
        feed.append(f'    <title>[{severity}] {title}</title>')
        feed.append(f'    <id>{permalink}</id>')
        feed.append(f'    <link href="{permalink}" rel="alternate"/>')
        feed.append(f'    <updated>{now}</updated>')
        feed.append(f'    <category term="{category}"/>')
        feed.append(f'    <content type="html">{content}</content>')
        feed.append(f'  </entry>')

    feed.append('</feed>')
    print("\n".join(feed))

if __name__ == "__main__":
    main()
