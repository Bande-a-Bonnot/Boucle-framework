#!/usr/bin/env bash
# enforce-engine: PreToolUse hook that enforces @enforced CLAUDE.md directives.
#
# Does NOT generate code. Reads declarative rule objects from
# .claude/enforcements/*.json and evaluates them against each tool call.
#
# Rule object schema:
# {
#   "name": "Rule Name",
#   "directive": "Original text from CLAUDE.md",
#   "trigger": { "tool": "WebSearch|WebFetch" },
#   "condition": { "type": "require_prior_tool", "tool": "Grep", "args_pattern": "docs/" },
#   "action": "block",
#   "message": "Search docs/ before using WebSearch"
# }
#
# Condition types:
#   require_prior_tool  — block unless a specific tool was used earlier in the session
#   block_tool          — always block this tool
#   require_args        — block unless tool args match a pattern
#   block_args          — block if tool args match a pattern (e.g., block force-push)
#   block_file_pattern  — block if file path matches a glob pattern
#   content_guard       — block if written/edited content matches a pattern (e.g., console.log)
#   scoped_content_guard — block if content matches a pattern AND file path matches a scope

set -euo pipefail

# Find enforcement rules directory (project-scoped)
# Walk up from cwd to find .claude/enforcements/
find_enforcements_dir() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        if [ -d "$dir/.claude/enforcements" ]; then
            echo "$dir/.claude/enforcements"
            return 0
        fi
        dir=$(dirname "$dir")
    done
    return 1
}

ENFORCEMENTS_DIR=$(find_enforcements_dir 2>/dev/null) || exit 0

# No rules? Allow everything.
RULE_FILES=$(find "$ENFORCEMENTS_DIR" -name "*.json" -type f 2>/dev/null)
[ -z "$RULE_FILES" ] && exit 0

# Read hook input
INPUT=$(cat)

# Pass all data through environment variables to avoid shell injection.
# TOOL_INPUT may contain quotes, newlines, or other special characters.
export ENFORCE_INPUT="$INPUT"
export ENFORCE_DIR="$ENFORCEMENTS_DIR"
export ENFORCE_SESSION_LOG="$HOME/.claude/session-logs/$(date -u +%Y-%m-%d).jsonl"

# Evaluate each rule (all user data via env vars, never shell interpolation)
python3 -c "
import json, sys, os, re, glob, fnmatch

raw_input = os.environ.get('ENFORCE_INPUT', '{}')
try:
    parsed = json.loads(raw_input)
except (json.JSONDecodeError, ValueError):
    sys.exit(0)

tool_name = parsed.get('tool_name', '')
tool_input = parsed.get('tool_input', {})
if not tool_name:
    sys.exit(0)

session_log = os.environ.get('ENFORCE_SESSION_LOG', '')
enforcements_dir = os.environ.get('ENFORCE_DIR', '')

# Load all rules
rules = []
for f in sorted(glob.glob(os.path.join(enforcements_dir, '*.json'))):
    try:
        with open(f) as fh:
            rule = json.load(fh)
            rules.append(rule)
    except (json.JSONDecodeError, IOError):
        pass

if not rules:
    print(json.dumps({'decision': 'allow'}))
    sys.exit(0)

# Check which rules match this tool
for rule in rules:
    trigger = rule.get('trigger', {})
    trigger_tools = trigger.get('tool', '').split('|')

    # Does this rule apply to the current tool?
    if tool_name not in trigger_tools:
        continue

    condition = rule.get('condition', {})
    cond_type = condition.get('type', '')
    action = rule.get('action', 'block')
    message = rule.get('message', f'Blocked by enforcement rule: {rule.get(\"name\", \"unknown\")}')

    blocked = False

    if cond_type == 'require_prior_tool':
        # Block unless a specific tool was used in this session
        required_tool = condition.get('tool', '')
        args_pattern = condition.get('args_pattern', '')
        found = False

        if os.path.exists(session_log):
            with open(session_log) as f:
                for line in f:
                    try:
                        entry = json.loads(line.strip())
                        if entry.get('tool') == required_tool:
                            if not args_pattern or args_pattern in entry.get('detail', ''):
                                found = True
                                break
                    except json.JSONDecodeError:
                        pass

        if not found:
            blocked = True

    elif cond_type == 'block_tool':
        blocked = True

    elif cond_type == 'block_args':
        pattern = condition.get('pattern', '')
        input_str = json.dumps(tool_input)
        if pattern and re.search(pattern, input_str, re.IGNORECASE):
            blocked = True

    elif cond_type == 'require_args':
        pattern = condition.get('pattern', '')
        input_str = json.dumps(tool_input)
        if pattern and not re.search(pattern, input_str, re.IGNORECASE):
            blocked = True

    elif cond_type == 'block_file_pattern':
        # Check if file_path in tool_input matches a blocked pattern
        file_path = tool_input.get('file_path', tool_input.get('command', ''))
        patterns = condition.get('patterns', [])
        for pat in patterns:
            if fnmatch.fnmatch(file_path, pat):
                blocked = True
                break

    elif cond_type == 'content_guard':
        # Block if written/edited content contains a banned pattern
        # Write has 'content', Edit has 'new_string'
        content = tool_input.get('content', '') or tool_input.get('new_string', '')
        patterns = condition.get('patterns', [])
        for pat in patterns:
            if re.search(pat, content, re.IGNORECASE):
                blocked = True
                break

    elif cond_type == 'scoped_content_guard':
        # Block if content matches a pattern AND file path matches a scope
        file_path = tool_input.get('file_path', '')
        scope = condition.get('scope', '')
        content = tool_input.get('content', '') or tool_input.get('new_string', '')
        patterns = condition.get('patterns', [])
        # Check scope first (file must be in the scoped path)
        in_scope = bool(scope and fnmatch.fnmatch(file_path, scope))
        if in_scope:
            for pat in patterns:
                if re.search(pat, content, re.IGNORECASE):
                    blocked = True
                    break

    if blocked:
        directive = rule.get('directive', '')
        full_message = f'enforce: {message}'
        if directive:
            full_message += f' (CLAUDE.md: \"{directive[:80]}\")'
        if action == 'warn':
            # Warn actions: allow the tool call but inject a visible warning.
            # Bare 'decision:warn' is silently dropped (claude-code#40380).
            # The only reliable way to surface warnings is hookSpecificOutput
            # with permissionDecision:allow and additionalContext.
            print(json.dumps({
                'hookSpecificOutput': {
                    'permissionDecision': 'allow',
                    'additionalContext': full_message
                }
            }))
        else:
            print(json.dumps({'decision': action, 'reason': full_message}))
        sys.exit(0)

# No rules blocked
print(json.dumps({'decision': 'allow'}))
"
