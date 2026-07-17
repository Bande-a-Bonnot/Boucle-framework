#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== Installer check passthrough =="

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/boucle-installer-check-XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

cat > "$tmpdir/curl" <<'EOF'
#!/bin/sh
cat <<'SCRIPT'
#!/bin/sh
printf 'CHECK_ARGS:%s\n' "$*"
case " $* " in
  *" --strict "*) exit 7 ;;
  *) exit 0 ;;
esac
SCRIPT
EOF
chmod +x "$tmpdir/curl"

set +e
output=$(PATH="$tmpdir:/usr/bin:/bin" bash "$REPO_ROOT/tools/install.sh" check --verify --strict 2>&1)
status=$?
set -e

if [ "$status" -ne 7 ]; then
    printf 'Expected strict check exit 7, got %s\nOutput:\n%s\n' "$status" "$output" >&2
    exit 1
fi

case "$output" in
    *"CHECK_ARGS:--verify --strict"*) ;;
    *)
        printf 'install.sh check did not pass safety-check flags through.\nOutput:\n%s\n' "$output" >&2
        exit 1
        ;;
esac

python3 - <<'PY' "$REPO_ROOT"
import sys
from pathlib import Path

repo = Path(sys.argv[1])
text = (repo / "tools" / "install.ps1").read_text()
paths = {
    repo / "tools" / "install.ps1": [
        "check --verify --strict",
        "$checkArgs = @()",
        "& bash $tmpFile @checkArgs",
        "$checkExit = $LASTEXITCODE",
        "exit $checkExit",
    ],
    repo / "README.md": [
        "check --verify --strict",
        "Run strict safety audit with hook payload verification",
    ],
    repo / "tools" / "README.md": [
        "install.sh check --verify --strict",
        "Run strict safety audit with payload checks",
    ],
    repo / "docs" / "index.html": [
        "check --verify --strict",
        "installer-managed strict safety audit",
    ],
}

missing = []
for path, snippets in paths.items():
    text = path.read_text()
    for snippet in snippets:
        if snippet not in text:
            missing.append(f"{path.relative_to(repo)}: missing {snippet!r}")
if missing:
    raise SystemExit("installer check passthrough drifted:\n" + "\n".join(missing))
PY

echo "Installer check passthrough OK"
