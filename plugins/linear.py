#!/usr/bin/env python3
# description: Linear issue operations (create, close, update, comment)
"""Linear operations for Boucle — plugin version.

Usage: boucle linear <command> [args]
Commands:
    create <title> <description> [state] [assignee] [priority]
    close <identifier>
    update <identifier> [state] [assignee]
    comment <identifier> <body>
    batch  (reads JSON from stdin)
"""
import json
import os
import subprocess
import sys
import urllib.request

ROOT = os.environ.get("BOUCLE_ROOT", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

def get_token():
    result = subprocess.run(
        [os.path.join(ROOT, "auth-linear.sh")],
        capture_output=True, text=True, cwd=ROOT
    )
    return result.stdout.strip()

def gql(token, query, variables=None):
    payload = {"query": query}
    if variables:
        payload["variables"] = variables
    data = json.dumps(payload).encode()
    req = urllib.request.Request("https://api.linear.app/graphql", data=data)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req)
        return json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode()
        print(f"HTTP {e.code}: {body}", file=sys.stderr)
        return None

MY_ID = "ebe9606d-ebc9-47f3-8631-bd1883301b0f"
THOMAS_ID = "a91ec4a2-da86-48b9-8e3e-09f87fe50e63"
TEAM_ID = "ea6c03d6-4337-432f-8a84-15ab095b466c"

STATES = {
    "backlog": "ebc2f289-1893-41be-80eb-6988b9e445c6",
    "canceled": "0960d073-26c3-445b-aa3a-ed5da2bc7aa5",
    "started": "996cfe5b-381a-4a81-baae-20a28b153793",
    "completed": "77e38e7e-10e5-4e49-a7ed-b9681b3ae0c6",
    "unstarted": "4718ef86-ea93-466c-8038-1c406122ec26",
}

ASSIGNEE_ALIASES = {"self": MY_ID, "thomas": THOMAS_ID}

def resolve_assignee(name):
    return ASSIGNEE_ALIASES.get(name, name) if name else None

def find_issue_id(token, identifier):
    parts = identifier.split("-")
    if len(parts) != 2:
        print(f"Invalid identifier: {identifier}", file=sys.stderr)
        return None
    try:
        number = int(parts[1])
    except ValueError:
        print(f"Invalid issue number: {parts[1]}", file=sys.stderr)
        return None
    result = gql(token, """
        query FindIssue($teamKey: String!, $number: Float!) {
            issues(filter: { team: { key: { eq: $teamKey } }, number: { eq: $number } }) {
                nodes { id identifier title }
            }
        }
    """, {"teamKey": parts[0], "number": number})
    nodes = (result or {}).get("data", {}).get("issues", {}).get("nodes", [])
    if nodes:
        return nodes[0]["id"]
    print(f"Issue not found: {identifier}", file=sys.stderr)
    return None

def close_issue(token, identifier):
    issue_id = find_issue_id(token, identifier)
    if not issue_id:
        return
    result = gql(token, """
        mutation($id: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $id, input: $input) {
                success issue { identifier title state { name } }
            }
        }
    """, {"id": issue_id, "input": {"stateId": STATES["completed"]}})
    if result:
        print(f"Closed: {identifier}")

def create_issue(token, title, description="", state="backlog", assignee=None, priority=None):
    input_data = {
        "teamId": TEAM_ID,
        "title": title,
        "description": description,
        "stateId": STATES.get(state, STATES["backlog"]),
    }
    if assignee:
        input_data["assigneeId"] = resolve_assignee(assignee)
    if priority:
        input_data["priority"] = int(priority)
    result = gql(token, """
        mutation($input: IssueCreateInput!) {
            issueCreate(input: $input) {
                success issue { identifier title url }
            }
        }
    """, {"input": input_data})
    issue = (result or {}).get("data", {}).get("issueCreate", {}).get("issue")
    if issue:
        print(f"Created: {issue['identifier']} — {issue['title']}")
    else:
        print(f"Failed to create issue", file=sys.stderr)

def update_issue(token, identifier, state=None, assignee=None):
    issue_id = find_issue_id(token, identifier)
    if not issue_id:
        return
    input_data = {}
    if state and state in STATES:
        input_data["stateId"] = STATES[state]
    if assignee:
        input_data["assigneeId"] = resolve_assignee(assignee)
    if not input_data:
        print("Nothing to update")
        return
    result = gql(token, """
        mutation($id: String!, $input: IssueUpdateInput!) {
            issueUpdate(id: $id, input: $input) {
                success issue { identifier title state { name } }
            }
        }
    """, {"id": issue_id, "input": input_data})
    issue = (result or {}).get("data", {}).get("issueUpdate", {}).get("issue")
    if issue:
        state_name = issue.get("state", {}).get("name", "?")
        print(f"Updated: {issue['identifier']} — {issue['title']} (state: {state_name})")

def add_comment(token, identifier, body):
    issue_id = find_issue_id(token, identifier)
    if not issue_id:
        return
    result = gql(token, """
        mutation($issueId: String!, $body: String!) {
            commentCreate(input: { issueId: $issueId, body: $body }) {
                success
            }
        }
    """, {"issueId": issue_id, "body": body})
    if result:
        print(f"Comment added to {identifier}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    token = get_token()
    if not token:
        print("Error: could not get Linear token", file=sys.stderr)
        sys.exit(1)

    cmd, args = sys.argv[1], sys.argv[2:]

    if cmd == "close":
        close_issue(token, args[0])
    elif cmd == "create":
        create_issue(token, args[0], *args[1:])
    elif cmd == "update":
        update_issue(token, args[0], args[1] if len(args) > 1 else None, args[2] if len(args) > 2 else None)
    elif cmd == "comment":
        add_comment(token, args[0], args[1])
    elif cmd == "batch":
        for op in json.loads(sys.stdin.read()):
            {"create": lambda o: create_issue(token, o["title"], o.get("description", ""), o.get("state", "backlog"), o.get("assignee"), o.get("priority")),
             "close": lambda o: close_issue(token, o["identifier"]),
             "update": lambda o: update_issue(token, o["identifier"], o.get("state"), o.get("assignee")),
             "comment": lambda o: add_comment(token, o["identifier"], o["body"]),
            }.get(op["type"], lambda o: print(f"Unknown: {o['type']}"))(op)
    else:
        print(f"Unknown command: {cmd}", file=sys.stderr)
        print(__doc__)
        sys.exit(1)
