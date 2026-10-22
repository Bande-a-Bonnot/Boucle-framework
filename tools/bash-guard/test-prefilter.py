#!/usr/bin/env python3
"""Check that the bash-guard fast path covers every check.

hook.sh exits early when the command matches none of the patterns in
PREFILTER_PATTERNS (case-sensitive) and PREFILTER_PATTERNS_I (-i). A check
whose pattern is missing from those lists would never run, so this test
fails if any `grep -qE` or `grep -qiE` pattern in hook.sh is not listed.

Run: python3 tools/bash-guard/test-prefilter.py [path/to/hook.sh]
"""
import re
import sys
from pathlib import Path

hook = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).with_name("hook.sh"))
src = hook.read_text()

# A shell word in single quotes, or in double quotes with backslash escapes.
QUOTED = r"""('[^']*'|"(?:[^"\\]|\\.)*")"""


def array_items(name):
    m = re.search(rf"^{name}=\(\n(.*?)^\)", src, re.S | re.M)
    if not m:
        sys.exit(f"FAIL: {name} array not found in {hook}")
    return set(re.findall(QUOTED, m.group(1)))


listed = array_items("PREFILTER_PATTERNS")
listed_i = array_items("PREFILTER_PATTERNS_I")

missing = []
for flags, pattern in re.findall(r"grep -q(i?)E " + QUOTED, src):
    # Custom deny rules run before the fast path, so they need no entry.
    if "${denied}" in pattern:
        continue
    if pattern not in (listed_i if flags else listed):
        missing.append(("-qiE " if flags else "-qE ") + pattern)

if missing:
    print("FAIL: checks missing from the bash-guard fast path:")
    for p in missing:
        print("  " + p)
    sys.exit(1)
print(f"PASS: fast path covers all {len(listed) + len(listed_i)} check patterns")
