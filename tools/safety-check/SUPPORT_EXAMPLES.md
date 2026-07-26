# Safe support examples

Use these examples when you need help with a failing `safety-check` result but
do not want to leak local paths, hook commands, settings files, prompts, or
secrets.

## Safe public report

Run the bounded summary command first:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Then post a report shaped like this:

```text
OS: macOS
Shell: zsh
Claude Code version: 1.0.93
Where hooks are installed: user settings
What changed recently: Claude Code update, then install.sh upgrade

--- Safety Summary (copy/paste) ---
Grade: C
Hooks: 3/8 framework hook slots detected
Issue: invalid project settings JSON in <project>/.claude/settings.json
Issue: 1 skipped PreToolUse hook check
Verify: 0 FAIL-OPEN | 6 payload checks | 1 skipped
Boundary: resolve skipped PreToolUse hook checks before trusting strict verification.
--- End Safety Summary ---
```

That is enough for triage because it includes the OS, shell, recent change,
summary issues, verification counts, and boundary line. The summary should
redact the home directory as `~` and the current checkout as `<project>`.

## Native Windows report

Native `install.ps1 verify` does not print the copy/paste safety summary. Use
only the final count line plus `WARN` or `SKIP` lines:

```text
OS: native Windows
Shell: PowerShell 7
Claude Code version: 1.0.93
Where hooks are installed: user settings
What changed recently: fresh recommended install

PowerShell verifier:
2 passed, 1 warnings, 1 skipped.
WARN: git-safe did not block force push payload.
SKIP: branch-guard needs git repo context to verify.
```

If Git Bash or WSL is available, prefer the bash `--summary-only` command when
asking in public. It produces a smaller redacted block.

## Unsafe snippets to avoid

Do not post full command lines or raw hook output like these:

```text
/Users/alice/work/acme-private/.claude/hooks/custom-guard.sh blocked request
```

```json
{"hooks":{"PreToolUse":[{"matcher":"Write","hooks":[{"command":"/Users/alice/work/acme-private/tools/check-secret.sh --token sk-live-..."}]}]}}
```

```text
Claude tried to read /Users/alice/work/acme-private/customer-data/.env
```

Those snippets can reveal usernames, repository names, private hook locations,
tokens, or sensitive file names. Rerun `--summary-only` and post the bounded
summary instead.

## If the summary is not enough

Build a temporary reproduction with throwaway paths:

```sh
tmpdir="$(mktemp -d)"
cd "$tmpdir"
mkdir -p .claude/hooks
printf '{"hooks":{}}\n' > .claude/settings.json
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Replace that settings file with the smallest redacted configuration that still
reproduces the issue. If the problem disappears in the temporary directory, the
remaining signal is probably in private paths, environment variables, shell
startup files, or custom hook code. Say that instead of posting the private
workspace.
