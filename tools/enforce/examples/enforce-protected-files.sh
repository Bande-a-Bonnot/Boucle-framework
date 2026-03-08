#!/usr/bin/env bash
# enforce: Never modify .env, secrets/, or *.pem files.
# Generated from CLAUDE.md by enforce-hooks skill
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
for pat in ".env" "secrets/" ".pem"; do
  [[ "$FILE" == *"$pat"* ]] && echo "{\"decision\": \"block\", \"reason\": \"Protected file: $FILE. (CLAUDE.md: Protected Files @enforced)\"}" && exit 0
done
exit 0
