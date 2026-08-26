#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Safety-check CI docs =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
path = repo / "tools" / "safety-check" / "CI.md"
text = path.read_text()
flat_text = " ".join(text.split())

snippets = [
    "Native PowerShell hooks in CI",
    "pwsh -File ./hooks/git-safe.ps1",
    "pwsh -NoProfile -File ./hooks/block-dangerous-bash.ps1",
    "Minimal PowerShell hook script",
    "[Console]::In.ReadToEnd()",
    "ConvertFrom-Json",
    "The Ubuntu workflow above does not install",
    "install.ps1 verify",
    "Git Bash, WSL, or a runner with bash",
    "Keep the same repo-policy guard here as in the",
    "unless the job is intentionally testing user-level hooks installed",
    "Do not add `install.sh recommended` to a repository CI job",
    "The installer writes user-level hooks under the CI",
    "installer smoke test",
    "does not prove the repository's checked-in",
    "run `--verify --strict` in the same job and",
    "do not use it as evidence that repo-local project hooks are present",
]

missing = [snippet for snippet in snippets if snippet not in text]
if "without bash or jq" not in flat_text:
    missing.append("without bash or jq")
if missing:
    raise SystemExit(
        "Safety-check CI docs drifted:\n"
        + "\n".join(f"{path.relative_to(repo)}: missing {snippet!r}" for snippet in missing)
    )

print("Safety-check CI docs OK")

recipes = repo / "docs" / "recipes.html"
recipes_text = recipes.read_text()
recipe_snippets = [
    "pwsh -NoProfile -File ./hooks/block-dangerous-bash.ps1",
    "[Console]::In.ReadToEnd()",
    "ConvertFrom-Json",
    "Blocked destructive rm -rf command",
]
recipe_missing = [snippet for snippet in recipe_snippets if snippet not in recipes_text]
if recipe_missing:
    raise SystemExit(
        "Safety-check recipes page drifted:\n"
        + "\n".join(f"{recipes.relative_to(repo)}: missing {snippet!r}" for snippet in recipe_missing)
    )

print("Safety-check recipes mirror OK")
PY
