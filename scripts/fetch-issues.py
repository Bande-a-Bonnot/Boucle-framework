#!/usr/bin/env python3
"""Fetch Claude Code issue details for KL evaluation."""
import subprocess
import urllib.request
import json
import sys
import os

os.chdir("/Users/thomas/Projects/Banade-a-Bonnot/autonomous-sandbox")
token = subprocess.check_output(
    ["bash", "auth-github.sh"], stderr=subprocess.DEVNULL
).decode().strip()

issues = [int(x) for x in sys.argv[1:]]
if not issues:
    issues = [43625, 43623, 43622, 43620, 43627, 43628]

for num in issues:
    url = "https://api.github.com/repos/anthropics/claude-code/issues/" + str(num)
    req = urllib.request.Request(url, headers={
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json"
    })
    d = json.loads(urllib.request.urlopen(req).read())
    labels = [l["name"] for l in d.get("labels", [])]
    body = (d.get("body", "") or "")[:500]
    print("=== #" + str(num) + ": " + d["title"] + " ===")
    print("Labels: " + str(labels))
    print("Body: " + body)
    print()
