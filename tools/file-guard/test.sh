#!/bin/bash
# Tests for file-guard hook
# Usage: bash test.sh

set -euo pipefail

HOOK="$(dirname "$0")/hook.sh"
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
  if echo "$result" | grep -q '"decision":"block"'; then
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
  if echo "$result" | grep -q '"decision":"block"'; then
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
  '{"tool_name":"Write","input":{"file_path":".env","content":"SECRET=foo"}}'

assert_blocked "Edit .env is blocked" \
  '{"tool_name":"Edit","input":{"file_path":".env","old_string":"a","new_string":"b"}}'

assert_allowed "Write to config.json is allowed" \
  '{"tool_name":"Write","input":{"file_path":"config.json","content":"{}"}}'

assert_blocked "Write to secrets.json is blocked" \
  '{"tool_name":"Write","input":{"file_path":"secrets.json","content":"{}"}}'

assert_allowed "Write to public.json is allowed" \
  '{"tool_name":"Write","input":{"file_path":"public.json","content":"{}"}}'

# --- Test: Glob patterns ---
echo ""
echo "--- Glob patterns ---"
cat > "$CONFIG" <<'EOF'
*.pem
*.key
credentials.*
EOF

assert_blocked "Write to server.pem is blocked" \
  '{"tool_name":"Write","input":{"file_path":"server.pem","content":"cert"}}'

assert_blocked "Write to path/to/id_rsa.key is blocked" \
  '{"tool_name":"Write","input":{"file_path":"path/to/id_rsa.key","content":"key"}}'

assert_blocked "Write to credentials.yaml is blocked" \
  '{"tool_name":"Write","input":{"file_path":"credentials.yaml","content":"{}"}}'

assert_allowed "Write to readme.md is allowed" \
  '{"tool_name":"Write","input":{"file_path":"readme.md","content":"hello"}}'

assert_blocked "Write to nested/cert.pem is blocked" \
  '{"tool_name":"Write","input":{"file_path":"nested/cert.pem","content":"cert"}}'

# --- Test: Directory patterns ---
echo ""
echo "--- Directory patterns ---"
cat > "$CONFIG" <<'EOF'
secrets/
.ssh/
EOF

assert_blocked "Write to secrets/api-key is blocked" \
  '{"tool_name":"Write","input":{"file_path":"secrets/api-key","content":"key"}}'

assert_blocked "Write to .ssh/authorized_keys is blocked" \
  '{"tool_name":"Write","input":{"file_path":".ssh/authorized_keys","content":"ssh-rsa"}}'

assert_allowed "Write to src/main.rs is allowed" \
  '{"tool_name":"Write","input":{"file_path":"src/main.rs","content":"fn main(){}"}}'

assert_blocked "Write to secrets/nested/deep is blocked" \
  '{"tool_name":"Write","input":{"file_path":"secrets/nested/deep/file","content":"x"}}'

# --- Test: Bash command interception ---
echo ""
echo "--- Bash command interception ---"
cat > "$CONFIG" <<'EOF'
.env
secrets.json
*.pem
EOF

assert_blocked "Bash rm .env is blocked" \
  '{"tool_name":"Bash","input":{"command":"rm .env"}}'

assert_blocked "Bash with redirect to .env is blocked" \
  '{"tool_name":"Bash","input":{"command":"echo SECRET=x > .env"}}'

assert_blocked "Bash mv secrets.json is blocked" \
  '{"tool_name":"Bash","input":{"command":"mv secrets.json /tmp/"}}'

assert_allowed "Bash cat .env is allowed (read-only)" \
  '{"tool_name":"Bash","input":{"command":"cat .env"}}'

assert_allowed "Bash git status is allowed" \
  '{"tool_name":"Bash","input":{"command":"git status"}}'

# --- Test: Absolute paths ---
echo ""
echo "--- Absolute path handling ---"
cat > "$CONFIG" <<'EOF'
.env
secrets/
EOF

assert_blocked "Absolute path Write to .env is blocked" \
  '{"tool_name":"Write","input":{"file_path":"'"$(pwd)"'/.env","content":"SECRET=x"}}'

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
  '{"tool_name":"Write","input":{"file_path":".env","content":"x"}}'

assert_blocked "Config with comments: secrets.json still blocked" \
  '{"tool_name":"Write","input":{"file_path":"secrets.json","content":"x"}}'

assert_allowed "Config with comments: readme.md still allowed" \
  '{"tool_name":"Write","input":{"file_path":"readme.md","content":"x"}}'

# --- Test: Non-intercepted tools ---
echo ""
echo "--- Non-intercepted tools ---"
cat > "$CONFIG" <<'EOF'
.env
EOF

assert_allowed "Read tool is not intercepted" \
  '{"tool_name":"Read","input":{"file_path":".env"}}'

assert_allowed "Grep tool is not intercepted" \
  '{"tool_name":"Grep","input":{"pattern":"SECRET","path":".env"}}'

# --- Test: Disabled mode ---
echo ""
echo "--- Disabled mode ---"
cat > "$CONFIG" <<'EOF'
.env
EOF

TOTAL=$((TOTAL + 1))
result=$(FILE_GUARD_DISABLED=1 echo '{"tool_name":"Write","input":{"file_path":".env","content":"x"}}' | FILE_GUARD_DISABLED=1 bash "$HOOK" 2>/dev/null) || true
if echo "$result" | grep -q '"decision":"block"'; then
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
result=$(echo '{"tool_name":"Write","input":{"file_path":".env","content":"x"}}' | bash "$HOOK" 2>/dev/null) || true
if echo "$result" | grep -q '"decision":"block"'; then
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
  '{"tool_name":"Write","input":{"file_path":".env.local","content":"x"}}'

assert_blocked "Write to .env.production is blocked" \
  '{"tool_name":"Write","input":{"file_path":".env.production","content":"x"}}'

assert_allowed "Write to env.example is allowed" \
  '{"tool_name":"Write","input":{"file_path":"env.example","content":"x"}}'

# --- Summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "All tests passed!"
