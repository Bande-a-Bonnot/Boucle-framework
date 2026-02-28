#!/bin/bash
# Boucle — Scheduling utilities
# Set up recurring agent execution via launchd (macOS) or cron (Linux)

set -euo pipefail

BOUCLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parse interval string to seconds
# Supports: 30s, 5m, 1h, 2h, 1d
interval_to_seconds() {
    local interval="$1"
    local number="${interval%[smhd]}"
    local unit="${interval: -1}"

    case "$unit" in
        s) echo "$number" ;;
        m) echo $((number * 60)) ;;
        h) echo $((number * 3600)) ;;
        d) echo $((number * 86400)) ;;
        *) echo "ERROR: Unknown interval unit '$unit'. Use s/m/h/d." >&2; return 1 ;;
    esac
}

# Set up launchd (macOS)
setup_launchd() {
    local agent_dir="$1"
    local interval_seconds="$2"
    local agent_name="$3"

    local plist_name="com.boucle.${agent_name}"
    local plist_path="$HOME/Library/LaunchAgents/${plist_name}.plist"
    local boucle_bin="$BOUCLE_DIR/bin/boucle"

    # Generate plist from template
    sed \
        -e "s|{{AGENT_NAME}}|${agent_name}|g" \
        -e "s|{{BOUCLE_BIN}}|${boucle_bin}|g" \
        -e "s|{{AGENT_DIR}}|${agent_dir}|g" \
        -e "s|{{INTERVAL_SECONDS}}|${interval_seconds}|g" \
        "$BOUCLE_DIR/templates/launchd.plist" > "$plist_path"

    echo "Created: $plist_path"
    echo ""
    echo "To activate:"
    echo "  launchctl load $plist_path"
    echo ""
    echo "To deactivate:"
    echo "  launchctl unload $plist_path"
    echo ""
    echo "To check status:"
    echo "  launchctl list | grep boucle"
}

# Set up cron (Linux/generic)
setup_cron() {
    local agent_dir="$1"
    local interval_seconds="$2"
    local boucle_bin="$BOUCLE_DIR/bin/boucle"

    local interval_minutes=$((interval_seconds / 60))
    if [ "$interval_minutes" -lt 1 ]; then
        interval_minutes=1
    fi

    local cron_expr
    if [ "$interval_minutes" -lt 60 ]; then
        cron_expr="*/$interval_minutes * * * *"
    elif [ "$interval_minutes" -lt 1440 ]; then
        local hours=$((interval_minutes / 60))
        cron_expr="0 */$hours * * *"
    else
        cron_expr="0 0 * * *"
    fi

    local cron_line="$cron_expr cd $agent_dir && $boucle_bin run"

    echo "Add this to your crontab (crontab -e):"
    echo ""
    echo "  $cron_line"
    echo ""
    echo "Or run:"
    echo "  (crontab -l 2>/dev/null; echo '$cron_line') | crontab -"
}

# Main schedule command
cmd_schedule() {
    local agent_dir
    agent_dir=$(find_agent_root "$(pwd)") || {
        echo "ERROR: No boucle.toml found." >&2
        exit 1
    }

    # Read config
    local interval="1h"
    local method="launchd"
    local agent_name="agent"

    if [ -f "$agent_dir/boucle.toml" ]; then
        interval=$(grep '^interval' "$agent_dir/boucle.toml" | head -1 | sed 's/.*= *"\(.*\)"/\1/' || echo "1h")
        method=$(grep '^method' "$agent_dir/boucle.toml" | head -1 | sed 's/.*= *"\(.*\)"/\1/' || echo "launchd")
        agent_name=$(grep '^name' "$agent_dir/boucle.toml" | head -1 | sed 's/.*= *"\(.*\)"/\1/' || echo "agent")
    fi

    # Override with CLI args
    while [ $# -gt 0 ]; do
        case "$1" in
            --interval) interval="$2"; shift 2 ;;
            --method) method="$2"; shift 2 ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    local seconds
    seconds=$(interval_to_seconds "$interval")

    echo "Setting up $method schedule for '$agent_name'"
    echo "Interval: $interval ($seconds seconds)"
    echo ""

    case "$method" in
        launchd)
            setup_launchd "$agent_dir" "$seconds" "$agent_name"
            ;;
        cron)
            setup_cron "$agent_dir" "$seconds"
            ;;
        *)
            echo "ERROR: Unknown scheduling method '$method'. Use 'launchd' or 'cron'." >&2
            exit 1
            ;;
    esac
}

export -f interval_to_seconds setup_launchd setup_cron cmd_schedule
