#!/usr/bin/env python3
"""Export the KL database (limitations.html) to JSON format.

Usage: python3 tools/export-kl.py > docs/limitations.json
"""
import re
import json
import html
import sys
import os

DOCS = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "docs")
ROOT = os.path.dirname(DOCS)
HTML_PATH = os.path.join(DOCS, "limitations.html")
JSON_PATH = os.path.join(DOCS, "limitations.json")
CARGO_PATH = os.path.join(ROOT, "Cargo.toml")


def package_version():
    with open(CARGO_PATH) as f:
        for line in f:
            m = re.match(r'version\s*=\s*"([^"]+)"', line.strip())
            if m:
                return m.group(1)
    raise RuntimeError("package version not found in Cargo.toml")

def extract():
    with open(HTML_PATH) as f:
        content = f.read()

    entries = []
    entry_re = re.compile(
        r'<div class="kl-entry" data-category="([^"]+)" data-issues="([^"]*)" '
        r'id="([^"]*)" data-severity="([^"]*)">'
    )
    title_re = re.compile(r'<h3>(.*?)</h3>')
    desc_re = re.compile(r'</h3>\s*<p>(.*?)</p>', re.DOTALL)

    for match in entry_re.finditer(content):
        category = match.group(1)
        raw_issues = match.group(2).strip().split()
        entry_id = match.group(3)
        severity = match.group(4)

        rest = content[match.end():match.end() + 3000]

        title_m = title_re.search(rest)
        title = html.unescape(title_m.group(1)) if title_m else ""

        desc_m = desc_re.search(rest)
        desc = ""
        if desc_m:
            desc = re.sub(r"<[^>]+>", "", desc_m.group(1)).strip()
            desc = html.unescape(desc)

        issues = []
        for i in raw_issues:
            i = i.strip()
            if i:
                issues.append("https://github.com/anthropics/claude-code/issues/" + i)

        entries.append({
            "id": entry_id,
            "title": title,
            "category": category,
            "severity": severity,
            "issues": issues,
            "description": desc[:400],
        })

    return entries


def main():
    entries = extract()
    categories = sorted(set(e["category"] for e in entries))
    severities = {}
    for e in entries:
        s = e["severity"]
        severities[s] = severities.get(s, 0) + 1

    data = {
        "version": package_version(),
        "count": len(entries),
        "categories": categories,
        "severity_counts": severities,
        "entries": entries,
    }

    with open(JSON_PATH, "w") as f:
        json.dump(data, f, indent=2)

    print("Exported {} entries to {}".format(len(entries), JSON_PATH), file=sys.stderr)
    print("Categories: {}".format(categories), file=sys.stderr)
    print("Severities: {}".format(severities), file=sys.stderr)


if __name__ == "__main__":
    main()
