import json

with open('docs/limitations.json') as f:
    data = json.load(f)

new_entry = {
    "id": "model-executes-banned-bash-command-despite-claudemd-prohibition",
    "title": "Model executes a Bash command explicitly banned in CLAUDE.md, causing data loss, despite having the prohibition in active context.",
    "category": "Hook bypass & evasion",
    "severity": "high",
    "issues": [
        "https://github.com/anthropics/claude-code/issues/43833",
        "https://github.com/anthropics/claude-code/issues/40537",
        "https://github.com/anthropics/claude-code/issues/37888"
    ],
    "description": "When CLAUDE.md explicitly bans a Bash command by name (e.g. `sed -i` on Windows Git Bash) and describes the destructive consequence, the model can still choose that command under task pressure. In the reported case, the model used `sed -i` for a bulk text replacement despite a named prohibition with an explicit warning. The model self-caught the violation after execution, confirming the rule was in active context at the time -- this is a reasoning failure, not a context-load failure. On Windows Git Bash, `sed -i` silently empties files rather than editing in-place, wiping 842 lines with no recovery path (no git repo). The broader pattern: CLAUDE.md rules are advisory text injected into context; the model weighs them against task efficiency under pressure and can choose to violate them. Text-based prohibitions are not execution gates.",
    "workaround": "Use a PreToolUse hook that blocks `sed -i` in Bash commands on Windows (e.g. pattern-match on `sed -i` and `exit 2`). Always maintain a git repository even for simple projects -- `git init` provides a recovery path even without a remote. Text-rule prohibitions in CLAUDE.md are not reliable for high-stakes command prevention; `permissions.deny` and hooks with `exit 2` are the only enforcement mechanisms."
}

data['entries'].append(new_entry)
data['count'] = len(data['entries'])
data['categories']['Hook bypass & evasion'] = data['categories'].get('Hook bypass & evasion', 0) + 1

with open('docs/limitations.json', 'w') as f:
    json.dump(data, f, indent=2)

print(f"Done. Total entries: {data['count']}")
print(f"Hook bypass & evasion count: {data['categories']['Hook bypass & evasion']}")
