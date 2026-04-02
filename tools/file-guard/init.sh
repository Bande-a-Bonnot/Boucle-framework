#!/bin/bash
# file-guard init: Scan a project for sensitive files and generate .file-guard config
#
# Usage:
#   ./init.sh              Scan current directory, write .file-guard
#   ./init.sh --dry-run    Show what would be added without writing
#   ./init.sh --append     Add to existing .file-guard instead of replacing
#   ./init.sh /path/to/dir Scan a specific directory
#
# Detects:
#   - Environment files (.env, .env.*)
#   - Certificates and keys (*.pem, *.key, *.p12, *.pfx, *.crt)
#   - SSH keys and config (.ssh/)
#   - Credential files (credentials.*, auth.json, .netrc, .npmrc, .pypirc)
#   - Framework secrets (master.key, database.yml, wp-config.php)
#   - Infrastructure state (*.tfstate, docker-compose secrets)
#   - Git-ignored secrets that still need hook protection
#
# Compatible with Bash 3.2+ (macOS default)

set -euo pipefail

# Parse arguments
DRY_RUN=0
APPEND=0
TARGET_DIR="."

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --append) APPEND=1; shift ;;
    --help|-h)
      echo "Usage: init.sh [--dry-run] [--append] [directory]"
      echo ""
      echo "Scans a project for sensitive files and generates .file-guard config."
      echo ""
      echo "Options:"
      echo "  --dry-run   Show detected files without writing config"
      echo "  --append    Add to existing .file-guard instead of replacing"
      echo "  --help      Show this help"
      exit 0
      ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) TARGET_DIR="$1"; shift ;;
  esac
done

cd "$TARGET_DIR"

# Use a temp file to store findings (Bash 3.x compatible, no associative arrays)
# Format: CATEGORY<TAB>PATTERN<TAB>DESCRIPTION
FINDINGS=$(mktemp)
trap 'rm -f "$FINDINGS"' EXIT

add_finding() {
  local category="$1"
  local pattern="$2"
  local desc="$3"

  # Avoid duplicate patterns within same category
  if grep -qF "	${pattern}	" "$FINDINGS" 2>/dev/null; then
    return
  fi
  printf '%s\t%s\t%s\n' "$category" "$pattern" "$desc" >> "$FINDINGS"
}

# ---- Detection rules ----

# 1. Environment files
if [ -f ".env" ]; then
  add_finding "Environment files" ".env" ".env"
fi
# .env.* variants
env_variants=$(ls -1 .env.* 2>/dev/null | grep -v '.example$' | grep -v '.sample$' | grep -v '.template$' | head -5 || true)
if [ -n "$env_variants" ]; then
  env_count=$(echo "$env_variants" | wc -l | tr -d ' ')
  add_finding "Environment files" ".env.*" ".env.* ($env_count files)"
fi
# Suggest .env protection if only template exists
if [ -f ".env.example" ] || [ -f ".env.sample" ] || [ -f ".env.template" ]; then
  add_finding "Environment files" ".env" ".env (template found, protect the real one)"
fi

# 2. Certificates and keys
for ext in pem key p12 pfx crt keystore jks; do
  found=$(find . -maxdepth 3 -name "*.${ext}" -not -path './.git/*' 2>/dev/null | head -5 || true)
  if [ -n "$found" ]; then
    count=$(echo "$found" | wc -l | tr -d ' ')
    add_finding "Certificates and keys" "*.${ext}" "*.${ext} ($count found)"
  fi
done

# 3. SSH directory
if [ -d ".ssh" ]; then
  add_finding "SSH" ".ssh/" ".ssh/ directory"
fi
# SSH keys in project root
for f in id_rsa id_ed25519 id_ecdsa; do
  if [ -f "$f" ] || [ -f "${f}.pub" ]; then
    add_finding "SSH" "$f" "$f"
  fi
done

# 4. Common credential files
for f in credentials.json credentials.yml credentials.yaml auth.json auth.yaml \
         service-account.json service_account.json gcloud-key.json \
         .netrc .npmrc .pypirc; do
  if [ -f "$f" ]; then
    add_finding "Credentials" "$f" "$f"
  fi
done
if [ -f ".docker/config.json" ]; then
  add_finding "Credentials" ".docker/config.json" ".docker/config.json"
fi
# Glob patterns for credentials
cred_files=$(ls -1 credentials.* 2>/dev/null | head -5 || true)
if [ -n "$cred_files" ]; then
  add_finding "Credentials" "credentials.*" "credentials.* files"
fi
secret_files=$(ls -1 secrets.* 2>/dev/null | head -5 || true)
if [ -n "$secret_files" ]; then
  add_finding "Credentials" "secrets.*" "secrets.* files"
fi
secret_named=$(find . -maxdepth 1 -name "*secret*" -type f 2>/dev/null | head -5 || true)
if [ -n "$secret_named" ]; then
  count=$(echo "$secret_named" | wc -l | tr -d ' ')
  add_finding "Credentials" "*secret*" "Files with 'secret' in name ($count found)"
fi

# 5. Framework-specific secrets
# Rails
if [ -f "config/master.key" ]; then
  add_finding "Framework secrets" "config/master.key" "config/master.key (Rails)"
fi
if [ -f "config/credentials.yml.enc" ] && [ ! -f "config/master.key" ]; then
  add_finding "Framework secrets" "config/master.key" "config/master.key (Rails encrypted credentials)"
fi
# Django
if [ -f "local_settings.py" ]; then
  add_finding "Framework secrets" "local_settings.py" "local_settings.py (Django)"
fi
# WordPress
if [ -f "wp-config.php" ]; then
  add_finding "Framework secrets" "wp-config.php" "wp-config.php (WordPress)"
fi

# 6. Secrets directories
for d in secrets .secrets private .private; do
  if [ -d "$d" ]; then
    add_finding "Secret directories" "${d}/" "${d}/ directory"
  fi
done

# 7. Infrastructure state
for ext in tfstate tfstate.backup; do
  found=$(find . -maxdepth 3 -name "*.${ext}" -not -path './.git/*' 2>/dev/null | head -3 || true)
  if [ -n "$found" ]; then
    add_finding "Infrastructure" "*.${ext}" "*.${ext} (Terraform state)"
  fi
done
# Ansible vault
vault_found=$(find . -maxdepth 3 -name "vault*.yml" 2>/dev/null | head -3 || true)
if [ -n "$vault_found" ]; then
  count=$(echo "$vault_found" | wc -l | tr -d ' ')
  add_finding "Infrastructure" "vault*.yml" "Ansible vault files ($count found)"
fi

# 8. Token/password files
for f in .token token.txt api_key.txt api-key.txt password.txt passwords.txt \
         .password .htpasswd; do
  if [ -f "$f" ]; then
    add_finding "Tokens and passwords" "$f" "$f"
  fi
done

# 9. GPG
if [ -d ".gnupg" ]; then
  add_finding "GPG" ".gnupg/" ".gnupg/ directory"
fi
gpg_found=$(find . -maxdepth 2 -name "*.gpg" 2>/dev/null | head -3 || true)
if [ -n "$gpg_found" ]; then
  add_finding "GPG" "*.gpg" "GPG encrypted files"
fi

# ---- Output ----

TOTAL=$(wc -l < "$FINDINGS" | tr -d ' ' || echo 0)

if [ "$TOTAL" -eq 0 ]; then
  echo "No sensitive files detected in $(pwd)"
  echo ""
  echo "This doesn't mean your project is safe! Consider protecting:"
  echo "  .env         - environment variables"
  echo "  *.pem *.key  - certificates and keys"
  echo "  secrets/     - secret directories"
  echo ""
  echo "Create .file-guard manually with patterns to protect."
  exit 0
fi

echo "file-guard init: Found $TOTAL sensitive patterns in $(basename "$(pwd)")"
echo ""

# Display grouped by category
current_cat=""
while IFS='	' read -r category pattern desc; do
  if [ "$category" != "$current_cat" ]; then
    if [ -n "$current_cat" ]; then
      echo ""
    fi
    echo "  $category:"
    current_cat="$category"
  fi
  echo "    $pattern  ($desc)"
done < "$FINDINGS"
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry run -- no files written)"
  exit 0
fi

# Generate .file-guard config
OUTPUT=".file-guard"

if [ "$APPEND" -eq 0 ] && [ -f "$OUTPUT" ]; then
  echo "  .file-guard already exists."
  echo "  Use --append to add new patterns, or delete it first."
  echo "  Use --dry-run to preview without writing."
  exit 0
fi

{
  if [ "$APPEND" -eq 0 ]; then
    echo "# file-guard: Protected files (generated by init.sh)"
    echo "# $(date +%Y-%m-%d)"
    echo "#"
    echo "# One pattern per line. Supports exact paths, globs, and directory prefixes."
    echo "# Edit freely -- this file is yours."
    echo ""
  else
    echo ""
    echo "# Added by file-guard init ($(date +%Y-%m-%d))"
  fi

  current_cat=""
  while IFS='	' read -r category pattern desc; do
    if [ "$category" != "$current_cat" ]; then
      echo "# $category"
      current_cat="$category"
    fi
    # If appending, check if pattern already exists
    if [ "$APPEND" -eq 1 ] && [ -f "$OUTPUT" ] && grep -qF "$pattern" "$OUTPUT" 2>/dev/null; then
      echo "# $pattern  (already listed)"
    else
      echo "$pattern"
    fi
  done < "$FINDINGS"
  echo ""
} >> "$OUTPUT"

if [ "$APPEND" -eq 1 ]; then
  echo "Appended new patterns to $OUTPUT"
else
  echo "Created $OUTPUT with $TOTAL protected patterns."
fi

echo ""
echo "Next steps:"
echo "  1. Review .file-guard and adjust patterns"
echo "  2. Install the hook: curl -fsSL https://raw.githubusercontent.com/Bande-a-Bonnot/Boucle-framework/main/tools/file-guard/install.sh | bash"
echo "  3. Test it: ask Claude to 'write to .env' -- it should be blocked"
