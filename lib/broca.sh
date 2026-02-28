#!/bin/bash
# Broca — File-based, git-native memory for AI agents
# Named after Broca's area (the brain region for language production)
#
# Memory entries are Markdown files with YAML frontmatter.
# No database required. Just files.

set -euo pipefail

# --- Memory Entry Management ---

# Create a new memory entry
# Usage: broca_remember <memory_dir> <type> <title> <content> [tags...]
broca_remember() {
    local memory_dir="$1"
    local entry_type="$2"  # fact, decision, observation, error, procedure
    local title="$3"
    local content="$4"
    shift 4
    local tags=("$@")

    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local slug
    slug=$(echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
    local filename="${timestamp}_${slug}.md"
    local filepath="$memory_dir/knowledge/$filename"

    mkdir -p "$memory_dir/knowledge"

    # Build YAML frontmatter
    local tags_yaml=""
    if [ ${#tags[@]} -gt 0 ]; then
        tags_yaml="tags: [$(printf '"%s", ' "${tags[@]}" | sed 's/, $//')]"
    else
        tags_yaml="tags: []"
    fi

    cat > "$filepath" <<EOF
---
type: $entry_type
$tags_yaml
created: $timestamp
confidence: 0.8
---

# $title

$content
EOF

    echo "$filepath"
}

# Write a journal entry (iteration summary)
# Usage: broca_journal <memory_dir> <summary>
broca_journal() {
    local memory_dir="$1"
    local summary="$2"
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local filepath="$memory_dir/journal/$timestamp.md"

    mkdir -p "$memory_dir/journal"

    cat > "$filepath" <<EOF
---
type: journal
created: $timestamp
---

# Iteration: $timestamp

$summary
EOF

    echo "$filepath"
}

# --- Memory Retrieval ---

# Search knowledge by tag
# Usage: broca_search_tag <memory_dir> <tag>
broca_search_tag() {
    local memory_dir="$1"
    local tag="$2"

    grep -rl "tags:.*$tag" "$memory_dir/knowledge/" 2>/dev/null || true
}

# Search knowledge by keyword in content
# Usage: broca_search <memory_dir> <query>
broca_search() {
    local memory_dir="$1"
    local query="$2"

    grep -rli "$query" "$memory_dir/knowledge/" 2>/dev/null || true
}

# Get recent knowledge entries
# Usage: broca_recent <memory_dir> [count]
broca_recent() {
    local memory_dir="$1"
    local count="${2:-10}"

    ls -t "$memory_dir/knowledge/"*.md 2>/dev/null | head -"$count"
}

# Get recent journal entries
# Usage: broca_journal_recent <memory_dir> [count]
broca_journal_recent() {
    local memory_dir="$1"
    local count="${2:-5}"

    ls -t "$memory_dir/journal/"*.md 2>/dev/null | head -"$count"
}

# --- State Management ---

# Read the current state file
# Usage: broca_state <memory_dir>
broca_state() {
    local memory_dir="$1"
    if [ -f "$memory_dir/state.md" ]; then
        cat "$memory_dir/state.md"
    else
        echo "(No state file found)"
    fi
}

# --- Memory Statistics ---

# Show memory stats
# Usage: broca_stats <memory_dir>
broca_stats() {
    local memory_dir="$1"

    echo "=== Broca Memory Stats ==="
    echo "Knowledge entries: $(ls "$memory_dir/knowledge/"*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "Journal entries: $(ls "$memory_dir/journal/"*.md 2>/dev/null | wc -l | tr -d ' ')"

    # Tag frequency
    echo ""
    echo "Top tags:"
    grep -h "^tags:" "$memory_dir/knowledge/"*.md 2>/dev/null | \
        sed 's/tags: *\[//;s/\]//;s/"//g' | \
        tr ',' '\n' | \
        sed 's/^ *//;s/ *$//' | \
        sort | uniq -c | sort -rn | head -10
}

export -f broca_remember broca_journal broca_search_tag broca_search broca_recent broca_journal_recent broca_state broca_stats
