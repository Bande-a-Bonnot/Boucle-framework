# Safe support examples

Use these examples when you need help with a failing `safety-check` result but
do not want to leak local paths, hook commands, settings files, prompts, or
secrets.

## Safe public report

Run the bounded summary command first:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

That command downloads `tools/safety-check/check.sh` from GitHub raw content and
runs it locally. It does not upload your `settings.json`, hook files, shell
history, repository contents, session logs, or safety summary output.

Then post a report shaped like this:

```text
OS: macOS
Shell: zsh
Claude Code version: 1.0.93
Where hooks are installed: user settings
What changed recently: Claude Code update, then install.sh upgrade
Pre-update baseline: summary/version captured

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
whether there is a pre-update baseline, summary issues, verification counts,
and boundary line. The summary should redact the home directory as `~` and the
current checkout as `<project>`.
In this example, `summary/version captured` means both the old Claude Code
version and the bounded safety summary were recorded before the update. If only
one was captured, say `not captured`.

## FAIL-OPEN public report

When `--verify` reports a `FAIL-OPEN` hook, post the bounded summary and one
short note about whether the hook is custom or installed by this framework.
Do not paste raw hook stderr from the Claude Code session.

```text
OS: Linux
Shell: bash
Claude Code version: 1.0.93
Where hooks are installed: project settings
What changed recently: moved the repository to a new checkout path
Pre-update baseline: not an update issue
Hook source: framework git-safe hook, not custom

--- Safety Summary (copy/paste) ---
Grade D | 62% | 4/8 hooks
[OK] bash-guard  [OK] git-safe  [OK] file-guard  [--] read-once
[--] branch-guard  [--] session-log  [--] enforce  [OK] worktree-guard
Verify: 1 FAIL-OPEN | 6 payload checks | 0 skipped
Boundary: fix FAIL-OPEN hooks before trusting the hook layer.
github.com/Bande-a-Bonnot/Boucle-framework
--- End Safety Summary ---
```

That report is enough to start triage. If a maintainer needs to know which
payload failed, reproduce it in a temporary directory with throwaway hook paths
instead of pasting private settings or live session output.

## Native Windows report

Native `install.ps1 verify` does not print the copy/paste safety summary. Use
only the final count line plus `WARN` or `SKIP` lines:

```text
OS: native Windows
Shell: PowerShell 7
Claude Code version: 1.0.93
Where hooks are installed: user settings
What changed recently: fresh recommended install
Pre-update baseline: not an update issue

PowerShell verifier:
2 passed, 1 warnings, 1 skipped.
WARN: git-safe did not block force push payload.
SKIP: branch-guard needs git repo context to verify.
```

If no native hooks are installed yet, share only the short result.
Do not paste the startup hook table if it includes local paths.

```text
OS: native Windows
Shell: PowerShell 7
Claude Code version: 1.0.93
Where hooks are installed: none detected
What changed recently: checking before first install
Pre-update baseline: not an update issue

PowerShell verifier:
No hooks installed. Run: install.ps1 recommended
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
tmp_home="$(mktemp -d)"
mkdir -p "$tmpdir/.claude/hooks"
printf '{"hooks":{}}\n' > "$tmpdir/.claude/settings.json"
cd "$tmpdir"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | HOME="$tmp_home" bash -s -- --verify --summary-only
```

Replace that settings file with the smallest redacted configuration that still
reproduces the issue. The temporary `HOME` keeps real user-level Claude Code
hooks out of the reproduction. If the problem disappears in the temporary
directory, the remaining signal is probably in private paths, environment
variables, shell startup files, or custom hook code. Say that instead of posting
the private workspace.
