#!/usr/bin/env python3
# description: HackerNews monitor with security filtering
"""Monitor HN posts for comments with injection detection.

Usage: boucle hn <item-id> [--raw]
"""
import json
import re
import sys
import urllib.request

HIGH_RISK = [
    r"ignore\s+(all\s+)?previous\s+instructions",
    r"you\s+are\s+now", r"forget\s+everything",
    r"system\s*:", r"disregard\s+(all\s+)?(above|previous)",
    r"override\s+(all\s+)?", r"pretend\s+(you\s+are|to\s+be)",
    r"<\s*system\s*>", r"\[INST\]", r"<\|im_start\|>",
]
MEDIUM_RISK = [
    r"delete\s+(all\s+)?files", r"rm\s+-rf",
    r"execute\s+(this\s+)?command", r"credentials?\s*(file|password|secret|key)",
]

def fetch(url):
    try:
        req = urllib.request.Request(url)
        req.add_header("User-Agent", "Boucle/1.0")
        return json.loads(urllib.request.urlopen(req, timeout=10).read().decode())
    except Exception:
        return None

def check(text):
    if not text:
        return "clean", []
    low = text.lower()
    found = [(p, "HIGH") for p in HIGH_RISK if re.search(p, low)]
    found += [(p, "MEDIUM") for p in MEDIUM_RISK if re.search(p, low)]
    if any(l == "HIGH" for _, l in found):
        return "HIGH", [p for p, _ in found]
    if found:
        return "MEDIUM", [p for p, _ in found]
    return "clean", []

def get_comments(item_id, depth=0, max_depth=3):
    if depth > max_depth:
        return []
    item = fetch(f"https://hacker-news.firebaseio.com/v0/item/{item_id}.json")
    if not item or item.get("dead") or item.get("deleted"):
        return []
    comments = []
    if item.get("type") == "comment" and item.get("text"):
        comments.append({"id": item["id"], "by": item.get("by", "?"),
            "text": item["text"], "depth": depth})
    for kid in item.get("kids", []):
        comments.extend(get_comments(kid, depth + 1, max_depth))
    return comments

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)

    item_id, raw = sys.argv[1], "--raw" in sys.argv
    post = fetch(f"https://hacker-news.firebaseio.com/v0/item/{item_id}.json")
    if not post:
        print("Could not fetch post."); sys.exit(1)

    print(f"## HN: {post.get('title', '?')}")
    print(f"Score: {post.get('score', 0)} | Comments: {post.get('descendants', 0)} | By: {post.get('by', '?')}")
    if post.get("dead"):
        print("[DEAD]")
    print()

    comments = []
    for kid in post.get("kids", []):
        comments.extend(get_comments(kid))

    if not comments:
        print("(No comments)"); return

    for c in comments:
        text = re.sub(r"<[^>]+>", " ", c["text"]).strip()
        text = re.sub(r"\s+", " ", text)
        level, patterns = check(text)
        indent = "  " * c["depth"]
        if level == "HIGH" and not raw:
            print(f"{indent}**{c['by']}**: [BLOCKED — injection pattern detected]")
        else:
            if level == "MEDIUM" and not raw:
                print(f"{indent}**{c['by']}** [SECURITY WARNING]:")
            else:
                print(f"{indent}**{c['by']}**:")
            print(f"{indent}  {text[:500]}")
        print()

if __name__ == "__main__":
    main()
