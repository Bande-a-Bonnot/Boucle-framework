#!/usr/bin/env python3
"""Regression test for hook installer JSON format (issue #1).

tclancy reported that individual installers wrote flat JSON format:
  {"type": "command", "command": "..."}
instead of the nested format Claude Code expects:
  {"hooks": [{"type": "command", "command": "..."}]}

This test runs each individual installer locally and verifies the output.
"""

import subprocess
import tempfile
import shutil
import os
import json
import sys

TOOLS = os.path.dirname(os.path.abspath(__file__))
HOOKS = ["bash-guard", "git-safe", "file-guard", "branch-guard", "session-log", "read-once"]

HOOK_TYPES = {
    "bash-guard": "PreToolUse",
    "git-safe": "PreToolUse",
    "file-guard": "PreToolUse",
    "branch-guard": "PreToolUse",
    "session-log": "PostToolUse",
    "read-once": "PreToolUse",
}

passes = 0
fails = 0


def p(msg):
    global passes
    passes += 1
    print(f"  PASS: {msg}")


def f(msg):
    global fails
    fails += 1
    print(f"  FAIL: {msg}")


def setup_hook_dir(test_home, hook):
    """Pre-create hook files so installer skips download."""
    hook_dir = os.path.join(test_home, ".claude", hook)
    os.makedirs(hook_dir, exist_ok=True)
    with open(os.path.join(hook_dir, "hook.sh"), "w") as fh:
        fh.write("#!/bin/bash\n")
    os.chmod(os.path.join(hook_dir, "hook.sh"), 0o755)
    if hook == "file-guard":
        with open(os.path.join(hook_dir, "init.sh"), "w") as fh:
            fh.write("#!/bin/bash\n")
        os.chmod(os.path.join(hook_dir, "init.sh"), 0o755)
    if hook == "read-once":
        with open(os.path.join(hook_dir, "read-once"), "w") as fh:
            fh.write("#!/bin/bash\n")
        os.chmod(os.path.join(hook_dir, "read-once"), 0o755)


def run_installer(test_home, hook):
    """Run an individual hook installer with HOME overridden."""
    installer = os.path.join(TOOLS, hook, "install.sh")
    env = os.environ.copy()
    env["HOME"] = test_home
    return subprocess.run(
        ["bash", installer], env=env, capture_output=True, timeout=10
    )


def load_settings(test_home):
    """Load settings.json from the test home."""
    path = os.path.join(test_home, ".claude", "settings.json")
    if not os.path.exists(path):
        return None
    with open(path) as sf:
        return json.load(sf)


def check_nested_format(entries):
    """Check all entries use nested format."""
    return all("hooks" in e for e in entries)


def check_hook_in_commands(entries, hook_name):
    """Check that a hook name appears in the nested commands."""
    for entry in entries:
        for h in entry.get("hooks", []):
            if hook_name in h.get("command", ""):
                return True
    return False


def safety_check_detects(settings, target_hook):
    """Replicate the safety-check detection logic."""
    detected = set()
    needles = ["bash-guard", "git-safe", "file-guard", "branch-guard", "session-log", "read-once"]
    for hook_type in ["PreToolUse", "PostToolUse"]:
        for entry in settings.get("hooks", {}).get(hook_type, []):
            cmds = [entry.get("command", "")]
            for hk in entry.get("hooks", []):
                cmds.append(hk.get("command", ""))
            for cmd in cmds:
                for needle in needles:
                    if needle in cmd:
                        detected.add(needle)
    return target_hook in detected


print("=== Hook Format Regression Tests (issue #1) ===")

for hook in HOOKS:
    installer = os.path.join(TOOLS, hook, "install.sh")
    if not os.path.exists(installer):
        f(f"{hook}: installer not found")
        continue

    print(f"--- {hook} ---")
    test_home = tempfile.mkdtemp()
    try:
        setup_hook_dir(test_home, hook)
        run_installer(test_home, hook)

        settings = load_settings(test_home)
        if settings is None:
            f(f"{hook}: settings.json not created")
            continue

        hook_type = HOOK_TYPES[hook]
        entries = settings.get("hooks", {}).get(hook_type, [])
        if not entries:
            f(f"{hook}: no {hook_type} entries")
            continue

        if check_nested_format(entries):
            p(f"{hook}: writes nested format ({hook_type})")
        else:
            f(f"{hook}: writes FLAT format (the bug from issue #1)")

        if check_hook_in_commands(entries, hook):
            p(f"{hook}: command references {hook}")
        else:
            f(f"{hook}: command does not reference {hook}")

        if safety_check_detects(settings, hook):
            p(f"{hook}: detected by safety-check logic")
        else:
            f(f"{hook}: NOT detected by safety-check")
    finally:
        shutil.rmtree(test_home, ignore_errors=True)


print("--- Mixed install (two individual installers) ---")
test_home = tempfile.mkdtemp()
try:
    for hook in ["bash-guard", "git-safe"]:
        setup_hook_dir(test_home, hook)
        run_installer(test_home, hook)

    settings = load_settings(test_home)
    entries = settings.get("hooks", {}).get("PreToolUse", [])
    if len(entries) == 2:
        p("two individual installs: 2 entries")
    else:
        f(f"two individual installs: expected 2, got {len(entries)}")
    if check_nested_format(entries):
        p("two individual installs: all nested")
    else:
        f("two individual installs: some flat")
finally:
    shutil.rmtree(test_home, ignore_errors=True)


print("--- Flat-to-nested migration ---")
test_home = tempfile.mkdtemp()
try:
    setup_hook_dir(test_home, "bash-guard")
    settings_path = os.path.join(test_home, ".claude", "settings.json")
    hook_path = os.path.join(test_home, ".claude", "bash-guard", "hook.sh")
    flat = {
        "hooks": {
            "PreToolUse": [
                {"type": "command", "command": hook_path}
            ]
        }
    }
    with open(settings_path, "w") as sf:
        json.dump(flat, sf, indent=2)

    run_installer(test_home, "bash-guard")

    settings = load_settings(test_home)
    entries = settings.get("hooks", {}).get("PreToolUse", [])
    all_nested = all("hooks" in e for e in entries)
    no_flat_type = all("type" not in e for e in entries)
    if all_nested and no_flat_type:
        p("flat format migrated to nested on re-install")
    else:
        f("flat format NOT migrated on re-install")
        print(f"    entries: {json.dumps(entries, indent=2)}")
finally:
    shutil.rmtree(test_home, ignore_errors=True)


print("--- Executable bits (git mode) ---")
# All hook.sh, install.sh, and CLI scripts should be executable in git
executable_scripts = []
for hook in HOOKS:
    executable_scripts.append(os.path.join(TOOLS, hook, "hook.sh"))
    install = os.path.join(TOOLS, hook, "install.sh")
    if os.path.exists(install):
        executable_scripts.append(install)
# Extra scripts that should be executable
for extra in [
    os.path.join(TOOLS, "install.sh"),
    os.path.join(TOOLS, "enforce", "enforce-hooks.py"),
    os.path.join(TOOLS, "enforce", "install.sh"),
]:
    if os.path.exists(extra):
        executable_scripts.append(extra)

for script in executable_scripts:
    if os.access(script, os.X_OK):
        p(f"{os.path.relpath(script, TOOLS)}: executable")
    else:
        f(f"{os.path.relpath(script, TOOLS)}: NOT executable (+x missing)")


print()
print(f"Results: {passes} passed, {fails} failed (total {passes + fails})")
if fails > 0:
    sys.exit(1)
