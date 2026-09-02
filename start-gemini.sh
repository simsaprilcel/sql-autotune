#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SQL Auto-Tune Launcher — Gemini CLI variant
#
# Kicks off an autonomous Gemini CLI session to optimize query.sql.
# See docs/gemini-cli-setup.md for setup and the differences from start.sh.
#
# Usage:
#   ./start-gemini.sh              # single session, uses MAX_ITERATIONS from config.sh
#   ./start-gemini.sh 50           # single session, 50 iterations
#   ./start-gemini.sh --loop       # restart automatically, uses config.sh
#   ./start-gemini.sh --loop 50    # restart automatically, 50 iterations
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

if [ ! -f ".gemini/settings.json" ]; then
    echo "ERROR: No .gemini/settings.json found."
    echo "See docs/gemini-cli-setup.md section 5 — the result-CSV boundary"
    echo "must come from OS permissions or a sandbox mount, not settings.json alone."
    exit 1
fi

# Source config, then apply CLI override if given
source config.sh
if [ -n "$ITER_OVERRIDE" ]; then
    MAX_ITERATIONS="$ITER_OVERRIDE"
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
#
# Gemini CLI has no --max-turns flag — the ceiling is model.maxSessionTurns
# in .gemini/settings.json. Patch it in place so the config the agent runs
# under always matches this invocation's iteration budget.
# ---------------------------------------------------------------------------

MAX_TURNS=$(( MAX_ITERATIONS * 5 + 10 ))

python3 - "$MAX_TURNS" <<'PYEOF'
import json, sys
path = ".gemini/settings.json"
with open(path) as f:
    settings = json.load(f)
settings.setdefault("model", {})["maxSessionTurns"] = int(sys.argv[1])
with open(path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")
PYEOF

# ---------------------------------------------------------------------------
# Launch prompt
# ---------------------------------------------------------------------------

PROMPT="Read program.md and begin. Run $MAX_ITERATIONS experiments (including the baseline). If results.tsv exists with entries, you are resuming — read it to see what's been tried and continue from where it left off. Otherwise start fresh with the baseline."

# ---------------------------------------------------------------------------
# Launch
# ---------------------------------------------------------------------------

run_session() {
    echo "============================================"
    echo "  SQL Auto-Tune — starting Gemini session"
    echo "  Branch:     $(git rev-parse --abbrev-ref HEAD)"
    echo "  Query:      $SCRIPT_DIR/query.sql"
    echo "  Iterations: $MAX_ITERATIONS"
    echo "  Max turns:  $MAX_TURNS"
    echo "============================================"
    echo ""

    # exit code 53 = Gemini CLI's own turn-limit exit, treated like a clean
    # stop below, same as a Claude session ending on --max-turns.
    set +e
    gemini -p "$PROMPT" --approval-mode auto_edit
    STATUS=$?
    set -e
    if [ "$STATUS" -ne 0 ] && [ "$STATUS" -ne 53 ]; then
        return "$STATUS"
    fi
    return 0
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
