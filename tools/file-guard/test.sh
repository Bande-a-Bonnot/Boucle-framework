#!/bin/bash
# Tests for file-guard hook
# Usage: bash test.sh

set -euo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/hook.sh"
PASS=0
FAIL=0
TOTAL=0

# Create temp config
TMPDIR=$(mktemp -d)
CONFIG="$TMPDIR/.file-guard"
export FILE_GUARD_CONFIG="$CONFIG"

cleanup() {
  rm -rf "$TMPDIR"
}
trap cleanup EXIT

assert_blocked() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))

  result=$(echo "$input" | bash "$HOOK" 2>/dev/null) || true
  if echo "$result" | grep -q '"permissionDecision":"deny"'; then
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected block, got: $result)"
  fi
}

assert_allowed() {
  local desc="$1"
  local input="$2"
  TOTAL=$((TOTAL + 1))

  result=$(echo "$input" | bash "$HOOK" 2>/dev/null) || true
  if echo "$result" | grep -q '"permissionDecision":"deny"'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc (expected allow, got blocked: $result)"
  else
    PASS=$((PASS + 1))
    echo "  PASS: $desc"
  fi
}

echo "=== file-guard tests ==="
echo ""

# --- Test: Basic exact match ---
echo "--- Exact path matching ---"
cat > "$CONFIG" <<'EOF'
.env
secrets.json
EOF

assert_blocked "Write to .env is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env","content":"SECRET=foo"}}'

assert_blocked "Edit .env is blocked" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$(pwd)"'/.env","old_string":"a","new_string":"b"}}'

assert_allowed "Write to config.json is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/config.json","content":"{}"}}'

assert_blocked "Write to secrets.json is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/secrets.json","content":"{}"}}'

assert_allowed "Write to public.json is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/public.json","content":"{}"}}'

# --- Test: Glob patterns ---
echo ""
echo "--- Glob patterns ---"
cat > "$CONFIG" <<'EOF'
*.pem
*.key
credentials.*
EOF

assert_blocked "Write to server.pem is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/server.pem","content":"cert"}}'

assert_blocked "Write to path/to/id_rsa.key is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/path/to/id_rsa.key","content":"key"}}'

assert_blocked "Write to credentials.yaml is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/credentials.yaml","content":"{}"}}'

assert_allowed "Write to readme.md is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/readme.md","content":"hello"}}'

assert_blocked "Write to nested/cert.pem is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/nested/cert.pem","content":"cert"}}'

# --- Test: Directory patterns ---
echo ""
echo "--- Directory patterns ---"
cat > "$CONFIG" <<'EOF'
secrets/
.ssh/
EOF

assert_blocked "Write to secrets/api-key is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/secrets/api-key","content":"key"}}'

assert_blocked "Write to .ssh/authorized_keys is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.ssh/authorized_keys","content":"ssh-rsa"}}'

assert_allowed "Write to src/main.rs is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/src/main.rs","content":"fn main(){}"}}'

assert_blocked "Write to secrets/nested/deep is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/secrets/nested/deep/file","content":"x"}}'

# --- Test: Bash command interception ---
echo ""
echo "--- Bash command interception ---"
cat > "$CONFIG" <<'EOF'
.env
secrets.json
*.pem
EOF

assert_blocked "Bash rm .env is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"rm .env"}}'

assert_blocked "Bash with redirect to .env is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"echo SECRET=x > .env"}}'

assert_blocked "Bash mv secrets.json is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"mv secrets.json /tmp/"}}'

assert_allowed "Bash cat .env is allowed (read-only, write-protect mode)" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'

assert_allowed "Bash git status is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# --- Test: Absolute paths ---
echo ""
echo "--- Absolute path handling ---"
cat > "$CONFIG" <<'EOF'
.env
secrets/
EOF

assert_blocked "Absolute path Write to .env is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env","content":"SECRET=x"}}'

# --- Test: Comments and blank lines in config ---
echo ""
echo "--- Config parsing ---"
cat > "$CONFIG" <<'EOF'
# This is a comment
.env

  # Indented comment
secrets.json

EOF

assert_blocked "Config with comments: .env still blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env","content":"x"}}'

assert_blocked "Config with comments: secrets.json still blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/secrets.json","content":"x"}}'

assert_allowed "Config with comments: readme.md still allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/readme.md","content":"x"}}'

# --- Test: Non-intercepted tools (write-protect only, no [deny]) ---
echo ""
echo "--- Non-intercepted tools (write-protect only) ---"
cat > "$CONFIG" <<'EOF'
.env
EOF

assert_allowed "Read tool is not intercepted (write-protect mode)" \
  '{"tool_name":"Read","tool_input":{"file_path":".env"}}'

assert_allowed "Grep tool is not intercepted (write-protect mode)" \
  '{"tool_name":"Grep","tool_input":{"pattern":"SECRET","path":".env"}}'

assert_allowed "Glob tool is not intercepted (write-protect mode)" \
  '{"tool_name":"Glob","tool_input":{"pattern":"*.env","path":"."}}'

# --- Test: Disabled mode ---
echo ""
echo "--- Disabled mode ---"
cat > "$CONFIG" <<'EOF'
.env
EOF

TOTAL=$((TOTAL + 1))
result=$(FILE_GUARD_DISABLED=1 echo '{"tool_name":"Write","tool_input":{"file_path":".env","content":"x"}}' | FILE_GUARD_DISABLED=1 bash "$HOOK" 2>/dev/null) || true
if echo "$result" | grep -q '"permissionDecision":"deny"'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: Disabled mode should allow everything"
else
  PASS=$((PASS + 1))
  echo "  PASS: Disabled mode allows everything"
fi

# --- Test: No config file ---
echo ""
echo "--- Missing config ---"
TOTAL=$((TOTAL + 1))
old_config="$FILE_GUARD_CONFIG"
export FILE_GUARD_CONFIG="$TMPDIR/nonexistent"
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/.env","content":"x"}}' | bash "$HOOK" 2>/dev/null) || true
if echo "$result" | grep -q '"permissionDecision":"deny"'; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: No config should allow everything"
else
  PASS=$((PASS + 1))
  echo "  PASS: No config allows everything"
fi
export FILE_GUARD_CONFIG="$old_config"

# --- Test: .env.* glob ---
echo ""
echo "--- Dotenv variants ---"
cat > "$CONFIG" <<'EOF'
.env
.env.*
EOF

assert_blocked "Write to .env.local is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env.local","content":"x"}}'

assert_blocked "Write to .env.production is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env.production","content":"x"}}'

assert_allowed "Write to env.example is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/env.example","content":"x"}}'

# --- Security: Path traversal bypass ---
echo "--- Path traversal prevention ---"
cat > "$CONFIG" <<'EOF'
.env
secrets.json
config/
EOF

assert_blocked "Traversal subdir/../.env is caught" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/subdir/../.env"}}'

assert_blocked "Deep traversal a/b/c/../../../.env is caught" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/a/b/c/../../../.env"}}'

assert_blocked "Traversal into protected dir src/../config/db.yml" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$(pwd)"'/src/../config/db.yml"}}'

assert_blocked "Traversal with ./ prefix ./x/../secrets.json" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/x/../secrets.json"}}'

assert_blocked "Traversal subdir/../.env via Edit" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$(pwd)"'/subdir/../.env"}}'

assert_allowed "Non-traversal file with dots in name" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/test..backup.sql"}}'

assert_allowed "Normal path not affected by traversal fix" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/src/app.js"}}'

# --- Security: JSON injection resistance ---
echo "--- JSON output validity ---"
cat > "$CONFIG" <<'EOF'
.env
EOF

# Verify block output is valid JSON (jq can parse it)
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env"}}' | bash "$HOOK" 2>/dev/null) || true
TOTAL=$((TOTAL + 1))
if echo "$result" | jq . >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: Block output is valid JSON"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Block output is not valid JSON: $result"
fi

# Verify reason field contains expected text
TOTAL=$((TOTAL + 1))
if echo "$result" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("file-guard")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: Block reason contains hook name"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Block reason missing hook name"
fi

# ==============================================================================
# [deny] section tests — blocks ALL access (read + write + search)
# ==============================================================================
echo ""
echo "=== [deny] section tests ==="

# --- Test: [deny] blocks Read ---
echo ""
echo "--- [deny] blocks Read ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
generated/
secret-data.bin
EOF

assert_blocked "Read from denied directory is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"codegen/models.ts"}}'

assert_blocked "Read from denied file is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"secret-data.bin"}}'

assert_blocked "Read from nested denied path is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"codegen/deep/nested/file.ts"}}'

assert_allowed "Read from non-denied path is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/main.ts"}}'

assert_allowed "Read from similarly-named path is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":"my-codegen-notes.md"}}'

# --- Test: [deny] blocks Grep ---
echo ""
echo "--- [deny] blocks Grep ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
EOF

assert_blocked "Grep in denied directory is blocked" \
  '{"tool_name":"Grep","tool_input":{"pattern":"import","path":"codegen/"}}'

assert_blocked "Grep targeting denied subpath is blocked" \
  '{"tool_name":"Grep","tool_input":{"pattern":"class","path":"codegen/models"}}'

assert_allowed "Grep in allowed directory is allowed" \
  '{"tool_name":"Grep","tool_input":{"pattern":"import","path":"src/"}}'

assert_allowed "Grep without path is allowed (searches cwd)" \
  '{"tool_name":"Grep","tool_input":{"pattern":"import"}}'

# --- Test: [deny] blocks Glob ---
echo ""
echo "--- [deny] blocks Glob ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
generated/
EOF

assert_blocked "Glob in denied directory is blocked" \
  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.ts","path":"codegen/"}}'

assert_blocked "Glob in denied directory (no trailing slash) is blocked" \
  '{"tool_name":"Glob","tool_input":{"pattern":"*.js","path":"codegen"}}'

assert_allowed "Glob in allowed directory is allowed" \
  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.ts","path":"src/"}}'

assert_allowed "Glob without path is allowed" \
  '{"tool_name":"Glob","tool_input":{"pattern":"**/*.ts"}}'

# --- Test: [deny] also blocks Write/Edit ---
echo ""
echo "--- [deny] blocks Write/Edit too ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
EOF

assert_blocked "Write to denied directory is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/codegen/output.ts","content":"x"}}'

assert_blocked "Edit in denied directory is blocked" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$(pwd)"'/codegen/models.ts","old_string":"a","new_string":"b"}}'

# --- Test: [deny] blocks ALL Bash access (not just modifying) ---
echo ""
echo "--- [deny] blocks Bash read access ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
secret-data.bin
EOF

assert_blocked "Bash cat of denied file is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"cat secret-data.bin"}}'

assert_blocked "Bash grep in denied directory is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"grep -r import codegen/"}}'

assert_blocked "Bash head of denied file is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"head -20 codegen/models.ts"}}'

assert_blocked "Bash ls of denied directory is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"ls codegen/"}}'

assert_blocked "Bash find in denied directory is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"find codegen/ -name *.ts"}}'

assert_blocked "Bash python script reading denied file is blocked" \
  '{"tool_name":"Bash","tool_input":{"command":"python3 -c \"open('"'"'codegen/models.ts'"'"').read()\""}}'

assert_allowed "Bash git status is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"git status"}}'

assert_allowed "Bash command not referencing denied paths is allowed" \
  '{"tool_name":"Bash","tool_input":{"command":"npm run build"}}'

# --- Test: Mixed config (write-protect + deny) ---
echo ""
echo "--- Mixed config (write-protect + deny) ---"
cat > "$CONFIG" <<'EOF'
# Write-protected: Claude can read but not modify
.env
secrets/*.key

# Access denied: Claude cannot access at all
[deny]
codegen/
internal-data.bin
EOF

# Write-protect: read OK, write blocked
assert_allowed "Read .env is allowed (write-protect only)" \
  '{"tool_name":"Read","tool_input":{"file_path":".env"}}'

assert_blocked "Write .env is blocked (write-protect)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env","content":"x"}}'

assert_allowed "Bash cat .env is allowed (write-protect, read OK)" \
  '{"tool_name":"Bash","tool_input":{"command":"cat .env"}}'

assert_blocked "Bash rm .env is blocked (write-protect, modify blocked)" \
  '{"tool_name":"Bash","tool_input":{"command":"rm .env"}}'

# Deny: everything blocked
assert_blocked "Read codegen/ is blocked (deny)" \
  '{"tool_name":"Read","tool_input":{"file_path":"codegen/file.ts"}}'

assert_blocked "Write codegen/ is blocked (deny)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/codegen/file.ts","content":"x"}}'

assert_blocked "Grep codegen/ is blocked (deny)" \
  '{"tool_name":"Grep","tool_input":{"pattern":"import","path":"codegen/"}}'

assert_blocked "Bash cat codegen/ is blocked (deny)" \
  '{"tool_name":"Bash","tool_input":{"command":"cat codegen/file.ts"}}'

# Unprotected: everything allowed
assert_allowed "Read src/app.ts is allowed (not protected)" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/app.ts"}}'

assert_allowed "Write src/app.ts is allowed (not protected)" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test/src/app.ts","content":"x"}}'

# --- Test: [deny] with glob patterns ---
echo ""
echo "--- [deny] with glob patterns ---"
cat > "$CONFIG" <<'EOF'
[deny]
*.generated.ts
*.codegen.js
EOF

assert_blocked "Read denied glob pattern is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"models.generated.ts"}}'

assert_blocked "Read nested denied glob is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/api.generated.ts"}}'

assert_allowed "Read non-matching file is allowed" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/manual.ts"}}'

# --- Test: [deny] path traversal prevention ---
echo ""
echo "--- [deny] path traversal prevention ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
secret-data.bin
EOF

assert_blocked "Read traversal into denied dir is caught" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/../codegen/models.ts"}}'

assert_blocked "Read traversal to denied file is caught" \
  '{"tool_name":"Read","tool_input":{"file_path":"subdir/../secret-data.bin"}}'

assert_blocked "Grep traversal into denied dir is caught" \
  '{"tool_name":"Grep","tool_input":{"pattern":"class","path":"src/../codegen/"}}'

# --- Test: [deny] JSON output validity ---
echo ""
echo "--- [deny] JSON output validity ---"
cat > "$CONFIG" <<'EOF'
[deny]
codegen/
EOF

result=$(echo '{"tool_name":"Read","tool_input":{"file_path":"codegen/file.ts"}}' | bash "$HOOK" 2>/dev/null) || true
TOTAL=$((TOTAL + 1))
if echo "$result" | jq . >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: [deny] block output is valid JSON"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: [deny] block output is not valid JSON: $result"
fi

TOTAL=$((TOTAL + 1))
if echo "$result" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("denied")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: [deny] block reason says 'denied'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: [deny] block reason missing 'denied'"
fi

# --- Test: [write] section header resets to write mode ---
echo ""
echo "--- Section switching ---"
cat > "$CONFIG" <<'EOF'
.env

[deny]
codegen/

[write]
passwords.txt
EOF

assert_allowed "Read .env is allowed (write section)" \
  '{"tool_name":"Read","tool_input":{"file_path":".env"}}'

assert_blocked "Write .env is blocked (write section)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/.env","content":"x"}}'

assert_blocked "Read codegen is blocked (deny section)" \
  '{"tool_name":"Read","tool_input":{"file_path":"codegen/file.ts"}}'

assert_blocked "Write passwords.txt is blocked (back to write section)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$(pwd)"'/passwords.txt","content":"x"}}'

assert_allowed "Read passwords.txt is allowed (write section, not deny)" \
  '{"tool_name":"Read","tool_input":{"file_path":"passwords.txt"}}'

# --- Test: Relative path rejection (always active, no config needed) ---
echo ""
echo "--- Relative path rejection (#38270) ---"
# Clear config to test that relative path check works WITHOUT any .file-guard
cat > "$CONFIG" <<'EOF'
EOF

assert_blocked "Write with relative path is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"src/foo.ts","content":"x"}}'

assert_blocked "Edit with relative path is blocked" \
  '{"tool_name":"Edit","tool_input":{"file_path":"lib/bar.rb","old_string":"a","new_string":"b"}}'

assert_blocked "Write with dot-relative path is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"./config.json","content":"{}"}}'

assert_allowed "Write with absolute path is allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"}}'

assert_allowed "Edit with absolute path is allowed" \
  '{"tool_name":"Edit","tool_input":{"file_path":"/Users/me/project/src/foo.ts","old_string":"a","new_string":"b"}}'

assert_allowed "Read with relative path is allowed (reads don't need absolute)" \
  '{"tool_name":"Read","tool_input":{"file_path":"src/foo.ts"}}'

# Relative path check with config still active
cat > "$CONFIG" <<'EOF'
.env
EOF

assert_blocked "Write with relative path blocked even with config" \
  '{"tool_name":"Write","tool_input":{"file_path":"src/app.ts","content":"x"}}'

# Verify the block message is helpful
result=$(echo '{"tool_name":"Write","tool_input":{"file_path":"src/foo.ts","content":"x"}}' | bash "$HOOK" 2>/dev/null) || true
TOTAL=$((TOTAL + 1))
if echo "$result" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("relative path")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: Relative path block reason mentions 'relative path'"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Relative path block reason should mention 'relative path': $result"
fi

TOTAL=$((TOTAL + 1))
if echo "$result" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("/")' >/dev/null 2>&1; then
  PASS=$((PASS + 1))
  echo "  PASS: Relative path block suggests absolute path"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: Relative path block should suggest absolute path: $result"
fi

# --- Test: Symlink bypass protection (GHSA-4q92-rfm6-2cqx) ---
echo ""
echo "--- Symlink bypass protection ---"

# Create symlinks for testing
SYMTEST="$TMPDIR/symtest"
mkdir -p "$SYMTEST"
echo "SECRET=value" > "$SYMTEST/.env"
echo "key data" > "$SYMTEST/secret-key.pem"
mkdir -p "$SYMTEST/secrets"
echo "api-key" > "$SYMTEST/secrets/api.key"
ln -sf "$SYMTEST/.env" "$SYMTEST/safe-link"
ln -sf "$SYMTEST/secret-key.pem" "$SYMTEST/harmless.txt"
ln -sf "$SYMTEST/secrets" "$SYMTEST/docs"

cat > "$CONFIG" <<EOF
.env
*.pem
[deny]
secrets/
EOF

# Write-protect: symlink to .env
cd "$SYMTEST"

assert_blocked "Write via symlink to .env is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$SYMTEST/safe-link"'","content":"HACKED=true"}}'

assert_blocked "Edit via symlink to .env is blocked" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$SYMTEST/safe-link"'","old_string":"SECRET","new_string":"HACKED"}}'

assert_blocked "Write via symlink to .pem is blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$SYMTEST/harmless.txt"'","content":"fake key"}}'

# Deny: symlink to denied directory
assert_blocked "Read via symlink to denied dir is blocked" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$SYMTEST/docs/api.key"'"}}'

assert_blocked "Grep via symlink to denied dir is blocked" \
  '{"tool_name":"Grep","tool_input":{"path":"'"$SYMTEST/docs"'","pattern":"key"}}'

assert_blocked "Glob via symlink to denied dir is blocked" \
  '{"tool_name":"Glob","tool_input":{"path":"'"$SYMTEST/docs"'","pattern":"*"}}'

# Non-symlink should still work
assert_allowed "Write to non-symlink non-protected file allowed" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$SYMTEST/readme.md"'","content":"hello"}}'

# Direct access to .env should still be blocked
assert_blocked "Direct write to .env still blocked" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$SYMTEST/.env"'","content":"HACKED"}}'

cd "$TMPDIR"

# --- Absolute paths (v2.1.89+: file_path now absolute in PreToolUse) ---
echo ""
echo "--- Absolute path resolution (v2.1.89 compat) ---"

# Create fresh test dir for absolute path tests
ABSTEST=$(mktemp -d)
cat > "$ABSTEST/.file-guard" << 'ABSEOF'
.env
secrets/
*.pem

[deny]
codegen/
private.key
ABSEOF

# Run tests from ABSTEST so pwd matches
cd "$ABSTEST"
export FILE_GUARD_CONFIG="$ABSTEST/.file-guard"

# Write-protect patterns with absolute paths
assert_blocked "Write .env (absolute path)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$ABSTEST/.env"'","content":"secret"}}'

assert_blocked "Write to secrets/ dir (absolute path)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$ABSTEST/secrets/key.txt"'","content":"s"}}'

assert_blocked "Write .pem glob (absolute path)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$ABSTEST/cert.pem"'","content":"c"}}'

assert_blocked "Edit .env (absolute path)" \
  '{"tool_name":"Edit","tool_input":{"file_path":"'"$ABSTEST/.env"'","old_string":"a","new_string":"b"}}'

assert_allowed "Write safe.txt (absolute path)" \
  '{"tool_name":"Write","tool_input":{"file_path":"'"$ABSTEST/safe.txt"'","content":"ok"}}'

# Deny patterns with absolute paths
mkdir -p "$ABSTEST/codegen"

assert_blocked "Read codegen/ file (absolute, deny)" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$ABSTEST/codegen/gen.js"'"}}'

assert_blocked "Read private.key (absolute, deny)" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$ABSTEST/private.key"'"}}'

assert_allowed "Read .env (absolute, write-protect allows read)" \
  '{"tool_name":"Read","tool_input":{"file_path":"'"$ABSTEST/.env"'"}}'

assert_blocked "Grep codegen/ (absolute, deny)" \
  '{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"'"$ABSTEST/codegen/"'"}}'

assert_blocked "Glob codegen/ (absolute, deny)" \
  '{"tool_name":"Glob","tool_input":{"pattern":"*.js","path":"'"$ABSTEST/codegen/"'"}}'

# Outside project root should not match relative patterns
assert_allowed "Write /etc/hosts (outside project)" \
  '{"tool_name":"Write","tool_input":{"file_path":"/etc/hosts","content":"x"}}'

rm -rf "$ABSTEST"
cd "$TMPDIR"
export FILE_GUARD_CONFIG="$CONFIG"

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "All tests passed!"
