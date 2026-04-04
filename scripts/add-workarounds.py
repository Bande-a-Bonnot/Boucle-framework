#!/usr/bin/env python3
"""Add workarounds to CRITICAL limitations entries that lack them."""
import json

WORKAROUNDS = {
    "autocomplete-bypasses-hooks": (
        "Use file-guard to protect sensitive files at the Bash/Read tool level. "
        "Add .env and other secrets to file-guard's block list. "
        "Since @-autocomplete injects file content without a tool call, "
        "the only defense is preventing the file from being readable in the first place: "
        "move secrets outside the project directory or use OS-level file permissions."
    ),
    "hook-deny-is-not-enforced-for-mcp-tool-calls": (
        "Do not rely on PreToolUse hooks to block MCP tool calls. "
        "Use MCP server-level access controls instead, or remove untrusted MCP servers from your configuration. "
        "For sensitive operations, configure the MCP server itself to reject unauthorized requests."
    ),
    "hooks-don-t-fire-in-pipe-mode-p-or-bare-mode-bare": (
        "Never use -p or --bare with untrusted inputs. These modes are designed for scripted use "
        "and intentionally skip all hooks. If you need hook enforcement, use interactive mode or "
        "headless mode (which does fire hooks). For CI/CD pipelines using -p, add validation outside "
        "Claude Code (e.g., review the output before applying changes)."
    ),
    "stop-hooks-do-not-fire-in-the-vscode-extension": (
        "Use PostToolUse hooks or session-log for session auditing instead of Stop hooks when running "
        "in VS Code. Alternatively, run Claude Code in the terminal (CLI) for workflows where Stop hooks "
        "are essential (e.g., cleanup or reporting at session end)."
    ),
    "session-level-permission-caching-bypasses-allow-list-in-sand": (
        "In sandbox mode, avoid approving broad command patterns. Each approval auto-approves all "
        "subsequent calls to that command for the entire session. Use explicit allow lists in "
        "settings.json rather than relying on runtime approval. Consider using bash-guard to add "
        "a secondary enforcement layer that is not affected by session caching."
    ),
    "internal-git-operations-bypass-all-hooks": (
        "Use git-safe or branch-guard hooks to protect critical branches at the Bash tool level. "
        "Internal git operations (fetch + reset) run programmatically without tool calls, so hook-based "
        "protection cannot intercept them. Protect important work by committing frequently and using "
        "separate branches. Consider Git server-side hooks (pre-receive) for critical branch protection."
    ),
    "permissionrequest-hooks-do-not-fire-for-subagent-permission-": (
        "Set explicit permission rules in settings.json allow/deny lists at the project level rather "
        "than relying on PermissionRequest hook interception. Rules in settings.json apply to both "
        "main sessions and subagents. For strict control, use bypassPermissions: false and define "
        "all allowed operations explicitly."
    ),
    "teammate-hooks-bypass": (
        "Define permission rules in settings.json allow/deny lists, which apply regardless of "
        "whether the operation runs in the main session or a teammate. Do not rely on PreToolUse "
        "hooks alone for security-critical enforcement when teammates are in use."
    ),
    "find-command-injection-cve": (
        "Update to Claude Code v2.0.72 or later, where this CVE is fixed. "
        "bash-guard also catches dangerous find patterns as a defense-in-depth measure."
    ),
    "stop-hooks-in-skills-never-fire": (
        "Use PostToolUse hooks or session-log hooks as alternatives for auditing or cleanup that "
        "would normally run at session end. Define Stop hooks at the project or user level instead "
        "of in SKILL.md files."
    ),
    "apikeyhelper-arbitrary-code-execution": (
        "Never trust apiKeyHelper in cloned repositories. Audit .claude/settings.json in any new "
        "repo before opening it with Claude Code. Define apiKeyHelper only in user-level settings "
        "(~/.claude/settings.json), never in project-level settings. Consider using environment "
        "variables for API keys instead."
    ),
    "resume-loads-zero-context-v2191": (
        "On v2.1.91, start a new session instead of resuming. If you must resume, check the context "
        "percentage shown in the status bar. If it shows 0%, start fresh. Update to a newer version "
        "where this regression is fixed."
    ),
    "managed-settings-deny-ignored": (
        "On macOS, define deny rules in ~/.claude/settings.json instead of the managed settings file. "
        "Verify that deny rules are actually enforced by testing with a blocked operation before "
        "relying on them for security. Use hook-based enforcement (bash-guard, file-guard) as a "
        "backup layer."
    ),
    "pretooluse-exit2-deny-ignored": (
        "Do not rely solely on exit code 2 with deny JSON for blocking tool execution. "
        "Use bash-guard or file-guard as a secondary enforcement layer. Test that your hooks "
        "actually block operations before depending on them in production."
    ),
    "remote-trigger-destructive-force-push-data-loss": (
        "Use git-safe or branch-guard hooks in any project where remote triggers run. "
        "These hooks block force-push operations at the Bash tool level. Additionally, "
        "protect critical branches with GitHub branch protection rules (server-side) as "
        "a defense-in-depth measure."
    ),
    "docker-prune-destroys-unrelated-images": (
        "Add docker system prune and docker volume prune to bash-guard's block list. "
        "Or use a PreToolUse hook that blocks any docker command containing 'prune' or '-af'. "
        "Review Docker commands carefully before approving them."
    ),
    "bulk-rm-rf-deletes-creative-assets-no-confirmation": (
        "Use file-guard to protect directories containing valuable files (artwork, media, data). "
        "Add critical directories to file-guard's protected paths list. Also consider using "
        "bash-guard to block broad rm -rf patterns, and always keep backups of irreplaceable files "
        "outside the project directory."
    ),
}

def patch_html(workarounds):
    """Insert workaround paragraphs into the static HTML file."""
    import re

    with open('docs/limitations.html', 'r') as f:
        html = f.read()

    patched = 0
    for entry_id, text in workarounds.items():
        # Check if this entry exists in the HTML and doesn't already have a workaround
        marker = f'id="{entry_id}"'
        if marker not in html:
            print(f"  [HTML] Entry not in HTML: {entry_id}")
            continue

        # Check if already has a workaround paragraph
        wk_marker = f'<!-- workaround:{entry_id} -->'
        if wk_marker in html:
            print(f"  [HTML] Already patched: {entry_id}")
            continue

        # Find the kl-issues div that follows this entry's id
        # Pattern: find the entry div, then find the first kl-issues div after it
        idx = html.index(marker)
        # Find the next kl-issues div after this entry
        issues_pattern = '<div class="kl-issues">'
        issues_idx = html.index(issues_pattern, idx)

        # Insert workaround paragraph before the kl-issues div
        workaround_html = (
            f'            {wk_marker}\n'
            f'            <p style="margin-top:0.5rem;padding:0.5rem 0.75rem;'
            f'background:#1a2a1a;border-left:3px solid #22c55e;border-radius:4px;'
            f'font-size:0.85rem;">'
            f'<strong style="color:#22c55e;">Workaround:</strong> {text}</p>\n'
        )
        html = html[:issues_idx] + workaround_html + html[issues_idx:]
        patched += 1
        print(f"  [HTML] Patched: {entry_id}")

    with open('docs/limitations.html', 'w') as f:
        f.write(html)

    print(f"\nPatched {patched} HTML entries with workarounds.")


SEV_COLORS = {
    'critical': '#8b0000', 'high': '#c9190b',
    'medium': '#d29922', 'low': '#4a90d9'
}


def sync_missing_entries():
    """Generate HTML for entries in JSON but missing from HTML."""
    with open('docs/limitations.json', 'r') as f:
        data = json.load(f)
    with open('docs/limitations.html', 'r') as f:
        html = f.read()

    missing = []
    for i, e in enumerate(data['entries']):
        eid = e['id']
        if f'id="{eid}"' not in html:
            missing.append((i + 1, e))

    if not missing:
        print("\nNo missing entries to sync.")
        return

    blocks = []
    for num, e in missing:
        eid = e['id']
        cat = e['category'].replace('&', '&amp;')
        sev = e['severity']
        color = SEV_COLORS.get(sev, '#4a90d9')
        title = e['title']
        desc = e['description']
        issues = e.get('issues', [])
        wk = e.get('workaround', '')

        issue_links = []
        issue_nums = []
        for url in issues:
            n = url.rstrip('/').split('/')[-1]
            issue_nums.append(n)
            issue_links.append(
                f'<a href="{url}" target="_blank">#{n}</a>'
            )

        data_issues = ' '.join(issue_nums)
        issues_html = ', '.join(issue_links) if issue_links else 'None'

        entry_lines = [
            '',
            f'        <div class="kl-entry" data-category="{cat}" '
            f'data-issues="{data_issues}" id="{eid}" data-severity="{sev}">',
            '            <div class="kl-meta">',
            f'                <span class="kl-num">#{num}</span>',
            f'                <span class="kl-cat">{cat}</span>',
            f'                <span class="kl-sev" style="font-size:0.7rem;'
            f'background:{color};color:white;padding:0.1rem 0.4rem;'
            f'border-radius:12px;margin-left:0.3rem;font-weight:600;'
            f'text-transform:uppercase;">{sev}</span>',
            '            </div>',
            f'            <h3>{title}</h3>',
            f'            <p>{desc}</p>',
        ]

        if wk:
            entry_lines.append(
                f'            <!-- workaround:{eid} -->'
            )
            entry_lines.append(
                f'            <p style="margin-top:0.5rem;padding:0.5rem 0.75rem;'
                f'background:#1a2a1a;border-left:3px solid #22c55e;'
                f'border-radius:4px;font-size:0.85rem;">'
                f'<strong style="color:#22c55e;">Workaround:</strong> '
                f'{wk}</p>'
            )

        entry_lines.append(
            f'            <div class="kl-issues">Issues: {issues_html}</div>'
        )
        entry_lines.append('        </div>')

        blocks.append('\n'.join(entry_lines))
        print(f"  [SYNC] Generated: #{num} {eid} [{sev}]")

    footer = '        <footer>'
    if footer in html:
        insert = '\n'.join(blocks) + '\n\n'
        html = html.replace(footer, insert + footer)
        with open('docs/limitations.html', 'w') as f:
            f.write(html)
        print(f"\nInserted {len(blocks)} missing entries into HTML.")
    else:
        print("ERROR: footer marker not found")


def main():
    with open('docs/limitations.json', 'r') as f:
        data = json.load(f)

    added = 0
    for entry in data['entries']:
        if entry.get('severity') == 'critical' and entry['id'] in WORKAROUNDS:
            if not entry.get('workaround'):
                entry['workaround'] = WORKAROUNDS[entry['id']]
                added += 1
                print(f"  [JSON] Added workaround: {entry['id']}")
            else:
                print(f"  [JSON] Already has workaround: {entry['id']}")

    with open('docs/limitations.json', 'w') as f:
        json.dump(data, f, indent=2)

    print(f"\nAdded {added} new workarounds to JSON.")

    # Now patch the HTML
    patch_html(WORKAROUNDS)

    # Sync any entries in JSON but missing from HTML
    sync_missing_entries()

if __name__ == '__main__':
    main()
