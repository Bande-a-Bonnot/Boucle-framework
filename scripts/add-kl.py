#!/usr/bin/env python3
"""Add a KL entry to limitations.json."""
import json, sys, os

def main():
    json_path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'docs', 'limitations.json')

    with open(json_path, 'r') as f:
        d = json.load(f)

    new_entry = {
        "id": sys.argv[1],
        "title": sys.argv[2],
        "severity": sys.argv[3],
        "category": sys.argv[4],
        "description": sys.argv[5],
        "issue": sys.argv[6],
        "status": "open",
        "date_added": sys.argv[7] if len(sys.argv) > 7 else "2026-04-08"
    }

    d['entries'].append(new_entry)

    total = len(d['entries'])
    sev_counts = {}
    status_counts = {"open": 0, "fixed": 0, "mitigated": 0}
    for e in d['entries']:
        s = e.get('severity', 'medium').lower()
        sev_counts[s] = sev_counts.get(s, 0) + 1
        st = e.get('status', 'open').lower()
        if st in status_counts:
            status_counts[st] += 1

    d['total'] = total
    d['severities'] = sev_counts
    d['stats'] = {"total": total, **sev_counts, **status_counts}
    d['last_updated'] = new_entry['date_added']
    d['lastUpdated'] = new_entry['date_added']

    with open(json_path, 'w') as f:
        json.dump(d, f, indent=2)

    print(f"Added KL. Total: {total}. Severities: {sev_counts}")

if __name__ == '__main__':
    main()
