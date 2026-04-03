#!/usr/bin/env python3
"""Tests for read-once PowerShell hooks (hook.ps1, compact.ps1).

Requires: pwsh (PowerShell 7+).
Skips all tests if pwsh is not found.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "hook.ps1")
COMPACT_HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)), "compact.ps1")
PASS = 0
FAIL = 0
TOTAL = 0
GREEN = "\033[0;32m"
RED = "\033[0;31m"
NC = "\033[0m"


def has_pwsh():
    try:
        subprocess.run(["pwsh", "--version"], capture_output=True, timeout=10)
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return False


def run_hook(json_input, env_overrides=None):
    env = os.environ.copy()
    for key in ["READ_ONCE_DISABLED", "READ_ONCE_MODE", "READ_ONCE_TTL",
                "READ_ONCE_DIFF", "READ_ONCE_DIFF_MAX"]:
        env.pop(key, None)
    if env_overrides:
        env.update(env_overrides)
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", HOOK],
        input=json.dumps(json_input),
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    return result.stdout.strip(), result.returncode


def make_input(tool_name, file_path="", session_id="test-session-123",
               offset=None, limit=None):
    tool_input = {}
    if file_path:
        tool_input["file_path"] = file_path
    if offset is not None:
        tool_input["offset"] = offset
    if limit is not None:
        tool_input["limit"] = limit
    return {"tool_name": tool_name, "tool_input": tool_input,
            "session_id": session_id}


def assert_blocked(desc, json_input, substring=None, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            if substring and substring not in stdout:
                FAIL += 1
                print(f"  {RED}FAIL{NC}: {desc} (blocked but missing '{substring}')")
            else:
                PASS += 1
                print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected block, got: {stdout!r})")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def assert_allowed(desc, json_input, **kwargs):
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"decision":"block"' in stdout or '"decision": "block"' in stdout:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected allow, got: {stdout!r})")
        else:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: {desc}")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def assert_warned(desc, json_input, substring=None, **kwargs):
    """Assert the hook outputs a warn (permissionDecision: allow with reason)."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    try:
        stdout, _ = run_hook(json_input, **kwargs)
        if '"permissionDecision":"allow"' in stdout or '"permissionDecision": "allow"' in stdout:
            if substring and substring not in stdout:
                FAIL += 1
                print(f"  {RED}FAIL{NC}: {desc} (warned but missing '{substring}')")
            else:
                PASS += 1
                print(f"  {GREEN}PASS{NC}: {desc}")
        else:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: {desc} (expected warn, got: {stdout!r})")
    except Exception as e:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: {desc} (exception: {e})")


def run_compact(json_input):
    """Run compact.ps1 with JSON input on stdin."""
    env = os.environ.copy()
    result = subprocess.run(
        ["pwsh", "-NoProfile", "-File", COMPACT_HOOK],
        input=json.dumps(json_input),
        capture_output=True,
        text=True,
        timeout=15,
        env=env,
    )
    return result.stdout.strip(), result.returncode


# ============================================================
# Tests
# ============================================================

def test_non_read_ignored():
    """Non-Read tools should be ignored."""
    for tool in ["Bash", "Write", "Edit", "Glob", "Grep"]:
        assert_allowed(
            f"ignores {tool} tool",
            make_input(tool),
        )


def test_disabled_env():
    """READ_ONCE_DISABLED=1 disables the hook."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "test.txt")
        with open(fp, "w") as f:
            f.write("test content")
        assert_allowed(
            "disabled via env",
            make_input("Read", file_path=fp),
            env_overrides={"READ_ONCE_DISABLED": "1"},
        )
    finally:
        shutil.rmtree(tmpdir)


def test_first_read_allowed():
    """First read of a file should always be allowed."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "first-read.txt")
        with open(fp, "w") as f:
            f.write("first read content")
        # Use unique session to avoid cache interference
        assert_allowed(
            "first read allowed",
            make_input("Read", file_path=fp, session_id="fresh-session-1"),
        )
    finally:
        shutil.rmtree(tmpdir)


def test_reread_unchanged_warn_mode():
    """Re-reading unchanged file in warn mode shows advisory."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "reread.txt")
        with open(fp, "w") as f:
            f.write("content that stays the same")
        sid = "warn-test-session"
        # First read: should be allowed
        run_hook(make_input("Read", file_path=fp, session_id=sid))
        # Second read: should warn (default mode)
        assert_warned(
            "reread unchanged warns in default mode",
            make_input("Read", file_path=fp, session_id=sid),
            substring="already in context",
        )
    finally:
        shutil.rmtree(tmpdir)


def test_reread_unchanged_deny_mode():
    """Re-reading unchanged file in deny mode blocks."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "deny.txt")
        with open(fp, "w") as f:
            f.write("content for deny mode")
        sid = "deny-test-session"
        env = {"READ_ONCE_MODE": "deny"}
        # First read
        run_hook(make_input("Read", file_path=fp, session_id=sid),
                 env_overrides=env)
        # Second read: should block
        assert_blocked(
            "reread unchanged blocks in deny mode",
            make_input("Read", file_path=fp, session_id=sid),
            substring="already in context",
            env_overrides=env,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_reread_changed_file_allowed():
    """Re-reading a changed file should be allowed."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "changing.txt")
        with open(fp, "w") as f:
            f.write("original")
        sid = "change-test-session"
        # First read
        run_hook(make_input("Read", file_path=fp, session_id=sid))
        # Modify file (ensure mtime changes)
        time.sleep(1.1)
        with open(fp, "w") as f:
            f.write("modified content")
        # Second read: file changed, should be allowed
        assert_allowed(
            "reread changed file allowed",
            make_input("Read", file_path=fp, session_id=sid),
        )
    finally:
        shutil.rmtree(tmpdir)


def test_ttl_expiry():
    """After TTL expires, re-read is allowed even if unchanged."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "ttl.txt")
        with open(fp, "w") as f:
            f.write("ttl test content")
        sid = "ttl-test-session"
        env = {"READ_ONCE_TTL": "1"}  # 1 second TTL
        # First read
        run_hook(make_input("Read", file_path=fp, session_id=sid),
                 env_overrides=env)
        # Wait for TTL to expire
        time.sleep(1.5)
        # Second read: TTL expired, should be allowed
        assert_allowed(
            "reread after TTL expiry allowed",
            make_input("Read", file_path=fp, session_id=sid),
            env_overrides=env,
        )
    finally:
        shutil.rmtree(tmpdir)


def test_partial_read_not_cached():
    """Partial reads (offset/limit) should never be cached."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "partial.txt")
        with open(fp, "w") as f:
            f.write("partial content\n" * 100)
        sid = "partial-test-session"
        # Read with offset
        assert_allowed(
            "partial read with offset allowed",
            make_input("Read", file_path=fp, session_id=sid, offset=10),
        )
        # Read with limit
        assert_allowed(
            "partial read with limit allowed",
            make_input("Read", file_path=fp, session_id=sid, limit=20),
        )
    finally:
        shutil.rmtree(tmpdir)


def test_missing_file_ignored():
    """Missing files should be allowed (let Read handle the error)."""
    assert_allowed(
        "missing file passes through",
        make_input("Read", file_path="/nonexistent/file.txt",
                   session_id="missing-session"),
    )


def test_no_session_id_ignored():
    """Missing session_id should be allowed."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "nosession.txt")
        with open(fp, "w") as f:
            f.write("no session")
        inp = {"tool_name": "Read", "tool_input": {"file_path": fp}}
        assert_allowed("missing session_id passes through", inp)
    finally:
        shutil.rmtree(tmpdir)


def test_different_sessions_independent():
    """Different sessions have independent caches."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "multi-session.txt")
        with open(fp, "w") as f:
            f.write("shared file")
        # Read in session A
        run_hook(make_input("Read", file_path=fp, session_id="session-A"))
        # Read in session B: should be allowed (different session)
        assert_allowed(
            "different session allows read",
            make_input("Read", file_path=fp, session_id="session-B"),
        )
    finally:
        shutil.rmtree(tmpdir)


def test_token_savings_in_reason():
    """Warn/block reason should include token savings estimate."""
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "tokens.txt")
        with open(fp, "w") as f:
            f.write("x" * 1000)  # ~425 estimated tokens
        sid = "token-test-session"
        # First read
        run_hook(make_input("Read", file_path=fp, session_id=sid))
        # Second read: check reason includes token info
        assert_warned(
            "warn includes token savings",
            make_input("Read", file_path=fp, session_id=sid),
            substring="tokens",
        )
    finally:
        shutil.rmtree(tmpdir)


# ============================================================
# PostCompact hook (compact.ps1) tests
# ============================================================

def test_compact_clears_cache():
    """Compaction clears session cache so re-reads are allowed."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "file.txt")
        with open(fp, "w") as f:
            f.write("hello world")
        sid = "compact-test-session"
        # First read: cache miss, allowed
        run_hook(make_input("Read", file_path=fp, session_id=sid))
        # Second read: cache hit, warned
        stdout, _ = run_hook(make_input("Read", file_path=fp, session_id=sid))
        if "already in context" not in stdout:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: compact clears cache (pre-check: expected warn)")
            return
        # Run compact hook
        compact_input = {"session_id": sid, "hook_event_name": "PostCompact"}
        cout, rc = run_compact(compact_input)
        if rc != 0:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: compact clears cache (compact exit code: {rc})")
            return
        # After compaction, re-read should be allowed (cache cleared)
        stdout2, _ = run_hook(make_input("Read", file_path=fp, session_id=sid))
        if "already in context" in stdout2:
            FAIL += 1
            print(f"  {RED}FAIL{NC}: compact clears cache (still cached after compact)")
        else:
            PASS += 1
            print(f"  {GREEN}PASS{NC}: compact clears cache")
    finally:
        shutil.rmtree(tmpdir)


def test_compact_logs_stats():
    """Compaction logs event to stats file."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    tmpdir = tempfile.mkdtemp()
    try:
        fp = os.path.join(tmpdir, "file.txt")
        with open(fp, "w") as f:
            f.write("stats test content")
        sid = "compact-stats-session"
        old_home = os.environ.get("HOME")
        fake_home = tempfile.mkdtemp()
        os.environ["HOME"] = fake_home
        try:
            cache_dir = os.path.join(fake_home, ".claude", "read-once")
            os.makedirs(cache_dir, exist_ok=True)
            # Seed cache with a read entry
            run_hook(make_input("Read", file_path=fp, session_id=sid))
            # Run compact
            compact_input = {"session_id": sid, "hook_event_name": "PostCompact"}
            run_compact(compact_input)
            # Check stats file
            stats_file = os.path.join(cache_dir, "stats.jsonl")
            if os.path.exists(stats_file):
                content = open(stats_file).read()
                if '"event":"compact"' in content or '"event": "compact"' in content:
                    PASS += 1
                    print(f"  {GREEN}PASS{NC}: compact logs stats")
                else:
                    FAIL += 1
                    print(f"  {RED}FAIL{NC}: compact logs stats (no compact event in stats)")
            else:
                FAIL += 1
                print(f"  {RED}FAIL{NC}: compact logs stats (no stats file)")
        finally:
            if old_home is not None:
                os.environ["HOME"] = old_home
            else:
                os.environ.pop("HOME", None)
            shutil.rmtree(fake_home, ignore_errors=True)
    finally:
        shutil.rmtree(tmpdir)


def test_compact_empty_session_id():
    """Compact with empty session_id exits cleanly."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    stdout, rc = run_compact({"session_id": "", "hook_event_name": "PostCompact"})
    if rc == 0 and not stdout:
        PASS += 1
        print(f"  {GREEN}PASS{NC}: compact empty session_id exits cleanly")
    else:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: compact empty session_id (rc={rc}, out={stdout!r})")


def test_compact_missing_session_id():
    """Compact with missing session_id exits cleanly."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    stdout, rc = run_compact({"hook_event_name": "PostCompact"})
    if rc == 0 and not stdout:
        PASS += 1
        print(f"  {GREEN}PASS{NC}: compact missing session_id exits cleanly")
    else:
        FAIL += 1
        print(f"  {RED}FAIL{NC}: compact missing session_id (rc={rc}, out={stdout!r})")


def test_compact_clears_snapshots():
    """Compact clears diff-mode snapshots for the session."""
    global PASS, FAIL, TOTAL
    TOTAL += 1
    fake_home = tempfile.mkdtemp()
    old_home = os.environ.get("HOME")
    os.environ["HOME"] = fake_home
    try:
        sid = "compact-snap-session"
        cache_dir = os.path.join(fake_home, ".claude", "read-once")
        snap_dir = os.path.join(cache_dir, "snapshots")
        os.makedirs(snap_dir, exist_ok=True)
        # Compute the session hash the same way PS1 does (first 16 hex of SHA256)
        import hashlib
        h = hashlib.sha256(sid.encode()).hexdigest()[:16]
        # Create fake snapshot files
        snap1 = os.path.join(snap_dir, f"{h}-abc123")
        snap2 = os.path.join(snap_dir, f"{h}-def456")
        other = os.path.join(snap_dir, "othersession-xyz")
        for f in [snap1, snap2, other]:
            with open(f, "w") as fh:
                fh.write("snapshot")
        # Run compact
        run_compact({"session_id": sid, "hook_event_name": "PostCompact"})
        # Session snapshots should be gone, other session's should remain
        if not os.path.exists(snap1) and not os.path.exists(snap2) and os.path.exists(other):
            PASS += 1
            print(f"  {GREEN}PASS{NC}: compact clears snapshots for session")
        else:
            FAIL += 1
            s1 = os.path.exists(snap1)
            s2 = os.path.exists(snap2)
            ot = os.path.exists(other)
            print(f"  {RED}FAIL{NC}: compact clears snapshots (s1={s1}, s2={s2}, other={ot})")
    finally:
        if old_home is not None:
            os.environ["HOME"] = old_home
        else:
            os.environ.pop("HOME", None)
        shutil.rmtree(fake_home, ignore_errors=True)


# ============================================================

if __name__ == "__main__":
    if not has_pwsh():
        print("SKIP: pwsh not found, skipping read-once PS1 tests")
        sys.exit(0)

    print("read-once PS1 tests")
    print("=" * 40)

    test_non_read_ignored()
    test_disabled_env()
    test_first_read_allowed()
    test_reread_unchanged_warn_mode()
    test_reread_unchanged_deny_mode()
    test_reread_changed_file_allowed()
    test_ttl_expiry()
    test_partial_read_not_cached()
    test_missing_file_ignored()
    test_no_session_id_ignored()
    test_different_sessions_independent()
    test_token_savings_in_reason()

    print()
    print("compact.ps1 (PostCompact hook)")
    print("-" * 40)

    test_compact_clears_cache()
    test_compact_logs_stats()
    test_compact_empty_session_id()
    test_compact_missing_session_id()
    test_compact_clears_snapshots()

    print("=" * 40)
    print(f"Results: {PASS}/{TOTAL} passed, {FAIL} failed")
    sys.exit(1 if FAIL > 0 else 0)
