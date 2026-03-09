#!/usr/bin/env python3
"""enforce-hooks: Generate PreToolUse hook scripts from CLAUDE.md directives.

Reads a CLAUDE.md file, identifies enforceable rules, and generates
standalone bash hook scripts that block tool calls violating those rules.

Usage:
    enforce-hooks.py [CLAUDE.md path] [options]
    enforce-hooks.py --scan                    # scan and show what's enforceable
    enforce-hooks.py --generate                # generate hook scripts to stdout
    enforce-hooks.py --install                 # generate and install hooks
    enforce-hooks.py --test                    # run self-tests

Zero dependencies beyond Python 3.6+ stdlib.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path


# --- Directive Classification ---

class Directive:
    """A single enforceable directive from CLAUDE.md."""
    __slots__ = ('text', 'hook_type', 'patterns', 'description', 'line_num')

    def __init__(self, text, hook_type, patterns, description, line_num=0):
        self.text = text
        self.hook_type = hook_type
        self.patterns = patterns
        self.description = description
        self.line_num = line_num

    def to_dict(self):
        return {
            'text': self.text,
            'hook_type': self.hook_type,
            'patterns': self.patterns,
            'description': self.description,
            'line_num': self.line_num,
        }


# Patterns that indicate file protection directives
FILE_GUARD_PATTERNS = [
    # "Never modify/edit/write/touch/change/read .env files"
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid|prohibited?)\s+'
        r'(?:modify|edit|write\s+to|touch|change|alter|update|overwrite|delete|remove|read)\s+'
        r'(?:files?\s+in\s+)?(.+)',
        re.IGNORECASE
    ),
    # "Protected files: .env, secrets/"
    re.compile(
        r'(?:protected?\s+files?|read[- ]only\s+files?|immutable\s+files?)\s*[:=]\s*(.+)',
        re.IGNORECASE
    ),
    # ".env files are protected"
    re.compile(
        r'(\S+(?:\s+\S+)?)\s+(?:files?\s+)?(?:are|is)\s+(?:protected|read[- ]only|immutable|off[- ]limits)',
        re.IGNORECASE
    ),
]

# Patterns for bash command blocking
BASH_GUARD_PATTERNS = [
    # "Never run/execute/use rm -rf"
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid|prohibited?)\s+'
        r'(?:run|execute|use|call|invoke)\s+'
        r'(.+)',
        re.IGNORECASE
    ),
    # "Blocked commands: rm -rf, sudo"
    re.compile(
        r'(?:blocked?|banned?|forbidden|prohibited?|dangerous)\s+commands?\s*[:=]\s*(.+)',
        re.IGNORECASE
    ),
    # "Don't force push" / "Never reset --hard" / "Do not checkout ."
    # (git operations without run/execute verb)
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid|prohibited?)\s+'
        r'(force\s+push\b.*|push\s+--?force\b.*|reset\s+--hard\b.*|'
        r'clean\s+-f\b.*|checkout\s+\.\s*$|restore\s+\.\s*$)',
        re.IGNORECASE
    ),
]

# Patterns for command substitution ("Use pnpm instead of npm", "Use yarn not npm")
PREFER_COMMAND_PATTERNS = [
    re.compile(
        r'(?:use|prefer)\s+(\w+)\s+(?:instead\s+of|over|not|rather\s+than)\s+(\w+)',
        re.IGNORECASE
    ),
]

# Patterns for branch protection
BRANCH_GUARD_PATTERNS = [
    # "Never commit/push/merge to main" or "Don't commit directly to main or production"
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:commit|push|merge|deploy)\s+'
        r'(?:\w+\s+)?'  # optional adverb: "directly", "ever", etc.
        r'(?:to|on|into)\s+'
        r'(.+)',
        re.IGNORECASE
    ),
    # "Protected branches: main, production"
    re.compile(
        r'(?:protected?\s+branch(?:es)?)\s*[:=]\s*(.+)',
        re.IGNORECASE
    ),
]

# Patterns for requiring a tool before another
REQUIRE_PRIOR_PATTERNS = [
    # "Always run tests before committing"
    re.compile(
        r'(?:always|must)\s+'
        r'(?:run|execute|use)\s+'
        r'(\S+(?:\s+\S+)?)\s+'
        r'before\s+'
        r'(\S+)',
        re.IGNORECASE
    ),
    # "Search locally before using web search" / "Always search locally before web search"
    re.compile(
        r'(?:always\s+)?(?:search|check|look)\s+(?:locally|the\s+codebase|existing\s+code)\s+'
        r'before\s+(?:using?\s+)?(.+)',
        re.IGNORECASE
    ),
]

# Patterns for tool blocking
TOOL_BLOCK_PATTERNS = [
    # "Never use WebSearch/WebFetch" / "Don't use the Agent tool"
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:us(?:e|ing)|call(?:ing)?|invok(?:e|ing))\s+'
        r'(?:the\s+)?'
        r'((?:Web(?:Search|Fetch)|NotebookEdit|Agent|Bash)(?:\s*(?:[,/&+]|or|and)\s*(?:Web(?:Search|Fetch)|NotebookEdit|Agent|Bash))*)',
        re.IGNORECASE
    ),
]


def extract_file_patterns(text):
    """Extract file patterns from directive text."""
    patterns = []
    # Match quoted strings
    for m in re.finditer(r'["`\']([\w.*/_-]+)["`\']', text):
        patterns.append(m.group(1))
    # Match common file patterns without quotes
    # Use (?:^|\W) instead of \b since dot-prefixed names don't have word boundary before them
    for m in re.finditer(r'(?:^|\W)(\.env\b|\.env\.\w+|secrets?/|\.pem\b|\.key\b|\.p12\b|\.pfx\b|credentials?\.\w+|vendor/|node_modules/|\*\.\w{1,5})', text):
        patterns.append(m.group(1))
    # Match common bare filenames (Makefile, Dockerfile, Gemfile, etc.)
    for m in re.finditer(r'\b(Makefile|Dockerfile|Gemfile|Rakefile|Procfile|Vagrantfile|Brewfile|Guardfile|Thorfile|Berksfile|Capfile|Podfile|Fastfile|Dangerfile|CLAUDE\.md|README\.md|LICENSE|CHANGELOG\.md|package\.json|tsconfig\.json|Cargo\.toml|go\.mod|\.gitignore|\.dockerignore)\b', text):
        if m.group(1) not in patterns:
            patterns.append(m.group(1))
    # Match paths with slashes
    for m in re.finditer(r'\b(\w+/\w+(?:/\w+)*/?)\b', text):
        candidate = m.group(1)
        if candidate not in patterns and not candidate.startswith('http'):
            patterns.append(candidate)
    # Strip leading * from glob patterns (bash check already wraps in *...*)
    cleaned = []
    for p in patterns:
        if p.startswith('*.'):
            p = p[1:]  # "*.pem" -> ".pem" (bash glob already wraps)
        cleaned.append(p)
    return list(dict.fromkeys(cleaned))  # dedupe preserving order


def extract_command_patterns(text):
    """Extract command patterns from directive text."""
    patterns = []
    # Match backtick-quoted commands
    for m in re.finditer(r'`([^`]+)`', text):
        patterns.append(m.group(1))
    # Match common dangerous commands mentioned without backticks
    dangerous = [
        'rm -rf', 'rm -r', 'sudo', 'chmod 777', 'push --force', 'push -f',
        'force push', 'reset --hard', 'clean -fd', 'clean -f',
        'checkout .', 'restore .',
        'curl | sh', 'curl | bash', 'wget | sh',
    ]
    lower = text.lower()
    for cmd in dangerous:
        if cmd in lower and cmd not in patterns:
            patterns.append(cmd)
    # Expand aliases: "force push" should also match "push --force" and "push -f"
    aliases = {
        'force push': ['push --force', 'push -f'],
        'push --force': ['force push', 'push -f'],
        'push -f': ['force push', 'push --force'],
    }
    expanded = list(patterns)
    for pat in patterns:
        for alias in aliases.get(pat, []):
            if alias not in expanded:
                expanded.append(alias)
    return expanded


def extract_branch_names(text):
    """Extract branch names from directive text."""
    branches = []
    # Common branch names
    for m in re.finditer(r'\b(main|master|production|prod|release|staging|develop)\b', text, re.IGNORECASE):
        b = m.group(1).lower()
        if b not in branches:
            branches.append(b)
    # Quoted branch names
    for m in re.finditer(r'["`\']([\w./-]+)["`\']', text):
        b = m.group(1)
        if b not in branches:
            branches.append(b)
    return branches


def classify_directive(line, line_num):
    """Classify a single line as an enforceable directive or None."""
    stripped = line.strip()
    if not stripped or stripped.startswith('#') and not stripped.startswith('##'):
        return None

    # Remove markdown list markers
    clean = re.sub(r'^[-*]\s+', '', stripped)
    clean = re.sub(r'^\d+\.\s+', '', clean)
    # Remove @enforced tag but remember it was there
    has_enforced = '@enforced' in clean
    clean = clean.replace('@enforced', '').strip()

    if not clean or len(clean) < 10:
        return None

    # Try file-guard patterns
    for pattern in FILE_GUARD_PATTERNS:
        m = pattern.search(clean)
        if m:
            file_pats = extract_file_patterns(m.group(1))
            if file_pats:
                return Directive(
                    text=stripped,
                    hook_type='file-guard',
                    patterns=file_pats,
                    description=f"Block Write/Edit to: {', '.join(file_pats)}",
                    line_num=line_num,
                )

    # Try branch-guard patterns (before bash-guard, since "commit to main" matches both)
    for pattern in BRANCH_GUARD_PATTERNS:
        m = pattern.search(clean)
        if m:
            branches = extract_branch_names(m.group(1))
            if branches:
                return Directive(
                    text=stripped,
                    hook_type='branch-guard',
                    patterns=branches,
                    description=f"Block commits to: {', '.join(branches)}",
                    line_num=line_num,
                )

    # Try tool-block patterns (before bash-guard, since "don't use WebSearch" matches both)
    for pattern in TOOL_BLOCK_PATTERNS:
        m = pattern.search(clean)
        if m:
            tools = [t.strip() for t in re.split(r'[,/\s]+', m.group(1))
                    if t.strip() and t.strip().lower() not in ('or', 'and', 'the', 'tool', 'tools')]
            if tools:
                return Directive(
                    text=stripped,
                    hook_type='tool-block',
                    patterns=tools,
                    description=f"Block tools: {', '.join(tools)}",
                    line_num=line_num,
                )

    # Try bash-guard patterns
    for pattern in BASH_GUARD_PATTERNS:
        m = pattern.search(clean)
        if m:
            cmd_pats = extract_command_patterns(m.group(1))
            if cmd_pats:
                return Directive(
                    text=stripped,
                    hook_type='bash-guard',
                    patterns=cmd_pats,
                    description=f"Block commands: {', '.join(cmd_pats)}",
                    line_num=line_num,
                )

    # Try prefer-command patterns ("Use pnpm instead of npm")
    for pattern in PREFER_COMMAND_PATTERNS:
        m = pattern.search(clean)
        if m:
            preferred, blocked = m.group(1), m.group(2)
            return Directive(
                text=stripped,
                hook_type='bash-guard',
                patterns=[blocked],
                description=f"Block commands: {blocked} (use {preferred} instead)",
                line_num=line_num,
            )

    # Try require-prior-tool patterns
    for pattern in REQUIRE_PRIOR_PATTERNS:
        m = pattern.search(clean)
        if m:
            groups = m.groups()
            if len(groups) >= 2:
                return Directive(
                    text=stripped,
                    hook_type='require-prior-tool',
                    patterns=list(groups),
                    description=f"Require {groups[0]} before {groups[1]}",
                    line_num=line_num,
                )
            elif len(groups) == 1:
                # Single-group: "search locally before web search" -> Grep before WebSearch
                target = groups[0].strip()
                return Directive(
                    text=stripped,
                    hook_type='require-prior-tool',
                    patterns=['Grep', target],
                    description=f"Require Grep before {target}",
                    line_num=line_num,
                )

    # @enforced tag on an unclassified line - try harder
    if has_enforced:
        # Check for file patterns
        file_pats = extract_file_patterns(clean)
        if file_pats:
            return Directive(
                text=stripped,
                hook_type='file-guard',
                patterns=file_pats,
                description=f"Block Write/Edit to: {', '.join(file_pats)}",
                line_num=line_num,
            )
        # Check for command patterns
        cmd_pats = extract_command_patterns(clean)
        if cmd_pats:
            return Directive(
                text=stripped,
                hook_type='bash-guard',
                patterns=cmd_pats,
                description=f"Block commands: {', '.join(cmd_pats)}",
                line_num=line_num,
            )

    return None


def scan_file(path):
    """Scan a CLAUDE.md file and return (enforceable, skipped) directives."""
    content = Path(path).read_text()
    lines = content.splitlines()
    enforceable = []
    skipped = []

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped:
            continue
        # Skip pure headers, code blocks, and very short lines
        if stripped.startswith('```'):
            continue
        if stripped.startswith('# ') and len(stripped) < 50:
            continue

        directive = classify_directive(line, i)
        if directive:
            enforceable.append(directive)
        elif '@enforced' in line:
            skipped.append((i, stripped, 'Could not classify'))

    return enforceable, skipped


# --- Hook Generation ---

FILE_GUARD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in {tool_case}) ;; *) exit 0 ;; esac
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
{checks}
exit 0
'''

BASH_GUARD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
{checks}
exit 0
'''

BRANCH_GUARD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
{checks}
exit 0
'''

TOOL_BLOCK_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
{checks}
exit 0
'''

REQUIRE_PRIOR_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
# NOTE: Requires session-log hook to be installed for tracking.
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in {target_tools}) ;; *) exit 0 ;; esac
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '"tool":"{required_tool}"' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo '{{"decision": "block", "reason": "Run {required_tool} first. (CLAUDE.md: {short})"}}'
exit 0
'''


def generate_file_guard_checks(patterns, short_directive):
    """Generate bash checks for file-guard patterns."""
    lines = []
    for pat in patterns:
        escaped = pat.replace('"', '\\"')
        short = short_directive.replace('"', '\\"')
        lines.append(
            f'[[ "$FILE" == *"{escaped}"* ]] && '
            f'echo \'{{"decision": "block", "reason": "Protected: $FILE matches {escaped}. (CLAUDE.md: {short})"}}\' && exit 0'
        )
    return '\n'.join(lines)


def generate_bash_guard_checks(patterns, short_directive):
    """Generate bash checks for bash-guard patterns."""
    lines = []
    for pat in patterns:
        escaped = pat.replace('"', '\\"').replace("'", "'\\''")
        short = short_directive.replace('"', '\\"').replace("'", "'\\''")
        lines.append(
            f'[[ "$CMD" == *"{escaped}"* ]] && '
            f'echo \'{{"decision": "block", "reason": "Blocked: {escaped}. (CLAUDE.md: {short})"}}\' && exit 0'
        )
    return '\n'.join(lines)


def generate_branch_guard_checks(branches, short_directive):
    """Generate bash checks for branch-guard patterns."""
    lines = []
    for branch in branches:
        short = short_directive.replace('"', '\\"')
        lines.append(f'''if [ "$BRANCH" = "{branch}" ]; then
  case "$CMD" in
    *"git commit"*|*"git merge"*|*"git push"*)
      echo '{{"decision": "block", "reason": "Branch {branch} is protected. (CLAUDE.md: {short})"}}'
      exit 0 ;;
  esac
fi''')
    return '\n'.join(lines)


def generate_tool_block_checks(tools, short_directive):
    """Generate bash checks for tool-block patterns."""
    lines = []
    for tool in tools:
        short = short_directive.replace('"', '\\"').replace("'", "'\\''")
        lines.append(
            f'[ "$TOOL" = "{tool}" ] && '
            f'echo \'{{"decision": "block", "reason": "Tool {tool} is blocked. (CLAUDE.md: {short})"}}\' && exit 0'
        )
    return '\n'.join(lines)


def generate_hook(directive):
    """Generate a hook script for a directive."""
    short = directive.text[:80].replace('@enforced', '').strip()

    if directive.hook_type == 'file-guard':
        checks = generate_file_guard_checks(directive.patterns, short)
        # Include Read tool if directive mentions reading
        text_lower = directive.text.lower()
        if any(w in text_lower for w in ['read', 'access', 'view', 'open', 'look at']):
            tool_case = 'Write|Edit|MultiEdit|Read'
        else:
            tool_case = 'Write|Edit|MultiEdit'
        return FILE_GUARD_TEMPLATE.format(directive=short, checks=checks, tool_case=tool_case)

    elif directive.hook_type == 'bash-guard':
        checks = generate_bash_guard_checks(directive.patterns, short)
        return BASH_GUARD_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'branch-guard':
        checks = generate_branch_guard_checks(directive.patterns, short)
        return BRANCH_GUARD_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'tool-block':
        checks = generate_tool_block_checks(directive.patterns, short)
        return TOOL_BLOCK_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'require-prior-tool':
        if len(directive.patterns) >= 2:
            required = directive.patterns[0]
            target = directive.patterns[1]
            # Map common terms to tool names
            tool_map = {
                'tests': 'Bash',
                'test': 'Bash',
                'lint': 'Bash',
                'search': 'Grep',
                'grep': 'Grep',
                'web search': 'WebSearch',
                'websearch': 'WebSearch',
            }
            target_tool = tool_map.get(target.lower(), 'Bash')
            return REQUIRE_PRIOR_TEMPLATE.format(
                directive=short,
                target_tools=target_tool,
                required_tool=required,
                short=short[:60],
            )

    return None


def hook_filename(directive, index, seen=None):
    """Generate a unique filename for a hook script."""
    type_prefix = directive.hook_type.replace('-', '_')
    # Create a short slug from the first pattern
    slug = directive.patterns[0] if directive.patterns else 'rule'
    slug = re.sub(r'[^a-zA-Z0-9]', '_', slug)[:20].strip('_').lower()
    base = f"enforce_{type_prefix}_{slug}"
    name = f"{base}.sh"
    # Deduplicate if seen set provided
    if seen is not None:
        counter = 2
        while name in seen:
            name = f"{base}_{counter}.sh"
            counter += 1
        seen.add(name)
    return name


# --- Installation ---

def install_hooks(directives, hooks_dir, settings_path):
    """Write hook scripts and update settings.json."""
    hooks_dir = Path(hooks_dir)
    hooks_dir.mkdir(parents=True, exist_ok=True)

    written = []
    seen_names = set()
    for i, directive in enumerate(directives):
        script = generate_hook(directive)
        if not script:
            continue
        filename = hook_filename(directive, i, seen_names)
        path = hooks_dir / filename
        path.write_text(script)
        path.chmod(0o755)
        written.append(str(path))

    # Update settings.json
    settings_path = Path(settings_path)
    settings = {}
    if settings_path.exists():
        try:
            settings = json.loads(settings_path.read_text())
        except json.JSONDecodeError:
            pass

    hooks_config = settings.setdefault('hooks', {})
    pre_tool = hooks_config.setdefault('PreToolUse', [])

    # Find or create the catch-all matcher entry
    catch_all = None
    for entry in pre_tool:
        if entry.get('matcher', '') == '':
            catch_all = entry
            break

    if not catch_all:
        catch_all = {'matcher': '', 'hooks': []}
        pre_tool.append(catch_all)

    existing_commands = {h.get('command', '') for h in catch_all.get('hooks', [])}

    for path in written:
        rel_path = str(path)
        if rel_path not in existing_commands:
            catch_all['hooks'].append({'type': 'command', 'command': rel_path})

    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2) + '\n')

    return written


# --- Output Formatting ---

def format_scan_table(enforceable, skipped):
    """Format scan results as a readable table."""
    lines = []
    if enforceable:
        lines.append(f"Found {len(enforceable)} enforceable directive(s):\n")
        lines.append(f"{'#':>3}  {'Type':<20}  {'What it blocks':<40}  {'Source line'}")
        lines.append(f"{'---':>3}  {'----':<20}  {'---':<40}  {'---'}")
        for i, d in enumerate(enforceable, 1):
            lines.append(f"{i:>3}  {d.hook_type:<20}  {d.description:<40}  L{d.line_num}")
    else:
        lines.append("No enforceable directives found.")

    if skipped:
        lines.append(f"\nSkipped {len(skipped)} @enforced directive(s) (could not classify):")
        for line_num, text, reason in skipped:
            lines.append(f"  L{line_num}: {text[:60]}... ({reason})")

    return '\n'.join(lines)


def format_json(enforceable, skipped):
    """Format scan results as JSON."""
    return json.dumps({
        'enforceable': [d.to_dict() for d in enforceable],
        'skipped': [{'line': ln, 'text': t, 'reason': r} for ln, t, r in skipped],
    }, indent=2)


# --- Self Tests ---

def run_tests():
    """Run self-tests."""
    passed = 0
    failed = 0

    def check(name, result, expected):
        nonlocal passed, failed
        if result == expected:
            passed += 1
        else:
            failed += 1
            print(f"  FAIL: {name}")
            print(f"    expected: {expected}")
            print(f"    got:      {result}")

    # Test file-guard detection
    d = classify_directive("Never modify .env files", 1)
    check("file-guard basic", d is not None and d.hook_type == 'file-guard', True)
    check("file-guard pattern", d is not None and '.env' in d.patterns, True)

    d = classify_directive("Don't edit secrets/ directory", 2)
    check("file-guard secrets", d is not None and d.hook_type == 'file-guard', True)

    d = classify_directive("Protected files: `.env`, `secrets/`, `*.pem`", 3)
    check("file-guard list", d is not None and d.hook_type == 'file-guard', True)
    check("file-guard list count", d is not None and len(d.patterns) == 3, True)

    d = classify_directive("Do not touch credentials.json", 4)
    check("file-guard credentials", d is not None and d.hook_type == 'file-guard', True)

    # Test bash-guard detection
    d = classify_directive("Never run `rm -rf /`", 5)
    check("bash-guard rm", d is not None and d.hook_type == 'bash-guard', True)

    d = classify_directive("Don't execute sudo commands", 6)
    check("bash-guard sudo", d is not None and d.hook_type == 'bash-guard', True)

    d = classify_directive("Blocked commands: `rm -rf`, `sudo`, `push --force`", 7)
    check("bash-guard list", d is not None and d.hook_type == 'bash-guard', True)
    check("bash-guard list count", d is not None and len(d.patterns) >= 2, True)

    # Test branch-guard detection
    d = classify_directive("Never commit to main", 8)
    check("branch-guard basic", d is not None and d.hook_type == 'branch-guard', True)
    check("branch-guard pattern", d is not None and 'main' in d.patterns, True)

    d = classify_directive("Don't push to production or staging", 9)
    check("branch-guard multi", d is not None and d.hook_type == 'branch-guard', True)
    check("branch-guard has production", d is not None and 'production' in d.patterns, True)
    check("branch-guard has staging", d is not None and 'staging' in d.patterns, True)

    d = classify_directive("Don't commit to main or production", 20)
    check("branch-guard or", d is not None and d.hook_type == 'branch-guard', True)
    check("branch-guard or main", d is not None and 'main' in d.patterns, True)
    check("branch-guard or production", d is not None and 'production' in d.patterns, True)

    d = classify_directive("Protected branches: main, release", 10)
    check("branch-guard list", d is not None and d.hook_type == 'branch-guard', True)

    # Test require-prior-tool detection
    d = classify_directive("Always run tests before committing", 11)
    check("require-prior basic", d is not None and d.hook_type == 'require-prior-tool', True)

    # Test non-enforceable directives
    d = classify_directive("Write clean code", 12)
    check("skip subjective", d is None, True)

    d = classify_directive("Use descriptive variable names", 13)
    check("skip variable names", d is None, True)

    d = classify_directive("Follow REST conventions", 14)
    check("skip conventions", d is None, True)

    d = classify_directive("Be concise in responses", 15)
    check("skip concise", d is None, True)

    d = classify_directive("", 16)
    check("skip empty", d is None, True)

    d = classify_directive("# Header", 17)
    check("skip header", d is None, True)

    # Test hook generation
    d = Directive(
        text="Never modify .env files",
        hook_type='file-guard',
        patterns=['.env'],
        description="Block Write/Edit to: .env",
        line_num=1,
    )
    hook = generate_hook(d)
    check("hook gen file-guard", hook is not None, True)
    check("hook has jq", hook is not None and 'jq' in hook, True)
    check("hook has block", hook is not None and '"block"' in hook, True)

    d = Directive(
        text="Never run rm -rf",
        hook_type='bash-guard',
        patterns=['rm -rf'],
        description="Block commands: rm -rf",
        line_num=2,
    )
    hook = generate_hook(d)
    check("hook gen bash-guard", hook is not None, True)
    check("hook bash tool check", hook is not None and 'Bash' in hook, True)

    d = Directive(
        text="Never commit to main",
        hook_type='branch-guard',
        patterns=['main'],
        description="Block commits to: main",
        line_num=3,
    )
    hook = generate_hook(d)
    check("hook gen branch-guard", hook is not None, True)
    check("hook branch check", hook is not None and 'BRANCH' in hook, True)

    # Test extract functions
    pats = extract_file_patterns('".env", "secrets/", "*.pem"')
    check("extract file patterns", len(pats) >= 3, True)

    pats = extract_command_patterns('`rm -rf /` and `sudo rm`')
    check("extract cmd patterns backtick", len(pats) >= 1, True)

    pats = extract_command_patterns('push --force or push -f')
    check("extract cmd push force", 'push --force' in pats, True)

    branches = extract_branch_names('main, production, staging')
    check("extract branches", len(branches) == 3, True)

    # Test *.pem cleanup
    pats = extract_file_patterns('`*.pem` files')
    check("pem glob stripped", '.pem' in pats, True)
    check("pem no star", '*.pem' not in pats, True)

    # Test filename deduplication
    seen = set()
    d1 = Directive("test1", "file-guard", [".env"], "test", 1)
    d2 = Directive("test2", "file-guard", [".env"], "test", 2)
    fn1 = hook_filename(d1, 0, seen)
    fn2 = hook_filename(d2, 1, seen)
    check("filename dedup different", fn1 != fn2, True)
    check("filename dedup has suffix", '_2' in fn2, True)

    # Test hook filename generation
    d = Directive("test", "file-guard", [".env"], "test", 1)
    fn = hook_filename(d, 0)
    check("filename format", fn.startswith("enforce_file_guard_"), True)
    check("filename ends sh", fn.endswith(".sh"), True)

    # Test scan on a sample CLAUDE.md
    import tempfile
    sample = """# Project Rules

## Safety
- Never modify .env files @enforced
- Don't run `rm -rf` on anything @enforced
- Never commit to main @enforced
- Always run tests before committing @enforced

## Style
- Write clean code
- Use descriptive variable names
- Follow REST conventions
"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write(sample)
        f.flush()
        enforceable, skipped = scan_file(f.name)
        check("scan sample count", len(enforceable) >= 3, True)
        types = {d.hook_type for d in enforceable}
        check("scan has file-guard", 'file-guard' in types, True)
        check("scan has bash-guard", 'bash-guard' in types, True)
        check("scan has branch-guard", 'branch-guard' in types, True)
        os.unlink(f.name)

    # Test install
    with tempfile.TemporaryDirectory() as tmpdir:
        hooks_dir = os.path.join(tmpdir, '.claude', 'hooks')
        settings_path = os.path.join(tmpdir, '.claude', 'settings.json')
        test_directives = [
            Directive("Never modify .env", "file-guard", [".env"], "test", 1),
            Directive("Never run sudo", "bash-guard", ["sudo"], "test", 2),
        ]
        written = install_hooks(test_directives, hooks_dir, settings_path)
        check("install wrote files", len(written) == 2, True)
        check("install files exist", all(os.path.exists(w) for w in written), True)
        check("install settings exists", os.path.exists(settings_path), True)

        settings = json.loads(Path(settings_path).read_text())
        check("install has hooks key", 'hooks' in settings, True)
        check("install has PreToolUse", 'PreToolUse' in settings.get('hooks', {}), True)

        # Test idempotent install (should not duplicate)
        written2 = install_hooks(test_directives, hooks_dir, settings_path)
        settings2 = json.loads(Path(settings_path).read_text())
        hook_count = len(settings2['hooks']['PreToolUse'][0]['hooks'])
        check("install idempotent", hook_count == 2, True)

    # Test force-push detection (new: git operation without run/execute verb)
    d = classify_directive("Do not force push to any branch", 21)
    check("force-push detect", d is not None and d.hook_type == 'bash-guard', True)
    check("force-push patterns", d is not None and 'force push' in d.patterns, True)
    check("force-push alias push --force", d is not None and 'push --force' in d.patterns, True)
    check("force-push alias push -f", d is not None and 'push -f' in d.patterns, True)

    d = classify_directive("Never reset --hard", 22)
    check("reset-hard detect", d is not None and d.hook_type == 'bash-guard', True)
    check("reset-hard pattern", d is not None and 'reset --hard' in d.patterns, True)

    # Test branch-guard with adverb ("directly")
    d = classify_directive("Never commit directly to main or production", 23)
    check("branch-guard adverb", d is not None and d.hook_type == 'branch-guard', True)
    check("branch-guard adverb main", d is not None and 'main' in d.patterns, True)
    check("branch-guard adverb production", d is not None and 'production' in d.patterns, True)

    # Test bare filename detection
    d = classify_directive("Don't edit the Makefile", 24)
    check("file-guard makefile", d is not None and d.hook_type == 'file-guard', True)
    check("file-guard makefile pattern", d is not None and 'Makefile' in d.patterns, True)

    d = classify_directive("Never modify Dockerfile", 25)
    check("file-guard dockerfile", d is not None and d.hook_type == 'file-guard', True)

    d = classify_directive("Don't edit package.json", 26)
    check("file-guard package.json", d is not None and d.hook_type == 'file-guard', True)

    # Test tool-block detection
    d = classify_directive("Don't use WebSearch", 27)
    check("tool-block websearch", d is not None and d.hook_type == 'tool-block', True)
    check("tool-block websearch pattern", d is not None and 'WebSearch' in d.patterns, True)

    d = classify_directive("Never use WebFetch", 28)
    check("tool-block webfetch", d is not None and d.hook_type == 'tool-block', True)

    d = classify_directive("Avoid using Agent", 29)
    check("tool-block agent", d is not None and d.hook_type == 'tool-block', True)

    # Test tool-block hook generation
    d = Directive("Don't use WebSearch", "tool-block", ["WebSearch"], "Block tools: WebSearch", 1)
    hook = generate_hook(d)
    check("hook gen tool-block", hook is not None, True)
    check("hook tool-block has tool name", hook is not None and 'WebSearch' in hook, True)
    check("hook tool-block has block", hook is not None and '"block"' in hook, True)

    # Test force-push alias expansion
    pats = extract_command_patterns('force push is not allowed')
    check("extract force push", 'force push' in pats, True)
    check("extract force push alias", 'push --force' in pats, True)
    check("extract force push alias -f", 'push -f' in pats, True)

    # Test executable permission
    with tempfile.TemporaryDirectory() as tmpdir:
        hooks_dir = os.path.join(tmpdir, 'hooks')
        settings_path = os.path.join(tmpdir, 'settings.json')
        written = install_hooks(
            [Directive("Never modify .env", "file-guard", [".env"], "test", 1)],
            hooks_dir, settings_path
        )
        if written:
            check("install executable", os.access(written[0], os.X_OK), True)

    # Test "read" verb in file-guard includes Read tool
    d = classify_directive("Don't read files in secrets/", 100)
    check("file-guard read verb", d is not None and d.hook_type == 'file-guard', True)
    check("file-guard read secrets", d is not None and 'secrets/' in d.patterns, True)
    if d:
        hook = generate_hook(d)
        check("file-guard read includes Read tool", 'Read)' in hook, True)

    d = classify_directive("Never modify .env files", 101)
    if d:
        hook = generate_hook(d)
        check("file-guard write excludes Read tool", 'Read)' not in hook, True)

    # Test prefer-command pattern ("Use X instead of Y")
    d = classify_directive("Use pnpm instead of npm", 102)
    check("prefer-command detected", d is not None and d.hook_type == 'bash-guard', True)
    check("prefer-command blocks npm", d is not None and 'npm' in d.patterns, True)

    d = classify_directive("Prefer yarn over npm", 103)
    check("prefer-over detected", d is not None and d.hook_type == 'bash-guard', True)
    check("prefer-over blocks npm", d is not None and 'npm' in d.patterns, True)

    d = classify_directive("Use bun not npm", 104)
    check("prefer-not detected", d is not None and d.hook_type == 'bash-guard', True)

    d = classify_directive("Use poetry rather than pip", 105)
    check("prefer-rather-than detected", d is not None and d.hook_type == 'bash-guard', True)
    check("prefer-rather-than blocks pip", d is not None and 'pip' in d.patterns, True)

    # Test "Always search locally before web search"
    d = classify_directive("Always search locally before using web search", 106)
    check("search-locally detected", d is not None and d.hook_type == 'require-prior-tool', True)
    check("search-locally has Grep", d is not None and 'Grep' in d.patterns, True)

    d = classify_directive("Check the codebase before using web search", 107)
    check("check-codebase detected", d is not None and d.hook_type == 'require-prior-tool', True)

    # Test tool-block doesn't include trailing "tool" word
    d = classify_directive("Don't use WebSearch tool", 108)
    check("tool-block no trailing tool", d is not None and d.hook_type == 'tool-block', True)
    check("tool-block clean list", d is not None and d.patterns == ['WebSearch'], True)

    d = classify_directive("Never use WebSearch", 109)
    check("tool-block simple", d is not None and d.hook_type == 'tool-block', True)
    check("tool-block simple list", d is not None and d.patterns == ['WebSearch'], True)

    d = classify_directive("Don't use WebSearch or WebFetch", 110)
    check("tool-block multi detect", d is not None and d.hook_type == 'tool-block', True)
    check("tool-block multi has both", d is not None and 'WebSearch' in d.patterns and 'WebFetch' in d.patterns, True)

    d = classify_directive("Never use WebSearch and WebFetch", 112)
    check("tool-block and separator", d is not None and d.patterns == ['WebSearch', 'WebFetch'], True)

    # Test prefer-language as file-guard edge case
    d = classify_directive("Prefer TypeScript over JavaScript for new files", 111)
    check("prefer-language detected", d is not None, True)

    print(f"\n{passed} passed, {failed} failed")
    return failed == 0


# --- Main ---

def find_claude_md():
    """Find CLAUDE.md in current directory or parent directories."""
    cwd = Path.cwd()
    for parent in [cwd] + list(cwd.parents):
        candidate = parent / 'CLAUDE.md'
        if candidate.exists():
            return str(candidate)
        # Also check .claude/CLAUDE.md
        candidate = parent / '.claude' / 'CLAUDE.md'
        if candidate.exists():
            return str(candidate)
    return None


def main():
    parser = argparse.ArgumentParser(
        description='Generate PreToolUse hook scripts from CLAUDE.md directives.',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog='''Examples:
  %(prog)s --scan                     Show enforceable directives
  %(prog)s --scan --json              Show as JSON
  %(prog)s --generate                 Print hook scripts to stdout
  %(prog)s --install                  Write hooks to .claude/hooks/
  %(prog)s --install path/CLAUDE.md   Use a specific CLAUDE.md
  %(prog)s --test                     Run self-tests
''',
    )
    parser.add_argument('file', nargs='?', help='Path to CLAUDE.md (auto-detected if omitted)')
    parser.add_argument('--scan', action='store_true', help='Scan and show enforceable directives')
    parser.add_argument('--generate', action='store_true', help='Generate hook scripts to stdout')
    parser.add_argument('--install', action='store_true', help='Generate and install hooks')
    parser.add_argument('--json', action='store_true', help='Output as JSON (with --scan)')
    parser.add_argument('--hooks-dir', default='.claude/hooks', help='Directory for hook scripts')
    parser.add_argument('--settings', default='.claude/settings.json', help='Path to settings.json')
    parser.add_argument('--test', action='store_true', help='Run self-tests')
    args = parser.parse_args()

    if args.test:
        success = run_tests()
        sys.exit(0 if success else 1)

    if not any([args.scan, args.generate, args.install]):
        args.scan = True  # Default to scan

    path = args.file or find_claude_md()
    if not path:
        print("Error: No CLAUDE.md found. Specify a path or run from a project directory.", file=sys.stderr)
        sys.exit(1)

    if not os.path.exists(path):
        print(f"Error: File not found: {path}", file=sys.stderr)
        sys.exit(1)

    enforceable, skipped = scan_file(path)

    if args.scan:
        if args.json:
            print(format_json(enforceable, skipped))
        else:
            print(f"Scanning: {path}\n")
            print(format_scan_table(enforceable, skipped))
        return

    if args.generate:
        seen_names = set()
        for i, d in enumerate(enforceable):
            script = generate_hook(d)
            if script:
                filename = hook_filename(d, i, seen_names)
                print(f"# === {filename} ===")
                print(script)
        return

    if args.install:
        if not enforceable:
            print("No enforceable directives found. Nothing to install.")
            return
        print(f"Installing {len(enforceable)} hook(s) to {args.hooks_dir}/...")
        written = install_hooks(enforceable, args.hooks_dir, args.settings)
        print(f"\nWrote {len(written)} hook script(s):")
        for w in written:
            print(f"  {w}")
        print(f"\nUpdated: {args.settings}")
        print("\nTo verify, try triggering a blocked action in Claude Code.")


if __name__ == '__main__':
    main()
