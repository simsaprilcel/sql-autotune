#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SQL Auto-Tune Runner (generic)
#
# Executes query.sql, measures elapsed time, validates correctness against
# baseline_results.csv. Configuration is read from config.sh.
#
# Usage: ./run.sh [CONNECTION_OVERRIDE]
#
# Output (last lines, grep-friendly):
#   elapsed_seconds: 12.345
#   row_count:       86
#   correctness:     PASS|FAIL|BASELINE|CRASH
# ---------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load configuration
source "$SCRIPT_DIR/config.sh"

# Allow connection override from CLI arg
CONNECTION="${1:-$CONNECTION}"

QUERY_FILE="$SCRIPT_DIR/query.sql"
BASELINE_FILE="$SCRIPT_DIR/baseline_results.csv"
RESULT_FILE="$SCRIPT_DIR/run_results.csv"
# Raw SQLcl stdout+stderr, before the trailer lines are trimmed. Kept separate
# so error text is still available when the output is too short for `head -n -2`.
RAW_FILE="$SCRIPT_DIR/run_raw.csv"

# Error text SQLcl emits on a bad statement. Matched to classify a run as CRASH
# and to decide which log lines are safe to echo.
DIAG_PATTERN='^[[:space:]]*(ORA-|SP2-|PLS-|TNS-|SQL Error|Usage:|Exception|java\.|Caused by:|at [a-zA-Z]+\.)'

# Echo only diagnostic lines from a SQLcl output file, and report how many lines
# were withheld. Result rows may contain protected data (FERPA) and this log is
# read by the agent, so nothing but recognized error text is allowed through.
print_diagnostics() {
    local file="$1" total diag diag_lines
    echo "--- DIAGNOSTICS (data rows suppressed) ---"
    total=$(wc -l < "$file" 2>/dev/null || echo 0)
    diag=$(grep -E "$DIAG_PATTERN" "$file" 2>/dev/null | head -20 || true)
    if [ -n "$diag" ]; then
        printf '%s\n' "$diag"
        diag_lines=$(printf '%s\n' "$diag" | wc -l)
    else
        echo "  (no recognized error text found)"
        diag_lines=0
    fi
    echo "  suppressed_lines: $(( total - diag_lines ))"
    echo "---"
}

if [ ! -f "$QUERY_FILE" ]; then
    echo "ERROR: query.sql not found. Drop your query into $QUERY_FILE"
    echo "---"
    echo "elapsed_seconds: 0.000"
    echo "row_count:       0"
    echo "correctness:     CRASH"
    exit 1
fi

# ---------------------------------------------------------------------------
# Read query and substitute bind variables
# ---------------------------------------------------------------------------
QUERY=$(cat "$QUERY_FILE")

for bind in "${BINDS[@]}"; do
    [ -z "$bind" ] && continue
    NAME="${bind%%=*}"
    VALUE="${bind#*=}"
    # Use word-boundary-aware sed: replace :name but not :name_suffix
    QUERY=$(echo "$QUERY" | sed "s/:${NAME}\b/'${VALUE}'/g")
done

# ---------------------------------------------------------------------------
# Run with timing (CSV output for diff comparison)
# ---------------------------------------------------------------------------
echo "Running query against $CONNECTION ..."

START_TIME=$(date +%s%N)

# Run with timeout. `set -o pipefail` inside the inner shell is required: without
# it the pipeline's status is that of the last stage, so a failing `sql` looks
# like success. WHENEVER SQLERROR makes SQLcl exit non-zero on a bad statement
# instead of printing ORA-xxxxx and exiting 0.
# Capture the real status: inside an `if ! cmd` branch, $? is the status of the
# negation (always 0), which would defeat the 124 timeout check below.
set +e
timeout "${QUERY_TIMEOUT}s" bash -c "
set -o pipefail
echo \"
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE
SET SQLBLANKLINES ON
SET SQLFORMAT csv
SET PAGESIZE 0
SET FEEDBACK OFF

$QUERY
\" | sql -s \"$CONNECTION\"
" > "$RAW_FILE" 2>&1
EXIT_CODE=$?
set -e

if [ "$EXIT_CODE" -ne 0 ]; then
    END_TIME=$(date +%s%N)
    ELAPSED=$(echo "scale=3; ($END_TIME - $START_TIME) / 1000000000" | bc)
    if [ "$EXIT_CODE" -eq 124 ]; then
        echo "TIMEOUT: Query exceeded ${QUERY_TIMEOUT}s limit"
    else
        echo "ERROR: Query execution failed (exit code $EXIT_CODE)"
        print_diagnostics "$RAW_FILE"
    fi
    echo "---"
    echo "elapsed_seconds: $ELAPSED"
    echo "row_count:       0"
    echo "correctness:     CRASH"
    exit 1
fi

END_TIME=$(date +%s%N)

ELAPSED=$(echo "scale=3; ($END_TIME - $START_TIME) / 1000000000" | bc)

# Belt and braces: SQLcl can report some problems on stdout while still exiting
# 0. Treat any recognized error text as a CRASH rather than letting it fall
# through to the diff, where it would be reported as a plain wrong-results FAIL.
if grep -qE "$DIAG_PATTERN" "$RAW_FILE" 2>/dev/null; then
    echo "ERROR: SQLcl reported an error in the query output"
    print_diagnostics "$RAW_FILE"
    echo "---"
    echo "elapsed_seconds: $ELAPSED"
    echo "row_count:       0"
    echo "correctness:     CRASH"
    exit 1
fi

# Trim SQLcl's two trailer lines to get the comparable result set.
head -n -2 "$RAW_FILE" > "$RESULT_FILE"

ROW_COUNT=$(wc -l < "$RESULT_FILE")

# ---------------------------------------------------------------------------
# Correctness check: diff against baseline
# ---------------------------------------------------------------------------
if [ ! -f "$BASELINE_FILE" ]; then
    echo "No baseline file found. Saving current results as baseline."
    cp "$RESULT_FILE" "$BASELINE_FILE"
    CORRECTNESS="BASELINE"
elif diff -q "$BASELINE_FILE" "$RESULT_FILE" > /dev/null 2>&1; then
    CORRECTNESS="PASS"
else
    CORRECTNESS="FAIL"
    # Report the SHAPE of the mismatch only — never the cell values. Result rows
    # may contain protected data (FERPA), and this log is read by the agent, so
    # it goes to an external API. Where the output diverged is enough to fix the
    # query; what it contains is not needed. Column positions are derived by a
    # naive comma split, so they are approximate for quoted fields.
    echo "--- DIFF SUMMARY (redacted: line/column positions only, no values) ---"
    awk -F',' '
        NR == FNR { base[FNR] = $0; base_nf[FNR] = NF; base_rows = FNR; next }
        {
            result_rows = FNR
            if (!(FNR in base)) { extra++; next }
            if ($0 == base[FNR]) next
            difflines++
            if (shown < 10) {
                if (NF != base_nf[FNR]) {
                    printf "  line %d: column count %d -> %d\n", FNR, base_nf[FNR], NF
                } else {
                    split(base[FNR], bf, ",")
                    cols = ""
                    for (i = 1; i <= NF; i++)
                        if ($i != bf[i]) cols = cols (cols == "" ? "" : " ") i
                    printf "  line %d: differing columns: %s\n", FNR, cols
                }
                shown++
            }
        }
        END {
            missing = base_rows - result_rows
            printf "  baseline_rows:  %d\n", base_rows
            printf "  result_rows:    %d\n", result_rows
            printf "  differing_rows: %d\n", difflines
            if (extra > 0)   printf "  extra_rows:     %d (result has rows past end of baseline)\n", extra
            if (missing > 0) printf "  missing_rows:   %d (result is short of baseline)\n", missing
            if (difflines > shown) printf "  (%d more differing rows not listed)\n", difflines - shown
        }
    ' "$BASELINE_FILE" "$RESULT_FILE"
    echo "---"
fi

# ---------------------------------------------------------------------------
# Summary (grep-friendly)
# ---------------------------------------------------------------------------
echo "---"
echo "elapsed_seconds: $ELAPSED"
echo "row_count:       $ROW_COUNT"
echo "correctness:     $CORRECTNESS"
