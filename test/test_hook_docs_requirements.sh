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
        "repo_root=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\"",
        'if ($root) { Set-Location $root }',
        "representative hook payloads to each hook",
        "does not execute the dangerous shell or git commands",
        "**Windows (PowerShell 7+)",
        "tools/install.ps1) } recommended",
        "Or install all standalone hooks at once",
        "Project hooks skipped from subdirectories",
        "ancestor project settings warning",
        "If you use `claude -w`, also install [worktree-guard]",
        "delete unmerged or unpushed commits",
        "tools/install.sh | bash -s -- backup list",
        "tools/install.sh | bash -s -- restore settings.20260101_120000.json",
        "tools/install.sh | bash -s -- recommended curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- all curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.ps1) } all\" iex \"& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify",
        "tools/install.ps1) } backup list",
        "tools/install.ps1) } restore settings.20260101_120000.json",
        "start a fresh Claude Code session from that same project root",
        "existing session may have loaded the previous settings or hook files",
        "Test all installed hooks with representative payloads",
        "This is not a sandbox: verify the hook, start a fresh session, and review the known limitations",
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
        "root=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\"",
        'if ($root) { Set-Location $root }',
        "--- End Safety Summary ---",
        "safety-check --verify --summary-only",
        "tools/install.sh | bash curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- recommended curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- read-once git-safe file-guard curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "Test installed hooks with representative payloads",
    ],
    repo / "tools" / "enforce" / "README.md": [
        "PreToolUse boundaries for covered tool calls",
        "hard-block covered tool calls at the runtime level",
        "This is not a sandbox: verify the hook, start a fresh session, and review known limitations",
        "deterministic boundary for those covered Write/Edit/Bash operations",
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
        'if ($root) { Set-Location $root }',
        "Use `all` instead of `recommended` only when you want the full standalone hook",
        "--verify --summary-only",
        "safety summary triage guide",
        "team handoff report",
    ],
    repo / "tools" / "safety-check" / "CI.md": [
        "cd \"$(git rev-parse --show-toplevel)\"",
        "working-directory: ${{ github.workspace }}",
        "Run it from the project root that contains `.claude/settings.json`",
        "does not execute the dangerous shell or git commands",
        "run `safety-check --verify --strict` on a runner that has both `bash` and `pwsh`",
        "Do not use `install.ps1 verify` as proof for repo-local hooks",
        "installed under the CI user's `~/.claude` directory",
        "not a repo-local CI contract",
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
        'if ($root) { Set-Location $root }',
        "--summary-only",
        "--- End Safety Summary ---",
    ],
    repo / "tools" / "safety-check" / "SUPPORT_EXAMPLES.md": [
        "FAIL-OPEN public report",
        "Hook source: framework git-safe hook, not custom",
        "Verify: 1 FAIL-OPEN | 6 payload checks | 0 skipped",
        "Boundary: fix FAIL-OPEN hooks before trusting the hook layer.",
        "Do not paste raw hook stderr from the Claude Code session.",
        "temporary directory with throwaway hook paths",
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
        "team handoff report",
        "git rev-parse --show-toplevel",
        'if ($root) { Set-Location $root }',
        "tools/install.sh | bash -s -- backup list",
        "tools/install.sh | bash -s -- restore settings.20260101_120000.json",
        "tools/install.ps1) } backup list",
        "tools/install.ps1) } restore settings.20260101_120000.json",
    ],
    repo / "tools" / "safety-check" / "FIRST_TEST.md": [
        "temporary `HOME`",
        "temporary project",
        "does not install hooks",
        "does not prove your real Claude Code setup is safe",
        "HOME=\"$tmp_home\" bash -s -- --verify --summary-only",
        "Temporary paths are printed only in that keep-for-inspection mode.",
        "Verify: not run | no hooks found | 0 payload checks",
        "Boundary: install hooks before trusting the hook layer.",
        "Verification mode does not execute dangerous shell or git commands.",
        "repo_root=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\"",
        "curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended",
        "tools/install.ps1) } recommended",
        "See the [quickstart](QUICKSTART.md)",
    ],
    repo / "tools" / "enforce" / "READ_ONLY_AUDIT.md": [
        "This is read-only for the audited Claude Code session after the hook is installed",
        "Setting up the boundary intentionally edits project files first",
        "do the setup on a disposable branch or worktree",
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
        'if ($root) { Set-Location $root }',
        "Then verify the updated hook boundary",
    ],
    repo / "tools" / "safety-check" / "TEAM_HANDOFF.md": [
        "Use this when one person has verified a Claude Code hook boundary",
        "repo_root=\"$(git rev-parse --show-toplevel 2>/dev/null || pwd)\"",
        "--verify --summary-only",
        "Fresh Claude Code session started after verification",
        "Residual platform warnings",
        "Next recheck trigger",
        "Treat this as a boundary statement, not a certificate.",
        "For native Windows `install.ps1 verify`, replace the safety summary block",
        "temporary reproduction",
        "For public support threads, use the [safe support evidence guide]",
    ],
    repo / "docs" / "index.html": [
        "bash, python3, and jq",
        "No hook installation required for the audit",
        "repo_root=\"$(git rev-parse --show-toplevel 2&gt;/dev/null || pwd)\"",
        "install.ps1) } recommended",
        "install the same recommended set from PowerShell 7",
        "start a fresh Claude Code session from that same project root",
        "github.com/anthropics/claude-code/issues/37550",
        "Safety-check invokes the hook scripts with Claude-style JSON input",
        "does not execute the dangerous shell or git commands",
        "200+ Rust tests",
        "tools/safety-check/FIRST_TEST.md",
        "First Test",
        "tools/safety-check/QUICKSTART.md",
        "Quickstart",
        "tools/enforce/READ_ONLY_AUDIT.md",
        "Read-only Audit",
        "tools/safety-check/SUPPORT_EVIDENCE.md",
        "Safe Support Evidence",
        "tools/safety-check/TEAM_HANDOFF.md",
        "Team Handoff",
        "application/atom+xml",
        "Claude Code Hook Limitations Feed",
        "/limitations-feed.xml",
        "limitations-feed.xml",
        "Limitations Feed",
        "Atom updates",
        "tools/install.sh | bash -s -- recommended <span class=\"prompt-char\">$</span> curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "tools/install.sh | bash -s -- all <span class=\"prompt-char\">$</span> curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
    ],
    repo / "docs" / "recipes.html": [
        "tools/enforce/install.sh | bash",
        "python3 .claude/hooks/enforce-hooks.py --verify",
        "python3 .claude/hooks/enforce-hooks.py --smoke-test",
        "I want to try the hooks without keeping them installed",
        "borrowed machine, a client repo, a CI runner",
        "tools/install.sh | bash -s -- backup",
        "tools/install.sh | bash -s -- backup list",
        "tools/install.sh | bash -s -- uninstall all",
        "After uninstall, the summary should no longer claim a verified hook boundary.",
        "does not mean the current setup is protected.",
        "run <code>backup list</code> first and inspect before restoring",
        "tools/install.ps1) } uninstall all",
        "tools/install.ps1) } backup list",
        "temporary first test",
        "Read-only review or audit",
        "python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict",
        "python3 /tmp/enforce-hooks.py CLAUDE.md --smoke-test --strict",
        "In default write-protect mode it blocks Edit, Write, MultiEdit, NotebookEdit, and modifying Bash commands",
        "Put patterns under a <code>[deny]</code> section when Claude must not read, search, list, or reference those paths at all",
        "I need to leave a PR or incident handoff",
        "I want CI to fail when repo hooks stop blocking",
        "SAFETY_CHECK_SKIP_CLAUDE_VERSION=1 bash /tmp/safety-check.sh --verify --strict",
        "Do not treat <code>install.sh recommended</code> in CI as proof",
        "it does not prove the checked-out <code>.claude/settings.json</code> or repository hook files protect developers",
        "scripted safety-check checks",
        "Fresh Claude Code session started after verification: yes / no",
        "Treat this as a boundary statement, not a certificate.",
        "team handoff reports",
        "tools/install.sh | bash -s -- all <span class=\"prompt-char\">$</span> curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify",
        "start a fresh Claude Code session from the same project root",
        "Claude Code updated. Are my hooks still working?",
        "Fix path: back up settings, upgrade, doctor, then strictly verify from the same project root",
        "tools/install.sh | bash -s -- backup",
        "tools/install.ps1) } backup",
        "backup list",
        "Keep the backup until the fresh session proves the hook boundary still works.",
        "safety-check/check.sh | bash -s -- --verify --strict",
        "tools/safety-check/UPDATE_CHECKLIST.md",
        "application/atom+xml",
        "Claude Code Hook Limitations Feed",
        "/limitations-feed.xml",
        "Limitations Feed",
    ],
    repo / "docs" / "limitations.html": [
        "https://framework.boucle.sh/limitations.html",
        "Claude Code Hook Limitations Feed",
        "limitations-feed.xml",
        "Source data",
        "title=\"Machine-readable JSON",
        "<a href=\"/\">Home</a>",
        "<a href=\"/recipes.html\">Recipes</a>",
        "<a href=\"/limitations-feed.xml\">Limitations Feed</a>",
        "<a href=\"/limitations.json\">JSON</a>",
        "<a href=\"https://github.com/Bande-a-Bonnot/Boucle-framework\">GitHub</a>",
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
    repo / "docs" / "recipes.html": [
        "Blocks Read, Edit, Write, and Bash access to matching paths",
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
    repo / "tools" / "safety-check" / "CI.md": [
        "repository settings point to native `.ps1` hook scripts, either add PowerShell to the runner",
        "PowerShell installer verification path",
        "shell: pwsh run: | iex \"& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify\"",
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
