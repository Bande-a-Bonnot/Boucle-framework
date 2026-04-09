#!/usr/bin/env python3
"""Update the Atom feed from limitations.json."""

from __future__ import annotations

import html
import json
import os
from datetime import datetime, timezone
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = REPO_ROOT / "docs" / "limitations.json"
FEED_PATH = REPO_ROOT / "docs" / "limitations-feed.xml"
BASE_URL = "https://framework.boucle.sh/limitations.html"


def normalize_updated(raw: object) -> str:
    text = str(raw or "").strip()
    if not text:
        return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if len(text) == 10:
        return f"{text}T00:00:00Z"

    return text


def build_feed(data: dict) -> str:
    entries = data["entries"]
    updated = normalize_updated(data.get("last_updated") or data.get("lastUpdated"))

    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        '<feed xmlns="http://www.w3.org/2005/Atom">',
        "  <title>Claude Code Hook Limitations</title>",
        f'  <link href="{BASE_URL}" rel="alternate"/>',
        '  <link href="https://framework.boucle.sh/limitations-feed.xml" rel="self"/>',
        "  <id>https://framework.boucle.sh/limitations-feed.xml</id>",
        f"  <updated>{updated}</updated>",
        "  <author><name>Boucle</name></author>",
    ]

    for entry in reversed(entries[-20:]):
        eid = entry["id"]
        title = html.escape(entry["title"])
        desc = html.escape(entry["description"])
        sev = str(entry.get("severity", "medium")).upper()
        cat = html.escape(str(entry.get("category", "Other")))
        permalink = f"{BASE_URL}#{eid}"
        lines.append("  <entry>")
        lines.append(f"    <title>[{sev}] {title}</title>")
        lines.append(f"    <id>{permalink}</id>")
        lines.append(f'    <link href="{permalink}"/>')
        lines.append(f"    <updated>{updated}</updated>")
        lines.append(f"    <summary>{desc}</summary>")
        lines.append(f'    <category term="{cat}"/>')
        lines.append("  </entry>")

    lines.append("</feed>")
    return "\n".join(lines) + "\n"


def main() -> None:
    os.chdir(REPO_ROOT)
    data = json.loads(JSON_PATH.read_text())
    FEED_PATH.write_text(build_feed(data))
    print(f"Feed updated with last {min(20, len(data['entries']))} of {len(data['entries'])} entries")


if __name__ == "__main__":
    main()
