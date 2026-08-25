# Team handoff reports

Use this when one person has verified a Claude Code hook boundary and needs to
hand the result to a teammate, reviewer, or incident owner. The goal is a short
record that says what was checked, where it was checked, and what remains
outside the hook boundary.

## 1. Verify from the working root

Run from the same project root where Claude Code will start. If you are inside
a git checkout, move to the repo root first:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

Command boundary: this downloads `tools/safety-check/check.sh` from GitHub raw
content and runs it locally on your current project and Claude Code settings.
The checker does not upload your `settings.json`, hook files, shell history,
repository contents, session logs, or safety summary output.

On native Windows with PowerShell hooks, use the native verifier:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

If Git Bash or WSL is available on Windows, prefer the bash `--summary-only`
command for a bounded copy/paste summary. Native `install.ps1 verify` does not
print the `--- Safety Summary (copy/paste) ---` block.

## 2. Paste this record

Use this shape in a PR comment, incident note, or team chat:

```text
Claude Code hook boundary checked:
- Project/root:
- OS and shell:
- Claude Code version:
- Hooks installed in: user settings / project settings / both / not sure
- Command used:
- Command/scope: real project-root --verify / isolated reproduction / native install.ps1 verify
- What changed recently: fresh install / Claude Code update / settings edit / hook edit / moved hook files
- Pre-update baseline: summary/version captured / not captured / not an update issue
- Fresh Claude Code session started after verification: yes / no
- Result:

--- Safety Summary (copy/paste) ---
...
--- End Safety Summary ---

Residual platform warnings:
- ...

Next intended action: audit only / local fix / commit / push / public report
Staged diff and destination reviewed separately: yes / no / not applicable
Next recheck trigger:
- Claude Code update / settings edit / hook edit / launch directory change / before risky automation
```

For native Windows `install.ps1 verify`, replace the safety summary block with
only the final verifier count plus any `WARN` or `SKIP` lines. Do not paste the
full startup hook table if it exposes private paths.

## 3. Interpret the handoff

Treat this as a boundary statement, not a certificate.

- `Verify: 0 FAIL-OPEN` means representative payload checks did not find a
  configured hook that failed open.
- `Verify: not run`, `no hooks found`, or `no payload checks ran` means the
  hook layer was not proven.
- A skipped `PreToolUse` hook is unverified for the boundary it is meant to
  enforce.
- A Grade C with `Verify: 0 FAIL-OPEN` often means hooks passed but Claude Code
  platform warnings remain. Record those warnings instead of reinstalling
  repeatedly.

For update handoffs, write `summary/version captured` only when the old Claude
Code version and bounded safety summary were recorded before the update. If the
next intended action is `commit`, `push`, or `public report`, inspect the staged
diff, destination branch, and remote target separately before approval. Hook
verification proves only the checked hook boundary, not that the pending
publication is safe.

Use the [triage guide](TRIAGE.md) when the summary has multiple findings and
you need a repair order.

## 4. Redaction rules

Do not paste raw `settings.json`, hook source, shell history, session logs,
full terminal transcripts, screenshots with paths, `.env` contents, tokens,
SSH keys, private URLs, or proprietary `CLAUDE.md` rules.

If a teammate needs to reproduce the issue, build a temporary reproduction
instead of sharing your real workspace, then run the bounded summary there:

```sh
(
  tmpdir="$(mktemp -d)"
  tmp_home="$(mktemp -d)"
  cleanup() {
    if [ "${KEEP_BOUCLE_REPRO:-0}" != "1" ]; then
      rm -f "$tmpdir/.claude/settings.json"
      rmdir "$tmpdir/.claude/hooks" "$tmpdir/.claude" "$tmpdir" "$tmp_home" 2>/dev/null || {
        printf 'Temporary directories were not empty; inspect and remove manually:\n'
        printf '  %s\n  %s\n' "$tmp_home" "$tmpdir"
      }
    fi
  }
  trap cleanup EXIT

  mkdir -p "$tmpdir/.claude/hooks"
  printf '{"hooks":{}}\n' > "$tmpdir/.claude/settings.json"
  cd "$tmpdir"

  curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | PYTHONDONTWRITEBYTECODE=1 HOME="$tmp_home" bash -s -- --verify --summary-only
  if [ "${KEEP_BOUCLE_REPRO:-0}" = "1" ]; then
    printf 'Temporary HOME: %s\nTemporary project: %s\n' "$tmp_home" "$tmpdir"
  fi
)
```

Replace the sample settings with the smallest redacted file that reproduces the
problem. Keep only throwaway hook scripts and placeholder paths. The temporary
`HOME` prevents your real user-level Claude Code hooks from making the
reproduction look safer or noisier than the redacted project settings. The
snippet removes the known throwaway settings file and then removes the
temporary directories only if they are empty; set `KEEP_BOUCLE_REPRO=1` in the
same shell before running it if you need to inspect them afterward. If anything
unexpected remains, the paths are printed so you can inspect and remove them
manually. `PYTHONDONTWRITEBYTECODE=1` prevents Python cache files from making the
temporary `HOME` look unexpectedly dirty.

## 5. Recheck triggers

Rerun the handoff check after:

- Claude Code updates.
- `~/.claude/settings.json` or `.claude/settings.json` changes.
- Hook files are installed, upgraded, moved, or edited.
- Claude Code starts from a different directory.
- The work moves between macOS, Linux, WSL, Git Bash, and native Windows.
- A long-running autonomous or semi-autonomous session starts.

For update-specific steps, use the [Claude Code update checklist](UPDATE_CHECKLIST.md).
For public support threads, use the [safe support evidence guide](SUPPORT_EVIDENCE.md)
and [safe support examples](SUPPORT_EXAMPLES.md).
