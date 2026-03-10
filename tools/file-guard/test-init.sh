#!/bin/bash
# Tests for file-guard init.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INIT="$SCRIPT_DIR/init.sh"
PASS=0
FAIL=0
TOTAL=0

assert() {
  local desc="$1"
  local result="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$result" -eq 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $desc"
  fi
}

setup_dir() {
  local dir
  dir=$(mktemp -d)
  echo "$dir"
}

cleanup() {
  rm -rf "$1"
}

echo "Testing file-guard init.sh"
echo "=========================="

# --- Test 1: Empty project ---
echo "Test: Empty project"
DIR=$(setup_dir)
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "empty project shows no findings" $([[ "$output" == *"No sensitive files detected"* ]]; echo $?)
cleanup "$DIR"

# --- Test 2: Detects .env ---
echo "Test: Detects .env"
DIR=$(setup_dir)
echo "SECRET=foo" > "$DIR/.env"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds .env" $([[ "$output" == *".env"* ]]; echo $?)
assert "categorizes as Environment files" $([[ "$output" == *"Environment files"* ]]; echo $?)
cleanup "$DIR"

# --- Test 3: Detects .env.* variants ---
echo "Test: Detects .env.* variants"
DIR=$(setup_dir)
echo "X=1" > "$DIR/.env.local"
echo "Y=2" > "$DIR/.env.production"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds .env.* pattern" $([[ "$output" == *".env.*"* ]]; echo $?)
cleanup "$DIR"

# --- Test 4: Detects .env from template ---
echo "Test: Detects .env from template"
DIR=$(setup_dir)
echo "X=changeme" > "$DIR/.env.example"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "suggests .env when template exists" $([[ "$output" == *".env"* ]]; echo $?)
cleanup "$DIR"

# --- Test 5: Detects PEM files ---
echo "Test: Detects PEM files"
DIR=$(setup_dir)
echo "-----BEGIN CERTIFICATE-----" > "$DIR/server.pem"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds *.pem" $([[ "$output" == *"*.pem"* ]]; echo $?)
assert "categorizes as Certificates" $([[ "$output" == *"Certificates"* ]]; echo $?)
cleanup "$DIR"

# --- Test 6: Detects key files ---
echo "Test: Detects key files"
DIR=$(setup_dir)
echo "private key" > "$DIR/api.key"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds *.key" $([[ "$output" == *"*.key"* ]]; echo $?)
cleanup "$DIR"

# --- Test 7: Detects SSH directory ---
echo "Test: Detects SSH directory"
DIR=$(setup_dir)
mkdir -p "$DIR/.ssh"
echo "key" > "$DIR/.ssh/id_rsa"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds .ssh/" $([[ "$output" == *".ssh/"* ]]; echo $?)
cleanup "$DIR"

# --- Test 8: Detects credentials files ---
echo "Test: Detects credentials files"
DIR=$(setup_dir)
echo '{"key":"val"}' > "$DIR/credentials.json"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds credentials.json" $([[ "$output" == *"credentials"* ]]; echo $?)
cleanup "$DIR"

# --- Test 9: Detects Rails master.key ---
echo "Test: Detects Rails master.key"
DIR=$(setup_dir)
mkdir -p "$DIR/config"
echo "abc123" > "$DIR/config/master.key"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds config/master.key" $([[ "$output" == *"config/master.key"* ]]; echo $?)
assert "identifies as Rails" $([[ "$output" == *"Framework secrets"* ]]; echo $?)
cleanup "$DIR"

# --- Test 10: Detects wp-config.php ---
echo "Test: Detects wp-config.php"
DIR=$(setup_dir)
echo "<?php define('DB_PASSWORD', 'x');" > "$DIR/wp-config.php"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds wp-config.php" $([[ "$output" == *"wp-config.php"* ]]; echo $?)
cleanup "$DIR"

# --- Test 11: Detects secrets directory ---
echo "Test: Detects secrets directory"
DIR=$(setup_dir)
mkdir -p "$DIR/secrets"
echo "token" > "$DIR/secrets/api.txt"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds secrets/" $([[ "$output" == *"secrets/"* ]]; echo $?)
cleanup "$DIR"

# --- Test 12: Detects terraform state ---
echo "Test: Detects terraform state"
DIR=$(setup_dir)
echo '{}' > "$DIR/terraform.tfstate"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds *.tfstate" $([[ "$output" == *"*.tfstate"* ]]; echo $?)
assert "categorizes as Infrastructure" $([[ "$output" == *"Infrastructure"* ]]; echo $?)
cleanup "$DIR"

# --- Test 13: Detects .htpasswd ---
echo "Test: Detects .htpasswd"
DIR=$(setup_dir)
echo "user:hash" > "$DIR/.htpasswd"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds .htpasswd" $([[ "$output" == *".htpasswd"* ]]; echo $?)
cleanup "$DIR"

# --- Test 14: Writes .file-guard ---
echo "Test: Writes .file-guard"
DIR=$(setup_dir)
echo "SECRET=x" > "$DIR/.env"
echo "key" > "$DIR/server.pem"
bash "$INIT" "$DIR" > /dev/null 2>&1
assert ".file-guard created" $([ -f "$DIR/.file-guard" ]; echo $?)
assert "contains .env" $(grep -q "^\.env$" "$DIR/.file-guard"; echo $?)
assert "contains *.pem" $(grep -q "^\*\.pem$" "$DIR/.file-guard"; echo $?)
assert "has header comment" $(grep -q "^# file-guard:" "$DIR/.file-guard"; echo $?)
cleanup "$DIR"

# --- Test 15: Refuses to overwrite ---
echo "Test: Refuses to overwrite existing .file-guard"
DIR=$(setup_dir)
echo ".env" > "$DIR/.file-guard"
echo "SECRET=x" > "$DIR/.env"
output=$(bash "$INIT" "$DIR" 2>&1)
assert "warns about existing file" $([[ "$output" == *"already exists"* ]]; echo $?)
cleanup "$DIR"

# --- Test 16: Append mode ---
echo "Test: Append mode"
DIR=$(setup_dir)
echo ".env" > "$DIR/.file-guard"
echo "key" > "$DIR/server.pem"
echo "SECRET=x" > "$DIR/.env"
bash "$INIT" --append "$DIR" > /dev/null 2>&1
assert "keeps original .env" $(grep -q "^\.env$" "$DIR/.file-guard"; echo $?)
assert "adds *.pem" $(grep -q "^\*\.pem$" "$DIR/.file-guard"; echo $?)
assert "marks .env as already listed" $(grep -q "already listed" "$DIR/.file-guard"; echo $?)
cleanup "$DIR"

# --- Test 17: Dry run doesn't write ---
echo "Test: Dry run doesn't write"
DIR=$(setup_dir)
echo "SECRET=x" > "$DIR/.env"
bash "$INIT" --dry-run "$DIR" > /dev/null 2>&1
assert "no .file-guard in dry run" $([ ! -f "$DIR/.file-guard" ]; echo $?)
cleanup "$DIR"

# --- Test 18: Multiple categories ---
echo "Test: Multiple categories at once"
DIR=$(setup_dir)
echo "x" > "$DIR/.env"
echo "k" > "$DIR/cert.pem"
mkdir -p "$DIR/secrets"
mkdir -p "$DIR/config"
echo "key" > "$DIR/config/master.key"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "shows multiple categories" $([[ "$output" == *"Environment files"* ]] && [[ "$output" == *"Certificates"* ]] && [[ "$output" == *"Framework secrets"* ]]; echo $?)
cleanup "$DIR"

# --- Test 19: .npmrc detection ---
echo "Test: Detects .npmrc"
DIR=$(setup_dir)
echo "//registry.npmjs.org/:_authToken=abc" > "$DIR/.npmrc"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds .npmrc" $([[ "$output" == *".npmrc"* ]]; echo $?)
cleanup "$DIR"

# --- Test 20: Nested key files ---
echo "Test: Nested key files (depth 3)"
DIR=$(setup_dir)
mkdir -p "$DIR/certs/prod"
echo "key" > "$DIR/certs/prod/server.key"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "finds nested *.key" $([[ "$output" == *"*.key"* ]]; echo $?)
cleanup "$DIR"

# --- Test 21: Help flag ---
echo "Test: Help flag"
output=$(bash "$INIT" --help 2>&1)
assert "--help shows usage" $([[ "$output" == *"Usage"* ]]; echo $?)
assert "--help mentions dry-run" $([[ "$output" == *"dry-run"* ]]; echo $?)

# --- Test 22: Count is correct ---
echo "Test: Pattern count in output"
DIR=$(setup_dir)
echo "x" > "$DIR/.env"
echo "k" > "$DIR/cert.pem"
output=$(bash "$INIT" --dry-run "$DIR" 2>&1)
assert "shows pattern count" $([[ "$output" == *"Found"*"sensitive patterns"* ]]; echo $?)
cleanup "$DIR"

# --- Results ---
echo ""
echo "=========================="
echo "Results: $PASS passed, $FAIL failed (of $TOTAL)"
if [ "$FAIL" -gt 0 ]; then
  echo "SOME TESTS FAILED"
  exit 1
else
  echo "ALL TESTS PASSED"
fi
