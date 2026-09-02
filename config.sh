#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# SQL Auto-Tune Configuration
#
# Edit this file for each new query you want to optimize.
# ---------------------------------------------------------------------------

# Database connection string.
# Use a QUERY-ONLY account. The agent runs whatever is in query.sql; a
# least-privilege account is the control that makes that safe.
#
# Oracle SQLcl examples:
#   CONNECTION="/@MY_WALLET_ALIAS"                # Oracle wallet — no password on disk
#   CONNECTION="scott/tiger@MYDB"                 # user/pass@TNS
#   CONNECTION="scott/tiger@//host:1521/service"  # Easy Connect
CONNECTION="/@PROGSAGE"

# Bind variable substitutions.
# query.sql can use :name placeholders. Each entry maps a name to a literal
# value. The runner wraps values in single quotes automatically.
#
# Example: for "WHERE created_date > :start_date", add "start_date=2025-01-01"
#
# Leave empty if your query has no bind variables.
BINDS=(
    "max_tables=1500"
)

# Maximum experiment iterations (including the baseline run).
MAX_ITERATIONS=20

# Query timeout in seconds. Runs exceeding this are killed and marked as crash.
QUERY_TIMEOUT=300
