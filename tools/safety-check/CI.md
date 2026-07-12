# Safety-check scripted checks

Use `--verify --strict` when a failed or inconclusive hook check should fail the
script. It is useful for developer workstation checks and for repositories that
keep Claude Code hook settings in version control.

Strict mode exits `1` when safety-check finds any of these:

- No hooks.
- No payload checks.
- A `FAIL-OPEN` hook.
- A skipped `PreToolUse` hook check.
- Missing, broken, or non-executable hook files.

## Developer workstation check

Run this after installing hooks, updating Claude Code, or changing
`~/.claude/settings.json`:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

A passing workstation check means the installed `PreToolUse` hooks blocked their
representative payloads in the current shell environment. Re-run it from the
same shell or terminal profile you use to start Claude Code, because environment
flags such as `IS_DEMO` and `CLAUDE_CODE_SIMPLE` can change hook behavior.

## Repository CI check

CI can only verify hook settings that are present in the checked-out repository
or installed in the CI user's home directory. It cannot prove every developer's
global `~/.claude/settings.json` is safe.

Use this when your repository includes `.claude/settings.json` with direct hook
script paths, or interpreter-wrapped paths such as `bash ./hooks/check.sh` or
`python ./hooks/check.py`:

```yaml
name: claude-code-safety

on:
  pull_request:
  push:
    branches: [main]

jobs:
  safety-check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Verify Claude Code hooks
        run: |
          curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh -o /tmp/safety-check.sh
          SAFETY_CHECK_SKIP_CLAUDE_VERSION=1 bash /tmp/safety-check.sh --verify --strict
```

`SAFETY_CHECK_SKIP_CLAUDE_VERSION=1` skips the optional `claude --version` probe
for CI runners that do not have Claude Code installed. It does not skip hook
inventory, hook file health, or payload verification.

## Expected outcomes

| Result | Meaning |
|--------|---------|
| Exit `0` with `Verify: 0 FAIL-OPEN` | The checked hooks passed representative payload checks. |
| Exit `1` with `no hooks found` | The checked environment has no hook layer to verify. |
| Exit `1` with `no payload checks ran` | Hooks were present, but safety-check could not send representative payloads. |
| Exit `1` with `FAIL-OPEN` | At least one hook did not block a dangerous representative payload. |
| Exit `1` with skipped `PreToolUse` checks | A `PreToolUse` hook command was too dynamic to verify automatically. |

Lifecycle hooks such as `SessionStart`, `Stop`, and `PostToolUse` are reported
but are not hard-blocking `PreToolUse` checks. If your safety boundary depends on
blocking file writes or shell commands, keep at least one verifiable
`PreToolUse` hook in the checked settings.

## Common fixes

- Install hooks before running the strict workstation check:
  `curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended`
- Commit repo-local hook scripts when CI checks `.claude/settings.json`.
- Avoid shell snippets that cannot be mapped to a script path. Prefer
  `bash ./hooks/name.sh` or `python ./hooks/name.py`.
- Run `install.sh doctor` locally when files are missing or non-executable.
- Use the [safe support evidence guide](SUPPORT_EVIDENCE.md) before sharing
  public failure output.
