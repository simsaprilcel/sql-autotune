# Catalog demo — three difficulty levels

A presentation fixture that needs **no setup and no fixture tables**. Every query
reads only the Oracle data dictionary, so it runs anywhere the tuning account
holds `SELECT_CATALOG_ROLE`.

Output is DBA metadata only — owner, object type, and counts. No end-user rows
are selected, displayed, or written to `baseline_results.csv`.

## Measured on PROGSAGE

| File | `max_tables` | Baseline (warm) | Tuned | Iteration cost (3 runs) |
|---|---|---|---|---|
| `query_easy.sql` | 500  | ~22 s | ~6 s | ~1.1 min |
| `query_med.sql`  | 1500 | ~42 s | ~8 s | ~2.1 min |
| `query_high.sql` | 4000 | ~63 s | ~8 s | ~3.2 min |

**`query_med.sql` is the pick for a 20-minute slot** — about 7 experiments fit,
enough for the agent to find the wins, discard a dead end or two, and leave a
readable `results.tsv`. The tuned rewrite has been run end to end and returns
`correctness: PASS`, so the demo is known-solvable, not hoped-solvable.

## Run it

```bash
cp examples/query_med.sql query.sql
rm -f baseline_results.csv results.tsv
./start.sh 8
```

`config.sh` is already set for this: `CONNECTION="/@PROGSAGE"`,
`BINDS=( "max_tables=1500" )`, `QUERY_TIMEOUT=300`.

## Read this before you present

- **Keep `QUERY_TIMEOUT=300`.** The default 120 is not safe here. A cold or
  contended run of the medium query was measured at 232 s against 42 s warm —
  same query, same bind, `PASS` both times. At 120 s the baseline itself would
  record as `CRASH` and there would be nothing to tune.
- **Warm the cache first.** Run `./prepare.sh` once a few minutes before you go
  on, then delete `baseline_results.csv` and start clean. The first touch of
  `dba_segments` is the expensive one.
- **The floor is ~5 s of SQLcl JVM startup**, before any SQL runs. Once the
  query is tuned, that floor dominates and further gains stop showing up in
  `elapsed_seconds`. Judge the tail end by execution plan, not the harness clock.
- **`row_count` in the runner output carries a constant +7 offset** from SQLcl
  banner and blank lines. The medium query reports `row_count: 235` for 228
  actual rows. Harmless — the correctness check is a byte diff, not a count —
  but do not read it out as a row count on stage.
- **Best-of-three is what makes this work.** `program.md` tells the agent to take
  the lowest of three runs. Given the 42 s / 232 s spread above, a single run is
  genuinely not a measurement. That is a good thing to say out loud.

## Determinism

Correctness is a byte-for-byte diff, so the dictionary must not shift during the
20 minutes. Verified stable across repeated runs (`PASS` on re-run of an
unchanged query). All three queries exclude recycle-bin objects (`BIN$%`) and
subobject rows, and select only counts — never `last_ddl_time`, `bytes`,
`extents`, or anything else that drifts on its own.

The `subobject_name IS NULL` predicate is load-bearing, not decoration: without
it `dba_objects` yields 104 duplicate `(owner, object_type, object_name)` groups
in this scope, which makes `SELECT DISTINCT` and `UNION` semantically required
and turns the intended `UNION ALL` rewrite into a `FAIL`. With it, duplicates
are zero and every intended rewrite is safe.

What still breaks it: someone compiling a package, creating a table, or running
an import on the demo database mid-presentation.

## What the agent should find

Spoilers — don't leave this open on the projector.

**The main win, all three levels.** Aggregate each lookup once and join, instead
of probing it once per driving row. `dba_segments` is the expensive one: it is a
complex `UNION ALL` view with no usable index on `(owner, segment_name)`, so
every correlated probe is a scan. Measured cost of that single probe is roughly
24 ms per driving row; the other probes are ~0.1 ms because they resolve through
an index and benefit from scalar-subquery caching.

**Medium and high, additionally:**

- `UNION` → `UNION ALL`. The branches are disjoint by `object_type`, so the
  sort-distinct removes nothing and only costs.
- Drop `SELECT DISTINCT` — redundant once `subobject_name IS NULL` is in place.
- Collapse the two `dba_objects` branches into one scan with conditional
  aggregation. Both read the same table with only the type list differing.
- Factor the repeated schema-filter subquery into a single CTE. It currently
  runs twice.

This is the verified rewrite of `query_med.sql` — 7.8 s, `PASS`:

```sql
WITH scoped AS (
    SELECT o2.owner FROM dba_objects o2
     WHERE o2.object_type = 'TABLE' AND o2.object_name NOT LIKE 'BIN$%'
     GROUP BY o2.owner HAVING COUNT(*) < :max_tables),
seg AS (SELECT owner, segment_name, COUNT(*) cnt FROM dba_segments GROUP BY owner, segment_name),
col AS (SELECT owner, table_name,   COUNT(*) cnt FROM dba_tab_columns GROUP BY owner, table_name),
src AS (SELECT owner, name, type,   COUNT(*) cnt FROM dba_source GROUP BY owner, name, type)
SELECT   o.owner,
         o.object_type,
         COUNT(*)                                                          AS object_count,
         SUM(CASE WHEN o.object_type='TABLE' THEN NVL(s.cnt,0) ELSE 0 END) AS segment_count,
         SUM(CASE WHEN o.object_type='TABLE' THEN NVL(c.cnt,0) ELSE 0 END) AS column_count,
         SUM(CASE WHEN o.object_type='TABLE' THEN 0 ELSE NVL(r.cnt,0) END) AS source_lines
    FROM dba_objects o
    JOIN scoped b ON b.owner = o.owner
    LEFT JOIN seg s ON s.owner = o.owner AND s.segment_name = o.object_name
    LEFT JOIN col c ON c.owner = o.owner AND c.table_name   = o.object_name
    LEFT JOIN src r ON r.owner = o.owner AND r.name = o.object_name AND r.type = o.object_type
   WHERE o.object_name NOT LIKE 'BIN$%'
     AND o.subobject_name IS NULL
     AND o.object_type IN ('TABLE','PACKAGE','PACKAGE BODY','PROCEDURE',
                           'FUNCTION','TRIGGER','TYPE','TYPE BODY')
GROUP BY o.owner, o.object_type
ORDER BY o.owner, o.object_type;
```

## Tuning the runtime

The `:max_tables` bind is the dial — it scopes the report to schemas owning
fewer than N tables, which on this database is the long tail rather than the few
huge vendor schemas. Measured curve for the single-probe (easy) shape:

| `max_tables` | driver rows | elapsed |
|---|---|---|
| 100  | ~1,425  | 11 s |
| 500  | ~3,912  | 22 s |
| 1500 | —       | 37 s |
| 4000 | —       | 56 s |
| none | ~11,915 | 297 s |

**Do not add a correlated probe against `dba_dependencies`.** It was tried and
exceeds 300 s on its own — the baseline records as `CRASH` and there is nothing
to tune. Mention it as a war story if you want; keep it out of the query.

## Talking points

- The agent never sees a result row. `prepare.sh` does the diff and reports only
  PASS/FAIL plus redacted line and column positions. Worth showing on screen —
  it is the reason this is safe to point at a production dictionary.
- `git log` on the `autotune/*` branch shows only the kept improvements. The
  discarded experiments live in `results.tsv` and nowhere else.
