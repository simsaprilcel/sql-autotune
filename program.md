# sql-autotune

Autonomous SQL query optimization using an experiment loop.

## Setup

1. **Read the in-scope files**:
   - `program.md` — this file (experiment protocol).
   - `query.sql` — the SQL query you modify. This is the **only** file you edit.
   - `prepare.sh` — fixed runner script. Executes query, measures time, validates correctness. Do not modify.
   - `config.sh` — connection and bind variable configuration. Do not modify.
   - `baseline_results.csv` — ground truth output. Results must match exactly. Do not modify.
2. **Check state**: Look at `results.tsv`. If it exists and has entries, you are resuming — read the history to understand what's been tried. Pick up from the current git state.
3. **If no baseline exists**: Run `./prepare.sh > run.log 2>&1` to establish the baseline. This also creates `baseline_results.csv`. Log it as the first entry in `results.tsv`.
4. **Begin the experiment loop**.

## Experimentation

Each experiment runs a single SQL query against an Oracle database. Launch with:
```bash
./prepare.sh > run.log 2>&1
```

**What you CAN do:**
- Modify `query.sql` — this is the only file you edit. Everything is fair game: query structure, join order, CTE restructuring, Oracle hints, analytic functions, subquery factoring, materialization hints, etc.

**What you CANNOT do:**
- Modify `prepare.sh`, `config.sh`, `baseline_results.csv`, or `program.md`.
- Create database objects (tables, indexes, views, materialized views). You can only change the query itself.
- Change the output columns or ordering. Results must be byte-identical to baseline.
- **Read, print, copy, or otherwise inspect the contents of `baseline_results.csv`, `run_results.csv`, or `run_raw.csv`.** These hold real result rows, which may include protected student data. Do not `cat`, `head`, `tail`, `grep`, `diff`, or Read them. `prepare.sh` performs the comparison for you and reports the verdict plus a redacted line/column summary — that is the only view of the data you get, and it is sufficient. If a query returns wrong results, reason about it from the SQL and the redacted summary.
- Run ad-hoc queries against the database outside `prepare.sh` (no direct `sql` invocations). The runner is the only path to the database.

**The goal is simple: get the lowest elapsed_seconds.** The constraint is that `correctness` must always be `PASS`.

**Simplicity criterion**: All else being equal, simpler is better. A small improvement that adds ugly complexity is not worth it. Removing complexity for equal or better performance is a great outcome.

## Output format

The runner prints a summary:
```
---
elapsed_seconds: 28.123
row_count:       86
correctness:     PASS
```

Extract key metrics:
```bash
grep "^elapsed_seconds:\|^correctness:" run.log
```

## Logging results

Log each experiment to `results.tsv` (tab-separated).

Header and columns:
```
commit	elapsed_sec	correctness	status	description
```

1. git commit hash (short, 7 chars)
2. elapsed_seconds (e.g. 28.123) — use 0.000 for crashes
3. correctness: PASS, FAIL, or CRASH
4. status: `keep`, `discard`, or `crash`
5. short text description of what this experiment tried

Example:
```
commit	elapsed_sec	correctness	status	description
a1b2c3d	28.123	PASS	keep	baseline
b2c3d4e	15.456	PASS	keep	added MATERIALIZE hints to CTEs
c3d4e5f	28.900	PASS	discard	reordered joins (no improvement)
d4e5f6g	0.000	CRASH	crash	syntax error in hint
```

## The experiment loop

LOOP FOREVER (up to MAX_ITERATIONS — check `config.sh` for the current value):

1. Look at the git state: the current branch/commit.
2. Modify `query.sql` with an optimization idea.
3. git commit.
4. Run the query **at least 3 times** to account for Oracle caching effects:
   ```bash
   ./prepare.sh > run1.log 2>&1
   ./prepare.sh > run2.log 2>&1
   ./prepare.sh > run3.log 2>&1
   ```
5. Read results from each run: `grep "^elapsed_seconds:\|^correctness:" run1.log run2.log run3.log`
6. If grep is empty or correctness is CRASH, run `tail -n 30 run1.log` to diagnose. The log carries only filtered diagnostics (`ORA-`/`SP2-` and similar) — data rows are suppressed by design. On a FAIL, the log's redacted diff summary gives you the differing line and column positions; use those to reason about the SQL, and do not try to view the underlying rows.
7. **Use the best (lowest) elapsed_seconds** from the runs as the representative time for this experiment. The first run often includes cold-cache overhead (parsing, buffer cache misses) that inflates the time. Subsequent runs reflect steady-state performance, which is what matters for comparison.
8. Record the best result in `results.tsv` (do NOT commit results.tsv).
9. If elapsed_seconds improved AND correctness is PASS — keep the commit ("advance").
10. If elapsed_seconds is worse OR correctness is FAIL — `git reset --hard HEAD~1` to revert.

**Why multiple runs matter**: Oracle caches data blocks, parsed cursors, and result sets. A single run of a changed query may appear slower simply because the cache is cold, or appear faster due to residual caching from a prior query variant. Running multiple times lets the cache warm up and gives you a stable, comparable measurement. A single run is **not sufficient** to judge whether an optimization helped.

**Timeout**: Configured in `config.sh`. Runs exceeding the timeout are killed automatically by `prepare.sh`.

**Optimization ideas to try** (non-exhaustive, Oracle-specific):
- **Replace PL/SQL function calls with pure SQL joins/subqueries.** This is often the single biggest win. A scalar function called in a `SELECT` list causes a PL/SQL-to-SQL context switch **per row** — extremely expensive at scale. Look up what the function does (it usually queries one table and returns a value) and replace it with a direct JOIN or scalar subquery. For example, a `fx_getCollege(pidm, term)` wrapper probably just looks up `sgbstdn_coll_code_1` from `sgbstdn` — a JOIN is orders of magnitude faster than calling the function per row.

  Below, `xx_*` / `fx_*` stand in for your site's locally-written packages and functions. Most Banner shops wrap common lookups in a house package with a site-specific prefix; substitute yours. `f_get_desc_fnc` is baseline Banner and is named literally.

  - `f_get_desc_fnc('STVXXX', code, len)` → JOIN to the `stvxxx` validation table and select `stvxxx_desc`
  - `xx_student.fx_get*(pidm, term)` → JOIN to `sgbstdn` (student record) with effective-date logic
  - `xx_person.fx_get*(pidm)` → JOIN to person tables (`spbpers`, `spriden`, etc.)
  - `xx_address.fx_get*(pidm)` → JOIN to `spraddr` with address type and priority logic
  - `xx_email.fx_get*(pidm)` → JOIN to `goremal` with preferred email logic
  - `xx_phone.fx_getPhone(pidm, type)` → JOIN to `sprtele` filtered by phone type
  - `xx_enrollment.fx_get*(pidm, term)` → JOIN to `sfrstcr` with registration status filter
  - `xx_admission.fx_is*(pidm, term)` → semi-join (`EXISTS`) against `sarappd` / `saradap` rather than a per-row boolean call

  **Before replacing a function, read its source** (`ALL_SOURCE`, or ask a DBA) to confirm what it actually returns — including any effective-date and priority logic you'd need to reproduce in the join.
- Oracle optimizer hints: `/*+ MATERIALIZE */`, `/*+ NO_MERGE */`, `/*+ LEADING(...) */`, `/*+ USE_HASH(...) */`, `/*+ PARALLEL(n) */`
- Replace correlated subqueries with analytic functions (`ROW_NUMBER()`, `MAX() OVER()`)
- Pre-aggregate before joining to reduce intermediate row counts
- Use `/*+ RESULT_CACHE */` for stable CTEs
- Combine multiple scans of the same table into a single pass
- Restructure joins to reduce cross-products
- Factor out repeated subexpressions into CTEs with `/*+ MATERIALIZE */`
- Eliminate unnecessary columns from intermediate results

**Important**: When replacing a function with a JOIN, the results MUST remain byte-identical to the baseline. If you're unsure what a function returns, test conservatively — replace one function at a time and verify correctness before moving on.

**NEVER STOP** within the iteration budget. Do NOT pause to ask the human. The human might be away. If you run out of ideas, re-read the query for new angles, try combining approaches, try more radical restructuring.

After the final iteration (or if you run out of ideas), print a summary of all results from `results.tsv`.

**How to check your iteration limit**: Run `grep MAX_ITERATIONS config.sh` to see how many experiments to run.
