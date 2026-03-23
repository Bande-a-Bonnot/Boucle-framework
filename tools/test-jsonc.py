#!/usr/bin/env python3
"""Test JSONC handling in the unified installer."""
import json
import re
import sys

PASS = 0
FAIL = 0

def test_pass(msg):
    global PASS
    PASS += 1
    print(f"  PASS: {msg}")

def test_fail(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL: {msg}")

def strip_jsonc(text):
    """Strip // and /* */ comments from JSONC, respecting quoted strings."""
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        if in_str:
            if text[i] == '\\' and i + 1 < n:
                out.append(text[i:i+2]); i += 2; continue
            if text[i] == '"': in_str = False
            out.append(text[i]); i += 1
        else:
            if text[i] == '"':
                in_str = True; out.append(text[i]); i += 1
            elif i + 1 < n and text[i:i+2] == '//':
                while i < n and text[i] != '\n': i += 1
            elif i + 1 < n and text[i:i+2] == '/*':
                i += 2
                while i + 1 < n and text[i:i+2] != '*/': i += 1
                i += 2
            else:
                out.append(text[i]); i += 1
    return ''.join(out)

print("=== JSONC Handling Tests ===")

# Test 1: Line comments
print("--- Line comments ---")
jsonc = '{\n  // This is a comment\n  "allowedTools": ["Bash"],\n  "denyRead": [".env"] // inline\n}'
try:
    result = json.loads(strip_jsonc(jsonc))
    if result.get("allowedTools") == ["Bash"] and result.get("denyRead") == [".env"]:
        test_pass("// comments stripped, values preserved")
    else:
        test_fail(f"wrong values: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 2: Block comments
print("--- Block comments ---")
jsonc2 = '{\n  /* Block comment */\n  "hooks": {\n    "PreToolUse": []\n  }\n}'
try:
    result = json.loads(strip_jsonc(jsonc2))
    if "hooks" in result:
        test_pass("/* */ block comments stripped")
    else:
        test_fail(f"missing hooks: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 3: Multi-line block comment
print("--- Multi-line block ---")
jsonc3 = '{\n  /* This is\n     a multi-line\n     comment */\n  "key": "value"\n}'
try:
    result = json.loads(strip_jsonc(jsonc3))
    if result.get("key") == "value":
        test_pass("multi-line block comment stripped")
    else:
        test_fail(f"wrong value: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 4: Comments inside strings must NOT be stripped
print("--- Comments in strings ---")
jsonc4 = '{"url": "https://example.com/path", "note": "use // for comments"}'
try:
    result = json.loads(strip_jsonc(jsonc4))
    if result.get("url") == "https://example.com/path" and "// for" in result.get("note", ""):
        test_pass("// inside strings preserved")
    else:
        test_fail(f"string content damaged: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 5: Regular JSON passes through unchanged
print("--- Regular JSON ---")
regular = '{"key": "value", "num": 42, "arr": [1, 2, 3]}'
try:
    result = json.loads(strip_jsonc(regular))
    if result == {"key": "value", "num": 42, "arr": [1, 2, 3]}:
        test_pass("regular JSON unchanged")
    else:
        test_fail(f"modified: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 6: Empty object
print("--- Edge cases ---")
try:
    result = json.loads(strip_jsonc("{}"))
    if result == {}:
        test_pass("empty object handled")
    else:
        test_fail(f"wrong: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 7: Escaped quotes in strings
jsonc7 = '{"key": "value with \\"quote\\"", "a": 1} // comment'
try:
    result = json.loads(strip_jsonc(jsonc7))
    if result.get("a") == 1:
        test_pass("escaped quotes handled")
    else:
        test_fail(f"wrong: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 8: Trailing comma (common JSONC feature) - strip_jsonc doesn't handle this
# but that's OK since we just handle comments
jsonc8 = '{"a": 1, "b": 2} // trailing'
try:
    result = json.loads(strip_jsonc(jsonc8))
    if result == {"a": 1, "b": 2}:
        test_pass("trailing comment stripped")
    else:
        test_fail(f"wrong: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 9: URL-like strings (https://) should not be treated as comments
print("--- URL handling ---")
jsonc9 = '{"command": "https://github.com/repo"}'
try:
    result = json.loads(strip_jsonc(jsonc9))
    if result.get("command") == "https://github.com/repo":
        test_pass("URLs in strings preserved")
    else:
        test_fail(f"URL damaged: {result}")
except Exception as e:
    test_fail(f"parse error: {e}")

# Test 10: Real-world Claude Code settings.json with JSONC
print("--- Real-world JSONC ---")
real_jsonc = """{
  // Claude Code user settings
  "allowedTools": ["Bash", "Read", "Write"],
  "denyRead": [".env", ".env.local"],
  "denyWrite": ["package-lock.json"],
  "hooks": {
    // Safety hooks
    "PreToolUse": [
      {
        /* File guard hook */
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/file-guard/hook.sh"
          }
        ]
      }
    ],
    "PostToolUse": [] // empty for now
  }
}"""
try:
    result = json.loads(strip_jsonc(real_jsonc))
    if (result.get("allowedTools") == ["Bash", "Read", "Write"]
        and result.get("denyRead") == [".env", ".env.local"]
        and len(result.get("hooks", {}).get("PreToolUse", [])) == 1):
        test_pass("real-world JSONC settings parsed correctly")
    else:
        test_fail(f"real-world parse wrong: {json.dumps(result, indent=2)}")
except Exception as e:
    test_fail(f"real-world parse error: {e}")

# Test 11: JSONC detection regex
print("--- JSONC detection ---")
detect_re = r'(?<!["\w])//[^\n]*|/\*[\s\S]*?\*/'

has_comments = bool(re.search(detect_re, jsonc))
if has_comments:
    test_pass("detects // comments")
else:
    test_fail("missed // comments")

has_block = bool(re.search(detect_re, jsonc2))
if has_block:
    test_pass("detects /* */ comments")
else:
    test_fail("missed /* */ comments")

# Regular JSON should ideally not trigger, but URL false positives are acceptable
# since strip_jsonc is safe on non-JSONC input

print()
print(f"Results: {PASS} passed, {FAIL} failed (total {PASS + FAIL})")
sys.exit(0 if FAIL == 0 else 1)
