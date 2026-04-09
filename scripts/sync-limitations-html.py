#!/usr/bin/env python3
"""Sync the limitations.html entry list from limitations.json."""

from __future__ import annotations

import html
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = REPO_ROOT / "docs" / "limitations.json"
HTML_PATH = REPO_ROOT / "docs" / "limitations.html"

SEVERITY_STYLES = {
    "critical": ("#dc2626", "Critical"),
    "high": ("#ea580c", "High"),
    "medium": ("#d97706", "Medium"),
    "low": ("#6b7280", "Low"),
}


def normalize_issue(issue: object) -> tuple[str, str] | None:
    if not issue:
        return None

    text = str(issue).strip()
    if not text:
        return None

    if text.startswith("http://") or text.startswith("https://"):
        match = re.search(r"/issues/(\d+)", text)
        label = f"#{match.group(1)}" if match else text
        return text, label

    if text.startswith("#") and text[1:].isdigit():
        number = text[1:]
        return f"https://github.com/anthropics/claude-code/issues/{number}", text

    if text.isdigit():
        return f"https://github.com/anthropics/claude-code/issues/{text}", f"#{text}"

    return None


def collect_issue_links(entry: dict) -> list[tuple[str, str]]:
    raw: list[object] = []
    issues = entry.get("issues")
    if isinstance(issues, list):
        raw.extend(issues)
    elif issues:
        raw.append(issues)

    for key in ("issue", "cc_issue"):
        if entry.get(key):
            raw.append(entry[key])

    links: list[tuple[str, str]] = []
    seen: set[tuple[str, str]] = set()
    for item in raw:
        normalized = normalize_issue(item)
        if normalized and normalized not in seen:
            seen.add(normalized)
            links.append(normalized)
    return links


def build_entry(entry: dict, number: int) -> str:
    entry_id = html.escape(entry["id"], quote=True)
    category = html.escape(entry.get("category", "Uncategorized"))
    title = html.escape(entry.get("title", "Untitled"))
    description = html.escape(entry.get("description", ""))
    severity_key = str(entry.get("severity", "low")).lower()
    severity_color, severity_label = SEVERITY_STYLES.get(
        severity_key, SEVERITY_STYLES["low"]
    )
    status = html.escape(str(entry.get("status", "open")).lower(), quote=True)
    issue_links = collect_issue_links(entry)
    issue_attr = html.escape(
        " ".join(label.lstrip("#") for _, label in issue_links), quote=True
    )

    lines = [
        f'        <div class="kl-entry" data-category="{category}" data-issues="{issue_attr}" id="{entry_id}" data-severity="{severity_key}" data-status="{status}">',
        '            <div class="kl-header">',
        f'                <span class="kl-num">#{number}</span>',
        f'                <span class="kl-cat">{category}</span>',
        f'                <span class="kl-sev" style="font-size:0.7rem;background:{severity_color};color:white;padding:0.1rem 0.4rem;border-radius:12px;margin-left:0.3rem;font-weight:600;text-transform:uppercase;">{severity_label.lower()}</span>',
        "            </div>",
        f"            <h3>{title}</h3>",
        f"            <p>{description}</p>",
    ]

    workaround = entry.get("workaround")
    if workaround:
        lines.extend(
            [
                f"                        <!-- workaround:{entry_id} -->",
                '            <p style="margin-top:0.5rem;padding:0.5rem 0.75rem;background:#1a2a1a;border-left:3px solid #22c55e;border-radius:4px;font-size:0.85rem;"><strong style="color:#22c55e;">Workaround:</strong> '
                + html.escape(str(workaround))
                + "</p>",
            ]
        )

    if issue_links:
        rendered_links = ", ".join(
            f'<a href="{html.escape(href, quote=True)}" target="_blank">{html.escape(label)}</a>'
            for href, label in issue_links
        )
        lines.append(f"            <div class=\"kl-issues\">Issues: {rendered_links}</div>")

    lines.append("        </div>")
    return "\n".join(lines)


def render_entries(entries: list[dict]) -> str:
    rendered = ["", "        <!-- BEGIN GENERATED LIMITATIONS -->"]
    rendered.extend(build_entry(entry, idx) for idx, entry in enumerate(entries, start=1))
    rendered.append("        <!-- END GENERATED LIMITATIONS -->")
    rendered.append("")
    return "\n".join(rendered)


def main() -> None:
    data = json.loads(JSON_PATH.read_text())
    entries = data["entries"]
    html_text = HTML_PATH.read_text()

    start_marker = '        <div class="count" id="count"></div>\n'
    footer_marker = "<footer>"
    start_idx = html_text.index(start_marker) + len(start_marker)
    end_idx = html_text.index(footer_marker, start_idx)

    generated = render_entries(entries)
    updated = html_text[:start_idx] + generated + html_text[end_idx:]

    updated = re.sub(
        r'<span id="total-count">\d+</span>',
        f'<span id="total-count">{len(entries)}</span>',
        updated,
        count=1,
    )
    updated = re.sub(
        r"Last updated: [0-9-]+\.",
        f"Last updated: {html.escape(str(data.get('last_updated') or data.get('lastUpdated') or 'unknown'))}.",
        updated,
        count=1,
    )

    HTML_PATH.write_text(updated)
    print(f"Synced limitations.html with {len(entries)} entries")


if __name__ == "__main__":
    main()
