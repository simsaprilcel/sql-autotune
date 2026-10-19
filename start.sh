#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SQL Auto-Tune Launcher
#
# Kicks off an autonomous Claude Code session to optimize query.sql.
# Run this from outside a Claude Code session.
#
# Usage:
#   ./start.sh              # single session, uses MAX_ITERATIONS from config.sh
#   ./start.sh 50           # single session, 50 iterations
#   ./start.sh --loop       # restart automatically, uses config.sh
#   ./start.sh --loop 50    # restart automatically, 50 iterations
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------

LOOP=false
ITER_OVERRIDE=""

for arg in "$@"; do
    case "$arg" in
        --loop) LOOP=true ;;
        [0-9]*) ITER_OVERRIDE="$arg" ;;
    esac
done

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

if [ ! -f "query.sql" ]; then
    echo "ERROR: No query.sql found."
    echo ""
    echo "Drop your SQL query into: $SCRIPT_DIR/query.sql"
    echo "Then edit config.sh with your connection and bind variables."
    exit 1
fi

if [ ! -f "config.sh" ]; then
    echo "ERROR: No config.sh found."
    exit 1
fi

# Source config, then apply CLI override if given
source config.sh
if [ -n "$ITER_OVERRIDE" ]; then
    MAX_ITERATIONS="$ITER_OVERRIDE"
    # Update config.sh so the agent sees the same value
    sed -i "s/^MAX_ITERATIONS=.*/MAX_ITERATIONS=$MAX_ITERATIONS/" config.sh
fi

# Ensure prepare.sh is executable
chmod +x prepare.sh

# ---------------------------------------------------------------------------
# Git setup: create branch if not already on an autotune branch
# ---------------------------------------------------------------------------

CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "none")

if [[ ! "$CURRENT_BRANCH" =~ ^autotune/ ]]; then
    TAG=$(date +%b%d | tr '[:upper:]' '[:lower:]')
    BRANCH="autotune/$TAG"

    # Avoid collision
    COUNTER=1
    while git rev-parse --verify "$BRANCH" >/dev/null 2>&1; do
        BRANCH="autotune/${TAG}-${COUNTER}"
        COUNTER=$((COUNTER + 1))
    done

    echo "Creating branch: $BRANCH"
    git checkout -b "$BRANCH"
fi

# ---------------------------------------------------------------------------
# Determine max turns (rough estimate: ~4 turns per experiment + overhead)
# ---------------------------------------------------------------------------

MAX_TURNS=$(( MAX_ITERATIONS * 5 + 10 ))

# ---------------------------------------------------------------------------
# Launch prompt
# ---------------------------------------------------------------------------

PROMPT="Read program.md and begin. Run $MAX_ITERATIONS experiments (including the baseline). If results.tsv exists with entries, you are resuming — read it to see what's been tried and continue from where it left off. Otherwise start fresh with the baseline."

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

run_session() {
    echo "============================================"
    echo "  SQL Auto-Tune — starting Claude session"
    echo "  Branch:     $(git rev-parse --abbrev-ref HEAD)"
    echo "  Query:      $SCRIPT_DIR/query.sql"
    echo "  Iterations: $MAX_ITERATIONS"
    echo "  Max turns:  $MAX_TURNS"
    echo "============================================"
    echo ""

    # JSON output carries token usage and cost; it arrives in one piece when
    # the session ends, so there is no streamed text while the agent works.
    local status=0 out
    out=$(claude -p "$PROMPT" \
        --allowedTools "Edit,Read,Write,Bash,Glob,Grep" \
        --max-turns "$MAX_TURNS" \
        --output-format json) || status=$?

    # One line per session, so --loop runs can be summed afterwards
    echo "$out" | jq -c --arg iter "$MAX_ITERATIONS" '{
        ended: (now | todate), iterations: ($iter | tonumber),
        num_turns, total_cost_usd, usage
    }' >> usage.jsonl 2>/dev/null || true

    echo "$out" | jq -r '.result // empty' 2>/dev/null || echo "$out"
    echo ""
    echo "$out" | jq -r '"Turns: \(.num_turns)  Cost: $\(.total_cost_usd)
Tokens: input \(.usage.input_tokens), cache read \(.usage.cache_read_input_tokens), cache write \(.usage.cache_creation_input_tokens), output \(.usage.output_tokens)"' 2>/dev/null || true

    return "$status"
}

if [ "$LOOP" = true ]; then
    echo "Running in loop mode (restarts on session end)."
    echo "Press Ctrl+C to stop."
    echo ""
    while true; do
        run_session || true
        echo ""
        echo "Session ended. Restarting in 5s... (Ctrl+C to stop)"
        sleep 5
    done
else
    run_session
fi
