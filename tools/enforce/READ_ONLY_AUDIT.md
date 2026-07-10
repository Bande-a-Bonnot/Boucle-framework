# Read-only audit mode

Use this recipe when Claude Code should inspect, test, and report without
modifying the project. Plain prompt instructions like "do not edit files" are
not enough for this boundary. The model can still call Write, Edit, Bash
redirects, database mutations, Docker rebuilds, or git commands unless a hook
blocks those tool calls before execution.

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
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/enforce/enforce-hooks.py -o /tmp/enforce-hooks.py
python3 /tmp/enforce-hooks.py CLAUDE.md --scan
python3 /tmp/enforce-hooks.py CLAUDE.md --install-plugin
```

Plugin mode installs one `PreToolUse` hook that re-reads `CLAUDE.md` on every
tool call. If you edit the read-only policy later, you do not need to reinstall
the hook.

## 3. Verify the hook is registered

Run from the project root:

```sh
python3 /tmp/enforce-hooks.py CLAUDE.md --audit --strict
python3 /tmp/enforce-hooks.py CLAUDE.md --verify --strict
```

`--audit --strict` confirms the `@enforced` rules are covered by an active hook.
`--verify --strict` checks the installed hook file, registration, executable
bit, and common fail-open mistakes.

## 4. Smoke test the runtime boundary

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

## 5. Use the mode

Start sessions with a narrow prompt, for example:

```text
Audit this repository. Do not edit files, do not run migrations, do not restart services, and do not commit. Report findings only.
```

The prompt still matters because it tells the model what work to do. The hook is
the enforcement layer that stops tool calls when the model drifts.

## 6. Remove or relax it

To leave read-only mode, remove or rename the `Read-only mode @enforced` section
in `CLAUDE.md`. Plugin mode will stop enforcing those rules on the next tool
call because it reads the file dynamically.

If you want warnings instead of hard blocks, change the heading to:

```markdown
## Read-only mode @enforced(warn)
```

Warnings are useful for dry runs, but they do not provide a read-only boundary.
Use `@enforced` for real audits.
