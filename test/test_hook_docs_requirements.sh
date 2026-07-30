#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Hook docs requirements =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])

docs = {
    repo / "README.md": [
        "**macOS / Linux requirements:** bash, python3, and jq",
        "installer uses python3 to manage",
        "safety-check uses python3",
        "most standalone shell hooks use jq",
        "No hook installation required for the audit",
        "--verify --summary-only",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
        "representative hook payloads to each hook",
        "does not execute the dangerous shell or git commands",
        "**Windows (PowerShell 7+)",
        "tools/install.ps1) } recommended",
        "Or install all standalone hooks at once",
        "Project hooks skipped from subdirectories",
        "ancestor project settings warning",
        "If you use `claude -w`, also install [worktree-guard]",
        "delete unmerged or unpushed commits",
        "tools/install.sh | bash -s -- recommended curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- all curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.ps1) } all\" iex \"& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify",
        "start a fresh Claude Code session from that same project root",
        "existing session may have loaded the previous settings or hook files",
        "Test all installed hooks with representative payloads",
    ],
    repo / "tools" / "README.md": [
        "**macOS / Linux:** bash, python3, and jq",
        "installers use python3 to manage",
        "safety-check uses python3",
        "6 of the 7 standalone shell hooks use jq",
        "**Windows:** [PowerShell 7+]",
        "Git Bash or WSL for safety-check",
        "tools/install.ps1) } recommended",
        "To choose hooks interactively instead",
        "stderr` and exit code 2",
        'JSON `permissionDecision: "deny"`',
        "not a universal hard-block contract",
        "Ancestor project settings warning",
        "subdirectory launches can skip root project hooks",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
        "--- End Safety Summary ---",
        "safety-check --verify --summary-only",
        "tools/install.sh | bash curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- recommended curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- read-once git-safe file-guard curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "Test installed hooks with representative payloads",
    ],
    repo / "tools" / "safety-check" / "README.md": [
        "No hook installation required for the audit",
        "## Requirements",
        "Bash 4+",
        "Python 3 (for JSON parsing of settings.json)",
        "Use `--verify` to send representative test payloads",
        "Hook Verification (sending representative test payloads)",
        "encoded as hook input",
        "It does not execute the shell or git commands",
        "install.sh | bash -s -- doctor",
        "install.sh | bash -s -- recommended",
        "install.ps1) } doctor",
        "install.ps1) } recommended",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
        "Use `all` instead of `recommended` only when you want the full standalone hook",
        "--verify --summary-only",
        "safety summary triage guide",
    ],
    repo / "tools" / "safety-check" / "CI.md": [
        "cd \"$(git rev-parse --show-toplevel)\"",
        "working-directory: ${{ github.workspace }}",
        "Run it from the project root that contains `.claude/settings.json`",
        "does not execute the dangerous shell or git commands",
    ],
    repo / "tools" / "safety-check" / "check.sh": [
        "No hook installation required for the audit",
        "Requires bash and python3",
        "sending representative test payloads",
    ],
    repo / "tools" / "safety-check" / "SUPPORT_EVIDENCE.md": [
        "Do not paste raw hook stderr from a live Claude Code session",
        "prefix hook stderr with the hook command path",
        "safety-check summary is the safer public artifact",
        "Build a minimal reproduction in a temporary directory",
        "smallest redacted settings file that reproduces the issue",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
        "--summary-only",
        "--- End Safety Summary ---",
    ],
    repo / "tools" / "safety-check" / "QUICKSTART.md": [
        "Do not paste raw hook stderr from a live Claude Code session",
        "platform can prefix it with the hook command path",
        "safe support evidence guide",
        "--verify --summary-only",
        "--- End Safety Summary ---",
        "install user-level hooks under",
        "register them in `~/.claude/settings.json`",
        "do not create repo-local `.claude/settings.json` policy",
        "project settings when they already exist",
        "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- all curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "The installer verifier sends representative payloads to the installed hooks",
        "does not execute the dangerous shell or git commands",
        "temporary-directory reproduction instead of real workspace",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
    ],
    repo / "tools" / "enforce" / "READ_ONLY_AUDIT.md": [
        "cd \"$(git rev-parse --show-toplevel)\"",
        "cp .claude/settings.json .claude/settings.json.pre-read-only.bak",
        "snapshots the project-level `.claude/settings.json` before",
        "remove the `enforce-pretooluse.sh` hook from Claude Code's",
        "Expect the strict audit to exit non-zero",
        "policy is no longer covered by",
        "zero `FAIL-OPEN` results for any remaining hooks",
        "start a fresh Claude Code session from that same project root",
        "old in-memory boundary",
    ],
    repo / "tools" / "safety-check" / "UPDATE_CHECKLIST.md": [
        "same project root you use to start Claude Code",
        "git rev-parse --show-toplevel",
        "Set-Location (git rev-parse --show-toplevel)",
        "Then verify the updated hook boundary",
    ],
    repo / "docs" / "index.html": [
        "bash, python3, and jq",
        "No hook installation required for the audit",
        'cd "$(git rev-parse --show-toplevel)"',
        "install.ps1) } recommended",
        "install the same recommended set from PowerShell 7",
        "start a fresh Claude Code session from that same project root",
        "github.com/anthropics/claude-code/issues/37550",
        "Safety-check invokes the hook scripts with Claude-style JSON input",
        "does not execute the dangerous shell or git commands",
        "200+ Rust tests",
        "tools/install.sh | bash -s -- recommended <span class=\"prompt-char\">$</span> curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- all <span class=\"prompt-char\">$</span> curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
    ],
    repo / "docs" / "recipes.html": [
        "tools/enforce/install.sh | bash",
    ],
}

missing = []
for path, snippets in docs.items():
    flat_text = " ".join(path.read_text().split())
    for snippet in snippets:
        if snippet not in flat_text:
            missing.append(f"{path.relative_to(repo)}: missing {snippet!r}")

if missing:
    raise SystemExit("Hook requirements docs drifted:\n" + "\n".join(missing))

hook_files = sorted((repo / "tools").glob("*/hook.sh"))
jq_hooks = [path for path in hook_files if "jq" in path.read_text()]
expected_count = f"{len(jq_hooks)} of the {len(hook_files)} standalone shell hooks use jq"
if expected_count != "6 of the 7 standalone shell hooks use jq":
    raise SystemExit(
        "Hook jq dependency count changed; update requirements docs and this "
        f"contract together (actual: {expected_count})"
    )

banned = {
    repo / "tools" / "safety-check" / "README.md": [
        "## No dependencies",
        "real test payloads",
    ],
    repo / "tools" / "safety-check" / "check.sh": [
        "No installation, no dependencies",
        "real payloads",
        "live verification (sends `rm -rf /`",
    ],
    repo / "README.md": [
        "cargo test           # Framework tests (",
        "218 Rust tests",
        "Boucle-framework has 96 stars",
        "not yet in the official docs",
        "real payloads",
    ],
    repo / "tools" / "enforce" / "README.md": [
        "The current docs still describe",
        "The docs still say",
    ],
    repo / "docs" / "index.html": [
        "218 Rust tests",
    ],
    repo / "docs" / "recipes.html": [
        "tools/install.sh | bash -s -- enforce",
    ],
}

violations = []
for path, snippets in banned.items():
    text = path.read_text()
    for snippet in snippets:
        if snippet in text:
            violations.append(f"{path.relative_to(repo)}: remove stale {snippet!r}")

if violations:
    raise SystemExit("Hook requirements docs contain stale wording:\n" + "\n".join(violations))

print("Hook docs requirements OK")
PY
