#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Windows safety-check docs =="
python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])

checks = [
    (
        repo / "README.md",
        [
            "install.ps1 verify` and `install.ps1 doctor` use native PowerShell hooks",
            "install.ps1 check` command runs the bash-based safety-check audit",
            "Git Bash, WSL, or another `bash` on PATH",
            'if ($root) { Set-Location $root }',
            "tools/install.ps1) } recommended\"\niex \"& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify",
        ],
    ),
    (
        repo / "tools" / "README.md",
        [
            "No bash or jq is required for the standalone Windows hooks",
            "install.ps1 check",
            "similar. The safety-check summary",
            "Git Bash or WSL for safety-check",
            "Safe Support Evidence",
            'if ($root) { Set-Location $root }',
            "through\n`--- End Safety Summary ---`",
            "For native `install.ps1 verify`, which does not\nprint that summary block",
            "final verifier count plus any `WARN` or\n`SKIP` lines",
            "safety-check/SUPPORT_EVIDENCE.md",
        ],
    ),
    (
        repo / "tools" / "safety-check" / "README.md",
        [
            "On native Windows, run the Bash checker from WSL or Git Bash",
            "install.ps1 verify` for payload checks that do\nnot require bash",
            "On Windows, run under WSL or Git Bash",
            "check",
            "bash-based safety-check script",
        ],
    ),
    (
        repo / "tools" / "safety-check" / "QUICKSTART.md",
        [
            "install.ps1 verify` uses native PowerShell hook payload checks",
            "install.ps1 check` command delegates to this bash-based safety-check script",
            "Git Bash, WSL, or another `bash` on PATH",
            "tools/install.ps1) } recommended\"\niex \"& { $(irm https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/install.ps1) } verify",
            "For native `install.ps1 verify`, there is no safety summary block",
            "On native Windows with `install.ps1 verify`, copy only the final verifier count",
            "The PowerShell verifier does not print the\n`--- Safety Summary (copy/paste) ---` block",
            'if ($root) { Set-Location $root }',
        ],
    ),
    (
        repo / "tools" / "safety-check" / "SUPPORT_EVIDENCE.md",
        [
            "native PowerShell verifier does not emit that block",
            "final count line",
            "Any `WARN` or `SKIP` lines",
            "Native Windows PowerShell verifier, if no Safety Summary block exists",
        ],
    ),
    (
        repo / "tools" / "safety-check" / "TRIAGE.md",
        [
            "install.ps1 verify` does not print the `--- Safety Summary (copy/paste) ---`",
            "final count line plus any `WARN` or `SKIP` lines",
            "Native `install.ps1 verify` warning count",
            "Native `install.ps1 verify` skipped count",
            'if ($root) { Set-Location $root }',
        ],
    ),
    (
        repo / "docs" / "index.html",
        [
            "run the PowerShell verifier from <strong>PowerShell 7</strong>",
            "tests the native <code>.ps1</code> hooks without bash or jq",
            "install.ps1) } verify",
            "install.ps1) } recommended",
            "install the same recommended set from PowerShell 7",
            "No jq or bash needed for native install, verify, or doctor",
        ],
    ),
]

failures = []
for path, snippets in checks:
    text = path.read_text()
    for snippet in snippets:
        if snippet not in text:
            failures.append(f"{path.relative_to(repo)}: missing {snippet!r}")

if failures:
    raise SystemExit("Windows safety-check docs drifted:\n" + "\n".join(failures))

print("Windows safety-check docs OK")
PY
