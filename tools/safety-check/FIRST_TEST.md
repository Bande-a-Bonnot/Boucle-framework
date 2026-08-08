# Safety-check first test

Use this when you want to try safety-check before letting it read or change your
real Claude Code setup. This test runs the audit in a temporary project with a
temporary `HOME` and prints the bounded support summary.

It does not install hooks. It does not prove your real Claude Code setup is
safe. It only proves the checker can run on this machine and shows what an
unconfigured baseline looks like.

## Network and upload boundary

The command downloads `tools/safety-check/check.sh` from this repository through
GitHub raw content, then runs it locally. The checker reads only the temporary
`HOME` and temporary project created in the snippet. It does not upload your
Claude Code settings, hook files, shell history, repository contents, or summary
output.

If your environment blocks `curl` to GitHub raw content, stop here and inspect
the script from a trusted network before running it another way.

## macOS, Linux, WSL, or Git Bash

Bash 3.2+ is enough for this isolated test; the default `/bin/bash` on macOS
works.

```sh
(
  tmp_home="$(mktemp -d)"
  tmp_project="$(mktemp -d)"
  cleanup() {
    if [ "${KEEP_BOUCLE_FIRST_TEST:-0}" != "1" ]; then
      rmdir "$tmp_home" "$tmp_project" 2>/dev/null || {
        printf 'Temporary directories were not empty; inspect and remove manually:\n'
        printf '  %s\n  %s\n' "$tmp_home" "$tmp_project"
      }
    fi
  }
  trap cleanup EXIT

  cd "$tmp_project"
  curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | PYTHONDONTWRITEBYTECODE=1 HOME="$tmp_home" bash -s -- --verify --summary-only
  if [ "${KEEP_BOUCLE_FIRST_TEST:-0}" = "1" ]; then
    printf 'Temporary HOME: %s\nTemporary project: %s\n' "$tmp_home" "$tmp_project"
  fi
)
```

Expected shape:

```text
--- Safety Summary (copy/paste) ---
...
Verify: not run | no hooks found | 0 payload checks
Boundary: install hooks before trusting the hook layer.
github.com/Bande-a-Bonnot/Boucle-framework
--- End Safety Summary ---
```

The exact grade can vary because the checker may still detect whether
`claude`, `python3`, or other local tools are available on `PATH`.
The `github.com/Bande-a-Bonnot/Boucle-framework` line is the support URL printed
inside the bounded block; it is not evidence that the checker uploaded output.
The temporary directories should contain only this isolated test state.
`PYTHONDONTWRITEBYTECODE=1` prevents Python cache files from making the
temporary `HOME` non-empty on macOS. The cleanup uses `rmdir` when the command
finishes; if something unexpected writes files there, it prints both paths
instead of recursively deleting them. To keep the directories for inspection,
run `export KEEP_BOUCLE_FIRST_TEST=1` in the same shell before pasting the
command. Temporary paths are printed only in that keep-for-inspection mode.

## What this proves

- The audit script downloads and starts.
- The copy/paste support summary is bounded.
- Verification mode does not execute dangerous shell or git commands.
- An empty temporary setup is reported as unverified instead of safe.

## Native Windows note

The isolated no-read first test above is for WSL, Git Bash, or another Bash
that respects the temporary `HOME` passed to the checker. On native Windows
PowerShell, `install.ps1 verify` is the right verifier for installed `.ps1`
hooks, but it inspects hooks under your real `$HOME/.claude` directory. Do not
use it as the "try without reading my real settings" path.

If you want an isolated first test on Windows before touching real Claude Code
settings, run the Bash command above from WSL or Git Bash. Then use the native
PowerShell verifier only when you are ready to inspect or verify the hooks
installed for your real Windows user.

## Next real check

Run the real audit from the same project root where you start Claude Code. If
you are inside a git checkout, move to the repo root first; otherwise stay in
the current project directory:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

If someone asked for a support report, send only the `Safety Summary
(copy/paste)` block plus OS, shell, and Claude Code version when quick. Do not
send raw settings, hook source, transcripts, session logs, repository access,
tokens, private URLs, or proprietary `CLAUDE.md` rules. See
[safe support evidence](SUPPORT_EVIDENCE.md) for the full public-report
boundary.

If the summary says `Verify: not run`, `no hooks found`, or
`0 payload checks`, install the recommended hooks and verify again:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

On native Windows, use PowerShell 7 for the native hook verifier:

```powershell
$root = if (Get-Command git -ErrorAction SilentlyContinue) { git rev-parse --show-toplevel 2>$null }
if ($root) { Set-Location $root }
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

See the [quickstart](QUICKSTART.md) for the full audit, install, verify, repair,
and update loop.
