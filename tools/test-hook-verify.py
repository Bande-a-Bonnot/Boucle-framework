#!/usr/bin/env python3
"""Test runner for test-hook.sh — validates against real Boucle hooks.

Also serves as integration tests for the test-hook.sh tool itself.
Run from anywhere: python3 tools/test-hook-runner.py
"""
import subprocess, json, sys, os, tempfile

TOOLS_DIR = os.path.dirname(os.path.abspath(__file__))
FRAMEWORK_DIR = os.path.dirname(TOOLS_DIR)

def run_hook(hook_cmd, tool_name, tool_input, env_extra=None):
    stdin_data = json.dumps({"tool_name": tool_name, "tool_input": tool_input})
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        ["bash", "-c", hook_cmd],
        input=stdin_data, capture_output=True, text=True, timeout=10,
        cwd=FRAMEWORK_DIR, env=env
    )
    return result.returncode, result.stdout.strip(), result.stderr.strip()

def parse_decision(code, stdout):
    """Parse hook output into a decision string."""
    if not stdout:
        return "allow" if code == 0 else "error"
    try:
        data = json.loads(stdout)
        hso = data.get("hookSpecificOutput", {})
        decision = hso.get("permissionDecision", "")
        if not decision:
            dec = data.get("decision", "")
            decision = "deny" if dec == "block" else "allow" if dec == "approve" else dec
        return decision or "allow"
    except json.JSONDecodeError:
        return "parse_error"

# Create temp file-guard config for file-guard tests
fg_config = tempfile.NamedTemporaryFile(mode='w', suffix='.file-guard', delete=False)
fg_config.write("# Test config\n.env\nsecrets/\n*.pem\n[deny]\n.ssh/\n")
fg_config.close()

tests = [
    # bash-guard: dangerous commands blocked, safe commands allowed
    ("bash tools/bash-guard/hook.sh", "Bash", {"command": "echo hello"}, "allow", "bash-guard: safe command"),
    ("bash tools/bash-guard/hook.sh", "Bash", {"command": "rm -rf /"}, "deny", "bash-guard: rm -rf /"),
    ("bash tools/bash-guard/hook.sh", "Bash", {"command": "git push --force origin main"}, "deny", "bash-guard: force push main"),
    ("bash tools/bash-guard/hook.sh", "Bash", {"command": "ls -la"}, "allow", "bash-guard: ls"),
    # file-guard: needs FILE_GUARD_CONFIG env var
    (f"FILE_GUARD_CONFIG={fg_config.name} bash tools/file-guard/hook.sh", "Read", {"file_path": "/tmp/safe.txt"}, "allow", "file-guard: read safe path"),
    (f"FILE_GUARD_CONFIG={fg_config.name} bash tools/file-guard/hook.sh", "Write", {"file_path": ".env", "content": "x"}, "deny", "file-guard: write .env"),
    (f"FILE_GUARD_CONFIG={fg_config.name} bash tools/file-guard/hook.sh", "Read", {"file_path": ".ssh/id_rsa"}, "deny", "file-guard: read denied .ssh"),
    # git-safe: blocks dangerous git operations
    ("bash tools/git-safe/hook.sh", "Bash", {"command": "git status"}, "allow", "git-safe: safe git"),
    ("bash tools/git-safe/hook.sh", "Bash", {"command": "git reset --hard HEAD~5"}, "deny", "git-safe: reset --hard"),
]

passed = 0
failed = 0
verbose = "--verbose" in sys.argv

for hook_cmd, tool, inp, expected, label in tests:
    code, stdout, stderr = run_hook(hook_cmd, tool, inp)
    decision = parse_decision(code, stdout)

    status = "PASS" if decision == expected else "FAIL"
    if status == "PASS":
        passed += 1
    else:
        failed += 1

    icon = "\033[32mPASS\033[0m" if status == "PASS" else "\033[31mFAIL\033[0m"
    print(f"[{icon}] {label}: expected={expected} got={decision}")
    if verbose or status == "FAIL":
        if stdout:
            print(f"       stdout: {stdout[:200]}")
        if stderr:
            print(f"       stderr: {stderr[:200]}")

# Cleanup
os.unlink(fg_config.name)

print(f"\n{passed}/{passed+failed} passed, {failed} failed")
sys.exit(1 if failed else 0)
