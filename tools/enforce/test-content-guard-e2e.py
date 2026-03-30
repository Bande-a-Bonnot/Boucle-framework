#!/usr/bin/env python3
"""End-to-end tests for content_guard and scoped_content_guard features."""

import json
import subprocess
import tempfile
import os
import shutil
import sys

ENFORCE = os.path.join(os.path.dirname(__file__), "enforce-hooks.py")
passed = 0
failed = 0

def test(name, tool_name, tool_input, claude_md_text, expect_block):
    global passed, failed
    test_dir = tempfile.mkdtemp()
    claude_md = os.path.join(test_dir, "CLAUDE.md")
    with open(claude_md, "w") as f:
        f.write(claude_md_text)

    payload = json.dumps({"tool_name": tool_name, "tool_input": tool_input})
    result = subprocess.run(
        ["python3", ENFORCE, claude_md, "--evaluate"],
        input=payload, capture_output=True, text=True,
    )
    stdout = result.stdout.strip()
    blocked = "BLOCKED" in stdout or "block" in stdout.lower()

    if blocked == expect_block:
        print(f"  [PASS] {name}")
        passed += 1
    else:
        print(f"  [FAIL] {name}")
        print(f"         expected={'block' if expect_block else 'allow'}, got: {stdout[:120]}")
        failed += 1

    shutil.rmtree(test_dir)


def test_scan(name, claude_md_text, expected_types):
    global passed, failed
    test_dir = tempfile.mkdtemp()
    claude_md = os.path.join(test_dir, "CLAUDE.md")
    with open(claude_md, "w") as f:
        f.write(claude_md_text)

    result = subprocess.run(
        ["python3", ENFORCE, claude_md, "--scan", "--json"],
        capture_output=True, text=True,
    )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        print(f"  [FAIL] {name} (no JSON output)")
        failed += 1
        shutil.rmtree(test_dir)
        return

    found_types = [d.get("hook_type", "") for d in data.get("enforceable", [])]
    if all(t in found_types for t in expected_types):
        print(f"  [PASS] {name} (found: {found_types})")
        passed += 1
    else:
        print(f"  [FAIL] {name} (expected {expected_types}, found {found_types})")
        failed += 1

    shutil.rmtree(test_dir)


CLAUDE_MD = """## Code Quality @enforced
- Never write console.log
- No eval() calls

## Scoped Rules @enforced
- No SQL queries in controllers/
"""

print("content_guard and scoped_content_guard e2e tests")
print("=" * 50)

# Scan detection tests
print("\n--- Scan Detection ---")
test_scan(
    "scan detects content_guard for console.log",
    CLAUDE_MD,
    ["content-guard"],
)
test_scan(
    "scan detects scoped-content-guard for SQL in controllers",
    CLAUDE_MD,
    ["scoped-content-guard"],
)

# content_guard enforcement tests
print("\n--- content_guard Enforcement ---")
test(
    "Write with console.log is blocked",
    "Write",
    {"file_path": "/tmp/test.js", "content": "function foo() {\n  console.log('debug');\n  return 1;\n}"},
    CLAUDE_MD,
    expect_block=True,
)
test(
    "Edit with eval() in new_string is blocked",
    "Edit",
    {"file_path": "/tmp/test.js", "new_string": "const x = eval(userInput);", "old_string": "const x = 1;"},
    CLAUDE_MD,
    expect_block=True,
)
test(
    "Write without banned patterns is allowed",
    "Write",
    {"file_path": "/tmp/test.js", "content": "function foo() {\n  return 1;\n}"},
    CLAUDE_MD,
    expect_block=False,
)
test(
    "Read is not affected by content_guard",
    "Read",
    {"file_path": "/tmp/test.js"},
    CLAUDE_MD,
    expect_block=False,
)
test(
    "Bash is not affected by content_guard",
    "Bash",
    {"command": "echo console.log"},
    CLAUDE_MD,
    expect_block=False,
)

# scoped_content_guard enforcement tests
print("\n--- scoped_content_guard Enforcement ---")
test(
    "SQL in controllers/ is blocked",
    "Write",
    {"file_path": "controllers/user.js", "content": "const result = db.query('SELECT * FROM users');"},
    CLAUDE_MD,
    expect_block=True,
)
test(
    "SQL in models/ is allowed (out of scope)",
    "Write",
    {"file_path": "models/user.js", "content": "const result = db.query('SELECT * FROM users');"},
    CLAUDE_MD,
    expect_block=False,
)
test(
    "Non-SQL content in controllers/ is allowed",
    "Write",
    {"file_path": "controllers/user.js", "content": "function getUser(id) {\n  return users.find(id);\n}"},
    CLAUDE_MD,
    expect_block=False,
)
test(
    "Edit with SQL in controllers/ is blocked",
    "Edit",
    {"file_path": "controllers/api.js", "new_string": "db.execute('INSERT INTO logs VALUES (1)')"},
    CLAUDE_MD,
    expect_block=True,
)

print(f"\n{'=' * 50}")
print(f"Results: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
