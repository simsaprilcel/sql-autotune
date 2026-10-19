# sql-autotune

Autonomous SQL query optimization powered by AI agents.

Give an agent a slow query, a query-only database connection, and a metric. It mutates the query, runs it, checks whether it got faster, keeps or discards, and repeats. You come back to a faster query and a log of every experiment.

Inspired by Karpathy's [autoresearch](https://github.com/karpathy/autoresearch) — the same loop, applied to SQL instead of neural network training.

**Presentation materials** for this repo live in [`presentation/`](presentation/); the Claude command-line setup guide is [`docs/claude-cli-setup.md`](docs/claude-cli-setup.md). A Gemini CLI variant (`start-gemini.sh`, [`docs/gemini-cli-setup.md`](docs/gemini-cli-setup.md)) is also included — the loop and harness are agent-agnostic, but the permission model is not a 1:1 swap; see that doc's §5.

## How it works

Three files that matter:

- **`prepare.sh`** — fixed runner. Executes the query, measures elapsed time, validates correctness against a baseline. Not modified by the agent.
- **`query.sql`** — the query being optimized. The only file the agent edits. Everything is fair game: structure, join order, CTEs, hints, analytic functions, subquery factoring.
- **`program.md`** — instructions for the agent. Defines the experiment loop, the rules, and the logging format.

Supporting files:

- **`config.sh`** — connection, bind variables, iteration limit, timeout.
- **`start.sh`** — launcher. Runs Claude Code non-interactively (`claude -p`) so you can kick it off and walk away.
- **`.claude/settings.json`** — tool permissions. Pre-approves the harness; denies reads of result files, wallets, and keys.
- **`results.tsv`** — the lab notebook (auto-created). Every experiment: commit, elapsed time, correctness, status, description.
- **`baseline_results.csv`** — ground truth (auto-created on first run). Every later run is diffed against it.

Each experiment:

1. The agent edits `query.sql` with an optimization idea
2. Commits the change
3. Runs `prepare.sh` at least three times (Oracle caching — one timing is not evidence)
4. If the best time improved **and** correctness is PASS → keeps the commit
5. If slower or wrong → `git reset --hard`
6. Logs the result to `results.tsv`
7. Repeats

## Data handling

The agent sees **structure, not data**. Result rows stay on the machine; only the SQL, the timing, and a verdict are ever visible to the model.

- Correctness is decided by `prepare.sh` in bash — it diffs the run against the baseline locally and reports `PASS`/`FAIL`/`CRASH`. The agent consumes the verdict, not the rows.
- On a `FAIL`, the log gets a **redacted diff summary** — differing line numbers, differing column positions, and row counts. No cell values.
- On a `CRASH`, only recognized diagnostic lines (`ORA-`, `SP2-`, `PLS-`, …) are echoed, with a count of suppressed lines. This keeps the agent able to fix its own syntax errors without dumping partial result sets into the log.
- `program.md` forbids the agent from reading `baseline_results.csv`, `run_results.csv`, and `run_raw.csv`, and from running queries outside the harness. **That is an instruction, not an enforcement boundary** — the `deny` rules in `.claude/settings.json` are what actually enforce it.
- All three files are gitignored so real rows never reach a commit.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) CLI, installed and authenticated — see [`docs/claude-cli-setup.md`](docs/claude-cli-setup.md)
- [Oracle SQLcl](https://www.oracle.com/database/sqldeveloper/technologies/sqlcl/) (`sql`) — or adapt `prepare.sh`, see below
- Git
- `jq` (optional) — for the token usage summary and `usage.jsonl`; without it `start.sh` prints the raw JSON
- A query-only database account, ideally against a non-production instance

## Quick start

```bash
git clone <repo-url> && cd sql-autotune

vim query.sql        # your slow query — with a deterministic ORDER BY
vim config.sh        # connection, bind variables, iteration budget, timeout

./start.sh
```

The agent creates a branch, establishes a baseline, and starts experimenting.

Never run it against a database before reading the checklist at the end of [`docs/claude-cli-setup.md`](docs/claude-cli-setup.md).

### Options

```bash
./start.sh              # MAX_ITERATIONS from config.sh (default 20)
./start.sh 50           # 50 iterations
./start.sh --loop       # auto-restart when a session ends (context limit, etc.)
./start.sh --loop 50    # both
```

For a run that outlives your ssh session:

```bash
tmux new -s autotune './start.sh --loop 50'
```

State lives in git and `results.tsv`, not in the session, so restarting is safe — the agent reads `results.tsv` and picks up where it left off.

### Token usage

These are estimates, not measurements. Each experiment takes about 5 agent turns, and every turn re-sends the whole conversation, so input tokens grow faster than linearly with iterations. Most input is billed as prompt-cache reads.

| Run | Iterations | Agent turns | Input tokens (mostly cache reads) | Output tokens |
|---|---|---|---|---|
| Minimal: `./start.sh 3` | 3 (baseline + 2 experiments) | ~15–20 | ~0.4–0.7M | ~10–25K |
| Default: `./start.sh` | 20 | ~100 | ~4–6M | ~50–150K |
| Long: `./start.sh 50` | 50 | ~250 | ~20–30M | ~150–350K |

Start with the minimal run. It confirms the connection, baseline and correctness check work, and often catches the biggest win (a correlated subquery or per-row function call), for a small fraction of the default run's tokens. For long runs, prefer `--loop` with smaller batches over one very long session.

`start.sh` runs Claude with `--output-format json`, so the agent's text appears only when the session ends. Each session's actual turns, token usage and cost are printed then and appended to `usage.jsonl` (gitignored). Sum the cost across `--loop` sessions with:

```bash
jq -s 'map(.total_cost_usd) | add' usage.jsonl
```

### Plan before you run

Plan mode can't run the loop itself: it is read-only, and every experiment edits `query.sql`, commits, and executes SQL through `prepare.sh`. It is a cheap way to start a run with better ideas, though:

1. Run `claude` in this directory and press Shift+Tab until plan mode is on.
2. Ask it to read `query.sql` and `program.md` and propose a ranked list of rewrites. This takes a few turns, roughly 30–50K tokens.
3. Review the list. Add the ideas worth trying to `program.md` as hints, then run `./start.sh 3` so the minimal run tries them first.

The proposals are guesses until the loop tests them. Only the timed runs and the baseline diff decide what is kept.

## Two requirements for your query

**A deterministic `ORDER BY`.** Correctness is a byte-for-byte diff against the baseline. A query whose row order can vary between runs will produce spurious `FAIL` results. Order by enough columns to make the result set unique.

**Bind placeholders as `:name`**, with values in `config.sh`. The runner substitutes them and quotes the values.

## Try it without your own data

[`examples/`](examples/) has a self-contained fixture that reproduces the per-row PL/SQL function problem — a demo table, a slow scalar function, and a query that calls it once per row. See [`examples/README.md`](examples/README.md).

## Example results

```
commit   elapsed_sec  correctness  status   description
a1b2c3d  28.123       PASS         keep     baseline
b2c3d4e  15.456       PASS         keep     added MATERIALIZE hints to CTEs
c3d4e5f  28.900       PASS         discard  reordered joins (no improvement)
d4e5f6g   0.000       CRASH        crash    syntax error in hint
e5f6g7h  12.301       PASS         keep     pre-aggregate before final join
```

The git log on the branch shows only the `keep` commits — a clean progression of verified improvements. Every discarded idea stays in `results.tsv`, which is often the more useful artifact.

## Known limits

- **Wall-clock floor.** Every `prepare.sh` invocation pays a fresh SQLcl JVM startup — a few seconds before any SQL runs. Once a query is fast, that floor dominates and further gains stop showing up in `elapsed_seconds`. Judge the tail end by execution plan and buffer gets.
- **Query text only.** No indexes, no statistics, no materialized views, no schema changes — sometimes exactly what a slow query actually needs.
- **One query at a time.** Not a workload tuner.
- **Cost is real.** A long run makes many API calls; `--max-turns` (set by `start.sh`) is the backstop. See [Token usage](#token-usage).
- **A human still reads the final plan** before anything ships. This replaces the tedium of tuning, not the judgment.

## Adapting for other databases

`prepare.sh` uses SQLcl to run the query and produce CSV. Replace the execution line for another engine:

```bash
# PostgreSQL
PGPASSWORD="$PASS" psql -h "$HOST" -U "$USER" -d "$DB" --csv -t -f "$QUERY_FILE"

# MySQL
mysql -h "$HOST" -u "$USER" -p"$PASS" "$DB" --batch --skip-column-names < "$QUERY_FILE"

# SQLite
sqlite3 -header -csv "$DB_FILE" < "$QUERY_FILE"
```

The contract `prepare.sh` must satisfy is three lines:

1. Execute `query.sql`, write results to `run_results.csv`
2. Print `elapsed_seconds: <number>`
3. Print `correctness: PASS|FAIL|CRASH` (by diffing against `baseline_results.csv`)

Everything else works unchanged.

## Adapting for non-SQL use cases

The pattern generalizes to anything with an objective metric:

| Component | SQL version | Yours |
|---|---|---|
| The artifact | `query.sql` | Any file the agent edits |
| The harness | `prepare.sh` | Any script that runs it and prints a metric |
| The metric | `elapsed_seconds` | Any scalar (latency, accuracy, throughput, score) |
| The correctness check | Diff against baseline CSV | Whatever "correct" means for you |

Examples: prompt engineering (accuracy), algorithm optimization (throughput), config tuning (p99 latency), CSS optimization (Lighthouse score).

## License

MIT
