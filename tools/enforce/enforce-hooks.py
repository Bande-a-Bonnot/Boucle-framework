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
import subprocess
import sys
import tempfile
from pathlib import Path


# --- JSONC Support ---

def strip_jsonc(text):
    """Strip // and /* */ comments from JSONC, respecting quoted strings."""
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        if in_str:
            if text[i] == '\\' and i + 1 < n:
                out.append(text[i:i+2]); i += 2; continue
            if text[i] == '"': in_str = False
            out.append(text[i]); i += 1
        else:
            if text[i] == '"':
                in_str = True; out.append(text[i]); i += 1
            elif i + 1 < n and text[i:i+2] == '//':
                while i < n and text[i] != '\n': i += 1
            elif i + 1 < n and text[i:i+2] == '/*':
                i += 2
                while i + 1 < n and text[i:i+2] != '*/': i += 1
                i += 2
            else:
                out.append(text[i]); i += 1
    return ''.join(out)


def load_settings_json(path):
    """Load settings.json, handling JSONC comments gracefully."""
    path = Path(path)
    if not path.exists():
        return {}
    raw = path.read_text()
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        try:
            result = json.loads(strip_jsonc(raw))
            # Rewrite as clean JSON (backup original)
            import shutil
            shutil.copy2(str(path), str(path) + '.bak')
            path.write_text(json.dumps(result, indent=2) + '\n')
            print(f"  Note: JSONC comments stripped from {path} (backup: {path}.bak)",
                  file=sys.stderr)
            return result
        except json.JSONDecodeError:
            print(f"  Warning: {path} is not valid JSON or JSONC", file=sys.stderr)
            return {}


# --- Directive Classification ---

class Directive:
    """A single enforceable directive from CLAUDE.md."""
    __slots__ = ('text', 'hook_type', 'patterns', 'description', 'line_num',
                 'path_filter', 'path_mode', 'severity')

    def __init__(self, text, hook_type, patterns, description, line_num=0,
                 path_filter=None, path_mode=None, severity='block'):
        self.text = text
        self.hook_type = hook_type
        self.patterns = patterns
        self.description = description
        self.line_num = line_num
        self.path_filter = path_filter  # list of path patterns (e.g. ['types/'])
        self.path_mode = path_mode      # 'only_in' or 'never_in'
        self.severity = severity        # 'block' or 'warn'

    def to_dict(self):
        d = {
            'text': self.text,
            'hook_type': self.hook_type,
            'patterns': self.patterns,
            'description': self.description,
            'line_num': self.line_num,
            'severity': self.severity,
        }
        if self.path_filter:
            d['path_filter'] = self.path_filter
            d['path_mode'] = self.path_mode
        return d


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
    # "Don't push without creating a PR" / "Never push to origin without a pull request"
    re.compile(
        r'(?:never|don\'?t|do\s+not)\s+'
        r'(push\b[^.]*?)\s*\bwithout\s+(?:creating|opening|making|having)\s+'
        r'(?:a\s+)?(?:PR|pull\s+request)',
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
    # "Always run tests before committing" / "Run cargo test before committing"
    re.compile(
        r'(?:always\s+)?(?:run|execute|use)\s+'
        r'(\S+(?:\s+\S+)?)\s+'
        r'before\s+'
        r'(\S+)',
        re.IGNORECASE
    ),
    # "Before any WebSearch, MUST grep the vault first"
    re.compile(
        r'before\s+(?:any\s+)?(\S+)[,;]\s+'
        r'(?:\w+\s+)?(?:must|should|always)?\s*'
        r'(?:run|execute|use|grep|search|check)\s+'
        r'(.+?)(?:\s+first)?\.?\s*$',
        re.IGNORECASE
    ),
    # "MUST grep X before WebSearch" / "Claude MUST grep X before Y"
    re.compile(
        r'must\s+(?:run\s+|execute\s+)?'
        r'(\S+(?:\s+\S+)?)\s+'
        r'(?:.+?\s+)?before\s+'
        r'(\S+)',
        re.IGNORECASE
    ),
    # "Search locally before using web search" / "Always search locally before web search"
    re.compile(
        r'(?:always\s+)?(?:search|check|look|grep)\s+(?:locally|the\s+codebase|existing\s+code|the\s+\S+)\s+'
        r'before\s+(?:using?\s+)?(.+)',
        re.IGNORECASE
    ),
    # "Read the test file before editing source" / "Read X before modifying Y"
    # Captures the verb "read" as group 1 and the target verb as group 2
    re.compile(
        r'(?:always\s+)?(read)\s+.+?\s+'
        r'before\s+(editing|modifying|changing|updating)',
        re.IGNORECASE
    ),
    # "Run npm test after every code change" / "Run tests after any modification"
    # Maps to require-prior-tool: must run X before next commit/push
    # Group 1 = required command, Group 2 = implied target (change/modification -> committing)
    re.compile(
        r'(?:always\s+)?(?:run|execute|use)\s+'
        r'(\S+(?:\s+\S+)?)\s+'
        r'after\s+(?:every|each|any|all)\s+'
        r'(?:code\s+)?(changes?|modifications?|edits?|updates?)',
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

# Patterns for content guards (check what's being written to files)
CONTENT_GUARD_PATTERNS = [
    # "Never write/include/add `X` ..." (backtick-quoted code pattern)
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:write|include|add|put|leave|output)\s+'
        r'`([^`]+)`',
        re.IGNORECASE
    ),
    # "Don't use `X` type/keyword" / "Avoid `X` keyword" (code context, not commands)
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:(?:us(?:e|ing))\s+)?'  # "use/using" is optional (for "avoid `X` type")
        r'(?:the\s+)?'
        r'`([^`]+)`\s+'
        r'(?:type|keyword|declaration|statement|function|method|class|variable|operator)',
        re.IGNORECASE
    ),
    # "Don't use `X` in production/code/TypeScript/Python files"
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:us(?:e|ing))\s+'
        r'(?:the\s+)?'
        r'`([^`]+)`\s+'
        r'in\s+(?:production|code|source|typescript|javascript|python|ruby)',
        re.IGNORECASE
    ),
    # "No `console.log` statements" / "No `debugger` calls"
    re.compile(
        r'(?:no|zero|eliminate)\s+'
        r'`([^`]+)`\s+'
        r'(?:statements?|calls?|usage|expressions?|literals?)',
        re.IGNORECASE
    ),
    # Bare code identifiers WITHOUT backticks:
    # "Never write console.log" / "Never use eval()" / "Avoid debugger"
    # Verb is optional for "avoid" ("Avoid debugger" vs "Avoid using debugger")
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid)\s+'
        r'(?:(?:us(?:e|ing)|writ(?:e|ing)|includ(?:e|ing)|add(?:ing)?|leav(?:e|ing)|call(?:ing)?|put|output|invoke)\s+)?'
        r'(console\.log|console\.error|console\.warn|console\.info|console\.debug'
        r'|debugger|eval\s*\(\)|exec\s*\(\)|document\.write|alert\s*\(\)|innerHTML'
        r'|\.innerHTML|window\.eval|Function\(\)'
        r'|binding\.pry|byebug|pdb\.set_trace)',
        re.IGNORECASE
    ),
    # "No console.log" (bare, without backticks)
    re.compile(
        r'(?:no|zero|eliminate)\s+'
        r'(console\.log|console\.error|console\.warn|debugger|eval\(\)|document\.write)',
        re.IGNORECASE
    ),
    # Parenthetical code examples: "Never use inline styles (style="...")"
    # Extracts the first code-like token from parentheses
    re.compile(
        r'(?:never|don\'?t|do\s+not|avoid|no)\s+'
        r'(?:(?:us(?:e|ing)|writ(?:e|ing)|includ(?:e|ing)|add(?:ing)?)\s+)?'
        r'[\w\s]*'
        r'\(([^)]*?(?:[=<>:;{}]|\.\.\.)[^)]*)\)',
        re.IGNORECASE
    ),
]

# Concept-to-pattern mapping for common antipatterns expressed as natural language
# Maps concept keywords to the actual code pattern to search for
CONCEPT_PATTERNS = {
    'inline style': 'style=',
    'inline styles': 'style=',
    'hex color': '#[0-9a-fA-F]',
    'hex colour': '#[0-9a-fA-F]',
    'hex code': '#[0-9a-fA-F]',
    'important': '!important',
    'todo comment': 'TODO',
    'fixme': 'FIXME',
    'hack comment': 'HACK',
    'xxx comment': 'XXX',
    'type assertion': ' as ',
    'ts-ignore': 'ts-ignore',
    'ts-nocheck': 'ts-nocheck',
    'eslint-disable': 'eslint-disable',
    'noinspection': 'noinspection',
    'noqa': 'noqa',
    'rubocop:disable': 'rubocop:disable',
    'wildcard import': 'import *',
}

# Code concepts that can be scoped to specific directories
# Maps natural language to regex patterns for content matching
SCOPED_CONCEPTS = {
    'interface': r'\binterface\s+\w+',
    'interfaces': r'\binterface\s+\w+',
    'type definition': r'\btype\s+\w+\s*=',
    'type definitions': r'\btype\s+\w+\s*=',
    'type alias': r'\btype\s+\w+\s*=',
    'type aliases': r'\btype\s+\w+\s*=',
    'class': r'\bclass\s+\w+',
    'classes': r'\bclass\s+\w+',
    'enum': r'\benum\s+\w+',
    'enums': r'\benum\s+\w+',
    'sql': r'\b(SELECT|INSERT|UPDATE|DELETE)\b',
    'sql queries': r'\b(SELECT|INSERT|UPDATE|DELETE)\b',
    'queries': r'\b(SELECT|INSERT|UPDATE|DELETE)\b',
    'console.log': r'console\.log',
    'console statements': r'console\.',
    'require': r'\brequire\(',
    'imports': r'\bimport\b',
    'styled-components': r'styled\.',
    'styled components': r'styled\.',
}


def extract_file_patterns(text):
    """Extract file patterns from directive text."""
    patterns = []
    # Match quoted strings
    for m in re.finditer(r'["`\']([\w.*/_-]+)["`\']', text):
        patterns.append(m.group(1))
    # Match common file patterns without quotes
    # Use (?:^|\W) instead of \b since dot-prefixed names don't have word boundary before them
    for m in re.finditer(r'(?:^|\W)(\.env\b|\.env\.\w+|\.env\.local\b|secrets?/|\.pem\b|\.key\b|\.p12\b|\.pfx\b|\.cert\b|\.crt\b|credentials?\.\w+|vendor/|node_modules/|\.git/|\*\.\w{1,5})', text):
        patterns.append(m.group(1))
    # Match common bare filenames (Makefile, Dockerfile, lock files, etc.)
    # NOTE: Longer compound names (Gemfile.lock) MUST appear before shorter
    # prefixes (Gemfile) in the alternation, or the shorter match wins.
    for m in re.finditer(r'\b(package-lock\.json|Gemfile\.lock|Cargo\.lock|Pipfile\.lock|Cargo\.toml|pnpm-lock\.yaml|shrinkwrap\.json|composer\.lock|poetry\.lock|bun\.lockb|flake\.lock|CHANGELOG\.md|CLAUDE\.md|README\.md|package\.json|tsconfig\.json|go\.mod|go\.sum|yarn\.lock|Makefile|Dockerfile|Gemfile|Rakefile|Procfile|Vagrantfile|Brewfile|Guardfile|Thorfile|Berksfile|Capfile|Podfile|Fastfile|Dangerfile|LICENSE|\.gitignore|\.dockerignore)\b', text):
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
        '--no-verify', '--no-gpg-sign', '--skip-hooks',
        '--dangerouslyDisableSandbox',
    ]
    lower = text.lower()
    for cmd in dangerous:
        if cmd in lower and cmd not in patterns:
            patterns.append(cmd)
    # Extract --flag patterns (e.g., "--no-verify", "--force-with-lease")
    # These are specific enough to be meaningful blockers
    for m in re.finditer(r'(--[\w][\w-]+)', text):
        flag = m.group(1)
        if flag not in patterns:
            patterns.append(flag)

    # Expand aliases: "force push" should also match "push --force" and "push -f"
    aliases = {
        'force push': ['push --force', 'push -f'],
        'push --force': ['force push', 'push -f'],
        'push -f': ['force push', 'push --force'],
    }
    # If the text mentions push (without force/--force), expand to "git push"
    # This handles "push to origin", "push without PR" etc.
    if not patterns and re.search(r'\bpush\b', lower):
        patterns.append('git push')

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


def _try_scoped_content(clean, clean_lower, stripped, line_num, severity='block'):
    """Try to classify as scoped-content-guard (content pattern + path scope).

    Detects rules like:
      "Interfaces should only be defined in types/ folders"  -> only_in
      "No SQL queries in controllers/"                       -> never_in
    Returns Directive or None.
    """
    # Step 1: Find a code concept mentioned in the directive
    concept_pat = None
    concept_name = None
    for name, pat in SCOPED_CONCEPTS.items():
        if name in clean_lower:
            concept_pat = pat
            concept_name = name
            break
    if not concept_pat:
        return None

    # Step 2: Find a directory path (word ending in /)
    path_match = re.search(r'["`\']([\w./-]+/[\w./-]*)["`\']', clean)
    if not path_match:
        path_match = re.search(r'\b(\w[\w.-]*/)', clean)
    if not path_match:
        return None
    path_filter = path_match.group(1)

    # Avoid false positives: path must look like a directory, not a URL or command
    if path_filter in ('http/', 'https/', 'ftp/', 'or/', 'and/'):
        return None

    # Step 3: Determine scope mode
    if re.search(r'\bonly\b', clean_lower):
        path_mode = 'only_in'
        desc = f"Only allow {concept_name} in {path_filter}"
    elif re.search(r'(?:never|don\'?t|do\s+not|no)\b', clean_lower):
        path_mode = 'never_in'
        desc = f"Block {concept_name} in {path_filter}"
    else:
        return None

    return Directive(
        text=stripped,
        hook_type='scoped-content-guard',
        patterns=[concept_pat],
        description=desc,
        line_num=line_num,
        path_filter=[path_filter],
        path_mode=path_mode,
        severity=severity,
    )


def classify_directive(line, line_num):
    """Classify a single line as an enforceable directive or None."""
    stripped = line.strip()
    if not stripped or stripped.startswith('#') and not stripped.startswith('##'):
        return None

    # Remove markdown list markers
    clean = re.sub(r'^[-*]\s+', '', stripped)
    clean = re.sub(r'^\d+\.\s+', '', clean)
    # Remove @enforced tag but remember it was there, and extract severity
    has_enforced = '@enforced' in clean
    severity = 'block'  # default
    # Parse @enforced(warn) or @enforced(block) syntax
    sev_match = re.search(r'@enforced\((\w+)\)', clean)
    if sev_match:
        sev_val = sev_match.group(1).lower()
        if sev_val in ('warn', 'block'):
            severity = sev_val
    clean = re.sub(r'@enforced(?:\(\w+\))?', '', clean).strip()
    clean = clean.replace('@required', '').strip()

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
                    severity=severity,
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
                    severity=severity,
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
                    severity=severity,
                )

    # Try scoped-content-guard (content + path combo)
    # "Interfaces should only be defined in types/ folders"
    # "No SQL queries in controllers/"
    clean_lower = clean.lower()
    scoped = _try_scoped_content(clean, clean_lower, stripped, line_num, severity=severity)
    if scoped:
        return scoped

    # Try concept-based content-guard (natural language antipatterns)
    # "Never use inline styles" → content-guard for style=
    # "No HEX color codes" → content-guard for #[0-9a-fA-F]
    for concept, code_pat in CONCEPT_PATTERNS.items():
        if concept in clean_lower:
            return Directive(
                text=stripped,
                hook_type='content-guard',
                patterns=[code_pat],
                description=f"Block writing: {code_pat}",
                line_num=line_num,
                severity=severity,
            )

    # Try content-guard patterns (before bash-guard to avoid false positives
    # like "don't use `any` type" being classified as bash-guard)
    for pattern in CONTENT_GUARD_PATTERNS:
        m = pattern.search(clean)
        if m:
            code_pat = m.group(1).strip()
            if code_pat:
                return Directive(
                    text=stripped,
                    hook_type='content-guard',
                    patterns=[code_pat],
                    description=f"Block writing: {code_pat}",
                    line_num=line_num,
                    severity=severity,
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
                    severity=severity,
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
                severity=severity,
            )

    # Try require-prior-tool patterns
    # Map common terms to Claude Code tool names
    _tool_name_map = {
        'tests': 'Bash', 'test': 'Bash', 'lint': 'Bash', 'linting': 'Bash',
        'cargo test': 'Bash', 'npm test': 'Bash', 'pytest': 'Bash',
        'change': 'Bash', 'changes': 'Bash', 'modification': 'Bash',
        'modifications': 'Bash', 'edits': 'Bash',
        'search': 'Grep', 'grep': 'Grep', 'rg': 'Grep',
        'web search': 'WebSearch', 'websearch': 'WebSearch',
        'webfetch': 'WebFetch', 'web fetch': 'WebFetch',
        'committing': 'Bash', 'commit': 'Bash', 'pushing': 'Bash',
        'read': 'Read', 'reading': 'Read',
        'editing': 'Edit', 'edit': 'Edit',
        'modifying': 'Edit', 'modify': 'Edit',
        'changing': 'Edit',
        'updating': 'Edit', 'update': 'Edit',
    }
    def _to_tool(name):
        """Map a term to its Claude Code tool name."""
        low = name.strip().lower()
        if low in _tool_name_map:
            return _tool_name_map[low]
        # If it looks like a tool name already (PascalCase), keep it
        if name[0].isupper() and name.isalnum():
            return name
        return name

    for idx, pattern in enumerate(REQUIRE_PRIOR_PATTERNS):
        m = pattern.search(clean)
        if m:
            groups = m.groups()
            if idx == 1:
                # Pattern: "Before any WebSearch, MUST grep the vault first"
                # Group 1 = target tool, verb = required action
                target_raw = groups[0].strip()
                verb_match = re.search(r'(?:must|should|always)\s+(?:run\s+|execute\s+)?(\S+)', clean, re.IGNORECASE)
                required_raw = verb_match.group(1) if verb_match else 'grep'
                required = _to_tool(required_raw)
                target = _to_tool(target_raw)
                return Directive(
                    text=stripped,
                    hook_type='require-prior-tool',
                    patterns=[required, target],
                    description=f"Require {required} before {target}",
                    line_num=line_num,
                    severity=severity,
                )
            elif len(groups) >= 2:
                # Pattern: "Run X before Y" -> required=X, target=Y
                required_raw = groups[0].strip()
                target_raw = groups[1].strip()
                required = _to_tool(required_raw)
                target = _to_tool(target_raw)
                # If both map to the same tool (e.g. both Bash), keep
                # the raw command text so the hook can pattern-match
                if required == target == 'Bash':
                    return Directive(
                        text=stripped,
                        hook_type='require-prior-command',
                        patterns=[required_raw, target_raw],
                        description=f"Require `{required_raw}` before `{target_raw}`",
                        line_num=line_num,
                        severity=severity,
                    )
                return Directive(
                    text=stripped,
                    hook_type='require-prior-tool',
                    patterns=[required, target],
                    description=f"Require {required} before {target}",
                    line_num=line_num,
                    severity=severity,
                )
            elif len(groups) == 1:
                # Single-group: "search locally before web search" -> Grep before WebSearch
                target = _to_tool(groups[0].strip())
                return Directive(
                    text=stripped,
                    hook_type='require-prior-tool',
                    patterns=['Grep', target],
                    description=f"Require Grep before {target}",
                    line_num=line_num,
                    severity=severity,
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
                severity=severity,
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
                severity=severity,
            )

    return None


def scan_file(path):
    """Scan a CLAUDE.md file and return (enforceable, skipped) directives."""
    content = Path(path).read_text()
    lines = content.splitlines()
    enforceable = []
    skipped = []
    section_enforced = False  # tracks whether current section has @enforced
    section_severity = 'block'  # section-level severity default
    in_code_block = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped:
            continue

        # Track code blocks
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        # Section headings (# through ####) may carry @enforced tag
        if re.match(r'^#{1,4}\s', stripped):
            section_enforced = '@enforced' in stripped or '@required' in stripped
            # Parse section-level severity: ## Rules @enforced(warn)
            sec_sev_match = re.search(r'@enforced\((\w+)\)', stripped)
            if sec_sev_match and sec_sev_match.group(1).lower() in ('warn', 'block'):
                section_severity = sec_sev_match.group(1).lower()
            elif section_enforced:
                section_severity = 'block'
            # Don't classify the heading itself as a directive — the
            # content lines under it are the actual rules.
            continue

        # Content lines: classify if they have @enforced inline or belong
        # to an @enforced section
        has_inline_tag = '@enforced' in line or '@required' in line
        if not has_inline_tag and not section_enforced:
            continue

        directive = classify_directive(line, i)
        if directive:
            # Inline @enforced(warn) takes precedence; if no inline tag,
            # inherit section severity
            if not has_inline_tag and section_enforced:
                directive.severity = section_severity
            enforceable.append(directive)
        elif has_inline_tag:
            skipped.append((i, stripped, 'Could not classify'))

    return enforceable, skipped


def scan_suggestions(path):
    """Scan ALL lines in CLAUDE.md, ignoring @enforced requirement.

    Returns directives that COULD be enforced if tagged. Used to guide
    new users who haven't added @enforced yet.
    """
    content = Path(path).read_text()
    lines = content.splitlines()
    suggestions = []
    in_code_block = False

    for i, line in enumerate(lines, 1):
        stripped = line.strip()
        if not stripped:
            continue
        if stripped.startswith('```'):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue
        if re.match(r'^#{1,4}\s', stripped):
            continue

        directive = classify_directive(line, i)
        if directive:
            suggestions.append(directive)

    return suggestions


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

REQUIRE_PRIOR_CMD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
# NOTE: Requires session-log hook to be installed for tracking.
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
# Only block commands matching the target pattern
case "$CMD" in *"{target_cmd}"*) ;; *) exit 0 ;; esac
# Check session log for the required prior command
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '{required_cmd}' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo '{{"decision": "block", "reason": "Run {required_cmd} first. (CLAUDE.md: {short})"}}'
exit 0
'''

REQUIRE_PRIOR_WARN_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive} [WARN]
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
echo "⚠ enforce-hooks WARN: Run {required_tool} first. (CLAUDE.md: {short})" >&2
exit 0
'''

REQUIRE_PRIOR_CMD_WARN_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive} [WARN]
# Generated by enforce-hooks from CLAUDE.md
# NOTE: Requires session-log hook to be installed for tracking.
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
# Only check commands matching the target pattern
case "$CMD" in *"{target_cmd}"*) ;; *) exit 0 ;; esac
# Check session log for the required prior command
TODAY=$(date -u +%Y-%m-%d)
LOG="$HOME/.claude/session-logs/$TODAY.jsonl"
if [ -f "$LOG" ]; then
  if grep -q '{required_cmd}' "$LOG" 2>/dev/null; then
    exit 0
  fi
fi
echo "⚠ enforce-hooks WARN: Run {required_cmd} first. (CLAUDE.md: {short})" >&2
exit 0
'''

# --- Armor: Hook Self-Protection Templates ---

ARMOR_FILE_GUARD = '''#!/usr/bin/env bash
# enforce: Hook self-protection (--armor)
# Generated by enforce-hooks --armor
# Prevents Claude from modifying hook scripts or settings via Write/Edit
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in Write|Edit|MultiEdit) ;; *) exit 0 ;; esac
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
[[ "$FILE" == *".claude/hooks/"* ]] && echo '{"decision": "block", "reason": "Armored: hook files in .claude/hooks/ are protected. (enforce-hooks --armor)"}' && exit 0
[[ "$FILE" == *".claude/settings.json"* ]] && echo '{"decision": "block", "reason": "Armored: .claude/settings.json is protected. (enforce-hooks --armor)"}' && exit 0
exit 0
'''

ARMOR_BASH_GUARD = '''#!/usr/bin/env bash
# enforce: Hook self-protection (--armor)
# Generated by enforce-hooks --armor
# Prevents Claude from deleting/moving/disabling hook scripts via Bash
INPUT=$(cat)
[ "$(echo "$INPUT" | jq -r '.tool_name')" != "Bash" ] && exit 0
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [[ "$CMD" == *".claude/hooks"* ]]; then
  case "$CMD" in
    *rm*|*mv*|*chmod*|*chown*|*truncate*|*unlink*|*">"*|*sed*-i*)
      echo '{"decision": "block", "reason": "Armored: destructive commands targeting .claude/hooks/ are blocked. (enforce-hooks --armor)"}'
      exit 0 ;;
  esac
fi
if [[ "$CMD" == *".claude/settings.json"* ]]; then
  case "$CMD" in
    *rm*|*mv*|*truncate*|*unlink*|*">"*|*sed*-i*)
      echo '{"decision": "block", "reason": "Armored: destructive commands targeting .claude/settings.json are blocked. (enforce-hooks --armor)"}'
      exit 0 ;;
  esac
fi
exit 0
'''


CONTENT_GUARD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac
# Extract content being written
if [ "$TOOL" = "Edit" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
elif [ "$TOOL" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [ "$TOOL" = "MultiEdit" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '[.tool_input.edits[].new_string] | join("\\n") // empty')
fi
[ -z "$CONTENT" ] && exit 0
{checks}
exit 0
'''


SCOPED_CONTENT_GUARD_TEMPLATE = '''#!/usr/bin/env bash
# enforce: {directive}
# Generated by enforce-hooks from CLAUDE.md
INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name')
case "$TOOL" in Edit|Write|MultiEdit) ;; *) exit 0 ;; esac
# Extract file path
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
[ -z "$FILE" ] && exit 0
# Check path scope
{path_check}
# Extract content being written
if [ "$TOOL" = "Edit" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // empty')
elif [ "$TOOL" = "Write" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // empty')
elif [ "$TOOL" = "MultiEdit" ]; then
  CONTENT=$(echo "$INPUT" | jq -r '[.tool_input.edits[].new_string] | join("\\n") // empty')
fi
[ -z "$CONTENT" ] && exit 0
{content_check}
exit 0
'''


def generate_scoped_content_guard(directive):
    """Generate a scoped-content-guard hook script."""
    short = re.sub(r'@enforced(?:\(\w+\))?', '', directive.text[:80]).strip()
    short_escaped = short.replace("'", "'\\''")
    sev = directive.severity

    # Path check
    path_lines = []
    for pf in (directive.path_filter or []):
        pf_escaped = pf.replace('"', '\\"')
        if directive.path_mode == 'only_in':
            # If path matches, content is allowed - exit early
            path_lines.append(f'[[ "$FILE" == *"{pf_escaped}"* ]] && exit 0')
        else:  # never_in
            # If path does NOT match, content is allowed - exit early
            path_lines.append(f'[[ "$FILE" != *"{pf_escaped}"* ]] && exit 0')
    path_check = '\n'.join(path_lines)

    # Content check (same logic as content-guard)
    content_lines = []
    for pat in directive.patterns:
        escaped = pat.replace("'", "'\\''")
        is_regex = any(c in pat for c in r'[](){}*+?|\\^$')
        grep_flag = '-qE' if is_regex else '-qF'
        if sev == 'warn':
            content_lines.append(
                f'if echo "$CONTENT" | grep {grep_flag} \'{escaped}\'; then\n'
                f'  echo "⚠ enforce-hooks WARN: {escaped} not allowed here. (CLAUDE.md: {short_escaped})" >&2\n'
                f'fi'
            )
        else:
            content_lines.append(
                f'if echo "$CONTENT" | grep {grep_flag} \'{escaped}\'; then\n'
                f'  echo \'{{"decision": "block", "reason": "Content blocked: {escaped} not allowed here. (CLAUDE.md: {short_escaped})"}}\'\n'
                f'  exit 0\n'
                f'fi'
            )
    content_check = '\n'.join(content_lines)

    return SCOPED_CONTENT_GUARD_TEMPLATE.format(
        directive=short,
        path_check=path_check,
        content_check=content_check,
    )


def generate_content_guard_checks(patterns, short_directive, severity='block'):
    """Generate bash checks for content-guard patterns."""
    lines = []
    for pat in patterns:
        escaped = pat.replace("'", "'\\''")
        short = short_directive.replace("'", "'\\''")
        # Use grep -E (regex) if pattern contains regex metacharacters, else grep -F (fixed)
        is_regex = any(c in pat for c in r'[](){}*+?|\\^$')
        grep_flag = '-qE' if is_regex else '-qF'
        if severity == 'warn':
            lines.append(
                f'if echo "$CONTENT" | grep {grep_flag} \'{escaped}\'; then\n'
                f'  echo "⚠ enforce-hooks WARN: Content matched: {escaped}. (CLAUDE.md: {short})" >&2\n'
                f'fi'
            )
        else:
            lines.append(
                f'if echo "$CONTENT" | grep {grep_flag} \'{escaped}\'; then\n'
                f'  echo \'{{"decision": "block", "reason": "Content blocked: {escaped} is not allowed. (CLAUDE.md: {short})"}}\'\n'
                f'  exit 0\n'
                f'fi'
            )
    return '\n'.join(lines)


def generate_file_guard_checks(patterns, short_directive, severity='block'):
    """Generate bash checks for file-guard patterns."""
    lines = []
    for pat in patterns:
        escaped = pat.replace('"', '\\"')
        short = short_directive.replace('"', '\\"').replace('`', '')
        if severity == 'warn':
            lines.append(
                f'[[ "$FILE" == *"{escaped}"* ]] && '
                f'echo "⚠ enforce-hooks WARN: $FILE matches {escaped}. (CLAUDE.md: {short})" >&2'
            )
        else:
            lines.append(
                f'[[ "$FILE" == *"{escaped}"* ]] && '
                f'echo "{{\\"decision\\": \\"block\\", \\"reason\\": \\"Protected: $FILE matches {escaped}. (CLAUDE.md: {short})\\"}}\" && exit 0'
            )
    return '\n'.join(lines)


def generate_bash_guard_checks(patterns, short_directive, severity='block'):
    """Generate bash checks for bash-guard patterns."""
    lines = []
    for pat in patterns:
        escaped = pat.replace('"', '\\"').replace("'", "'\\''")
        short = short_directive.replace('"', '\\"').replace("'", "'\\''")
        if severity == 'warn':
            lines.append(
                f'[[ "$CMD" == *"{escaped}"* ]] && '
                f'echo "⚠ enforce-hooks WARN: {escaped} detected. (CLAUDE.md: {short})" >&2'
            )
        else:
            lines.append(
                f'[[ "$CMD" == *"{escaped}"* ]] && '
                f'echo \'{{"decision": "block", "reason": "Blocked: {escaped}. (CLAUDE.md: {short})"}}\' && exit 0'
            )
    return '\n'.join(lines)


def generate_branch_guard_checks(branches, short_directive, severity='block'):
    """Generate bash checks for branch-guard patterns."""
    lines = []
    for branch in branches:
        short = short_directive.replace('"', '\\"')
        if severity == 'warn':
            lines.append(f'''if [ "$BRANCH" = "{branch}" ]; then
  case "$CMD" in
    *"git commit"*|*"git merge"*|*"git push"*)
      echo "⚠ enforce-hooks WARN: Branch {branch} is protected. (CLAUDE.md: {short})" >&2 ;;
  esac
fi''')
        else:
            lines.append(f'''if [ "$BRANCH" = "{branch}" ]; then
  case "$CMD" in
    *"git commit"*|*"git merge"*|*"git push"*)
      echo '{{"decision": "block", "reason": "Branch {branch} is protected. (CLAUDE.md: {short})"}}'
      exit 0 ;;
  esac
fi''')
    return '\n'.join(lines)


def generate_tool_block_checks(tools, short_directive, severity='block'):
    """Generate bash checks for tool-block patterns."""
    lines = []
    for tool in tools:
        short = short_directive.replace('"', '\\"').replace("'", "'\\''")
        if severity == 'warn':
            lines.append(
                f'[ "$TOOL" = "{tool}" ] && '
                f'echo "⚠ enforce-hooks WARN: Tool {tool} used. (CLAUDE.md: {short})" >&2'
            )
        else:
            lines.append(
                f'[ "$TOOL" = "{tool}" ] && '
                f'echo \'{{"decision": "block", "reason": "Tool {tool} is blocked. (CLAUDE.md: {short})"}}\' && exit 0'
            )
    return '\n'.join(lines)


def _truncate_short(text, maxlen=60):
    """Truncate text for use in hook messages, word-boundary aware."""
    clean = re.sub(r'@enforced(?:\(\w+\))?', '', text).replace('@required', '').strip()
    if len(clean) <= maxlen:
        return clean
    # Truncate at word boundary
    truncated = clean[:maxlen].rsplit(' ', 1)[0]
    # Don't leave dangling punctuation
    truncated = truncated.rstrip('(,[;:')
    return truncated + '...'


def generate_hook(directive):
    """Generate a hook script for a directive."""
    short = _truncate_short(directive.text, 80)

    sev = directive.severity

    if directive.hook_type == 'scoped-content-guard':
        return generate_scoped_content_guard(directive)

    elif directive.hook_type == 'content-guard':
        checks = generate_content_guard_checks(directive.patterns, short, severity=sev)
        return CONTENT_GUARD_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'file-guard':
        checks = generate_file_guard_checks(directive.patterns, short, severity=sev)
        # Include Read tool if directive mentions reading
        text_lower = directive.text.lower()
        if any(w in text_lower for w in ['read', 'access', 'view', 'open', 'look at']):
            tool_case = 'Write|Edit|MultiEdit|Read'
        else:
            tool_case = 'Write|Edit|MultiEdit'
        return FILE_GUARD_TEMPLATE.format(directive=short, checks=checks, tool_case=tool_case)

    elif directive.hook_type == 'bash-guard':
        checks = generate_bash_guard_checks(directive.patterns, short, severity=sev)
        return BASH_GUARD_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'branch-guard':
        checks = generate_branch_guard_checks(directive.patterns, short, severity=sev)
        return BRANCH_GUARD_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'tool-block':
        checks = generate_tool_block_checks(directive.patterns, short, severity=sev)
        return TOOL_BLOCK_TEMPLATE.format(directive=short, checks=checks)

    elif directive.hook_type == 'require-prior-tool':
        if len(directive.patterns) >= 2:
            required = directive.patterns[0]
            target = directive.patterns[1]
            if sev == 'warn':
                return REQUIRE_PRIOR_WARN_TEMPLATE.format(
                    directive=short,
                    target_tools=target,
                    required_tool=required,
                    short=_truncate_short(directive.text),
                )
            return REQUIRE_PRIOR_TEMPLATE.format(
                directive=short,
                target_tools=target,
                required_tool=required,
                short=_truncate_short(directive.text),
            )

    elif directive.hook_type == 'require-prior-command':
        if len(directive.patterns) >= 2:
            required_cmd = directive.patterns[0]
            target_cmd = directive.patterns[1]
            # Map common verb forms to git command patterns
            target_map = {
                'committing': 'git commit',
                'commit': 'git commit',
                'pushing': 'git push',
                'push': 'git push',
                'merging': 'git merge',
                'deploying': 'deploy',
            }
            target_pattern = target_map.get(target_cmd.lower(), target_cmd)
            if sev == 'warn':
                return REQUIRE_PRIOR_CMD_WARN_TEMPLATE.format(
                    directive=short,
                    target_cmd=target_pattern,
                    required_cmd=required_cmd,
                    short=_truncate_short(directive.text),
                )
            return REQUIRE_PRIOR_CMD_TEMPLATE.format(
                directive=short,
                target_cmd=target_pattern,
                required_cmd=required_cmd,
                short=_truncate_short(directive.text),
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

    # Update settings.json (handles JSONC comments)
    settings_path = Path(settings_path)
    settings = load_settings_json(settings_path)

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


def install_armor(hooks_dir, settings_path):
    """Install self-protection hooks that guard .claude/hooks/ from modification.

    Generates two standalone hooks:
    - armor_file_guard.sh: blocks Write/Edit/MultiEdit on hook files and settings
    - armor_bash_guard.sh: blocks rm/mv/chmod/etc. targeting hook files and settings

    These hooks protect themselves: the file-guard blocks edits to the bash-guard,
    and the bash-guard blocks deletion of the file-guard. Neither requires CLAUDE.md.
    """
    hooks_dir = Path(hooks_dir)
    hooks_dir.mkdir(parents=True, exist_ok=True)

    written = []
    for name, content in [('armor_file_guard.sh', ARMOR_FILE_GUARD),
                          ('armor_bash_guard.sh', ARMOR_BASH_GUARD)]:
        path = hooks_dir / name
        path.write_text(content)
        path.chmod(0o755)
        written.append(str(path))

    # Update settings.json (handles JSONC comments)
    settings_path = Path(settings_path)
    settings = load_settings_json(settings_path)

    hooks_config = settings.setdefault('hooks', {})
    pre_tool = hooks_config.setdefault('PreToolUse', [])

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
        if path not in existing_commands:
            catch_all['hooks'].append({'type': 'command', 'command': path})

    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2) + '\n')

    return written


# --- Runtime Evaluation ---

def get_current_branch():
    """Get current git branch by reading .git/HEAD directly (no subprocess)."""
    cwd = Path.cwd()
    for parent in [cwd] + list(cwd.parents):
        head = parent / '.git' / 'HEAD'
        if head.exists():
            try:
                content = head.read_text().strip()
                if content.startswith('ref: refs/heads/'):
                    return content[len('ref: refs/heads/'):]
            except IOError:
                pass
            return None
    return None


def evaluate_tool_call(directives, tool_name, tool_input):
    """Evaluate a tool call against all directives.

    Returns dict: {"decision": "allow"} or {"decision": "block", "reason": "..."}
    Warn-severity directives produce warnings on stderr but don't block.
    """
    warnings = []
    for d in directives:
        result = _check_single(d, tool_name, tool_input)
        if result:
            if d.severity == 'warn':
                # Warn: collect but don't block
                msg = result.get('reason', 'rule violation')
                warnings.append(msg)
                print(f"⚠ enforce-hooks WARN: {msg}", file=sys.stderr)
            else:
                return result
    return {"decision": "allow"}


def _check_single(directive, tool_name, tool_input):
    """Check if a tool call violates a single directive."""
    short = re.sub(r'@enforced(?:\(\w+\))?', '', directive.text[:80]).strip()

    if directive.hook_type == 'scoped-content-guard':
        if tool_name not in ('Write', 'Edit', 'MultiEdit'):
            return None
        file_path = tool_input.get('file_path', '')
        if not file_path:
            return None
        # Check path scope
        path_match = any(pf in file_path for pf in (directive.path_filter or []))
        if directive.path_mode == 'only_in' and path_match:
            return None  # File is in the allowed path, content is fine
        if directive.path_mode == 'never_in' and not path_match:
            return None  # File is not in the blocked path, content is fine
        # Extract content
        content = ''
        if tool_name == 'Edit':
            content = tool_input.get('new_string', '')
        elif tool_name == 'Write':
            content = tool_input.get('content', '')
        elif tool_name == 'MultiEdit':
            edits = tool_input.get('edits', [])
            content = '\n'.join(e.get('new_string', '') for e in edits)
        if not content:
            return None
        for pat in directive.patterns:
            matched = False
            if any(c in pat for c in r'[](){}*+?|\\^$'):
                try:
                    matched = bool(re.search(pat, content))
                except re.error:
                    matched = pat in content
            else:
                matched = pat in content
            if matched:
                scope_desc = ', '.join(directive.path_filter or [])
                if directive.path_mode == 'only_in':
                    reason = f"Content blocked: {pat} only allowed in {scope_desc}. (CLAUDE.md: \"{short}\")"
                else:
                    reason = f"Content blocked: {pat} not allowed in {scope_desc}. (CLAUDE.md: \"{short}\")"
                return {"decision": "block", "reason": reason}

    elif directive.hook_type == 'content-guard':
        if tool_name not in ('Write', 'Edit', 'MultiEdit'):
            return None
        content = ''
        if tool_name == 'Edit':
            content = tool_input.get('new_string', '')
        elif tool_name == 'Write':
            content = tool_input.get('content', '')
        elif tool_name == 'MultiEdit':
            edits = tool_input.get('edits', [])
            content = '\n'.join(e.get('new_string', '') for e in edits)
        if not content:
            return None
        for pat in directive.patterns:
            matched = False
            # Use regex matching if pattern contains regex metacharacters
            if any(c in pat for c in r'[](){}*+?|\\^$'):
                try:
                    matched = bool(re.search(pat, content))
                except re.error:
                    matched = pat in content  # fallback to literal
            else:
                matched = pat in content
            if matched:
                return {"decision": "block",
                        "reason": f"Content blocked: {pat} is not allowed. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'file-guard':
        text_lower = directive.text.lower()
        read_words = ['read', 'access', 'view', 'open', 'look at']
        target_tools = {'Write', 'Edit', 'MultiEdit'}
        if any(w in text_lower for w in read_words):
            target_tools.add('Read')

        if tool_name not in target_tools:
            return None

        file_path = tool_input.get('file_path', '')
        if not file_path:
            return None

        for pat in directive.patterns:
            if pat in file_path:
                return {"decision": "block",
                        "reason": f"Protected: {file_path} matches {pat}. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'bash-guard':
        if tool_name != 'Bash':
            return None
        cmd = tool_input.get('command', '')
        if not cmd:
            return None
        for pat in directive.patterns:
            if pat.lower() in cmd.lower():
                return {"decision": "block",
                        "reason": f"Blocked command: {pat}. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'branch-guard':
        if tool_name != 'Bash':
            return None
        cmd = tool_input.get('command', '')
        if not cmd:
            return None
        git_ops = ['git commit', 'git merge', 'git push']
        if not any(op in cmd for op in git_ops):
            return None
        branch = get_current_branch()
        if branch and branch in directive.patterns:
            return {"decision": "block",
                    "reason": f"Branch {branch} is protected. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'tool-block':
        if tool_name in directive.patterns:
            return {"decision": "block",
                    "reason": f"Tool {tool_name} is blocked. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'require-prior-tool':
        if len(directive.patterns) >= 2:
            required = directive.patterns[0]
            target = directive.patterns[1]
            tool_map = {
                'tests': 'Bash', 'test': 'Bash', 'lint': 'Bash',
                'search': 'Grep', 'grep': 'Grep',
                'web search': 'WebSearch', 'websearch': 'WebSearch',
                'edit': 'Edit', 'editing': 'Edit', 'modify': 'Edit',
                'write': 'Write', 'writing': 'Write',
                'read': 'Read', 'reading': 'Read',
            }
            target_tool = tool_map.get(target.lower(), 'Bash')

            if tool_name != target_tool:
                return None

            from datetime import date
            today = date.today().isoformat()
            session_log = Path.home() / '.claude' / 'session-logs' / f'{today}.jsonl'

            found = False
            if session_log.exists():
                try:
                    for line in session_log.read_text().splitlines():
                        try:
                            entry = json.loads(line)
                            if entry.get('tool') == required:
                                found = True
                                break
                        except json.JSONDecodeError:
                            pass
                except IOError:
                    pass

            if not found:
                return {"decision": "block",
                        "reason": f"Run {required} first. (CLAUDE.md: \"{short}\")"}

    elif directive.hook_type == 'require-prior-command':
        if tool_name != 'Bash':
            return None
        if len(directive.patterns) >= 2:
            required_cmd = directive.patterns[0]
            target_cmd = directive.patterns[1]
            # Map verb forms to git command patterns
            target_map = {
                'committing': 'git commit',
                'commit': 'git commit',
                'pushing': 'git push',
                'push': 'git push',
                'merging': 'git merge',
                'deploying': 'deploy',
            }
            target_pattern = target_map.get(target_cmd.lower(), target_cmd)
            cmd = tool_input.get('command', '')
            if not cmd or target_pattern.lower() not in cmd.lower():
                return None

            from datetime import date
            today = date.today().isoformat()
            session_log = Path.home() / '.claude' / 'session-logs' / f'{today}.jsonl'

            found = False
            if session_log.exists():
                try:
                    for line in session_log.read_text().splitlines():
                        try:
                            entry = json.loads(line)
                            entry_cmd = entry.get('command', '')
                            if required_cmd.lower() in entry_cmd.lower():
                                found = True
                                break
                        except json.JSONDecodeError:
                            pass
                except IOError:
                    pass

            if not found:
                return {"decision": "block",
                        "reason": f"Run `{required_cmd}` before `{target_pattern}`. (CLAUDE.md: \"{short}\")"}

    return None


CACHE_FILENAME = '.enforce-cache.json'


def load_cached_directives(claude_md_path, cache_dir=None):
    """Load directives from cache if CLAUDE.md hasn't changed."""
    md_path = Path(claude_md_path)
    cache_path = Path(cache_dir or '.claude') / CACHE_FILENAME

    try:
        md_mtime = md_path.stat().st_mtime
    except OSError:
        return None

    if cache_path.exists():
        try:
            cache = json.loads(cache_path.read_text())
            if cache.get('mtime') == md_mtime and cache.get('path') == str(md_path):
                return [Directive(**d) for d in cache['directives']]
        except (json.JSONDecodeError, KeyError, TypeError):
            pass

    return None


def save_cached_directives(claude_md_path, directives, cache_dir=None):
    """Save directives to cache."""
    md_path = Path(claude_md_path)
    cache_path = Path(cache_dir or '.claude') / CACHE_FILENAME

    try:
        md_mtime = md_path.stat().st_mtime
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        cache = {
            'mtime': md_mtime,
            'path': str(md_path),
            'directives': [d.to_dict() for d in directives],
        }
        cache_path.write_text(json.dumps(cache))
    except (OSError, IOError):
        pass


def run_evaluate(claude_md_path):
    """Run evaluate mode: read tool call from stdin, check rules, output decision."""
    directives = load_cached_directives(claude_md_path)
    if directives is None:
        enforceable, _ = scan_file(claude_md_path)
        directives = enforceable
        save_cached_directives(claude_md_path, directives)

    if not directives:
        print(json.dumps({"decision": "allow"}))
        return

    try:
        raw = sys.stdin.read()
        tool_call = json.loads(raw)
    except (json.JSONDecodeError, IOError):
        print(json.dumps({"decision": "allow"}))
        return

    tool_name = tool_call.get('tool_name', '')
    tool_input = tool_call.get('tool_input', {})

    if not tool_name:
        print(json.dumps({"decision": "allow"}))
        return

    result = evaluate_tool_call(directives, tool_name, tool_input)
    print(json.dumps(result))


def install_plugin(claude_md_path, hooks_dir, settings_path):
    """Install enforce-hooks as a single PreToolUse hook (plugin mode).

    Instead of generating per-rule scripts, installs one hook that
    reads CLAUDE.md at runtime and enforces all rules dynamically.
    """
    hooks_dir = Path(hooks_dir)
    hooks_dir.mkdir(parents=True, exist_ok=True)

    # Copy enforce-hooks.py into the hooks directory
    src = Path(__file__).resolve()
    dst = hooks_dir / 'enforce-hooks.py'
    dst.write_text(src.read_text())

    # Write the thin wrapper hook
    wrapper = hooks_dir / 'enforce-pretooluse.sh'
    wrapper.write_text(
        '#!/usr/bin/env bash\n'
        '# enforce-pretooluse.sh - Enforces CLAUDE.md directives on every tool call.\n'
        '# Auto-generated by enforce-hooks.py --install-plugin\n'
        'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\n'
        'exec python3 "$DIR/enforce-hooks.py" --evaluate\n'
    )
    wrapper.chmod(0o755)

    # Register in settings.json (handles JSONC comments)
    settings_path = Path(settings_path)
    settings = load_settings_json(settings_path)

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

    hook_cmd = str(wrapper)
    # Clean up stale enforce-hooks entries (old temp dirs, non-existent paths)
    if 'hooks' in catch_all:
        catch_all['hooks'] = [
            h for h in catch_all['hooks']
            if not (h.get('command', '').endswith('enforce-pretooluse.sh')
                    and not Path(h['command']).exists())
        ]
    existing_commands = {h.get('command', '') for h in catch_all.get('hooks', [])}
    if hook_cmd not in existing_commands:
        catch_all['hooks'].append({'type': 'command', 'command': hook_cmd})

    settings_path.parent.mkdir(parents=True, exist_ok=True)
    settings_path.write_text(json.dumps(settings, indent=2) + '\n')

    return [str(dst), str(wrapper)]


# --- Audit ---

def audit_hooks(claude_md_path, hooks_dir='.claude/hooks', settings_path='.claude/settings.json'):
    """Audit relationship between CLAUDE.md rules and installed hooks.

    Returns a dict with:
      enforced: list of directives that have active enforcement
      unenforced: list of directives that could be enforced but aren't
      suggestions: list of rules not tagged @enforced but classifiable
      orphan_hooks: list of hook files not matching any directive
      broken_refs: list of settings entries pointing to missing files
      plugin_mode: bool, whether dynamic plugin is installed
      settings_hooks: list of registered hook commands
    """
    hooks_dir = Path(hooks_dir)
    settings_path = Path(settings_path)

    # 1. Scan CLAUDE.md
    enforceable, skipped = scan_file(claude_md_path)
    suggestions = scan_suggestions(claude_md_path)
    # Filter suggestions to only those NOT already in enforceable
    enforced_lines = {d.line_num for d in enforceable}
    suggestions = [s for s in suggestions if s.line_num not in enforced_lines]

    # 2. Check for plugin mode (dynamic enforcement)
    plugin_hook = hooks_dir / 'enforce-pretooluse.sh'
    plugin_engine = hooks_dir / 'enforce-hooks.py'
    plugin_mode = plugin_hook.exists() and plugin_engine.exists()

    # 3. Read settings.json for registered hooks (handles JSONC)
    settings_hooks = []
    enforce_registered = False
    try:
        settings = load_settings_json(settings_path)
        for entry in settings.get('hooks', {}).get('PreToolUse', []):
            for h in entry.get('hooks', []):
                cmd = h.get('command', '')
                if cmd:
                    settings_hooks.append(cmd)
                    if 'enforce' in cmd.lower():
                        enforce_registered = True
    except (KeyError, Exception):
        pass

    # 4. Find enforce hook scripts on disk
    existing_scripts = set()
    if hooks_dir.exists():
        for f in hooks_dir.iterdir():
            if f.is_file() and f.name.startswith('enforce_') and f.suffix == '.sh':
                existing_scripts.add(str(f))

    # 5. Classify enforcement status
    if plugin_mode and enforce_registered:
        # Plugin mode: all @enforced directives are covered dynamically
        enforced = list(enforceable)
        unenforced = []
    elif existing_scripts:
        # Per-rule mode: match scripts to directives by filename pattern
        enforced = []
        unenforced = []
        seen_names = set()
        for i, d in enumerate(enforceable):
            expected_name = hook_filename(d, i, set())
            expected_path = str(hooks_dir / expected_name)
            if expected_path in existing_scripts:
                enforced.append(d)
                existing_scripts.discard(expected_path)
            else:
                unenforced.append(d)
        orphan_scripts = existing_scripts  # Remaining scripts match nothing
    else:
        enforced = []
        unenforced = list(enforceable)

    # 6. Find orphan hooks (per-rule scripts that don't match any directive)
    orphan_hooks = []
    if not plugin_mode:
        orphan_hooks = sorted(existing_scripts) if existing_scripts else []

    # 7. Find broken references (settings point to missing files)
    broken_refs = []
    for cmd in settings_hooks:
        if not Path(cmd).exists():
            broken_refs.append(cmd)

    return {
        'enforced': enforced,
        'unenforced': unenforced,
        'suggestions': suggestions,
        'orphan_hooks': orphan_hooks,
        'broken_refs': broken_refs,
        'plugin_mode': plugin_mode,
        'plugin_registered': enforce_registered,
        'settings_hooks': settings_hooks,
        'skipped': skipped,
    }


def format_audit_report(audit):
    """Format audit results as a readable report."""
    lines = []

    # Status header
    if audit['plugin_mode'] and audit['plugin_registered']:
        lines.append("enforce-hooks: ACTIVE (plugin mode)")
        lines.append("  All @enforced rules are checked on every tool call.\n")
    elif audit['plugin_mode'] and not audit['plugin_registered']:
        lines.append("enforce-hooks: WARNING (plugin files exist but not registered)")
        lines.append("  Run --install-plugin to register the hook.\n")
    elif audit['enforced']:
        lines.append("enforce-hooks: ACTIVE (per-rule mode)")
        lines.append(f"  {len(audit['enforced'])} individual hook script(s) installed.\n")
    else:
        lines.append("enforce-hooks: NOT INSTALLED")
        lines.append("  No enforcement active. Run --install-plugin to set up.\n")

    # Enforced rules
    enforced = audit['enforced']
    if enforced:
        lines.append(f"Enforced ({len(enforced)}):")
        for d in enforced:
            sev_tag = ' [warn]' if d.severity == 'warn' else ''
            lines.append(f"  [ok]  {d.hook_type:<18}  {d.description}{sev_tag}")

    # Unenforced rules (tagged @enforced but no hook)
    unenforced = audit['unenforced']
    if unenforced:
        lines.append(f"\nNot enforced ({len(unenforced)}):")
        for d in unenforced:
            sev_tag = ' [warn]' if d.severity == 'warn' else ''
            lines.append(f"  [!!]  {d.hook_type:<18}  {d.description}{sev_tag}")
        if not audit['plugin_mode']:
            lines.append("  Fix: run --install or --install-plugin")

    # Suggestions (classifiable but not tagged @enforced)
    suggestions = audit['suggestions']
    if suggestions:
        lines.append(f"\nCould be enforced ({len(suggestions)}):")
        for s in suggestions:
            lines.append(f"  [--]  {s.hook_type:<18}  {s.description}  (L{s.line_num})")
        lines.append("  Add @enforced to activate: \"Never modify .env files @enforced\"")

    # Skipped (tagged @enforced but not classifiable)
    skipped = audit['skipped']
    if skipped:
        lines.append(f"\nUnclassifiable ({len(skipped)}):")
        for line_num, text, reason in skipped:
            lines.append(f"  [??]  L{line_num}: {text[:55]}  ({reason})")

    # Orphan hooks
    orphans = audit['orphan_hooks']
    if orphans:
        lines.append(f"\nOrphan hooks ({len(orphans)}):")
        for o in orphans:
            lines.append(f"  [~~]  {o}")
        lines.append("  These hook scripts don't match any current CLAUDE.md rule.")

    # Broken references
    broken = audit['broken_refs']
    if broken:
        lines.append(f"\nBroken references ({len(broken)}):")
        for b in broken:
            lines.append(f"  [XX]  {b}")
        lines.append("  settings.json points to files that don't exist. Re-run --install-plugin.")

    # Summary line
    total_rules = len(enforced) + len(unenforced) + len(suggestions)
    coverage = (len(enforced) / total_rules * 100) if total_rules > 0 else 0
    lines.append(f"\nCoverage: {len(enforced)}/{total_rules} classifiable rules enforced ({coverage:.0f}%)")

    return '\n'.join(lines)


# --- Hook Verification ---

def verify_hooks(hooks_dir='.claude/hooks', settings_path='.claude/settings.json'):
    """Verify installed hooks for correctness issues.

    Checks every hook script in hooks_dir for:
      - Executable permission (+x)
      - Valid shebang line
      - Wrong field name (.input.X instead of .tool_input.X)
      - Fail-open on empty values (gets empty string, exits 0)
      - JSON parsing method (jq, python, etc.)
      - Settings.json registration

    Returns a dict with:
      hooks: list of dicts, one per hook file, each with 'path', 'issues', 'info'
      settings_issues: list of issues with settings.json
      summary: dict with counts
    """
    hooks_dir = Path(hooks_dir)
    settings_path = Path(settings_path)

    results = []
    settings_issues = []

    # 1. Read settings.json to find registered hooks (handles JSONC)
    registered_commands = set()
    try:
        settings = load_settings_json(settings_path)
        for event_type in settings.get('hooks', {}):
            for entry in settings.get('hooks', {}).get(event_type, []):
                for h in entry.get('hooks', []):
                    cmd = h.get('command', '')
                    if cmd:
                        registered_commands.add(cmd)
    except (KeyError, Exception):
        settings_issues.append({
            'severity': 'error',
            'message': f'Cannot parse {settings_path}',
        })

    # 2. Scan hook files
    if not hooks_dir.exists():
        return {
            'hooks': [],
            'settings_issues': settings_issues + [{
                'severity': 'info',
                'message': f'No hooks directory found at {hooks_dir}',
            }],
            'summary': {'total': 0, 'ok': 0, 'warnings': 0, 'errors': 0},
        }

    hook_files = sorted(f for f in hooks_dir.iterdir() if f.is_file() and not f.name.startswith('.'))

    for hook_path in hook_files:
        hook_result = {
            'path': str(hook_path),
            'name': hook_path.name,
            'issues': [],
            'info': [],
        }

        # Read content
        try:
            content = hook_path.read_text(errors='replace')
        except Exception as e:
            hook_result['issues'].append({
                'severity': 'error',
                'check': 'readable',
                'message': f'Cannot read file: {e}',
            })
            results.append(hook_result)
            continue

        lines = content.split('\n')

        # Check: executable permission
        if not os.access(str(hook_path), os.X_OK):
            hook_result['issues'].append({
                'severity': 'error',
                'check': 'executable',
                'message': 'Not executable. Fix: chmod +x ' + str(hook_path),
            })

        # Check: shebang
        if lines and lines[0].startswith('#!'):
            shebang = lines[0]
            hook_result['info'].append({'check': 'shebang', 'value': shebang})
            # Check for common bad shebangs
            if '/usr/bin/bash' in shebang and sys.platform == 'darwin':
                hook_result['issues'].append({
                    'severity': 'warn',
                    'check': 'shebang',
                    'message': 'Uses /usr/bin/bash (may not exist on macOS). Prefer /bin/bash or #!/usr/bin/env bash.',
                })
        elif not hook_path.suffix == '.json':
            hook_result['issues'].append({
                'severity': 'warn',
                'check': 'shebang',
                'message': 'No shebang line. Hook may not execute correctly.',
            })

        # Check: .input.X vs .tool_input.X (the chris-peterson bug)
        # This is the critical check. Claude Code sends tool_input, not input.
        wrong_field_lines = []
        correct_field_lines = []
        for i, line in enumerate(lines, 1):
            # Skip comments
            stripped = line.lstrip()
            if stripped.startswith('#') or stripped.startswith('//'):
                continue
            # Detect jq patterns: .input.command, .input.file_path, etc.
            # Also detect Python patterns: ['input'], .get('input')
            # jq-style: .input.something (but NOT .tool_input.something)
            for m in re.finditer(r'(?<!\w)\.input\.(\w+)', line):
                # Make sure it's not part of .tool_input.
                pos = m.start()
                prefix = line[max(0, pos-5):pos]
                if 'tool_' not in prefix:
                    wrong_field_lines.append((i, m.group(0), line.strip()[:80]))
            # Python dict-style: ['input'] or .get('input') (but not ['tool_input'])
            for m in re.finditer(r"""\[['"]input['"]\]|\.get\(['"]input['"]""", line):
                pos = m.start()
                prefix = line[max(0, pos-10):pos]
                if 'tool_' not in prefix:
                    wrong_field_lines.append((i, m.group(0), line.strip()[:80]))
            # Detect correct usage
            for m in re.finditer(r'\.tool_input\.\w+|tool_input|tool_input', line):
                correct_field_lines.append(i)

        if wrong_field_lines:
            hook_result['issues'].append({
                'severity': 'error',
                'check': 'field_name',
                'message': (
                    f'Uses .input.X instead of .tool_input.X ({len(wrong_field_lines)} occurrence(s)). '
                    'Claude Code sends tool arguments in tool_input, not input. '
                    'This hook silently fails open (gets empty values, never blocks).'
                ),
                'details': [
                    {'line': ln, 'match': match, 'context': ctx}
                    for ln, match, ctx in wrong_field_lines
                ],
            })
        elif correct_field_lines:
            hook_result['info'].append({
                'check': 'field_name',
                'value': f'Uses tool_input correctly ({len(correct_field_lines)} reference(s))',
            })

        # Check: fail-open pattern (empty string check followed by exit 0)
        # Common pattern: if [ -z "$VAR" ]; then exit 0; fi
        # This is dangerous if the var is empty because the field name is wrong
        fail_open_count = 0
        for i, line in enumerate(lines, 1):
            stripped = line.strip()
            if re.match(r'if\s+\[\s+-z\s+"?\$\w+"?\s*\]', stripped):
                # Look at the next few lines for exit 0
                for j in range(i, min(i + 3, len(lines))):
                    if 'exit 0' in lines[j-1]:  # Lines are 0-indexed in the list
                        fail_open_count += 1
                        break
        if fail_open_count > 0 and wrong_field_lines:
            hook_result['issues'].append({
                'severity': 'error',
                'check': 'fail_open',
                'message': (
                    f'Combines wrong field name with fail-open pattern ({fail_open_count} instance(s)). '
                    'Hook reads empty value from wrong field, then exits 0 (allow). '
                    'This hook never actually blocks anything.'
                ),
            })
        elif fail_open_count > 0:
            hook_result['info'].append({
                'check': 'fail_open',
                'value': f'{fail_open_count} empty-check exit(s) (safe if field names are correct)',
            })

        # Check: JSON parsing method
        uses_jq = 'jq ' in content or 'jq\t' in content or content.endswith('jq')
        uses_python_json = 'json.loads' in content or 'json.load' in content
        if uses_jq:
            hook_result['info'].append({'check': 'json_parser', 'value': 'jq'})
        elif uses_python_json:
            hook_result['info'].append({'check': 'json_parser', 'value': 'python json'})
        elif hook_path.suffix in ('.sh', '.bash', ''):
            # Shell script without jq is suspicious
            if 'tool_name' in content or 'tool_input' in content or 'input' in content:
                hook_result['issues'].append({
                    'severity': 'warn',
                    'check': 'json_parser',
                    'message': 'Shell hook references tool data but does not use jq or python for JSON parsing.',
                })

        # Check: registered in settings.json
        is_registered = False
        for cmd in registered_commands:
            if hook_path.name in cmd or str(hook_path) in cmd:
                is_registered = True
                break
        if not is_registered:
            hook_result['issues'].append({
                'severity': 'warn',
                'check': 'registration',
                'message': f'Not registered in {settings_path}. Hook will not fire.',
            })

        results.append(hook_result)

    # 3. Check settings references point to existing files
    for cmd in registered_commands:
        # Extract file path from command (first token or path-like segment)
        parts = cmd.split()
        for part in parts:
            if '/' in part and not part.startswith('-'):
                if not Path(part).exists():
                    settings_issues.append({
                        'severity': 'error',
                        'message': f'settings.json references missing file: {part}',
                    })
                break

    # Summary
    total_errors = sum(
        1 for h in results for i in h['issues'] if i['severity'] == 'error'
    )
    total_warnings = sum(
        1 for h in results for i in h['issues'] if i['severity'] == 'warn'
    )
    ok_hooks = sum(1 for h in results if not h['issues'])

    return {
        'hooks': results,
        'settings_issues': settings_issues,
        'summary': {
            'total': len(results),
            'ok': ok_hooks,
            'warnings': total_warnings,
            'errors': total_errors,
        },
    }


def format_verify_report(result):
    """Format verification results as a readable report."""
    lines = []
    summary = result['summary']

    lines.append(f"Hook Health Check: {summary['total']} hook(s) scanned\n")

    for hook in result['hooks']:
        has_errors = any(i['severity'] == 'error' for i in hook['issues'])
        has_warnings = any(i['severity'] == 'warn' for i in hook['issues'])
        if has_errors:
            status = 'FAIL'
        elif has_warnings:
            status = 'WARN'
        else:
            status = 'OK'

        lines.append(f"  [{status:>4}]  {hook['name']}")

        for issue in hook['issues']:
            marker = 'ERR ' if issue['severity'] == 'error' else 'WARN'
            lines.append(f"         [{marker}] {issue['message']}")
            if 'details' in issue:
                for d in issue['details'][:3]:  # Show max 3 examples
                    lines.append(f"                L{d['line']}: {d['context']}")

    # Settings issues
    if result['settings_issues']:
        lines.append(f"\nSettings issues:")
        for si in result['settings_issues']:
            lines.append(f"  [{si['severity'].upper():>4}]  {si['message']}")

    # Summary
    lines.append(f"\nSummary: {summary['ok']} ok, {summary['warnings']} warning(s), {summary['errors']} error(s)")

    if summary['errors'] > 0:
        lines.append("\nMost common fix: replace .input.X with .tool_input.X in hook scripts.")
        lines.append("See: https://github.com/anthropics/claude-code/issues/32163")

    return '\n'.join(lines)


def smoke_test_hooks(hooks_dir='.claude/hooks', settings_path='.claude/settings.json'):
    """Run each registered hook with real test payloads and verify it responds correctly.

    Unlike --verify (static analysis), this actually executes hooks and checks:
      - Hook runs without crashing
      - Output is valid JSON
      - JSON contains a 'decision' field
      - Benign payloads get 'allow' (not false-positive blocking)
      - Known-bad payloads get 'block' where detectable

    Returns a dict with per-hook results and summary.
    """
    hooks_dir = Path(hooks_dir)
    settings_path = Path(settings_path)

    results = []
    settings_issues = []

    # Benign test payloads that should be allowed by any hook
    BENIGN_PAYLOADS = [
        {
            'label': 'Read a normal file',
            'payload': {"tool_name": "Read", "tool_input": {"file_path": "/tmp/smoke-test.txt"}},
        },
        {
            'label': 'Write to a temp file',
            'payload': {"tool_name": "Write", "tool_input": {"file_path": "/tmp/smoke-test-out.txt", "content": "test"}},
        },
        {
            'label': 'Run a safe Bash command',
            'payload': {"tool_name": "Bash", "tool_input": {"command": "echo hello"}},
        },
    ]

    # Payloads that should be blocked (for hooks we can identify)
    BLOCK_PAYLOADS = {
        'file-guard': {
            'label': 'Write to .env',
            'payload': {"tool_name": "Write", "tool_input": {"file_path": ".env", "content": "SECRET=x"}},
        },
        'bash-guard': {
            'label': 'Run rm -rf /',
            'payload': {"tool_name": "Bash", "tool_input": {"command": "rm -rf /"}},
        },
        'git-safe': {
            'label': 'Force push',
            'payload': {"tool_name": "Bash", "tool_input": {"command": "git push --force origin main"}},
        },
        'branch-guard': {
            'label': 'Commit on main',
            'payload': {"tool_name": "Bash", "tool_input": {"command": "git commit -m 'test'"}},
        },
    }

    # 1. Read settings.json to find registered hooks (handles JSONC)
    registered = []  # list of (event_type, command)
    if settings_path.exists():
        try:
            settings = load_settings_json(settings_path)
            for event_type, entries in settings.get('hooks', {}).items():
                for entry in entries:
                    for h in entry.get('hooks', []):
                        cmd = h.get('command', '')
                        if cmd:
                            registered.append((event_type, cmd))
        except (KeyError, Exception) as e:
            settings_issues.append(f'Cannot parse {settings_path}: {e}')
    else:
        return {
            'hooks': [],
            'settings_issues': [f'No settings file at {settings_path}'],
            'summary': {'total': 0, 'passed': 0, 'failed': 0, 'warnings': 0},
        }

    if not registered:
        return {
            'hooks': [],
            'settings_issues': ['No hooks registered in settings.json'],
            'summary': {'total': 0, 'passed': 0, 'failed': 0, 'warnings': 0},
        }

    # 2. Test each hook
    for event_type, command in registered:
        hook_result = {
            'command': command,
            'event_type': event_type,
            'tests': [],
            'status': 'ok',
        }

        # Identify the hook type from the command path
        hook_type = None
        cmd_lower = command.lower()
        for ht in ['file-guard', 'bash-guard', 'git-safe', 'branch-guard', 'enforce', 'session-log', 'read-once', 'armor']:
            if ht in cmd_lower:
                hook_type = ht
                break

        # Run benign payloads
        for bp in BENIGN_PAYLOADS:
            test_result = _run_hook_test(command, bp['payload'], bp['label'])
            test_result['expect'] = 'allow'

            if test_result['status'] == 'error':
                hook_result['status'] = 'fail'
            elif test_result['status'] == 'blocked':
                # Benign payload was blocked = false positive
                test_result['status'] = 'false_positive'
                test_result['message'] = f"Benign payload blocked: {test_result.get('reason', 'unknown')}"
                if hook_result['status'] != 'fail':
                    hook_result['status'] = 'warn'

            hook_result['tests'].append(test_result)

        # Run block payload if we identified the hook type
        if hook_type and hook_type in BLOCK_PAYLOADS:
            bp = BLOCK_PAYLOADS[hook_type]
            test_result = _run_hook_test(command, bp['payload'], bp['label'])
            test_result['expect'] = 'block'

            if test_result['status'] == 'error':
                hook_result['status'] = 'fail'
            elif test_result['status'] == 'allowed':
                # Bad payload was allowed = hook not working
                test_result['status'] = 'fail_open'
                test_result['message'] = 'Hook allowed a payload it should have blocked'
                hook_result['status'] = 'fail'

            hook_result['tests'].append(test_result)

        results.append(hook_result)

    # Summary
    passed = sum(1 for r in results if r['status'] == 'ok')
    failed = sum(1 for r in results if r['status'] == 'fail')
    warnings = sum(1 for r in results if r['status'] == 'warn')

    return {
        'hooks': results,
        'settings_issues': settings_issues,
        'summary': {
            'total': len(results),
            'passed': passed,
            'failed': failed,
            'warnings': warnings,
        },
    }


def _run_hook_test(command, payload, label):
    """Execute a single hook with a test payload and check the response."""
    result = {
        'label': label,
        'status': 'ok',
        'raw_output': '',
        'decision': None,
        'reason': None,
    }

    try:
        proc = subprocess.run(
            command,
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            timeout=5,
            shell=True,
        )

        result['raw_output'] = (proc.stdout or '')[:500]
        result['exit_code'] = proc.returncode
        stderr = (proc.stderr or '')[:200]
        if stderr:
            result['stderr'] = stderr

        # Non-zero exit = hook crashed
        if proc.returncode != 0 and not proc.stdout.strip():
            result['status'] = 'error'
            result['message'] = f'Exit code {proc.returncode}'
            if stderr:
                result['message'] += f': {stderr[:100]}'
            return result

        stdout = (proc.stdout or '').strip()

        # Empty output = hook produced nothing (fail-open)
        if not stdout:
            result['status'] = 'error'
            result['message'] = 'No output (hook is fail-open: empty stdout = allow)'
            return result

        # Parse JSON
        try:
            parsed = json.loads(stdout)
        except json.JSONDecodeError:
            result['status'] = 'error'
            result['message'] = f'Invalid JSON output: {stdout[:100]}'
            return result

        # Check for decision field
        decision = parsed.get('decision')
        if decision is None:
            result['status'] = 'error'
            result['message'] = f'Missing "decision" field in output: {stdout[:100]}'
            return result

        result['decision'] = decision
        result['reason'] = parsed.get('reason', '')

        if decision == 'block':
            result['status'] = 'blocked'
        elif decision == 'allow':
            result['status'] = 'allowed'
        else:
            result['status'] = 'warn'
            result['message'] = f'Unknown decision value: {decision}'

    except subprocess.TimeoutExpired:
        result['status'] = 'error'
        result['message'] = 'Hook timed out after 5 seconds'
    except FileNotFoundError:
        result['status'] = 'error'
        result['message'] = f'Command not found: {command}'
    except Exception as e:
        result['status'] = 'error'
        result['message'] = f'Unexpected error: {e}'

    return result


def format_smoke_test_report(result):
    """Format smoke test results as a readable report."""
    lines = []
    summary = result['summary']

    lines.append(f"Smoke Test: {summary['total']} hook(s) tested\n")

    for hook in result['hooks']:
        if hook['status'] == 'ok':
            status = 'PASS'
        elif hook['status'] == 'warn':
            status = 'WARN'
        else:
            status = 'FAIL'

        # Short name from command
        cmd = hook['command']
        name = Path(cmd.split()[0]).name if cmd else '???'
        lines.append(f"  [{status:>4}]  {name}  ({hook['event_type']})")

        for test in hook['tests']:
            if test['status'] in ('allowed', 'blocked') and test['status'] == test['expect'].replace('allow', 'allowed').replace('block', 'blocked'):
                # Expected result
                icon = 'OK'
            elif test['status'] == 'error':
                icon = 'ERR'
            elif test.get('message', '').startswith('Benign'):
                icon = 'FP'  # false positive
            elif test['status'] == 'fail_open':
                icon = 'OPEN'  # fail-open
            else:
                icon = 'OK'

            detail = ''
            if test.get('message'):
                detail = f'  -- {test["message"]}'
            elif test.get('decision'):
                detail = f'  -> {test["decision"]}'

            lines.append(f"         [{icon:>4}] {test['label']}{detail}")

    if result['settings_issues']:
        lines.append(f"\nSettings issues:")
        for si in result['settings_issues']:
            lines.append(f"  {si}")

    lines.append(f"\nSummary: {summary['passed']} passed, {summary['warnings']} warning(s), {summary['failed']} failed")

    if summary['failed'] > 0:
        lines.append("\nFailed hooks are not protecting your project.")
        lines.append("Common causes:")
        lines.append("  - Wrong JSON field: .input.X instead of .tool_input.X")
        lines.append("  - Missing jq: install with 'brew install jq' or 'apt install jq'")
        lines.append("  - Not executable: chmod +x <hook-path>")
        lines.append("  - Empty output on error: hook exits silently instead of printing JSON")

    return '\n'.join(lines)


# --- Output Formatting ---

def format_scan_table(enforceable, skipped):
    """Format scan results as a readable table."""
    lines = []
    if enforceable:
        lines.append(f"Found {len(enforceable)} enforceable directive(s):\n")
        lines.append(f"{'#':>3}  {'Type':<20}  {'What it does':<40}  {'Severity':<8}  {'Source line'}")
        lines.append(f"{'---':>3}  {'----':<20}  {'---':<40}  {'---':<8}  {'---'}")
        for i, d in enumerate(enforceable, 1):
            lines.append(f"{i:>3}  {d.hook_type:<20}  {d.description:<40}  {d.severity:<8}  L{d.line_num}")
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
    check("require-prior basic", d is not None and d.hook_type in ('require-prior-tool', 'require-prior-command'), True)

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
    check("hook has block", hook is not None and 'block' in hook, True)

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

    # --- evaluate_tool_call tests ---
    def section(name):
        pass  # silent sections, only failures print

    section("evaluate: file-guard")
    d = Directive("Never modify .env files", "file-guard", [".env"], "protect env", 1)
    r = evaluate_tool_call([d], "Write", {"file_path": "/project/.env"})
    check("eval: blocks Write to .env", r["decision"], "block")
    r = evaluate_tool_call([d], "Edit", {"file_path": "/project/.env"})
    check("eval: blocks Edit to .env", r["decision"], "block")
    r = evaluate_tool_call([d], "MultiEdit", {"file_path": "/project/.env"})
    check("eval: blocks MultiEdit to .env", r["decision"], "block")
    r = evaluate_tool_call([d], "Write", {"file_path": "/project/app.py"})
    check("eval: allows Write to app.py", r["decision"], "allow")
    r = evaluate_tool_call([d], "Bash", {"command": "echo hi"})
    check("eval: ignores Bash for file-guard", r["decision"], "allow")
    r = evaluate_tool_call([d], "Read", {"file_path": "/project/.env"})
    check("eval: allows Read .env (no read verb)", r["decision"], "allow")

    d2 = Directive("Don't read files in secrets/", "file-guard", ["secrets/"], "protect secrets", 2)
    r = evaluate_tool_call([d2], "Read", {"file_path": "/project/secrets/key.pem"})
    check("eval: blocks Read secrets/ (read verb)", r["decision"], "block")
    r = evaluate_tool_call([d2], "Write", {"file_path": "/project/secrets/key.pem"})
    check("eval: blocks Write secrets/ too", r["decision"], "block")
    r = evaluate_tool_call([d2], "Read", {"file_path": "/project/src/main.py"})
    check("eval: allows Read non-secrets", r["decision"], "allow")

    section("evaluate: bash-guard")
    d = Directive("Never run rm -rf", "bash-guard", ["rm -rf"], "block rm", 3)
    r = evaluate_tool_call([d], "Bash", {"command": "rm -rf /"})
    check("eval: blocks rm -rf", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "RM -RF /tmp"})
    check("eval: blocks rm -rf case-insensitive", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "ls -la"})
    check("eval: allows ls", r["decision"], "allow")
    r = evaluate_tool_call([d], "Write", {"file_path": "x"})
    check("eval: ignores Write for bash-guard", r["decision"], "allow")

    d = Directive("Don't use sudo", "bash-guard", ["sudo"], "block sudo", 4)
    r = evaluate_tool_call([d], "Bash", {"command": "sudo apt install vim"})
    check("eval: blocks sudo", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "apt install vim"})
    check("eval: allows non-sudo", r["decision"], "allow")

    section("evaluate: tool-block")
    d = Directive("Don't use WebSearch", "tool-block", ["WebSearch"], "block web", 5)
    r = evaluate_tool_call([d], "WebSearch", {})
    check("eval: blocks WebSearch", r["decision"], "block")
    r = evaluate_tool_call([d], "Read", {})
    check("eval: allows Read", r["decision"], "allow")
    r = evaluate_tool_call([d], "WebFetch", {})
    check("eval: allows WebFetch (not blocked)", r["decision"], "allow")

    d = Directive("Don't use WebSearch or WebFetch", "tool-block", ["WebSearch", "WebFetch"], "block web", 6)
    r = evaluate_tool_call([d], "WebSearch", {})
    check("eval: multi-tool blocks WebSearch", r["decision"], "block")
    r = evaluate_tool_call([d], "WebFetch", {})
    check("eval: multi-tool blocks WebFetch", r["decision"], "block")
    r = evaluate_tool_call([d], "Grep", {})
    check("eval: multi-tool allows Grep", r["decision"], "allow")

    section("evaluate: branch-guard")
    d = Directive("Never commit to main", "branch-guard", ["main"], "protect main", 7)
    r = evaluate_tool_call([d], "Bash", {"command": "ls -la"})
    check("eval: branch-guard ignores non-git", r["decision"], "allow")
    r = evaluate_tool_call([d], "Write", {"file_path": "x"})
    check("eval: branch-guard ignores Write", r["decision"], "allow")

    section("evaluate: multiple directives")
    d1 = Directive("Never modify .env", "file-guard", [".env"], "protect env", 1)
    d2 = Directive("Never run rm -rf", "bash-guard", ["rm -rf"], "block rm", 2)
    d3 = Directive("Don't use WebSearch", "tool-block", ["WebSearch"], "block web", 3)
    all_d = [d1, d2, d3]
    r = evaluate_tool_call(all_d, "Bash", {"command": "rm -rf /"})
    check("eval: multi matches bash-guard", r["decision"], "block")
    r = evaluate_tool_call(all_d, "Write", {"file_path": ".env"})
    check("eval: multi matches file-guard", r["decision"], "block")
    r = evaluate_tool_call(all_d, "WebSearch", {})
    check("eval: multi matches tool-block", r["decision"], "block")
    r = evaluate_tool_call(all_d, "Read", {"file_path": "app.py"})
    check("eval: multi allows unmatched", r["decision"], "allow")
    r = evaluate_tool_call(all_d, "Bash", {"command": "echo hello"})
    check("eval: multi allows safe bash", r["decision"], "allow")

    section("evaluate: empty/edge cases")
    r = evaluate_tool_call([], "Bash", {"command": "rm -rf /"})
    check("eval: no directives allows all", r["decision"], "allow")
    r = evaluate_tool_call([d1], "Write", {})
    check("eval: no file_path allows", r["decision"], "allow")
    r = evaluate_tool_call([d2], "Bash", {})
    check("eval: no command allows", r["decision"], "allow")

    section("evaluate: require-prior-tool targets Edit correctly (BUG 1 fix)")
    d = Directive("Always read before editing", "require-prior-tool", ["Read", "Edit"], "read first", 50)
    r = evaluate_tool_call([d], "Edit", {"file_path": "/project/app.py"})
    check("eval: require-prior-tool targets Edit not Bash", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "echo hello"})
    check("eval: require-prior-tool ignores Bash for Edit target", r["decision"], "allow")

    d = Directive("Always read before writing", "require-prior-tool", ["Read", "Write"], "read first", 51)
    r = evaluate_tool_call([d], "Write", {"file_path": "/project/app.py", "content": "x"})
    check("eval: require-prior-tool targets Write not Bash", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "ls"})
    check("eval: require-prior-tool ignores Bash for Write target", r["decision"], "allow")

    section("evaluate: require-prior-command handled (BUG 2 fix)")
    d = Directive("Always run tests before committing", "require-prior-command",
                  ["test", "committing"], "test before commit", 52)
    r = evaluate_tool_call([d], "Bash", {"command": "git commit -m 'fix'"})
    check("eval: require-prior-command blocks git commit", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "echo hello"})
    check("eval: require-prior-command allows non-commit", r["decision"], "allow")
    r = evaluate_tool_call([d], "Write", {"file_path": "x", "content": "y"})
    check("eval: require-prior-command ignores Write", r["decision"], "allow")

    section("evaluate: bash-guard force-push precision (BUG 3 fix)")
    d = Directive("Don't force push", "bash-guard", ["force push", "push --force", "push -f"],
                  "no force push", 53)
    r = evaluate_tool_call([d], "Bash", {"command": "git push --force origin main"})
    check("eval: force-push blocks push --force", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "git push -f origin main"})
    check("eval: force-push blocks push -f", r["decision"], "block")
    r = evaluate_tool_call([d], "Bash", {"command": "git push origin feature-branch"})
    check("eval: force-push allows normal push", r["decision"], "allow")
    r = evaluate_tool_call([d], "Bash", {"command": "npm run push-notification"})
    check("eval: force-push allows unrelated push", r["decision"], "allow")
    r = evaluate_tool_call([d], "Bash", {"command": "docker push myimage:latest"})
    check("eval: force-push allows docker push", r["decision"], "allow")

    section("evaluate: cache round-trip")
    import tempfile
    with tempfile.TemporaryDirectory() as tmpdir:
        md = Path(tmpdir) / 'CLAUDE.md'
        md.write_text('- Never modify .env @enforced\n- Never run sudo @enforced\n')
        cache_dir = Path(tmpdir) / 'cache'
        cache_dir.mkdir()

        # No cache yet
        cached = load_cached_directives(str(md), str(cache_dir))
        check("eval: cache miss returns None", cached, None)

        # Scan and save
        enforceable, _ = scan_file(str(md))
        save_cached_directives(str(md), enforceable, str(cache_dir))

        # Cache hit
        cached = load_cached_directives(str(md), str(cache_dir))
        check("eval: cache hit returns list", cached is not None, True)
        check("eval: cache preserves count", len(cached) if cached else 0, len(enforceable))

        # Modify file invalidates cache
        import time
        time.sleep(0.05)
        md.write_text('- Never modify .env @enforced\n')
        cached = load_cached_directives(str(md), str(cache_dir))
        check("eval: mtime change invalidates cache", cached, None)

    # Test scan_suggestions (finds enforceable rules without @enforced tags)
    no_tags = """# Project Rules

## Safety
- Never modify .env or .env.local files
- Do not edit any file in the secrets/ directory
- Never run `rm -rf` commands
- Do not use `git push --force` or `git push -f`
- Never commit directly to main or master branch
- Always run tests before committing

## Style
- Use 4-space indentation
- Write clean code
"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write(no_tags)
        f.flush()
        enforceable_tagged, _ = scan_file(f.name)
        check("no-tag scan finds nothing", len(enforceable_tagged), 0)

        suggestions = scan_suggestions(f.name)
        check("suggestions finds rules", len(suggestions) >= 4, True)
        stypes = {d.hook_type for d in suggestions}
        check("suggestions has file-guard", 'file-guard' in stypes, True)
        check("suggestions has bash-guard", 'bash-guard' in stypes, True)
        check("suggestions has branch-guard", 'branch-guard' in stypes, True)
        os.unlink(f.name)

    # Test suggestions ignores code blocks and headers
    code_block_md = """# Rules

## Safety
- Never modify .env files

```bash
rm -rf /tmp/test
```

- Never run `sudo` commands
"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write(code_block_md)
        f.flush()
        suggestions = scan_suggestions(f.name)
        texts = [d.text for d in suggestions]
        check("suggestions skips code blocks", not any('tmp/test' in t for t in texts), True)
        check("suggestions finds sudo rule", len(suggestions) >= 1, True)
        os.unlink(f.name)

    # --- Content-guard tests ---

    # Classification
    d = classify_directive("Never write `console.log` in production code", 80)
    check("content-guard console.log", d is not None and d.hook_type == 'content-guard', True)
    check("content-guard console.log pattern", d is not None and d.patterns == ['console.log'], True)

    d = classify_directive("Don't use the `any` type in TypeScript files", 81)
    check("content-guard any type", d is not None and d.hook_type == 'content-guard', True)
    check("content-guard any pattern", d is not None and d.patterns == ['any'], True)

    d = classify_directive("Never include `debugger` statements in code", 82)
    check("content-guard debugger", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Don't use `eval()` in production code", 83)
    check("content-guard eval", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Avoid `var` keyword in JavaScript", 84)
    check("content-guard var keyword", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("No `console.log` statements", 85)
    check("content-guard no-statements", d is not None and d.hook_type == 'content-guard', True)

    # Content-guard should NOT match command-like patterns
    d = classify_directive("Never run `rm -rf /`", 86)
    check("content-guard not rm", d is not None and d.hook_type == 'bash-guard', True)

    # Hook generation
    d = Directive(
        text="Never write `console.log` @enforced",
        hook_type='content-guard',
        patterns=['console.log'],
        description="Block writing: console.log",
        line_num=1,
    )
    hook = generate_hook(d)
    check("content-guard hook generated", hook is not None, True)
    check("content-guard hook has grep", 'grep' in hook, True)
    check("content-guard hook has console.log", 'console.log' in hook, True)
    check("content-guard hook checks Edit", 'Edit' in hook, True)
    check("content-guard hook checks Write", 'Write' in hook, True)

    # Evaluate mode
    d = Directive(
        text="Never write `console.log` @enforced",
        hook_type='content-guard',
        patterns=['console.log'],
        description="Block writing: console.log",
        line_num=1,
    )
    result = _check_single(d, 'Edit', {'new_string': 'console.log("debug")', 'file_path': 'app.js', 'old_string': ''})
    check("content-guard evaluate blocks", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': 'function hello() { return 1; }', 'file_path': 'app.js'})
    check("content-guard evaluate allows clean", result is None, True)

    result = _check_single(d, 'Write', {'content': 'console.log("test")\nreturn 1;', 'file_path': 'app.js'})
    check("content-guard evaluate blocks write", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Bash', {'command': 'echo hello'})
    check("content-guard ignores bash", result is None, True)

    result = _check_single(d, 'Read', {'file_path': 'app.js'})
    check("content-guard ignores read", result is None, True)

    # --- Bare code identifier tests (no backticks) ---

    d = classify_directive("Never write console.log in production code", 200)
    check("bare console.log detected", d is not None and d.hook_type == 'content-guard', True)
    check("bare console.log pattern", d is not None and 'console.log' in (d.patterns[0] if d else ''), True)

    d = classify_directive("Never use eval() in any file", 201)
    check("bare eval() detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Don't use exec() in production code", 202)
    check("bare exec() detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Avoid debugger in JavaScript files", 203)
    check("bare debugger detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Don't include document.write in any page", 204)
    check("bare document.write detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("No console.log", 205)
    check("bare no-console.log detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Avoid innerHTML assignments", 206)
    check("bare innerHTML detected", d is not None and d.hook_type == 'content-guard', True)

    # Bare identifiers should NOT steal from bash-guard
    d = classify_directive("Never run rm -rf /", 207)
    check("bare rm still bash-guard", d is not None and d.hook_type == 'bash-guard', True)

    # --- "After every change" require-prior tests ---

    d = classify_directive("Run npm test after every code change", 210)
    check("after-change detected", d is not None and d.hook_type in ('require-prior-tool', 'require-prior-command'), True)
    check("after-change has npm test", d is not None and 'npm test' in str(d.patterns), True)

    d = classify_directive("Always run pytest after each modification", 211)
    check("after-modification detected", d is not None and d.hook_type in ('require-prior-tool', 'require-prior-command'), True)

    # --- "Push without PR" bash-guard tests ---

    d = classify_directive("Do not push to origin without creating a PR first", 220)
    check("push-without-pr detected", d is not None and d.hook_type == 'bash-guard', True)
    check("push-without-pr has push", d is not None and any('push' in p for p in (d.patterns if d else [])), True)

    d = classify_directive("Never push without opening a pull request", 221)
    check("push-without-pr variant", d is not None and d.hook_type == 'bash-guard', True)

    # --- Top-level heading @enforced propagation ---

    toplevel_md = """# Rules @enforced

- Never modify .env files
- Don't push to main directly
"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write(toplevel_md)
        f.flush()
        enforced, skipped = scan_file(f.name)
        check("toplevel @enforced propagates", len(enforced) >= 2, True)
        types = [d.hook_type for d in enforced]
        check("toplevel has file-guard", 'file-guard' in types, True)
        check("toplevel has branch-guard", 'branch-guard' in types, True)
        os.unlink(f.name)

    # --- Lock file detection tests ---

    d = classify_directive("Protected files: package-lock.json, yarn.lock", 90)
    check("lock-files detected", d is not None and d.hook_type == 'file-guard', True)
    check("lock-files has package-lock", d is not None and 'package-lock.json' in d.patterns, True)
    check("lock-files has yarn.lock", d is not None and 'yarn.lock' in d.patterns, True)

    d = classify_directive("Never modify Gemfile.lock or Cargo.lock", 91)
    check("lock-files gemfile", d is not None and d.hook_type == 'file-guard', True)
    check("lock-files has Gemfile.lock", d is not None and 'Gemfile.lock' in d.patterns, True)
    check("lock-files has Cargo.lock", d is not None and 'Cargo.lock' in d.patterns, True)

    d = classify_directive("Don't edit pnpm-lock.yaml or poetry.lock", 92)
    check("lock-files pnpm", d is not None and d.hook_type == 'file-guard', True)

    # --- .env variants ---

    d = classify_directive("Never modify .env.local files", 93)
    check("env-local detected", d is not None and d.hook_type == 'file-guard', True)

    # --- Read before editing ---

    d = classify_directive("Read the relevant test file before editing source code", 95)
    check("read-before-edit detected", d is not None and d.hook_type == 'require-prior-tool', True)
    check("read-before-edit requires Read", d is not None and d.patterns[0] == 'Read', True)

    d = classify_directive("Always read the spec before modifying implementation", 96)
    check("read-before-modify detected", d is not None and d.hook_type == 'require-prior-tool', True)

    # --- scan_suggestions UX: no @enforced but classifiable rules ---

    section("scan_suggestions")
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write("# Rules\n- Never modify .env files\n- Don't force push\n")
        tmp_path = f.name
    try:
        sugg = scan_suggestions(tmp_path)
        check("suggestions found without @enforced", len(sugg) >= 1, True)
        types = [s.hook_type for s in sugg]
        check("file-guard in suggestions", 'file-guard' in types, True)
        check("bash-guard in suggestions", 'bash-guard' in types, True)

        # Tagged version should find enforceable
        with open(tmp_path, 'w') as f:
            f.write("# Rules\n- Never modify .env files @enforced\n")
        enf, _ = scan_file(tmp_path)
        check("@enforced tags produce enforceable", len(enf) >= 1, True)
    finally:
        os.unlink(tmp_path)

    # Empty file should return no suggestions
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write("")
        tmp_path = f.name
    try:
        sugg = scan_suggestions(tmp_path)
        check("empty file: no suggestions", len(sugg), 0)
    finally:
        os.unlink(tmp_path)

    # --- Concept-based content-guard tests ---

    d = classify_directive("Never use inline styles in HTML files @enforced", 300)
    check("concept inline styles detected", d is not None and d.hook_type == 'content-guard', True)
    check("concept inline styles pattern", d is not None and d.patterns == ['style='], True)

    d = classify_directive("Don't use inline style attributes @enforced", 301)
    check("concept inline style singular", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Never use HEX color codes in CSS files @enforced", 302)
    check("concept hex color detected", d is not None and d.hook_type == 'content-guard', True)
    check("concept hex color pattern", d is not None and '#[0-9a-fA-F]' in (d.patterns[0] if d else ''), True)

    d = classify_directive("Avoid !important in stylesheets @enforced", 303)
    check("concept !important detected", d is not None and d.hook_type == 'content-guard', True)
    check("concept !important pattern", d is not None and d.patterns == ['!important'], True)

    d = classify_directive("No TODO comments in production code @enforced", 304)
    check("concept TODO detected", d is not None and d.hook_type == 'content-guard', True)
    check("concept TODO pattern", d is not None and d.patterns == ['TODO'], True)

    d = classify_directive("Never use eslint-disable comments @enforced", 305)
    check("concept eslint-disable detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("No ts-ignore directives @enforced", 306)
    check("concept ts-ignore detected", d is not None and d.hook_type == 'content-guard', True)

    d = classify_directive("Avoid wildcard imports @enforced", 307)
    check("concept wildcard import detected", d is not None and d.hook_type == 'content-guard', True)

    # Concept content-guard evaluate: inline styles
    d = Directive(
        text="Never use inline styles @enforced",
        hook_type='content-guard',
        patterns=['style='],
        description="Block writing: style=",
        line_num=1,
    )
    result = _check_single(d, 'Edit', {'new_string': '<div style="color: red">', 'file_path': 'app.html', 'old_string': ''})
    check("concept inline style blocks edit", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': '<div class="container">Hello</div>', 'file_path': 'app.html'})
    check("concept inline style allows clean", result is None, True)

    # Concept content-guard evaluate: HEX colors
    d = Directive(
        text="Never use HEX color codes @enforced",
        hook_type='content-guard',
        patterns=['#[0-9a-fA-F]'],
        description="Block writing: #[0-9a-fA-F]",
        line_num=1,
    )
    result = _check_single(d, 'Edit', {'new_string': 'color: #ff0000;', 'file_path': 'style.css', 'old_string': ''})
    check("concept hex color blocks edit", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': 'color: var(--primary);', 'file_path': 'style.css'})
    check("concept hex color allows clean", result is None, True)

    # Parenthetical example extraction
    d = classify_directive('Never use inline styles (style="...") in templates @enforced', 310)
    check("paren example detected", d is not None and d.hook_type == 'content-guard', True)

    # Concept should NOT steal from other guard types
    d = classify_directive("Never modify .env files @enforced", 320)
    check("concept doesn't steal file-guard", d is not None and d.hook_type == 'file-guard', True)

    d = classify_directive("Don't force push @enforced", 321)
    check("concept doesn't steal bash-guard", d is not None and d.hook_type == 'bash-guard', True)

    # --- Scoped content-guard tests ---

    # Classification: "only in" patterns
    d = classify_directive("Interfaces should only be defined in types/ folders @enforced", 400)
    check("scoped: interfaces only in types/", d is not None and d.hook_type == 'scoped-content-guard', True)
    check("scoped: path_filter is types/", d is not None and d.path_filter == ['types/'], True)
    check("scoped: path_mode is only_in", d is not None and d.path_mode == 'only_in', True)
    check("scoped: pattern is interface regex", d is not None and r'\binterface\s+\w+' in d.patterns[0], True)

    d = classify_directive("Only define classes in models/ @enforced", 401)
    check("scoped: classes only in models/", d is not None and d.hook_type == 'scoped-content-guard', True)
    check("scoped: models/ path", d is not None and d.path_filter == ['models/'], True)
    check("scoped: only_in mode", d is not None and d.path_mode == 'only_in', True)

    d = classify_directive("Enums should only be in constants/ directory @enforced", 402)
    check("scoped: enums only in constants/", d is not None and d.hook_type == 'scoped-content-guard', True)

    # Classification: "never in" patterns
    d = classify_directive("Never put SQL queries in controllers/ @enforced", 410)
    check("scoped: no SQL in controllers/", d is not None and d.hook_type == 'scoped-content-guard', True)
    check("scoped: never_in mode", d is not None and d.path_mode == 'never_in', True)
    check("scoped: controllers/ path", d is not None and d.path_filter == ['controllers/'], True)

    d = classify_directive("Don't use console.log in src/ @enforced", 411)
    check("scoped: no console.log in src/", d is not None and d.hook_type == 'scoped-content-guard', True)
    check("scoped: never_in console", d is not None and d.path_mode == 'never_in', True)

    # Classification: should NOT be scoped (no path)
    d = classify_directive("Never use inline styles @enforced", 420)
    check("scoped: no path stays content-guard", d is not None and d.hook_type == 'content-guard', True)

    # Evaluate: only_in mode - blocks interface outside types/
    d = Directive(
        text="Interfaces should only be defined in types/ @enforced",
        hook_type='scoped-content-guard',
        patterns=[r'\binterface\s+\w+'],
        description="Only allow interface in types/",
        line_num=1,
        path_filter=['types/'],
        path_mode='only_in',
    )
    result = _check_single(d, 'Write', {'content': 'export interface User { name: string }', 'file_path': 'src/components/User.tsx'})
    check("scoped: blocks interface outside types/", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': 'export interface User { name: string }', 'file_path': 'src/types/User.ts'})
    check("scoped: allows interface in types/", result is None, True)

    result = _check_single(d, 'Edit', {'new_string': 'interface Config {}', 'old_string': '', 'file_path': 'lib/utils.ts'})
    check("scoped: blocks interface edit outside types/", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': 'const x = 42;', 'file_path': 'src/index.ts'})
    check("scoped: allows non-interface outside types/", result is None, True)

    result = _check_single(d, 'Bash', {'command': 'echo hello'})
    check("scoped: ignores Bash tool", result is None, True)

    result = _check_single(d, 'Read', {'file_path': 'src/types/User.ts'})
    check("scoped: ignores Read tool", result is None, True)

    # Evaluate: never_in mode - blocks SQL in controllers/
    d = Directive(
        text="Never put SQL queries in controllers/ @enforced",
        hook_type='scoped-content-guard',
        patterns=[r'\b(SELECT|INSERT|UPDATE|DELETE)\b'],
        description="Block SQL in controllers/",
        line_num=1,
        path_filter=['controllers/'],
        path_mode='never_in',
    )
    result = _check_single(d, 'Write', {'content': 'SELECT * FROM users', 'file_path': 'app/controllers/users_controller.rb'})
    check("scoped: blocks SQL in controllers/", result is not None and result['decision'] == 'block', True)

    result = _check_single(d, 'Write', {'content': 'SELECT * FROM users', 'file_path': 'app/models/user.rb'})
    check("scoped: allows SQL outside controllers/", result is None, True)

    result = _check_single(d, 'Edit', {'new_string': 'render :index', 'old_string': '', 'file_path': 'app/controllers/home_controller.rb'})
    check("scoped: allows non-SQL in controllers/", result is None, True)

    # Hook generation: scoped-content-guard produces valid script
    d = Directive(
        text="Interfaces only in types/ @enforced",
        hook_type='scoped-content-guard',
        patterns=[r'\binterface\s+\w+'],
        description="Only allow interface in types/",
        line_num=1,
        path_filter=['types/'],
        path_mode='only_in',
    )
    hook = generate_hook(d)
    check("scoped: hook generated", hook is not None, True)
    check("scoped: hook has jq file_path", 'file_path' in hook, True)
    check("scoped: hook has path check", 'types/' in hook, True)
    check("scoped: hook has content grep", 'grep' in hook, True)
    check("scoped: hook has Edit case", 'Edit' in hook, True)
    check("scoped: hook checks Write", 'Write' in hook, True)

    # Hook generation: never_in mode
    d_never = Directive(
        text="No SQL in controllers/ @enforced",
        hook_type='scoped-content-guard',
        patterns=[r'\b(SELECT|INSERT|UPDATE|DELETE)\b'],
        description="Block SQL in controllers/",
        line_num=1,
        path_filter=['controllers/'],
        path_mode='never_in',
    )
    hook_never = generate_hook(d_never)
    check("scoped: never_in hook generated", hook_never is not None, True)
    check("scoped: never_in has != check", '!=' in hook_never, True)

    # to_dict includes path fields
    dd = d.to_dict()
    check("scoped: to_dict has path_filter", dd.get('path_filter') == ['types/'], True)
    check("scoped: to_dict has path_mode", dd.get('path_mode') == 'only_in', True)

    # Regular directive to_dict omits path fields
    d_plain = Directive(text="No console.log", hook_type='content-guard', patterns=['console.log'], description="test")
    dd_plain = d_plain.to_dict()
    check("plain: to_dict no path_filter", 'path_filter' not in dd_plain, True)

    # Test --flag pattern extraction in bash-guard
    d = classify_directive("Never use --no-verify when committing @enforced", 1)
    check("flag: --no-verify detected", d is not None, True)
    check("flag: --no-verify type", d.hook_type, 'bash-guard')
    check("flag: --no-verify in patterns", '--no-verify' in d.patterns, True)

    d = classify_directive("Don't run --no-gpg-sign @enforced", 1)
    check("flag: --no-gpg-sign detected", d is not None, True)
    check("flag: --no-gpg-sign in patterns", '--no-gpg-sign' in d.patterns, True)

    d = classify_directive("Never use --dangerouslyDisableSandbox @enforced", 1)
    check("flag: --dangerouslyDisableSandbox detected", d is not None, True)
    check("flag: --dangerouslyDisableSandbox in patterns", '--dangerouslyDisableSandbox' in d.patterns, True)

    # Test flag evaluation blocks matching Bash commands
    flag_dir = Directive("Never use --no-verify @enforced", 'bash-guard',
                         ['--no-verify'], "Block: --no-verify", 1)
    result = _check_single(flag_dir, 'Bash', {'command': 'git commit --no-verify -m "test"'})
    check("flag eval: --no-verify blocked", result is not None and result['decision'] == 'block', True)

    result = _check_single(flag_dir, 'Bash', {'command': 'git commit -m "normal commit"'})
    check("flag eval: normal commit allowed", result, None)

    # Test --skip-hooks flag
    d = classify_directive("Never use --skip-hooks @enforced", 1)
    check("flag: --skip-hooks detected", d is not None, True)
    check("flag: --skip-hooks in patterns", '--skip-hooks' in d.patterns, True)

    # Test backtick-quoted flags still work
    d = classify_directive("Never run `--no-verify` @enforced", 1)
    check("flag: backtick --no-verify detected", d is not None, True)
    check("flag: backtick --no-verify in patterns", '--no-verify' in d.patterns, True)

    # --- Audit tests ---
    # Test audit with no hooks installed
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Rules @enforced\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        check("audit: no hooks -> unenforced", len(result['unenforced']), 2)
        check("audit: no hooks -> enforced is 0", len(result['enforced']), 0)
        check("audit: no hooks -> plugin_mode false", result['plugin_mode'], False)

    # Test audit with plugin mode installed
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        os.makedirs(hooks_d, exist_ok=True)
        # Create plugin files
        Path(hooks_d, 'enforce-pretooluse.sh').write_text('#!/bin/bash\n')
        Path(hooks_d, 'enforce-hooks.py').write_text('# engine\n')
        # Create settings with registration
        Path(settings_f).write_text(json.dumps({
            'hooks': {'PreToolUse': [{'matcher': '', 'hooks': [
                {'type': 'command', 'command': os.path.join(hooks_d, 'enforce-pretooluse.sh')}
            ]}]}
        }))
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        check("audit: plugin -> enforced count", len(result['enforced']), 2)
        check("audit: plugin -> unenforced is 0", len(result['unenforced']), 0)
        check("audit: plugin -> plugin_mode true", result['plugin_mode'], True)
        check("audit: plugin -> registered", result['plugin_registered'], True)

    # Test audit with suggestions (rules not tagged @enforced)
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Rules\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        check("audit: untagged -> enforced is 0", len(result['enforced']), 0)
        check("audit: untagged -> suggestions > 0", len(result['suggestions']) >= 1, True)

    # Test audit with broken references
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Rules @enforced\n- Never modify .env files\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        os.makedirs(os.path.dirname(settings_f), exist_ok=True)
        Path(settings_f).write_text(json.dumps({
            'hooks': {'PreToolUse': [{'matcher': '', 'hooks': [
                {'type': 'command', 'command': '/nonexistent/hook.sh'}
            ]}]}
        }))
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        check("audit: broken ref detected", len(result['broken_refs']), 1)
        check("audit: broken ref path", result['broken_refs'][0], '/nonexistent/hook.sh')

    # Test format_audit_report produces output
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        report = format_audit_report(result)
        check("audit report: contains NOT INSTALLED", 'NOT INSTALLED' in report, True)
        check("audit report: contains Coverage", 'Coverage:' in report, True)

    # Test audit JSON output
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        # Simulate JSON output
        json_result = {
            'enforced': [d.to_dict() for d in result['enforced']],
            'unenforced': [d.to_dict() for d in result['unenforced']],
            'coverage': len(result['enforced']) / max(1, len(result['enforced']) + len(result['unenforced']) + len(result['suggestions'])),
        }
        parsed = json.loads(json.dumps(json_result))
        check("audit json: valid", 'coverage' in parsed, True)
        check("audit json: coverage 0", parsed['coverage'], 0)

    # Test --strict mode: fails when unenforced rules exist
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Rules @enforced\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        has_unenforced = len(result['unenforced']) > 0
        has_broken = len(result['broken_refs']) > 0
        should_fail = has_unenforced or has_broken
        check("strict: unenforced rules -> should fail", should_fail, True)

    # Test --strict mode: passes when all rules enforced (plugin mode)
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n- Do not run `rm -rf`\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        os.makedirs(hooks_d, exist_ok=True)
        Path(hooks_d, 'enforce-pretooluse.sh').write_text('#!/bin/bash\n')
        Path(hooks_d, 'enforce-hooks.py').write_text('# engine\n')
        Path(settings_f).write_text(json.dumps({
            'hooks': {'PreToolUse': [{'matcher': '', 'hooks': [
                {'type': 'command', 'command': os.path.join(hooks_d, 'enforce-pretooluse.sh')}
            ]}]}
        }))
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        has_unenforced = len(result['unenforced']) > 0
        has_broken = len(result['broken_refs']) > 0
        should_fail = has_unenforced or has_broken
        check("strict: plugin mode all enforced -> should pass", should_fail, False)

    # Test --strict mode: fails on broken refs
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        os.makedirs(hooks_d, exist_ok=True)
        Path(hooks_d, 'enforce-pretooluse.sh').write_text('#!/bin/bash\n')
        Path(hooks_d, 'enforce-hooks.py').write_text('# engine\n')
        Path(settings_f).write_text(json.dumps({
            'hooks': {'PreToolUse': [{'matcher': '', 'hooks': [
                {'type': 'command', 'command': os.path.join(hooks_d, 'enforce-pretooluse.sh')},
                {'type': 'command', 'command': '/nonexistent/old-hook.sh'}
            ]}]}
        }))
        result = audit_hooks(str(claude_md), hooks_d, settings_f)
        has_broken = len(result['broken_refs']) > 0
        check("strict: broken refs -> should fail", has_broken, True)

    # Test --strict CLI: exit code 1 on unenforced rules
    import subprocess
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Rules @enforced\n- Never modify .env files\n')
        proc = subprocess.run(
            [sys.executable, __file__, str(claude_md), '--audit', '--strict',
             '--hooks-dir', os.path.join(tmpdir, '.claude', 'hooks'),
             '--settings', os.path.join(tmpdir, '.claude', 'settings.json')],
            capture_output=True, text=True
        )
        check("strict cli: exit 1 on unenforced", proc.returncode, 1)
        check("strict cli: FAIL in output", 'FAIL' in proc.stdout, True)

    # Test --strict CLI: exit code 0 when all enforced
    with tempfile.TemporaryDirectory() as tmpdir:
        claude_md = Path(tmpdir) / 'CLAUDE.md'
        claude_md.write_text('## Safety @enforced\n- Never modify .env files\n')
        hooks_d = os.path.join(tmpdir, '.claude', 'hooks')
        settings_f = os.path.join(tmpdir, '.claude', 'settings.json')
        os.makedirs(hooks_d, exist_ok=True)
        Path(hooks_d, 'enforce-pretooluse.sh').write_text('#!/bin/bash\n')
        Path(hooks_d, 'enforce-hooks.py').write_text('# engine\n')
        Path(settings_f).write_text(json.dumps({
            'hooks': {'PreToolUse': [{'matcher': '', 'hooks': [
                {'type': 'command', 'command': os.path.join(hooks_d, 'enforce-pretooluse.sh')}
            ]}]}
        }))
        proc = subprocess.run(
            [sys.executable, __file__, str(claude_md), '--audit', '--strict',
             '--hooks-dir', hooks_d, '--settings', settings_f],
            capture_output=True, text=True
        )
        check("strict cli: exit 0 when all enforced", proc.returncode, 0)
        check("strict cli: PASS in output", 'PASS' in proc.stdout, True)

    # Test evaluate mode gracefully allows when CLAUDE.md is missing
    import subprocess
    result = subprocess.run(
        [sys.executable, __file__, '--evaluate', '/nonexistent/CLAUDE.md'],
        input='{"tool_name":"Bash","tool_input":{"command":"ls"}}',
        capture_output=True, text=True
    )
    check("evaluate missing CLAUDE.md: exits 0", result.returncode, 0)
    try:
        decision = json.loads(result.stdout.strip())
        check("evaluate missing CLAUDE.md: allows", decision.get('decision'), 'allow')
    except (json.JSONDecodeError, AttributeError):
        check("evaluate missing CLAUDE.md: valid JSON", False, True)

    # --- Warn mode tests ---

    # 1. Parse @enforced(warn) syntax
    d = classify_directive("Never modify .env files @enforced(warn)", 1)
    check("warn: @enforced(warn) parsed", d is not None, True)
    if d:
        check("warn: severity is warn", d.severity, 'warn')
        check("warn: hook_type is file-guard", d.hook_type, 'file-guard')

    # 2. Parse @enforced(block) explicit syntax
    d = classify_directive("Never modify .env files @enforced(block)", 1)
    check("warn: @enforced(block) parsed", d is not None, True)
    if d:
        check("warn: explicit block severity", d.severity, 'block')

    # 3. Plain @enforced defaults to block
    d = classify_directive("Never modify .env files @enforced", 1)
    check("warn: @enforced defaults to block", d is not None and d.severity == 'block', True)

    # 4. Warn mode generates stderr output (no block JSON)
    d = Directive(
        text="Never modify .env files @enforced(warn)",
        hook_type='file-guard',
        patterns=['.env'],
        description="Protect .env",
        line_num=1,
        severity='warn',
    )
    script = generate_hook(d)
    check("warn: hook script generated", script is not None, True)
    if script:
        check("warn: no block JSON in script", '"decision": "block"' not in script
              and '"decision\\": \\"block\\"' not in script, True)
        check("warn: has stderr redirect", '>&2' in script, True)
        check("warn: has WARN prefix", 'WARN' in script, True)

    # 5. Block mode still generates block JSON
    d_block = Directive(
        text="Never modify .env files @enforced",
        hook_type='file-guard',
        patterns=['.env'],
        description="Protect .env",
        line_num=1,
        severity='block',
    )
    script_block = generate_hook(d_block)
    check("block: has block decision", 'block' in script_block and 'decision' in script_block, True)

    # 6. Warn mode in bash-guard
    d = Directive(
        text="Don't run rm -rf @enforced(warn)",
        hook_type='bash-guard',
        patterns=['rm -rf'],
        description="Block rm -rf",
        line_num=1,
        severity='warn',
    )
    script = generate_hook(d)
    check("warn bash-guard: no block JSON", '"decision": "block"' not in script, True)
    check("warn bash-guard: has stderr", '>&2' in script, True)

    # 7. Warn mode in branch-guard
    d = Directive(
        text="Never commit to main @enforced(warn)",
        hook_type='branch-guard',
        patterns=['main'],
        description="Protect main",
        line_num=1,
        severity='warn',
    )
    script = generate_hook(d)
    check("warn branch-guard: no block JSON", '"decision": "block"' not in script, True)
    check("warn branch-guard: has stderr", '>&2' in script, True)

    # 8. Warn mode in tool-block
    d = Directive(
        text="Don't use WebSearch @enforced(warn)",
        hook_type='tool-block',
        patterns=['WebSearch'],
        description="Block WebSearch",
        line_num=1,
        severity='warn',
    )
    script = generate_hook(d)
    check("warn tool-block: no block JSON", '"decision": "block"' not in script, True)
    check("warn tool-block: has stderr", '>&2' in script, True)

    # 9. Warn mode in content-guard
    d = Directive(
        text="Never use inline styles @enforced(warn)",
        hook_type='content-guard',
        patterns=[r'style\s*=\s*"'],
        description="Block inline styles",
        line_num=1,
        severity='warn',
    )
    script = generate_hook(d)
    check("warn content-guard: no block JSON", '"decision": "block"' not in script, True)
    check("warn content-guard: has stderr", '>&2' in script, True)

    # 10. Evaluate mode: warn returns allow, not block
    warn_directives = [
        Directive(
            text="Never modify .env files @enforced(warn)",
            hook_type='file-guard',
            patterns=['.env'],
            description="Protect .env",
            line_num=1,
            severity='warn',
        ),
    ]
    result = evaluate_tool_call(warn_directives, 'Write', {'file_path': '.env'})
    check("warn evaluate: allows (not blocks)", result['decision'], 'allow')

    # 11. Evaluate mode: block still blocks
    block_directives = [
        Directive(
            text="Never modify .env files @enforced",
            hook_type='file-guard',
            patterns=['.env'],
            description="Protect .env",
            line_num=1,
            severity='block',
        ),
    ]
    result = evaluate_tool_call(block_directives, 'Write', {'file_path': '.env'})
    check("block evaluate: blocks", result['decision'], 'block')

    # 12. Section-level @enforced(warn) propagation
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write("## Guidelines @enforced(warn)\n- Never modify .env files\n- Don't run sudo\n")
        f.flush()
        enforceable, _ = scan_file(f.name)
        check("section warn: found directives", len(enforceable) >= 2, True)
        for d_item in enforceable:
            check(f"section warn: severity={d_item.severity}", d_item.severity, 'warn')
        os.unlink(f.name)

    # 13. Inline @enforced(warn) overrides section @enforced
    with tempfile.NamedTemporaryFile(mode='w', suffix='.md', delete=False) as f:
        f.write("## Rules @enforced\n- Never modify .env files @enforced(warn)\n- Don't run sudo\n")
        f.flush()
        enforceable, _ = scan_file(f.name)
        check("inline override: found directives", len(enforceable) >= 2, True)
        # First rule has inline warn, second inherits section block
        env_rule = [d_item for d_item in enforceable if '.env' in d_item.description]
        sudo_rule = [d_item for d_item in enforceable if 'sudo' in d_item.description]
        if env_rule:
            check("inline override: .env is warn", env_rule[0].severity, 'warn')
        if sudo_rule:
            check("inline override: sudo is block", sudo_rule[0].severity, 'block')
        os.unlink(f.name)

    # 14. to_dict includes severity
    d = classify_directive("Never modify .env @enforced(warn)", 1)
    if d:
        dd = d.to_dict()
        check("to_dict: severity in dict", dd.get('severity'), 'warn')

    # 15. Directive round-trip through cache
    d = Directive(text="test @enforced(warn)", hook_type='file-guard',
                  patterns=['.env'], description="test", severity='warn')
    dd = d.to_dict()
    d2 = Directive(**dd)
    check("cache round-trip: severity preserved", d2.severity, 'warn')

    # 16. Audit shows severity
    with tempfile.TemporaryDirectory() as td:
        claude_md = Path(td) / 'CLAUDE.md'
        hooks_dir = Path(td) / '.claude' / 'hooks'
        settings_path = Path(td) / '.claude' / 'settings.json'
        claude_md.write_text('## Rules @enforced(warn)\n- Never modify .env files\n')
        audit = audit_hooks(str(claude_md), str(hooks_dir), str(settings_path))
        # Should be unenforced (no hooks installed) with warn severity
        if audit['unenforced']:
            check("audit: warn severity shown", audit['unenforced'][0].severity, 'warn')
            report = format_audit_report(audit)
            check("audit report: [warn] tag present", '[warn]' in report, True)

    # 17. Warn scoped-content-guard
    d = Directive(
        text="Interfaces only in types/ @enforced(warn)",
        hook_type='scoped-content-guard',
        patterns=[r'\binterface\b'],
        description="Only interfaces in types/",
        line_num=1,
        path_filter=['types/'],
        path_mode='only_in',
        severity='warn',
    )
    script = generate_hook(d)
    check("warn scoped-content: no block JSON", '"decision": "block"' not in script, True)
    check("warn scoped-content: has stderr", '>&2' in script, True)

    # 18. Armor: hook self-protection
    print("\n  --- Armor (self-protection) ---")

    # 18a. Armor templates are valid bash
    check("armor file-guard: is bash script", ARMOR_FILE_GUARD.startswith('#!/usr/bin/env bash'), True)
    check("armor bash-guard: is bash script", ARMOR_BASH_GUARD.startswith('#!/usr/bin/env bash'), True)
    check("armor file-guard: blocks Write", 'Write|Edit|MultiEdit' in ARMOR_FILE_GUARD, True)
    check("armor bash-guard: blocks rm", '*rm*' in ARMOR_BASH_GUARD, True)
    check("armor file-guard: references hooks dir", '.claude/hooks/' in ARMOR_FILE_GUARD, True)
    check("armor bash-guard: references hooks dir", '.claude/hooks' in ARMOR_BASH_GUARD, True)
    check("armor file-guard: references settings", '.claude/settings.json' in ARMOR_FILE_GUARD, True)
    check("armor bash-guard: references settings", '.claude/settings.json' in ARMOR_BASH_GUARD, True)
    check("armor file-guard: outputs block JSON", '"decision": "block"' in ARMOR_FILE_GUARD, True)
    check("armor bash-guard: outputs block JSON", '"decision": "block"' in ARMOR_BASH_GUARD, True)

    # 18b. Armor install creates files and updates settings
    with tempfile.TemporaryDirectory() as tmpdir:
        hooks_dir = os.path.join(tmpdir, '.claude', 'hooks')
        settings_path = os.path.join(tmpdir, '.claude', 'settings.json')
        written = install_armor(hooks_dir, settings_path)

        check("armor install: writes 2 files", len(written), 2)
        check("armor install: file-guard exists", os.path.exists(os.path.join(hooks_dir, 'armor_file_guard.sh')), True)
        check("armor install: bash-guard exists", os.path.exists(os.path.join(hooks_dir, 'armor_bash_guard.sh')), True)

        # Check executable bit
        fg_stat = os.stat(os.path.join(hooks_dir, 'armor_file_guard.sh'))
        bg_stat = os.stat(os.path.join(hooks_dir, 'armor_bash_guard.sh'))
        check("armor install: file-guard is executable", bool(fg_stat.st_mode & 0o111), True)
        check("armor install: bash-guard is executable", bool(bg_stat.st_mode & 0o111), True)

        # Check settings.json was created and has hooks registered
        check("armor install: settings.json created", os.path.exists(settings_path), True)
        settings = json.loads(Path(settings_path).read_text())
        hooks_list = settings.get('hooks', {}).get('PreToolUse', [])
        check("armor install: PreToolUse entry exists", len(hooks_list) > 0, True)
        if hooks_list:
            commands = [h.get('command', '') for h in hooks_list[0].get('hooks', [])]
            check("armor install: file-guard registered", any('armor_file_guard' in c for c in commands), True)
            check("armor install: bash-guard registered", any('armor_bash_guard' in c for c in commands), True)

        # 18c. Idempotent: running again doesn't duplicate entries
        written2 = install_armor(hooks_dir, settings_path)
        settings2 = json.loads(Path(settings_path).read_text())
        hooks_list2 = settings2.get('hooks', {}).get('PreToolUse', [])
        commands2 = [h.get('command', '') for h in hooks_list2[0].get('hooks', [])]
        check("armor install: idempotent (no duplicates)", len(commands2), len(commands))

    # 18d. Armor hooks block the right tool calls (functional tests via subprocess)
    with tempfile.TemporaryDirectory() as tmpdir:
        hooks_dir = os.path.join(tmpdir, '.claude', 'hooks')
        settings_path = os.path.join(tmpdir, '.claude', 'settings.json')
        install_armor(hooks_dir, settings_path)

        import subprocess

        def run_hook(hook_file, tool_input_json):
            """Run a hook script with tool input and return stdout."""
            hook_path = os.path.join(hooks_dir, hook_file)
            try:
                result = subprocess.run(
                    ['bash', hook_path],
                    input=tool_input_json,
                    capture_output=True, text=True, timeout=5
                )
                return result.stdout.strip()
            except Exception:
                return ''

        # File guard: blocks Write to .claude/hooks/somefile.sh
        out = run_hook('armor_file_guard.sh', json.dumps({
            'tool_name': 'Write',
            'tool_input': {'file_path': '/project/.claude/hooks/my-hook.sh'}
        }))
        check("armor file-guard: blocks Write to hooks/", '"block"' in out, True)

        # File guard: blocks Edit to .claude/settings.json
        out = run_hook('armor_file_guard.sh', json.dumps({
            'tool_name': 'Edit',
            'tool_input': {'file_path': '/project/.claude/settings.json'}
        }))
        check("armor file-guard: blocks Edit to settings.json", '"block"' in out, True)

        # File guard: allows Write to other files
        out = run_hook('armor_file_guard.sh', json.dumps({
            'tool_name': 'Write',
            'tool_input': {'file_path': '/project/src/main.py'}
        }))
        check("armor file-guard: allows Write to other files", out, '')

        # File guard: allows non-Write tools
        out = run_hook('armor_file_guard.sh', json.dumps({
            'tool_name': 'Read',
            'tool_input': {'file_path': '/project/.claude/hooks/my-hook.sh'}
        }))
        check("armor file-guard: allows Read on hooks/", out, '')

        # Bash guard: blocks rm targeting hooks
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'rm .claude/hooks/my-hook.sh'}
        }))
        check("armor bash-guard: blocks rm on hooks/", '"block"' in out, True)

        # Bash guard: blocks rm -rf targeting hooks
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'rm -rf .claude/hooks/'}
        }))
        check("armor bash-guard: blocks rm -rf on hooks/", '"block"' in out, True)

        # Bash guard: blocks mv targeting hooks
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'mv .claude/hooks/guard.sh /tmp/'}
        }))
        check("armor bash-guard: blocks mv on hooks/", '"block"' in out, True)

        # Bash guard: blocks chmod targeting hooks
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'chmod -x .claude/hooks/guard.sh'}
        }))
        check("armor bash-guard: blocks chmod on hooks/", '"block"' in out, True)

        # Bash guard: blocks truncate targeting settings.json
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'truncate -s 0 .claude/settings.json'}
        }))
        check("armor bash-guard: blocks truncate on settings.json", '"block"' in out, True)

        # Bash guard: allows normal bash commands
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'ls -la'}
        }))
        check("armor bash-guard: allows normal commands", out, '')

        # Bash guard: allows bash commands mentioning hooks/ in non-destructive way
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Bash',
            'tool_input': {'command': 'ls .claude/hooks/'}
        }))
        check("armor bash-guard: allows ls on hooks/", out, '')

        # Bash guard: allows non-Bash tools
        out = run_hook('armor_bash_guard.sh', json.dumps({
            'tool_name': 'Write',
            'tool_input': {'command': 'rm .claude/hooks/x.sh'}
        }))
        check("armor bash-guard: ignores non-Bash tools", out, '')

    # --- Verify (hook health-check) tests ---

    # Create test hooks in temp dir
    verify_dir = os.path.join(td, 'verify-hooks')
    os.makedirs(verify_dir)
    verify_settings = os.path.join(td, 'verify-settings.json')

    # Bad hook: uses .input.command (wrong field name)
    bad_hook = os.path.join(verify_dir, 'bad-hook.sh')
    with open(bad_hook, 'w') as f:
        f.write('#!/bin/bash\nINPUT=$(cat)\n')
        f.write('COMMAND=$(echo "$INPUT" | jq -r \'.input.command // empty\')\n')
        f.write('if [ -z "$COMMAND" ]; then\n  exit 0\nfi\n')
    os.chmod(bad_hook, 0o755)

    # Good hook: uses .tool_input.command (correct)
    good_hook = os.path.join(verify_dir, 'good-hook.sh')
    with open(good_hook, 'w') as f:
        f.write('#!/bin/bash\nINPUT=$(cat)\n')
        f.write('COMMAND=$(echo "$INPUT" | jq -r \'.tool_input.command // empty\')\n')
        f.write('if [ -z "$COMMAND" ]; then\n  exit 0\nfi\n')
    os.chmod(good_hook, 0o755)

    # Non-executable hook
    noexec_hook = os.path.join(verify_dir, 'noexec-hook.sh')
    with open(noexec_hook, 'w') as f:
        f.write('#!/bin/bash\necho "not executable"\n')
    os.chmod(noexec_hook, 0o644)

    # Python hook with wrong field (dict-style)
    py_bad_hook = os.path.join(verify_dir, 'py-bad-hook.py')
    with open(py_bad_hook, 'w') as f:
        f.write('#!/usr/bin/env python3\n')
        f.write('import json, sys\n')
        f.write('data = json.loads(sys.stdin.read())\n')
        f.write('cmd = data.get("input", {}).get("command", "")\n')
    os.chmod(py_bad_hook, 0o755)

    # Python hook with correct field
    py_good_hook = os.path.join(verify_dir, 'py-good-hook.py')
    with open(py_good_hook, 'w') as f:
        f.write('#!/usr/bin/env python3\n')
        f.write('import json, sys\n')
        f.write('data = json.loads(sys.stdin.read())\n')
        f.write('cmd = data.get("tool_input", {}).get("command", "")\n')
    os.chmod(py_good_hook, 0o755)

    # No-shebang hook
    noshebang = os.path.join(verify_dir, 'noshebang.sh')
    with open(noshebang, 'w') as f:
        f.write('INPUT=$(cat)\necho "$INPUT"\n')
    os.chmod(noshebang, 0o755)

    # Settings with registered + missing hooks
    with open(verify_settings, 'w') as f:
        json.dump({
            'hooks': {
                'PreToolUse': [{
                    'hooks': [
                        {'command': bad_hook},
                        {'command': good_hook},
                        {'command': os.path.join(verify_dir, 'ghost-hook.sh')},
                    ]
                }]
            }
        }, f)

    result = verify_hooks(verify_dir, verify_settings)

    # Summary checks
    check("verify: found all hooks", result['summary']['total'], 6)
    check("verify: has errors", result['summary']['errors'] > 0, True)
    check("verify: has warnings", result['summary']['warnings'] > 0, True)

    # Bad hook: should have field_name error + fail_open error
    bad = [h for h in result['hooks'] if h['name'] == 'bad-hook.sh'][0]
    bad_checks = [i['check'] for i in bad['issues']]
    check("verify: bad-hook has field_name error", 'field_name' in bad_checks, True)
    check("verify: bad-hook has fail_open error", 'fail_open' in bad_checks, True)
    bad_severities = [i['severity'] for i in bad['issues'] if i['check'] == 'field_name']
    check("verify: field_name is error severity", bad_severities[0] if bad_severities else '', 'error')

    # Good hook: should have no field_name error
    good = [h for h in result['hooks'] if h['name'] == 'good-hook.sh'][0]
    good_checks = [i['check'] for i in good['issues']]
    check("verify: good-hook has no field_name error", 'field_name' in good_checks, False)
    good_info_checks = [i['check'] for i in good['info']]
    check("verify: good-hook has field_name info", 'field_name' in good_info_checks, True)

    # Non-executable hook: should have executable error
    noexec = [h for h in result['hooks'] if h['name'] == 'noexec-hook.sh'][0]
    noexec_checks = [i['check'] for i in noexec['issues']]
    check("verify: noexec-hook has executable error", 'executable' in noexec_checks, True)

    # Python bad hook: should detect wrong field
    pybad = [h for h in result['hooks'] if h['name'] == 'py-bad-hook.py'][0]
    pybad_checks = [i['check'] for i in pybad['issues']]
    check("verify: py-bad-hook has field_name error", 'field_name' in pybad_checks, True)

    # Python good hook: should be clean
    pygood = [h for h in result['hooks'] if h['name'] == 'py-good-hook.py'][0]
    pygood_checks = [i['check'] for i in pygood['issues']]
    check("verify: py-good-hook has no field_name error", 'field_name' in pygood_checks, False)

    # No-shebang hook: should have shebang warning
    nosheb = [h for h in result['hooks'] if h['name'] == 'noshebang.sh'][0]
    nosheb_checks = [i['check'] for i in nosheb['issues']]
    check("verify: noshebang has shebang warning", 'shebang' in nosheb_checks, True)

    # Unregistered hooks: noexec and noshebang should have registration warning
    noexec_reg = [i for i in noexec['issues'] if i['check'] == 'registration']
    check("verify: noexec-hook has registration warning", len(noexec_reg) > 0, True)

    # Settings: missing hook reference
    settings_errs = [s for s in result['settings_issues'] if 'ghost-hook' in s.get('message', '')]
    check("verify: detects missing hook reference in settings", len(settings_errs) > 0, True)

    # Format report
    report = format_verify_report(result)
    check("verify: report contains FAIL", 'FAIL' in report, True)
    check("verify: report contains .tool_input", 'tool_input' in report, True)
    check("verify: report contains summary line", 'Summary:' in report, True)

    # JSON output
    json_out = json.dumps(result, indent=2, default=str)
    parsed = json.loads(json_out)
    check("verify: JSON roundtrips", parsed['summary']['total'], 6)

    # --- Verify: empty hooks dir ---
    empty_dir = os.path.join(td, 'empty-hooks')
    os.makedirs(empty_dir)
    empty_result = verify_hooks(empty_dir, os.path.join(td, 'nonexistent-settings.json'))
    check("verify: empty dir has 0 hooks", empty_result['summary']['total'], 0)

    # --- Verify: nonexistent dir ---
    missing_result = verify_hooks(os.path.join(td, 'no-such-dir'), verify_settings)
    check("verify: missing dir returns info", len(missing_result['settings_issues']) > 0, True)

    # --- Smoke test ---
    section("smoke-test")

    # Create a temp project with hooks
    smoke_dir = os.path.join(td, 'smoke-project')
    smoke_hooks = os.path.join(smoke_dir, '.claude', 'hooks')
    os.makedirs(smoke_hooks)

    # Good hook: reads stdin, outputs valid JSON allow
    good_hook = os.path.join(smoke_hooks, 'good-hook.sh')
    with open(good_hook, 'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write('INPUT=$(cat)\n')
        f.write('TOOL=$(echo "$INPUT" | jq -r \'.tool_name\')\n')
        f.write('echo \'{"decision": "allow"}\'\n')
    os.chmod(good_hook, 0o755)

    # Bad hook: reads wrong field, outputs nothing useful
    bad_hook = os.path.join(smoke_hooks, 'bad-hook.sh')
    with open(bad_hook, 'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write('INPUT=$(cat)\n')
        f.write('# Bug: using .input instead of .tool_input\n')
        f.write('FILE=$(echo "$INPUT" | jq -r \'.input.file_path\')\n')
        f.write('# No output at all = fail-open\n')
    os.chmod(bad_hook, 0o755)

    # Blocking hook: always blocks Write to .env
    block_hook = os.path.join(smoke_hooks, 'file-guard-hook.sh')
    with open(block_hook, 'w') as f:
        f.write('#!/usr/bin/env bash\n')
        f.write('INPUT=$(cat)\n')
        f.write('TOOL=$(echo "$INPUT" | jq -r \'.tool_name\')\n')
        f.write('FILE=$(echo "$INPUT" | jq -r \'.tool_input.file_path // empty\')\n')
        f.write('if [[ "$TOOL" == "Write" ]] && [[ "$FILE" == *".env"* ]]; then\n')
        f.write('  echo \'{"decision": "block", "reason": "Protected file"}\'\n')
        f.write('else\n')
        f.write('  echo \'{"decision": "allow"}\'\n')
        f.write('fi\n')
    os.chmod(block_hook, 0o755)

    # Register hooks in settings
    smoke_settings = os.path.join(smoke_dir, '.claude', 'settings.json')
    with open(smoke_settings, 'w') as f:
        json.dump({
            'hooks': {
                'PreToolUse': [{
                    'hooks': [
                        {'command': good_hook},
                        {'command': bad_hook},
                        {'command': block_hook},
                    ]
                }]
            }
        }, f)

    result = smoke_test_hooks(smoke_hooks, smoke_settings)
    check("smoke: found 3 hooks", result['summary']['total'], 3)

    # Good hook should pass all benign tests
    good_r = [h for h in result['hooks'] if 'good-hook' in h['command']][0]
    check("smoke: good-hook passes", good_r['status'], 'ok')
    good_allows = [t for t in good_r['tests'] if t.get('decision') == 'allow']
    check("smoke: good-hook allows benign payloads", len(good_allows) >= 3, True)

    # Bad hook should fail (no output = fail-open)
    bad_r = [h for h in result['hooks'] if 'bad-hook' in h['command']][0]
    bad_errors = [t for t in bad_r['tests'] if t['status'] == 'error']
    check("smoke: bad-hook has errors", len(bad_errors) > 0, True)
    check("smoke: bad-hook status is fail", bad_r['status'], 'fail')

    # Blocking hook: benign payloads should be allowed
    block_r = [h for h in result['hooks'] if 'file-guard' in h['command']][0]
    block_allows = [t for t in block_r['tests'] if t.get('decision') == 'allow']
    check("smoke: file-guard allows benign payloads", len(block_allows) >= 3, True)
    # Block payload (Write to .env) should be blocked
    block_blocks = [t for t in block_r['tests'] if t.get('decision') == 'block']
    check("smoke: file-guard blocks .env write", len(block_blocks) >= 1, True)
    check("smoke: file-guard status ok", block_r['status'], 'ok')

    # Format report
    report = format_smoke_test_report(result)
    check("smoke: report contains PASS", 'PASS' in report, True)
    check("smoke: report contains FAIL", 'FAIL' in report, True)
    check("smoke: report contains Summary:", 'Summary:' in report, True)

    # JSON output
    json_out = json.dumps(result, indent=2, default=str)
    parsed = json.loads(json_out)
    check("smoke: JSON roundtrips", parsed['summary']['total'], 3)

    # --- Smoke test: no settings ---
    no_settings_result = smoke_test_hooks(smoke_hooks, os.path.join(td, 'nonexistent.json'))
    check("smoke: no settings returns 0 hooks", no_settings_result['summary']['total'], 0)
    check("smoke: no settings has issue", len(no_settings_result['settings_issues']) > 0, True)

    # --- Smoke test: empty settings ---
    empty_settings = os.path.join(td, 'empty-settings.json')
    with open(empty_settings, 'w') as f:
        json.dump({}, f)
    empty_result = smoke_test_hooks(smoke_hooks, empty_settings)
    check("smoke: empty settings returns 0 hooks", empty_result['summary']['total'], 0)

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
  %(prog)s --install                  Write per-rule hooks to .claude/hooks/
  %(prog)s --install-plugin           Install as one dynamic hook (recommended)
  %(prog)s --audit                    Audit rules vs installed hooks
  %(prog)s --audit --strict            CI gate: exit 1 if any rules unenforced
  %(prog)s --armor                    Protect hooks from being deleted/modified
  %(prog)s --verify                   Health-check installed hooks for correctness
  %(prog)s --verify --strict          CI gate: exit 1 if any hooks have errors
  %(prog)s --smoke-test               Execute hooks with test payloads, verify responses
  %(prog)s --smoke-test --strict      CI gate: exit 1 if any hooks fail
  %(prog)s --evaluate                 PreToolUse mode (reads stdin, outputs decision)
  %(prog)s --test                     Run self-tests
''',
    )
    parser.add_argument('file', nargs='?', help='Path to CLAUDE.md (auto-detected if omitted)')
    parser.add_argument('--scan', action='store_true', help='Scan and show enforceable directives')
    parser.add_argument('--generate', action='store_true', help='Generate hook scripts to stdout')
    parser.add_argument('--install', action='store_true', help='Generate and install hooks')
    parser.add_argument('--json', action='store_true', help='Output as JSON (with --scan)')
    parser.add_argument('--evaluate', action='store_true',
                        help='PreToolUse mode: read tool call from stdin, check rules, output decision')
    parser.add_argument('--install-plugin', action='store_true',
                        help='Install as a single dynamic hook (recommended)')
    parser.add_argument('--hooks-dir', default='.claude/hooks', help='Directory for hook scripts')
    parser.add_argument('--settings', default='.claude/settings.json', help='Path to settings.json')
    parser.add_argument('--audit', action='store_true',
                        help='Audit: compare CLAUDE.md rules vs installed hooks')
    parser.add_argument('--strict', action='store_true',
                        help='With --audit: exit 1 if any @enforced rules lack hooks (CI gate)')
    parser.add_argument('--armor', action='store_true',
                        help='Install self-protection: hooks that guard .claude/hooks/ from modification')
    parser.add_argument('--verify', action='store_true',
                        help='Health-check installed hooks for correctness (wrong field names, permissions, fail-open)')
    parser.add_argument('--smoke-test', action='store_true', dest='smoke_test',
                        help='Run each hook with test payloads and verify it responds correctly')
    parser.add_argument('--test', action='store_true', help='Run self-tests')
    args = parser.parse_args()

    if args.test:
        success = run_tests()
        sys.exit(0 if success else 1)

    if not any([args.scan, args.generate, args.install, args.evaluate, args.install_plugin, args.audit, args.armor, args.verify, args.smoke_test]):
        args.scan = True  # Default to scan

    if args.verify:
        hooks_dir = args.hooks_dir
        settings = args.settings
        if args.file and os.path.exists(args.file):
            project_root = str(Path(args.file).resolve().parent)
            if hooks_dir == '.claude/hooks':
                hooks_dir = os.path.join(project_root, '.claude', 'hooks')
            if settings == '.claude/settings.json':
                settings = os.path.join(project_root, '.claude', 'settings.json')
        result = verify_hooks(hooks_dir, settings)
        if args.json:
            print(json.dumps(result, indent=2, default=str))
        else:
            print(format_verify_report(result))
        if args.strict:
            if result['summary']['errors'] > 0:
                print(f"\n--strict: FAIL ({result['summary']['errors']} error(s))")
                sys.exit(1)
            else:
                print("\n--strict: PASS (all hooks healthy)")
        return

    if args.smoke_test:
        hooks_dir = args.hooks_dir
        settings = args.settings
        if args.file and os.path.exists(args.file):
            project_root = str(Path(args.file).resolve().parent)
            if hooks_dir == '.claude/hooks':
                hooks_dir = os.path.join(project_root, '.claude', 'hooks')
            if settings == '.claude/settings.json':
                settings = os.path.join(project_root, '.claude', 'settings.json')
        result = smoke_test_hooks(hooks_dir, settings)
        if args.json:
            print(json.dumps(result, indent=2, default=str))
        else:
            print(format_smoke_test_report(result))
        if args.strict:
            if result['summary']['failed'] > 0:
                print(f"\n--strict: FAIL ({result['summary']['failed']} hook(s) failed)")
                sys.exit(1)
            else:
                print("\n--strict: PASS (all hooks responding correctly)")
        return

    if args.armor:
        hooks_dir = args.hooks_dir
        settings = args.settings
        # If a CLAUDE.md path was given, derive project root from it
        if args.file and os.path.exists(args.file):
            project_root = str(Path(args.file).resolve().parent)
            if hooks_dir == '.claude/hooks':
                hooks_dir = os.path.join(project_root, '.claude', 'hooks')
            if settings == '.claude/settings.json':
                settings = os.path.join(project_root, '.claude', 'settings.json')
        written = install_armor(hooks_dir, settings)
        print(f"Armor installed ({len(written)} hooks):")
        for w in written:
            print(f"  {w}")
        print(f"\nUpdated: {settings}")
        print("\nHook self-protection is active:")
        print("  - Write/Edit/MultiEdit to .claude/hooks/ or settings.json: blocked")
        print("  - Bash rm/mv/chmod/truncate targeting hooks or settings: blocked")
        print("  - The armor hooks protect each other (self-referential)")
        print("\nContext: https://github.com/anthropics/claude-code/issues/32990")
        return

    path = args.file or find_claude_md()
    if not path or not os.path.exists(path):
        if args.evaluate:
            # In hook mode, missing CLAUDE.md must not block tool calls
            print(json.dumps({"decision": "allow"}))
            sys.exit(0)
        if not path:
            print("Error: No CLAUDE.md found. Specify a path or run from a project directory.", file=sys.stderr)
        else:
            print(f"Error: File not found: {path}", file=sys.stderr)
        sys.exit(1)

    enforceable, skipped = scan_file(path)

    if args.scan:
        if args.json:
            result = {
                'enforceable': [d.to_dict() for d in enforceable],
                'skipped': [{'line': ln, 'text': t, 'reason': r} for ln, t, r in skipped],
            }
            if not enforceable:
                suggestions = scan_suggestions(path)
                result['suggestions'] = [d.to_dict() for d in suggestions]
            print(json.dumps(result, indent=2))
        else:
            print(f"Scanning: {path}\n")
            print(format_scan_table(enforceable, skipped))
            if not enforceable:
                suggestions = scan_suggestions(path)
                if suggestions:
                    print(f"\nFound {len(suggestions)} rule(s) that could be enforced:\n")
                    print(f"{'#':>3}  {'Type':<20}  {'What it would block':<40}  {'Source line'}")
                    print(f"{'---':>3}  {'----':<20}  {'---':<40}  {'---'}")
                    for i, d in enumerate(suggestions, 1):
                        print(f"{i:>3}  {d.hook_type:<20}  {d.description:<40}  L{d.line_num}")
                    print("\nTo activate enforcement, add @enforced to each rule:")
                    print("  - Never modify .env files @enforced")
                    print("  - Do not use `git push --force` @enforced")
                    print("  - Avoid using `any` type @enforced(warn)    # warns but allows")
                    print("\nOr tag an entire section:")
                    print("  ## Safety @enforced")
                    print("  - Never modify .env files")
                    print("  - Never run `rm -rf` commands")
                else:
                    print("\nNo classifiable rules found in your CLAUDE.md.")
                    print("enforce-hooks detects rules like:")
                    print("  - Never modify .env files @enforced       (file protection)")
                    print("  - Do not run `rm -rf` @enforced           (command blocking)")
                    print("  - Never commit to main @enforced          (branch protection)")
                    print("  - Always run tests before committing @enforced  (workflow)")
        return

    if args.audit:
        # Derive hooks/settings paths from CLAUDE.md location when defaults
        hooks_dir = args.hooks_dir
        settings = args.settings
        if hooks_dir == '.claude/hooks' and path != 'CLAUDE.md':
            project_root = str(Path(path).resolve().parent)
            hooks_dir = os.path.join(project_root, '.claude', 'hooks')
            settings = os.path.join(project_root, '.claude', 'settings.json')
        result = audit_hooks(path, hooks_dir, settings)
        if args.json:
            json_result = {
                'enforced': [d.to_dict() for d in result['enforced']],
                'unenforced': [d.to_dict() for d in result['unenforced']],
                'suggestions': [d.to_dict() for d in result['suggestions']],
                'orphan_hooks': result['orphan_hooks'],
                'broken_refs': result['broken_refs'],
                'plugin_mode': result['plugin_mode'],
                'plugin_registered': result['plugin_registered'],
                'settings_hooks': result['settings_hooks'],
                'coverage': len(result['enforced']) / max(1, len(result['enforced']) + len(result['unenforced']) + len(result['suggestions'])),
            }
            print(json.dumps(json_result, indent=2))
        else:
            print(f"Auditing: {path}\n")
            print(format_audit_report(result))

        if args.strict:
            failures = []
            if result['unenforced']:
                failures.append(f"{len(result['unenforced'])} @enforced rule(s) without hooks")
            if result['broken_refs']:
                failures.append(f"{len(result['broken_refs'])} broken hook reference(s)")
            if failures:
                print(f"\n--strict: FAIL ({', '.join(failures)})")
                sys.exit(1)
            else:
                print("\n--strict: PASS (all @enforced rules have active hooks)")
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

    if args.evaluate:
        run_evaluate(path)
        return

    if args.install_plugin:
        enforceable, _ = scan_file(path)
        if not enforceable:
            suggestions = scan_suggestions(path)
            if suggestions:
                print(f"No @enforced directives found, but {len(suggestions)} rule(s) could be enforced:\n")
                print(f"{'#':>3}  {'Type':<20}  {'What it would block':<40}  {'Source line'}")
                print(f"{'---':>3}  {'----':<20}  {'---':<40}  {'---'}")
                for i, d in enumerate(suggestions, 1):
                    print(f"{i:>3}  {d.hook_type:<20}  {d.description:<40}  L{d.line_num}")
                print("\nTo activate, add @enforced to each rule in your CLAUDE.md:")
                print("  - Never modify .env files @enforced")
                print("\nOr tag an entire section:")
                print("  ## Safety @enforced")
                print("  - Never modify .env files")
                print("  - Never run `rm -rf` commands")
                print("\nThen re-run:")
                print("  python3 enforce-hooks.py --install-plugin")
            else:
                print("No enforceable directives found in your CLAUDE.md.")
                print("enforce-hooks detects rules like:")
                print("  - Never modify .env files @enforced       (file protection)")
                print("  - Do not run `rm -rf` @enforced           (command blocking)")
                print("  - Don't commit to main @enforced          (branch protection)")
            return
        print(f"Found {len(enforceable)} enforceable directive(s) in {path}")
        # Derive hooks/settings paths from CLAUDE.md location when defaults are used
        hooks_dir = args.hooks_dir
        settings = args.settings
        if hooks_dir == '.claude/hooks' and path != 'CLAUDE.md':
            project_root = str(Path(path).resolve().parent)
            hooks_dir = os.path.join(project_root, '.claude', 'hooks')
            settings = os.path.join(project_root, '.claude', 'settings.json')
        written = install_plugin(path, hooks_dir, settings)
        print(f"\nInstalled plugin mode ({len(written)} files):")
        for w in written:
            print(f"  {w}")
        print(f"\nUpdated: {settings}")
        print("\nHow it works:")
        print("  - One hook runs on every tool call")
        print("  - Reads your CLAUDE.md, enforces rules dynamically")
        print("  - Change CLAUDE.md and rules update automatically")
        print("\nTo verify, try triggering a blocked action in Claude Code.")
        return

    if args.install:
        if not enforceable:
            suggestions = scan_suggestions(path)
            if suggestions:
                print(f"No @enforced directives found, but {len(suggestions)} rule(s) could be enforced.\n")
                print("Add @enforced to activate enforcement:")
                print("  - Never modify .env files @enforced\n")
                print("Then re-run: python3 enforce-hooks.py --install")
            else:
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
