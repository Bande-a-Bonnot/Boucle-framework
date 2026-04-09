#!/bin/bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "== limitations metadata =="
python3 "$REPO_ROOT/scripts/reconcile-limitations.py" --check
