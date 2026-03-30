#!/usr/bin/env python3
"""Test the uninstall Python logic in isolation (no filesystem needed)."""

import json
import os
import sys

PASS = 0
FAIL = 0


def ok(msg):
    global PASS
    PASS += 1
    print(f"  PASS: {msg}")


def fail(msg):
    global FAIL
    FAIL += 1
    print(f"  FAIL: {msg}")


def make_settings(*hooks):
    """Build a settings dict with the given hooks installed."""
    settings = {
        "allowedTools": ["Bash"],
        "denyRead": [".env"],
        "hooks": {}
    }
    for hook in hooks:
        event = "PostToolUse" if hook == "session-log" else "PreToolUse"
        command = os.path.expanduser(f"~/.claude/{hook}/hook.sh")
        entry = {"hooks": [{"type": "command", "command": command, "timeout": 5000}]}
        if event not in settings["hooks"]:
            settings["hooks"][event] = []
        settings["hooks"][event].append(entry)
    return settings


def run_uninstall(settings, hooks_to_remove):
    """Run the uninstall logic on settings dict. Returns modified settings."""
    import copy
    settings = copy.deepcopy(settings)

    for hook in hooks_to_remove:
        command = os.path.expanduser(f"~/.claude/{hook}/hook.sh")
        for event in list(settings.get("hooks", {}).keys()):
            entries = settings["hooks"][event]
            settings["hooks"][event] = [
                h for h in entries
                if not (
                    isinstance(h, dict) and (
                        h.get("command", "") == command or
                        any(hk.get("command", "") == command
                            for hk in h.get("hooks", []))
                    )
                )
            ]
            if not settings["hooks"][event]:
                del settings["hooks"][event]

    if "hooks" in settings and not settings["hooks"]:
        del settings["hooks"]

    return settings


def count_hooks(settings, event="PreToolUse"):
    return len(settings.get("hooks", {}).get(event, []))


def has_hook(settings, hook_name):
    command = os.path.expanduser(f"~/.claude/{hook_name}/hook.sh")
    for event in settings.get("hooks", {}).values():
        for entry in event:
            if isinstance(entry, dict):
                if entry.get("command", "") == command:
                    return True
                for hk in entry.get("hooks", []):
                    if hk.get("command", "") == command:
                        return True
    return False


print("=== Uninstall Logic Tests ===")
print()

print("--- Remove single hook ---")
s = make_settings("read-once", "git-safe", "bash-guard")
result = run_uninstall(s, ["read-once"])

if not has_hook(result, "read-once"):
    ok("read-once removed from settings")
else:
    fail("read-once still in settings")

if has_hook(result, "git-safe"):
    ok("git-safe preserved")
else:
    fail("git-safe lost")

if has_hook(result, "bash-guard"):
    ok("bash-guard preserved")
else:
    fail("bash-guard lost")

if count_hooks(result) == 2:
    ok("correct hook count after removal")
else:
    fail(f"expected 2 hooks, got {count_hooks(result)}")

print()
print("--- Remove multiple hooks ---")
result = run_uninstall(s, ["read-once", "git-safe"])

if count_hooks(result) == 1:
    ok("2 hooks removed, 1 remaining")
else:
    fail(f"expected 1 hook, got {count_hooks(result)}")

if has_hook(result, "bash-guard"):
    ok("bash-guard survived multi-remove")
else:
    fail("bash-guard lost in multi-remove")

print()
print("--- Remove all hooks cleans up ---")
s = make_settings("read-once", "git-safe")
result = run_uninstall(s, ["read-once", "git-safe"])

if "hooks" not in result:
    ok("empty hooks object removed")
else:
    fail("empty hooks object left behind")

if "allowedTools" in result:
    ok("allowedTools preserved after full uninstall")
else:
    fail("allowedTools lost")

if "denyRead" in result:
    ok("denyRead preserved after full uninstall")
else:
    fail("denyRead lost")

print()
print("--- Remove hook not in settings (no-op) ---")
s = make_settings("git-safe")
result = run_uninstall(s, ["read-once"])

if count_hooks(result) == 1:
    ok("removing absent hook is no-op")
else:
    fail(f"removing absent hook changed count to {count_hooks(result)}")

if has_hook(result, "git-safe"):
    ok("existing hook untouched")
else:
    fail("existing hook removed by accident")

print()
print("--- Mixed PreToolUse and PostToolUse ---")
s = make_settings("bash-guard", "session-log")
result = run_uninstall(s, ["session-log"])

if count_hooks(result, "PreToolUse") == 1:
    ok("PreToolUse hook preserved")
else:
    fail("PreToolUse hook affected")

if "PostToolUse" not in result.get("hooks", {}):
    ok("empty PostToolUse cleaned up")
else:
    fail("empty PostToolUse left behind")

print()
print("--- Flat format hooks (command at top level) ---")
s = {
    "hooks": {
        "PreToolUse": [
            {"type": "command", "command": os.path.expanduser("~/.claude/git-safe/hook.sh")}
        ]
    }
}
result = run_uninstall(s, ["git-safe"])

if "hooks" not in result:
    ok("flat-format hook removed")
else:
    fail("flat-format hook not removed")

print()
print("--- Empty settings (no hooks key) ---")
s = {"allowedTools": ["Bash"]}
result = run_uninstall(s, ["read-once"])

if "allowedTools" in result:
    ok("settings without hooks key handled gracefully")
else:
    fail("settings without hooks key broke")

print()
print(f"Results: {PASS} passed, {FAIL} failed (total {PASS + FAIL})")
sys.exit(0 if FAIL == 0 else 1)
