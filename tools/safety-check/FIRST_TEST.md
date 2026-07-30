# Safety-check first test

Use this when you want to try safety-check before letting it read or change your
real Claude Code setup. This test runs the audit in a temporary project with a
temporary `HOME` and prints the bounded support summary.

It does not install hooks. It does not prove your real Claude Code setup is
safe. It only proves the checker can run on this machine and shows what an
unconfigured baseline looks like.

## macOS, Linux, WSL, or Git Bash

```sh
tmp_home="$(mktemp -d)"
tmp_project="$(mktemp -d)"
(
  cd "$tmp_project"
  curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | HOME="$tmp_home" bash -s -- --verify --summary-only
)
printf 'Temporary HOME: %s\nTemporary project: %s\n' "$tmp_home" "$tmp_project"
```

Expected shape:

```text
--- Safety Summary (copy/paste) ---
...
Verify: not run | no hooks found | 0 payload checks
Boundary: install hooks before trusting the hook layer.
--- End Safety Summary ---
```

The exact grade can vary because the checker may still detect whether
`claude`, `python3`, or other local tools are available on `PATH`.
The printed temporary directories contain only this isolated test state; remove
them with your normal temp-file cleanup process if you want to inspect them
first.

## What this proves

- The audit script downloads and starts.
- The copy/paste support summary is bounded.
- Verification mode does not execute dangerous shell or git commands.
- An empty temporary setup is reported as unverified instead of safe.

## Next real check

Run the real audit from the same project root where you start Claude Code:

```sh
cd "$(git rev-parse --show-toplevel)"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

If the summary says `Verify: not run`, `no hooks found`, or
`0 payload checks`, install the recommended hooks and verify again:

```sh
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- recommended
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.sh | bash -s -- verify
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --strict
```

On native Windows, use PowerShell 7 for the native hook verifier:

```powershell
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } recommended"
iex "& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify"
```

See the [quickstart](QUICKSTART.md) for the full audit, install, verify, repair,
and update loop.
