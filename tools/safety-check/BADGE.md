# Claude Code Safety Badge

Use this only after you can reproduce the same `safety-check --verify --badge`
result locally. The badge is a short status label for one setup at one point in
time; it is not a certification.

## Generate

Run from the Claude Code project root you actually use:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --badge
```

Copy only the `Markdown:` line. Keep the support summary locally as evidence,
and do not share raw `settings.json`, hook command inventories, shell history,
transcripts, screenshots, account access, repository access, or payment details.

If you need a bounded local evidence block before copying the badge, run the
summary form from the same root:

```sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"
curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/safety-check/check.sh | bash -s -- --verify --summary-only
```

## Tiers

Read the `Verify:` line together with the `Boundary:` line. A nonzero
`skipped` count can still be verified when the boundary says only lifecycle or
non-PreToolUse hooks were skipped; it is inconclusive when the boundary says a
PreToolUse hook check was skipped or no hook payload checks ran.

| Badge | Meaning |
|-------|---------|
| `claude-code-safety: verified` | Grade A or B, zero `FAIL-OPEN` checks, at least one payload check, and no skipped PreToolUse boundary. |
| `claude-code-safety: partial` | Grade C or better and zero `FAIL-OPEN` checks, but residual warnings remain. |
| `claude-code-safety: inconclusive` | Verification did not prove the hook layer, or evidence is missing. |
| `claude-code-safety: fail-open` | At least one representative dangerous payload was not blocked. |

## Boundary

The badge is self-reported from `safety-check --verify --badge`. It can go
stale after Claude Code updates, hook edits, settings edits, shell changes,
platform changes, or moving work to a different project root.

Remove the badge when you cannot reproduce the same tier. Rerun verification
after every Claude Code update and after changing hooks or settings.
