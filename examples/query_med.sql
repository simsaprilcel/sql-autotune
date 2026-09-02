-- ---------------------------------------------------------------------------
-- CATALOG DEMO -- MEDIUM        measured on ORAWALLET: baseline ~42s, tuned ~7s
--
-- RECOMMENDED for a 20-minute slot. Three runs per iteration at ~42s is about
-- 2 min/iteration, so 7-8 experiments fit -- enough for the agent to find the
-- wins, discard a couple of dead ends, and leave a readable results.tsv.
--
-- Schema inventory in two branches: segment-bearing objects and stored code.
-- Reads only the data dictionary, so it runs anywhere the account holds
-- SELECT_CATALOG_ROLE. Output is DBA metadata only -- owner, object type,
-- counts. No end-user rows are selected or written to baseline.
--
--   cp examples/query_med.sql query.sql
--
-- config.sh:  BINDS=( "max_tables=1500" )
--
-- Planted problems:
--   1. Correlated dba_segments probe, once per driving row. This is the
--      expensive one -- dba_segments has no usable index on
--      (owner, segment_name), so each probe scans.
--   2. A second correlated probe against dba_tab_columns.
--   3. A third against dba_source on the stored-code branch.
--   4. UNION where UNION ALL would do. The branches are disjoint by
--      object_type, so the sort-distinct removes nothing and only costs.
--   5. SELECT DISTINCT inside each branch, on an already-unique row source.
--   6. dba_objects scanned four times -- once per branch, once per
--      schema-filter subquery.
-- ---------------------------------------------------------------------------

SELECT   u.owner,
         u.object_type,
         COUNT(*)              AS object_count,
         SUM(u.segment_count)  AS segment_count,
         SUM(u.column_count)   AS column_count,
         SUM(u.source_lines)   AS source_lines
    FROM (SELECT DISTINCT
                 o.owner,
                 o.object_type,
                 o.object_name,
                 (SELECT COUNT(*)
                    FROM dba_segments s
                   WHERE s.owner        = o.owner
                     AND s.segment_name = o.object_name)  AS segment_count,
                 (SELECT COUNT(*)
                    FROM dba_tab_columns c
                   WHERE c.owner      = o.owner
                     AND c.table_name = o.object_name)    AS column_count,
                 0                                        AS source_lines
            FROM dba_objects o
           WHERE o.object_type = 'TABLE'
             AND o.object_name NOT LIKE 'BIN$%'
             AND o.subobject_name IS NULL
             AND o.owner IN (SELECT o2.owner
                               FROM dba_objects o2
                              WHERE o2.object_type = 'TABLE'
                                AND o2.object_name NOT LIKE 'BIN$%'
                              GROUP BY o2.owner
                             HAVING COUNT(*) < :max_tables)
           UNION
          SELECT DISTINCT
                 o.owner,
                 o.object_type,
                 o.object_name,
                 0,
                 0,
                 (SELECT COUNT(*)
                    FROM dba_source r
                   WHERE r.owner = o.owner
                     AND r.name  = o.object_name
                     AND r.type  = o.object_type)
            FROM dba_objects o
           WHERE o.object_type IN ('PACKAGE', 'PACKAGE BODY', 'PROCEDURE',
                                   'FUNCTION', 'TRIGGER', 'TYPE', 'TYPE BODY')
             AND o.object_name NOT LIKE 'BIN$%'
             AND o.subobject_name IS NULL
             AND o.owner IN (SELECT o2.owner
                               FROM dba_objects o2
                              WHERE o2.object_type = 'TABLE'
                                AND o2.object_name NOT LIKE 'BIN$%'
                              GROUP BY o2.owner
                             HAVING COUNT(*) < :max_tables)) u
GROUP BY u.owner, u.object_type
ORDER BY u.owner, u.object_type;
