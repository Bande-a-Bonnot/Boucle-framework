#!/usr/bin/env python3
"""Rebuild all derived limitations artifacts from limitations.json."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"


def run(script_name: str) -> None:
    subprocess.run(
        [sys.executable, str(SCRIPTS_DIR / script_name)],
        cwd=REPO_ROOT,
        check=True,
    )


def main() -> None:
    run("reconcile-limitations.py")
    run("sync-limitations-html.py")
    run("update-feed.py")
    print("Synced limitations metadata, HTML page, and Atom feed")


if __name__ == "__main__":
    main()
