# Demo fixture

A self-contained example you can run without any institutional data. It reproduces the single optimization that matters most in practice: replacing a per-row PL/SQL function call with a join.

## Setup

Run once, as a schema owner in a **scratch or dev schema** (this needs `CREATE TABLE` and `CREATE PROCEDURE`, so it is deliberately not run by the query-only account you tune with):

```bash
sql owner/pass@DEV @examples/setup_demo.sql
```

Then grant your query-only account access:

```sql
GRANT SELECT  ON demo_enrollment    TO tuning_user;
GRANT SELECT  ON demo_dept          TO tuning_user;
GRANT EXECUTE ON demo_get_dept_desc TO tuning_user;
```

## Run the loop

```bash
cp examples/slow_query.sql query.sql
vim config.sh          # CONNECTION + term_code bind
./start.sh 10
```

## What to expect

The starting query calls `demo_get_dept_desc()` once per row in the `SELECT` and again in the `GROUP BY`. Each call is a PL/SQL-to-SQL context switch, so the cost scales with row count rather than with the 40 rows actually returned.

The rewrite is to aggregate first and join to `demo_dept` for the description — one join instead of ~100,000 function calls:

```sql
SELECT e.dept_code, d.dept_desc, COUNT(*) AS enrollments, ...
  FROM demo_enrollment e
  JOIN demo_dept d ON d.dept_code = e.dept_code
 WHERE e.term_code = :term_code
 GROUP BY e.dept_code, d.dept_desc
 ORDER BY e.dept_code;
```

Watch `results.tsv` fill in, and `git log` on the `autotune/*` branch to see only the kept improvements.

Two things worth pointing out when demoing this:

- **The floor is not zero.** Each `prepare.sh` invocation pays a fresh SQLcl JVM startup — a few seconds of wall clock before any SQL runs. Once a query is fast, that floor dominates the measurement and further gains stop showing up in `elapsed_seconds`. Judge the tail end by execution plan and buffer gets, not by the harness clock.
- **`ORDER BY` is load-bearing.** Correctness is a byte-for-byte diff against the baseline. Without a deterministic ordering, a correct rewrite can be reported `FAIL` simply because Oracle returned the same rows in a different order.
