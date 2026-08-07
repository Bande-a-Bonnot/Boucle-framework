# Read-only audit mode

Use this recipe when Claude Code should inspect, test, and report without
modifying the project. Plain prompt instructions like "do not edit files" are
not enough for this boundary. The model can still call Write, Edit, Bash
redirects, database mutations, Docker rebuilds, or git commands unless a hook
blocks those tool calls before execution.

This is read-only for the audited Claude Code session after the hook is
installed. Setting up the boundary intentionally edits project files first: you
add an `@enforced` rule to `CLAUDE.md` and register a project-level hook in
`.claude/settings.json`. If you need the main workspace untouched, do the setup
on a disposable branch or worktree and keep the settings backup below until the
audit is finished.

## 1. Add the policy

Paste this into your project's `CLAUDE.md`:

```markdown
## Read-only mode @enforced
- Never modify any files
- Never run rm -rf
- Never run `>`, `>>`, `tee`, `touch`, `mkdir`, `rm`, `sed -i`, `perl -pi`, `mv`, `cp`, `unlink`, `chmod`, or `chown`
- Never run ALTER, DROP, TRUNCATE, INSERT, UPDATE, or DELETE
- Never run docker restart, docker stop, docker build, or docker rm
- Never run sudo
- Never run git commit, git push, or git merge
```

The `@enforced` tag is required. Without it, `enforce-hooks.py` can suggest the
rules but will not activate them.

## 2. Install the dynamic hook

Run these commands from the project root, next to the `CLAUDE.md` you edited.
If the directory is in a git checkout, the first two lines move to the repo
root. Outside git, they keep you in the current project directory:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
mkdir -p .claude
backup_stamp="$(date +%Y%m%d_%H%M%S)"
test -f .claude/settings.json && cp -p .claude/settings.json ".claude/settings.json.read-only-${backup_stamp}.bak"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py CLAUDE.md --scan
python3 /tmp/enforce-hooks.py CLAUDE.md --install-plugin
```

Plugin mode installs one `PreToolUse` hook that re-reads `CLAUDE.md` on every
tool call. If you edit the read-only policy later, you do not need to reinstall
the hook.
The backup command snapshots the project-level `.claude/settings.json` before
`--install-plugin` registers the hook. The timestamp keeps repeated audit setup
runs from overwriting the previous snapshot. Keep the intended snapshot until
the audit is finished.

## 3. Verify the hook is registered

Run from the project root:

```sh
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
python3 /tmp/enforce-hooks.py CLAUDE.md --verify --strict
```

`--audit --strict` confirms the `@enforced` rules are covered by an active hook.
`--verify --strict` checks the installed hook file, registration, executable
bit, and common fail-open mistakes.

## 4. Check the full Claude Code boundary

Run the safety check from the same project root:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

This catches problems outside the read-only rule itself: hook-disabling
environment variables, invalid user or project `settings.json`, missing hook
files, non-executable shell hooks, and other installed hooks that fail open.

For CI or a scripted workstation check, make those findings fail the command:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

Do not treat the boundary as verified if the summary says `Verify: not run`,
`no hooks found`, `no payload checks ran`, or reports any `FAIL-OPEN` result.
Fix those first, then re-run the check from the project root.

## 5. Read the result

The safety-check summary is the trust boundary for the next Claude Code
session. Do not use the letter grade alone.

Stop and fix the setup first when the summary says:

- `Verify: not run`
- `no hooks found`
- `0 payload checks`
- any `FAIL-OPEN` hook
- skipped <code>PreToolUse</code> checks for hooks you expected to enforce the
  read-only policy
- broken hook files or invalid user/project settings JSON

The minimum useful read-only result is `Verify: 0 FAIL-OPEN` with at least one
payload check for the project-level `PreToolUse` hook. A Grade C with clean
verification can be good enough for an audit session when remaining warnings
are platform limitations or unrelated hygiene. Record the residual warnings
instead of reinstalling repeatedly to chase an A.

For result interpretation, use the safety summary triage guide before asking a
tester or teammate to copy what is safe to share:

- [First Test](../safety-check/FIRST_TEST.md)
- [Quickstart](../safety-check/QUICKSTART.md)
- [Read-only Audit](READ_ONLY_AUDIT.md)
- [Safe Support Evidence](../safety-check/SUPPORT_EVIDENCE.md)
- [Safe Support Examples](../safety-check/SUPPORT_EXAMPLES.md)
- [Triage](../safety-check/TRIAGE.md)

The docs path above is backed by the safety-check shell tests and the
framework's 200+ Rust tests, but those tests do not prove your local hook
registration. Your local proof is the fresh `--verify` output from the same
project root where the audited Claude Code session will start.

## 6. Smoke test the runtime boundary

After a clean verification, start a fresh Claude Code session from that same
project root before relying on read-only mode. The hook registration and
project settings are on disk, but a session that was already open may still be
using its old in-memory boundary.

Run from the project root:

```sh
python3 /tmp/enforce-hooks.py CLAUDE.md --smoke-test --strict
```

Smoke testing executes installed hooks with representative `PreToolUse`
payloads. The read-only policy should block write-style payloads and allow
benign reads. The generic smoke test labels a blocked "Write to a temp file" as
a false-positive warning because that write is normally benign. In read-only
mode, that warning is expected. `--strict` still passes when the hook responds
correctly.

For a direct manual probe, start Claude Code in the project and ask it to read a
file, then ask it to create a temporary file. The read should be allowed. The
write should be blocked by the hook before any file is created.

## 7. Use the mode

Start sessions with a narrow prompt, for example:

```text
Audit this repository. Do not edit files, do not run migrations, do not restart services, and do not commit. Report findings only.
```

The prompt still matters because it tells the model what work to do. The hook is
the enforcement layer that stops tool calls when the model drifts.

## 8. Remove or relax it

To leave read-only mode, remove or rename the `Read-only mode @enforced` section
in `CLAUDE.md`, then verify the boundary from the same project root:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Plugin mode reads `CLAUDE.md` dynamically, so it stops enforcing the read-only
rules on the next tool call after the section is removed or renamed. The audit
should pass with `0/0 classifiable rules enforced` if there are no other
`@enforced` rules in the file.

If you want warnings instead of hard blocks, change the heading to:

```markdown
## Read-only mode @enforced(warn)
```

Warnings are useful for dry runs, but they do not provide a read-only boundary.
Use `@enforced` for real audits.

If you want to remove the plugin registration entirely, restore the project
settings snapshot only when you want `.claude/settings.json` returned to its
pre-audit state, or remove the `enforce-pretooluse.sh` hook from Claude Code's
hooks UI. Then re-run the same checks:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
ls -1t .claude/settings.json.read-only-*.bak 2>/dev/null || true
cp -p .claude/settings.json.read-only-20260101_120000.bak .claude/settings.json
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

If there was no pre-audit settings file, there will be no
`.claude/settings.json.read-only-*.bak` snapshot to restore. In that case,
remove only the temporary enforce hook entry and generated plugin files:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
python3 - <<'PY'
import json
from pathlib import Path

path = Path(".claude/settings.json")
if not path.exists():
    raise SystemExit(0)
settings = json.loads(path.read_text())
hooks = settings.get("hooks", {})
pre_tool = hooks.get("PreToolUse", [])
for entry in pre_tool:
    entry["hooks"] = [
        hook for hook in entry.get("hooks", [])
        if not hook.get("command", "").endswith("enforce-pretooluse.sh")
    ]
hooks["PreToolUse"] = [
    entry for entry in pre_tool
    if entry.get("hooks")
]
if not hooks["PreToolUse"]:
    hooks.pop("PreToolUse")
if not hooks:
    settings.pop("hooks", None)
path.write_text(json.dumps(settings, indent=2) + "\n")
PY
rm -f .claude/hooks/enforce-hooks.py .claude/hooks/enforce-pretooluse.sh
rmdir .claude/hooks .claude 2>/dev/null || true
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Use the cleanup snippet above only for the temporary plugin files created by
this recipe. If `.claude/settings.json` contains other project settings, keep
the file and remove only the `enforce-pretooluse.sh` hook entry.

Expect the strict audit to exit non-zero if `CLAUDE.md` still contains the
`Read-only mode @enforced` section, because the policy is no longer covered by
an active hook. Also expect it to fail if the restored settings snapshot
contains broken hook references. The safety-check summary should still show
zero `FAIL-OPEN` results for any remaining hooks you intend to keep.
