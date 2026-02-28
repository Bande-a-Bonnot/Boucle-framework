#!/bin/bash
# Boucle — Core loop runner
# This is the engine that drives each agent iteration.
#
# Extension points:
#   context.d/  — Executable scripts that output extra context sections
#   hooks/      — Scripts that run at lifecycle points:
#                   pre-run      — before anything else
#                   post-context — after context assembly (receives context as stdin)
#                   post-llm     — after LLM runs (receives exit code as $1)
#                   post-commit  — after git commit (e.g., push to remote)

set -euo pipefail

# --- Configuration ---
BOUCLE_VERSION="0.2.0"

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

# --- Config Parsing ---
# Simple TOML value reader (handles basic key = "value" and key = value)
toml_get() {
    local file="$1"
    local key="$2"
    local default="${3:-}"

    if [ ! -f "$file" ]; then
        echo "$default"
        return
    fi

    local value
    value=$(grep "^${key} " "$file" 2>/dev/null | head -1 | sed 's/.*= *//;s/^"//;s/"$//' || true)
    if [ -n "$value" ]; then
        echo "$value"
    else
        echo "$default"
    fi
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

# --- Script Runner ---
# Runs a script file, detecting interpreter from shebang or file extension.
# This avoids the need for +x permission on the script.
run_script() {
    local script="$1"
    shift

    if [ ! -f "$script" ]; then
        return 1
    fi

    # If executable, run directly
    if [ -x "$script" ]; then
        "$script" "$@"
        return $?
    fi

    # Otherwise, detect interpreter from shebang
    local shebang
    shebang=$(head -1 "$script" 2>/dev/null || true)
    if [[ "$shebang" == "#!/usr/bin/env "* ]]; then
        local interpreter="${shebang#\#!/usr/bin/env }"
        $interpreter "$script" "$@"
        return $?
    elif [[ "$shebang" == "#!"* ]]; then
        local interpreter="${shebang#\#!}"
        $interpreter "$script" "$@"
        return $?
    fi

    # Fallback: detect by extension
    case "$script" in
        *.py)  python3 "$script" "$@" ;;
        *.sh)  bash "$script" "$@" ;;
        *.rb)  ruby "$script" "$@" ;;
        *.js)  node "$script" "$@" ;;
        *)     bash "$script" "$@" ;;  # Default to bash
    esac
}

# --- Hooks ---
# Run a hook script if it exists
run_hook() {
    local agent_dir="$1"
    local hook_name="$2"
    shift 2

    local hook_file="$agent_dir/hooks/$hook_name"
    if [ -f "$hook_file" ]; then
        echo "Running hook: $hook_name"
        run_script "$hook_file" "$@" || {
            echo "WARN: Hook '$hook_name' failed (exit $?)" >&2
        }
    fi
}

# --- Context Assembly ---
# Builds the full prompt from the agent's current state
assemble_context() {
    local agent_dir="$1"
    local config="$agent_dir/boucle.toml"

    echo "## Current Goals"
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

    echo "## Memory"
    echo ""
    # Support both state.md and STATE.md (case-insensitive)
    local state_file=""
    for candidate in "$agent_dir/memory/state.md" "$agent_dir/memory/STATE.md"; do
        if [ -f "$candidate" ]; then
            state_file="$candidate"
            break
        fi
    done
    if [ -n "$state_file" ]; then
        cat "$state_file"
    else
        echo "(No memory yet. This is your first loop.)"
    fi
    echo ""

    echo "## Pending Approvals"
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

    echo "## Last Log Entry"
    echo ""
    local last_log
    last_log=$(ls -t "$agent_dir"/logs/*.md 2>/dev/null | head -1 || true)
    if [ -n "${last_log:-}" ] && [ -f "$last_log" ]; then
        cat "$last_log"
    else
        echo "(No previous logs. This is your first run.)"
    fi
    echo ""

    # Run context plugins (context.d/ scripts)
    if [ -d "$agent_dir/context.d" ]; then
        for plugin in "$agent_dir"/context.d/*; do
            if [ -f "$plugin" ]; then
                echo ""
                run_script "$plugin" "$agent_dir" 2>/dev/null || {
                    echo "(Context plugin '$(basename "$plugin")' failed)" >&2
                }
            fi
        done
    fi
    echo ""

    # System status
    echo "## System Status"
    echo ""
    echo "- Timestamp: $(date +%Y-%m-%d_%H-%M-%S)"
    echo "- Disk free: $(df -h "$agent_dir" 2>/dev/null | awk 'NR==2{print $4}' || echo 'unknown')"
    echo "- Loop iterations so far: $(ls "$agent_dir"/logs/*.md 2>/dev/null | wc -l | tr -d ' ')"
    echo "- Git status: $(git -C "$agent_dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ') uncommitted changes"
    echo "- Last commit: $(git -C "$agent_dir" log -1 --format='%h %s' 2>/dev/null || echo 'none')"
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

# Read allowed tools from config
read_allowed_tools() {
    local agent_dir="$1"
    local config="$agent_dir/boucle.toml"

    if [ -f "$agent_dir/allowed-tools.txt" ]; then
        # One tool per line, joined with commas
        paste -sd, "$agent_dir/allowed-tools.txt" | tr -d ' '
    else
        # Default: all tools
        echo ""
    fi
}

# --- Main Loop Execution ---
run_iteration() {
    local agent_dir="$1"
    local config="$agent_dir/boucle.toml"
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

    # Pre-run hook
    run_hook "$agent_dir" "pre-run" "$timestamp"

    # Assemble context
    echo "Assembling context..."
    local context
    context=$(assemble_context "$agent_dir")

    # Post-context hook (can modify context via stdout)
    if [ -f "$agent_dir/hooks/post-context" ]; then
        context=$(echo "$context" | run_script "$agent_dir/hooks/post-context" "$agent_dir")
    fi

    # Read agent config for LLM settings
    local system_prompt
    system_prompt=$(read_system_prompt "$agent_dir")

    local allowed_tools
    allowed_tools=$(read_allowed_tools "$agent_dir")

    # Build claude command
    local claude_args=("-p" "--system-prompt" "$system_prompt")
    if [ -n "$allowed_tools" ]; then
        claude_args+=("--allowed-tools" "$allowed_tools")
    fi
    claude_args+=("$context")

    # Invoke the LLM
    echo "Invoking LLM..."
    cd "$agent_dir"

    local exit_code=0
    claude "${claude_args[@]}" > "$log_file" 2>&1 || exit_code=$?

    # Check for quota/rate limit issues
    if [ "$exit_code" -ne 0 ]; then
        if grep -qi "rate\|limit\|quota\|capacity\|overloaded\|429\|503" "$log_file" 2>/dev/null; then
            echo "QUOTA HIT — skipping this iteration" >> "$log_file"
            echo "Quota/rate limit hit. Will retry next iteration."
            release_lock "$agent_dir"
            trap - EXIT
            exit 0
        else
            echo "LLM exited with code $exit_code" >> "$log_file"
            echo "ERROR: LLM failed (exit $exit_code). Log: $log_file" >&2
        fi
    fi

    # Post-LLM hook
    run_hook "$agent_dir" "post-llm" "$exit_code"

    # Read git config from boucle.toml
    local git_name
    git_name=$(toml_get "$config" "commit_name" "Boucle")
    local git_email
    git_email=$(toml_get "$config" "commit_email" "boucle@agent.local")

    # Commit changes
    echo "Committing iteration..."
    git -C "$agent_dir" add -A
    if ! git -C "$agent_dir" diff --cached --quiet; then
        git -C "$agent_dir" \
            -c user.name="$git_name" \
            -c user.email="$git_email" \
            commit -m "Loop iteration: $timestamp"

        # Post-commit hook (e.g., push to remote)
        run_hook "$agent_dir" "post-commit" "$timestamp"
    else
        echo "No changes to commit."
    fi

    echo "Loop complete. Log: $log_file"
}

# Export functions for use by the CLI
export -f find_agent_root acquire_lock release_lock assemble_context run_iteration read_system_prompt read_allowed_tools toml_get run_script run_hook
