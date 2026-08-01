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

Run these commands from the project root, next to the `CLAUDE.md` you edited:

```sh
cd "$(git rev-parse --show-toplevel)"
mkdir -p .claude
test ! -f .claude/settings.json || cp .claude/settings.json .claude/settings.json.pre-read-only.bak
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py CLAUDE.md --scan
python3 /tmp/enforce-hooks.py CLAUDE.md --install-plugin
```

Plugin mode installs one `PreToolUse` hook that re-reads `CLAUDE.md` on every
tool call. If you edit the read-only policy later, you do not need to reinstall
the hook.
The backup command snapshots the project-level `.claude/settings.json` before
`--install-plugin` registers the hook. Keep it until the audit is finished.

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
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

This catches problems outside the read-only rule itself: hook-disabling
environment variables, invalid user or project `settings.json`, missing hook
files, non-executable shell hooks, and other installed hooks that fail open.

For CI or a scripted workstation check, make those findings fail the command:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

Do not treat the boundary as verified if the summary says `Verify: not run`,
`no hooks found`, `no payload checks ran`, or reports any `FAIL-OPEN` result.
Fix those first, then re-run the check from the project root.

## 5. Smoke test the runtime boundary

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

## 6. Use the mode

Start sessions with a narrow prompt, for example:

```text
Audit this repository. Do not edit files, do not run migrations, do not restart services, and do not commit. Report findings only.
```

The prompt still matters because it tells the model what work to do. The hook is
the enforcement layer that stops tool calls when the model drifts.

## 7. Remove or relax it

To leave read-only mode, remove or rename the `Read-only mode @enforced` section
in `CLAUDE.md`, then verify the boundary from the same project root:

```sh
cd "$(git rev-parse --show-toplevel)"
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
cd "$(git rev-parse --show-toplevel)"
test ! -f .claude/settings.json.pre-read-only.bak || cp .claude/settings.json.pre-read-only.bak .claude/settings.json
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify
```

Expect the strict audit to exit non-zero if `CLAUDE.md` still contains the
`Read-only mode @enforced` section, because the policy is no longer covered by
an active hook. Also expect it to fail if the restored settings snapshot
contains broken hook references. The safety-check summary should still show
zero `FAIL-OPEN` results for any remaining hooks you intend to keep.
