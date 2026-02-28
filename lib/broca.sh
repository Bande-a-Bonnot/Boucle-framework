#!/bin/bash
# Broca — File-based, git-native memory for AI agents
# Named after Broca's area (the brain region for language production)
#
# Memory entries are Markdown files with YAML frontmatter.
# No database required. Just files.
#
# Types: fact, decision, observation, error, procedure
# Confidence: 0.0 to 1.0 (default 0.8)

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

# Intelligent recall — search with relevance scoring
# Returns entries ranked by: keyword matches + tag matches + recency + confidence
# Output format: SCORE<tab>FILEPATH<tab>TITLE (one per line, highest score first)
# Usage: broca_recall <memory_dir> <query> [max_results]
broca_recall() {
    local memory_dir="$1"
    local query="$2"
    local max_results="${3:-10}"
    local knowledge_dir="$memory_dir/knowledge"

    if [ ! -d "$knowledge_dir" ]; then
        return
    fi

    # Split query into words for multi-word matching
    local query_lower
    query_lower=$(echo "$query" | tr '[:upper:]' '[:lower:]')

    local results=""

    for filepath in "$knowledge_dir"/*.md; do
        [ -f "$filepath" ] || continue

        local score=0
        local content
        content=$(cat "$filepath")
        local content_lower
        content_lower=$(echo "$content" | tr '[:upper:]' '[:lower:]')

        # Score: keyword matches in content (1 point each, max 5)
        local keyword_hits=0
        for word in $query_lower; do
            if echo "$content_lower" | grep -qF "$word"; then
                keyword_hits=$((keyword_hits + 1))
            fi
        done
        if [ "$keyword_hits" -gt 5 ]; then
            keyword_hits=5
        fi
        score=$((score + keyword_hits * 2))

        # Skip entries with zero keyword matches
        if [ "$keyword_hits" -eq 0 ]; then
            continue
        fi

        # Score: title match (3 bonus points)
        local title_line
        title_line=$(grep "^# " "$filepath" | head -1 || true)
        local title_lower
        title_lower=$(echo "$title_line" | tr '[:upper:]' '[:lower:]')
        for word in $query_lower; do
            if echo "$title_lower" | grep -qF "$word"; then
                score=$((score + 3))
            fi
        done

        # Score: tag match (2 bonus points per tag)
        local tags_line
        tags_line=$(grep "^tags:" "$filepath" || true)
        for word in $query_lower; do
            if echo "$tags_line" | tr '[:upper:]' '[:lower:]' | grep -qF "$word"; then
                score=$((score + 2))
            fi
        done

        # Score: confidence (add confidence * 2, rounded)
        local confidence
        confidence=$(grep "^confidence:" "$filepath" | head -1 | sed 's/confidence: *//' || echo "0.5")
        # Convert to integer score (0.8 -> 1, 1.0 -> 2)
        local conf_score
        conf_score=$(echo "$confidence" | awk '{printf "%d", $1 * 2}')
        score=$((score + conf_score))

        # Score: recency (newer files get more points)
        # Files are named with timestamps, so alphabetical sort = chronological
        local filename
        filename=$(basename "$filepath")
        local file_date
        file_date=$(echo "$filename" | cut -d_ -f1,2,3 | tr '-' ' ' | tr '_' ' ')
        # Simple recency: +1 for all entries (could be improved with proper date math)
        score=$((score + 1))

        # Extract title for display
        local display_title
        display_title=$(echo "$title_line" | sed 's/^# //')

        results="${results}${score}\t${filepath}\t${display_title}\n"
    done

    # Sort by score (descending) and limit results
    if [ -n "$results" ]; then
        printf "%b" "$results" | sort -t$'\t' -k1 -rn | head -"$max_results"
    fi
}

# Show a memory entry's content (title + body, without frontmatter)
# Usage: broca_show <filepath>
broca_show() {
    local filepath="$1"
    if [ ! -f "$filepath" ]; then
        echo "(Entry not found: $filepath)"
        return 1
    fi
    # Skip YAML frontmatter (between --- markers)
    sed -n '/^---$/,/^---$/!p' "$filepath" | tail -n +1
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

# --- Memory Updates ---

# Update confidence on an existing entry
# Usage: broca_update_confidence <filepath> <new_confidence>
broca_update_confidence() {
    local filepath="$1"
    local new_confidence="$2"

    if [ ! -f "$filepath" ]; then
        echo "Entry not found: $filepath" >&2
        return 1
    fi

    # Replace confidence line in frontmatter
    sed -i.bak "s/^confidence: .*/confidence: $new_confidence/" "$filepath"
    rm -f "${filepath}.bak"
    echo "$filepath"
}

# Mark an entry as superseded by another
# Usage: broca_supersede <old_filepath> <new_filepath>
broca_supersede() {
    local old_filepath="$1"
    local new_filepath="$2"

    if [ ! -f "$old_filepath" ]; then
        echo "Entry not found: $old_filepath" >&2
        return 1
    fi

    local new_basename
    new_basename=$(basename "$new_filepath")

    # Add superseded_by to frontmatter (before the closing ---)
    sed -i.bak "/^---$/,/^---$/ {
        /^---$/!b
        N
        /^---\n---$/!{
            P
            D
        }
        i\\
superseded_by: $new_basename
    }" "$old_filepath" 2>/dev/null || {
        # Fallback: just append after first frontmatter line
        sed -i.bak "0,/^confidence:/{s/^confidence: .*/&\nsuperseded_by: $new_basename/}" "$old_filepath"
    }
    rm -f "${old_filepath}.bak"

    # Drop confidence of old entry
    broca_update_confidence "$old_filepath" "0.3"
}

# Add a relationship between entries
# Usage: broca_relate <filepath> <relation_type> <target_filepath>
# relation_type: supports, contradicts, extends, depends_on
broca_relate() {
    local filepath="$1"
    local relation="$2"
    local target="$3"

    if [ ! -f "$filepath" ]; then
        echo "Entry not found: $filepath" >&2
        return 1
    fi

    local target_basename
    target_basename=$(basename "$target")

    # Append relation to the end of the file
    echo "" >> "$filepath"
    echo "_${relation}: ${target_basename}_" >> "$filepath"
}

# --- Index Generation ---

# Generate a YAML index of all knowledge entries for quick lookup
# Usage: broca_index <memory_dir>
broca_index() {
    local memory_dir="$1"
    local knowledge_dir="$memory_dir/knowledge"
    local index_file="$memory_dir/index.yml"

    if [ ! -d "$knowledge_dir" ]; then
        echo "No knowledge directory found." >&2
        return 1
    fi

    echo "# Broca Knowledge Index" > "$index_file"
    echo "# Auto-generated — do not edit" >> "$index_file"
    echo "# Generated: $(date +%Y-%m-%d_%H-%M-%S)" >> "$index_file"
    echo "" >> "$index_file"
    echo "entries:" >> "$index_file"

    for filepath in "$knowledge_dir"/*.md; do
        [ -f "$filepath" ] || continue

        local filename
        filename=$(basename "$filepath")
        local entry_type
        entry_type=$(grep "^type:" "$filepath" | head -1 | sed 's/type: *//' || echo "unknown")
        local tags
        tags=$(grep "^tags:" "$filepath" | head -1 | sed 's/tags: *//' || echo "[]")
        local confidence
        confidence=$(grep "^confidence:" "$filepath" | head -1 | sed 's/confidence: *//' || echo "0.5")
        local title
        title=$(grep "^# " "$filepath" | head -1 | sed 's/^# //' || echo "untitled")
        local created
        created=$(grep "^created:" "$filepath" | head -1 | sed 's/created: *//' || echo "unknown")

        echo "  - file: $filename" >> "$index_file"
        echo "    title: \"$title\"" >> "$index_file"
        echo "    type: $entry_type" >> "$index_file"
        echo "    tags: $tags" >> "$index_file"
        echo "    confidence: $confidence" >> "$index_file"
        echo "    created: $created" >> "$index_file"
    done

    echo "$index_file"
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

    # Entries by type
    echo ""
    echo "By type:"
    grep -h "^type:" "$memory_dir/knowledge/"*.md 2>/dev/null | \
        sed 's/type: *//' | \
        sort | uniq -c | sort -rn

    # Tag frequency
    echo ""
    echo "Top tags:"
    grep -h "^tags:" "$memory_dir/knowledge/"*.md 2>/dev/null | \
        sed 's/tags: *\[//;s/\]//;s/"//g' | \
        tr ',' '\n' | \
        sed 's/^ *//;s/ *$//' | \
        sort | uniq -c | sort -rn | head -10

    # Confidence distribution
    echo ""
    echo "Confidence levels:"
    grep -h "^confidence:" "$memory_dir/knowledge/"*.md 2>/dev/null | \
        sed 's/confidence: *//' | \
        awk '{
            if ($1 >= 0.9) high++;
            else if ($1 >= 0.6) med++;
            else low++;
        } END {
            printf "  High (>=0.9): %d\n  Medium (0.6-0.9): %d\n  Low (<0.6): %d\n", high+0, med+0, low+0
        }'
}

export -f broca_remember broca_journal broca_search_tag broca_search broca_recall broca_show broca_recent broca_journal_recent broca_state broca_stats broca_update_confidence broca_supersede broca_relate broca_index
