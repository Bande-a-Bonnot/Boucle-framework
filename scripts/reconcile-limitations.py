#!/usr/bin/env python3
"""Rebuild derived metadata in docs/limitations.json.

This keeps summary fields in sync with the actual entry list after manual
batch additions.
"""
from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
JSON_PATH = REPO_ROOT / "docs" / "limitations.json"


def normalize_status(status: str | None) -> str:
    return (status or "open").strip().lower()


def normalize_severity(severity: str | None) -> str:
    return (severity or "MEDIUM").strip().upper()


def build_expected(data: dict) -> dict:
    entries = data["entries"]

    for entry in entries:
        entry["status"] = normalize_status(entry.get("status"))
        entry["severity"] = normalize_severity(entry.get("severity"))

    category_counts = Counter(entry.get("category", "Unknown") for entry in entries)
    severity_counts = Counter(entry["severity"] for entry in entries)
    status_counts = Counter(entry["status"] for entry in entries)

    total = len(entries)
    data["count"] = total
    data["total"] = total
    data["categories"] = dict(sorted(category_counts.items(), key=lambda item: (-item[1], item[0].lower())))
    data["severity_counts"] = dict(sorted(severity_counts.items()))
    data["status_summary"] = {
        "open": status_counts.get("open", 0),
        "fixed": status_counts.get("fixed", 0),
        "mitigated": status_counts.get("mitigated", 0),
    }
    data["severities"] = {key.lower(): value for key, value in data["severity_counts"].items()}
    data["stats"] = {
        "total": total,
        "critical": severity_counts.get("CRITICAL", 0),
        "high": severity_counts.get("HIGH", 0),
        "medium": severity_counts.get("MEDIUM", 0),
        "low": severity_counts.get("LOW", 0),
        "open": data["status_summary"]["open"],
        "fixed": data["status_summary"]["fixed"],
        "mitigated": data["status_summary"]["mitigated"],
    }
    return data


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true", help="exit non-zero if metadata is out of sync")
    args = parser.parse_args()

    original = json.loads(JSON_PATH.read_text())
    reconciled = build_expected(json.loads(JSON_PATH.read_text()))

    if args.check:
        if original != reconciled:
            print("limitations.json metadata drift detected")
            return 1
        print("limitations.json metadata is consistent")
        return 0

    JSON_PATH.write_text(json.dumps(reconciled, indent=2) + "\n")
    print(
        "Reconciled limitations.json:",
        f"total={reconciled['count']}",
        f"open={reconciled['status_summary']['open']}",
        f"fixed={reconciled['status_summary']['fixed']}",
        f"mitigated={reconciled['status_summary']['mitigated']}",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
