#!/bin/bash
# Boucle — Core loop runner
# This is the engine that drives each agent iteration.

set -euo pipefail

# --- Configuration ---
BOUCLE_VERSION="0.1.0"

# Find the agent root (where boucle.toml lives)
find_agent_root() {
    local dir="$1"
    while [ "$dir" != "/" ]; do
        if [ -f "$dir/boucle.toml" ]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# --- Locking ---
acquire_lock() {
    local lock_file="$1/.boucle.lock"
    if [ -f "$lock_file" ]; then
        local existing_pid
        existing_pid=$(cat "$lock_file")
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo "ERROR: Agent is already running (PID $existing_pid). Skipping." >&2
            return 1
        else
            echo "WARN: Stale lock file (PID $existing_pid is dead). Cleaning up." >&2
            rm -f "$lock_file"
        fi
    fi
    echo $$ > "$lock_file"
}

release_lock() {
    local lock_file="$1/.boucle.lock"
    rm -f "$lock_file"
}

# --- Context Assembly ---
# Builds the full prompt from the agent's current state
assemble_context() {
    local agent_dir="$1"

    echo "## Current State"
    echo ""

    # Memory / State
    if [ -f "$agent_dir/memory/state.md" ]; then
        echo "### Memory"
        echo ""
        cat "$agent_dir/memory/state.md"
        echo ""
    fi

    # Goals
    echo "### Goals"
    echo ""
    local found_goals=0
    for f in "$agent_dir"/goals/*.md; do
        if [ -f "$f" ]; then
            cat "$f"
            echo -e "\n---\n"
            found_goals=1
        fi
    done
    if [ "$found_goals" -eq 0 ]; then
        echo "(No active goals.)"
    fi
    echo ""

    # Pending approvals
    echo "### Pending Approvals"
    echo ""
    local found_gates=0
    for f in "$agent_dir"/gates/*.md; do
        if [ -f "$f" ]; then
            cat "$f"
            echo -e "\n---\n"
            found_gates=1
        fi
    done
    if [ "$found_gates" -eq 0 ]; then
        echo "(No pending approvals.)"
    fi
    echo ""

    # Journal (last entry)
    echo "### Last Journal Entry"
    echo ""
    local last_entry
    last_entry=$(ls -t "$agent_dir"/memory/journal/*.md 2>/dev/null | head -1)
    if [ -n "${last_entry:-}" ] && [ -f "$last_entry" ]; then
        cat "$last_entry"
    else
        echo "(No previous journal entries.)"
    fi
    echo ""

    # System status
    echo "### System Status"
    echo ""
    echo "- Timestamp: $(date +%Y-%m-%d_%H-%M-%S)"
    echo "- Iteration count: $(ls "$agent_dir"/memory/journal/*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "- Git status: $(git -C "$agent_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted changes"
}

# --- Main Loop Execution ---
run_iteration() {
    local agent_dir="$1"
    local timestamp
    timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local log_file="$agent_dir/logs/$timestamp.md"

    # Ensure directories exist
    mkdir -p "$agent_dir/memory/journal" "$agent_dir/memory/knowledge"
    mkdir -p "$agent_dir/goals" "$agent_dir/gates" "$agent_dir/logs"

    # Acquire lock
    acquire_lock "$agent_dir" || exit 0
    trap "release_lock '$agent_dir'" EXIT

    echo "=== Boucle Loop: $timestamp ==="
    echo "Agent directory: $agent_dir"

    # Assemble context
    echo "Assembling context..."
    local context
    context=$(assemble_context "$agent_dir")

    # Read agent config for LLM settings
    local system_prompt
    system_prompt=$(read_system_prompt "$agent_dir")

    # Invoke the LLM
    echo "Invoking LLM..."
    cd "$agent_dir"

    local exit_code=0
    claude -p \
        --system-prompt "$system_prompt" \
        "$context" \
        > "$log_file" 2>&1 || exit_code=$?

    if [ "$exit_code" -ne 0 ]; then
        echo "LLM exited with code $exit_code" >> "$log_file"
        echo "ERROR: LLM failed (exit $exit_code). Log: $log_file" >&2
    fi

    # Commit changes
    echo "Committing iteration..."
    git -C "$agent_dir" add -A
    if ! git -C "$agent_dir" diff --cached --quiet; then
        git -C "$agent_dir" \
            -c user.name="Boucle" \
            -c user.email="boucle@bande-a-bonnot.dev" \
            commit -m "Loop iteration: $timestamp"
    else
        echo "No changes to commit."
    fi

    echo "Loop complete. Log: $log_file"
}

# Read the system prompt from config or use default
read_system_prompt() {
    local agent_dir="$1"
    if [ -f "$agent_dir/system-prompt.md" ]; then
        cat "$agent_dir/system-prompt.md"
    else
        echo "You are an autonomous AI agent running in a loop. Read your current state and decide what to do. Update your memory when done."
    fi
}

# Export functions for use by the CLI
export -f find_agent_root acquire_lock release_lock assemble_context run_iteration read_system_prompt
