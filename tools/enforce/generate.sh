#!/usr/bin/env bash
# enforce-generate: Parse CLAUDE.md for @enforced directives and generate rule objects.
#
# Usage:
#   enforce-generate                    # Parse CLAUDE.md in current project
#   enforce-generate --claude-file PATH # Parse a specific file
#   enforce-generate --dry-run          # Show rules without writing
#
# Finds @enforced or @required tags in CLAUDE.md headings or inline,
# then uses Claude to translate each directive into a declarative rule object.
# Rules are written to .claude/enforcements/*.json for the enforcement engine.

set -euo pipefail

CLAUDE_FILE=""
DRY_RUN=false

while [ $# -gt 0 ]; do
    case "$1" in
        --claude-file) CLAUDE_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Find CLAUDE.md
if [ -z "$CLAUDE_FILE" ]; then
    dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/CLAUDE.md" ]; then
            CLAUDE_FILE="$dir/CLAUDE.md"
            break
        fi
        dir=$(dirname "$dir")
    done
fi

if [ -z "$CLAUDE_FILE" ] || [ ! -f "$CLAUDE_FILE" ]; then
    echo "No CLAUDE.md found. Specify with --claude-file PATH"
    exit 1
fi

PROJECT_ROOT=$(dirname "$CLAUDE_FILE")
ENFORCEMENTS_DIR="$PROJECT_ROOT/.claude/enforcements"

echo "Parsing: $CLAUDE_FILE"
echo ""

# Extract @enforced/@required sections
python3 -c "
import re, sys, json, os

claude_file = '$CLAUDE_FILE'
dry_run = '$DRY_RUN' == 'true'
enforcements_dir = '$ENFORCEMENTS_DIR'

with open(claude_file) as f:
    content = f.read()

# Find sections with @enforced or @required
# Pattern: heading with @enforced tag, followed by body text until next heading
pattern = r'(#{1,6}\s+.+?@(?:enforced|required).*?)(?=\n#{1,6}\s|\Z)'
matches = re.findall(pattern, content, re.DOTALL)

if not matches:
    # Also try inline @enforced markers
    lines = content.split('\n')
    current_section = []
    in_enforced = False
    for line in lines:
        if '@enforced' in line or '@required' in line:
            if current_section:
                matches.append('\n'.join(current_section))
            current_section = [line]
            in_enforced = True
        elif in_enforced and line.strip() and not line.startswith('#'):
            current_section.append(line)
        elif in_enforced and (line.startswith('#') or not line.strip()):
            if current_section:
                matches.append('\n'.join(current_section))
            current_section = []
            in_enforced = False
    if current_section:
        matches.append('\n'.join(current_section))

if not matches:
    print('No @enforced or @required directives found in CLAUDE.md')
    print('Tag directives like: ## My Rule @enforced')
    sys.exit(0)

print(f'Found {len(matches)} enforced directive(s):')
print()

for i, section in enumerate(matches):
    # Clean up
    section = section.strip()
    # Extract title
    title_match = re.match(r'#{1,6}\s+(.+?)(?:\s*@(?:enforced|required))', section)
    title = title_match.group(1).strip() if title_match else f'Rule {i+1}'
    # Get body (everything after the heading)
    body_lines = section.split('\n')[1:]
    body = '\n'.join(l for l in body_lines if l.strip()).strip()

    print(f'  [{i+1}] {title}')
    if body:
        preview = body[:100] + ('...' if len(body) > 100 else '')
        print(f'      {preview}')
    print()

print('To generate enforcement rules, pipe each directive through an LLM')
print('to create .claude/enforcements/*.json rule objects.')
print()
print(f'Target directory: {enforcements_dir}')

if not dry_run:
    os.makedirs(enforcements_dir, exist_ok=True)
    # Write the raw directives for the LLM to process
    directives_file = os.path.join(enforcements_dir, '_directives.md')
    with open(directives_file, 'w') as f:
        for i, section in enumerate(matches):
            f.write(f'--- Directive {i+1} ---\n')
            f.write(section.strip())
            f.write('\n\n')
    print(f'Directives extracted to: {directives_file}')
    print('Next: run enforce-compile to generate rule objects from these directives.')
"
