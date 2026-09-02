-- ---------------------------------------------------------------------------
-- CATALOG DEMO -- HIGH          measured on ORAWALLET: baseline ~65s, tuned ~8s
--
-- Same report, widened driver and a fourth correlated probe. At ~65s a full
-- three-run iteration costs over 3 minutes, so budget only 5-6 experiments in
-- a 20-minute slot. Use this if you want the first number on screen to hurt.
--
-- Reads only the data dictionary, so it runs anywhere the account holds
-- SELECT_CATALOG_ROLE. Output is DBA metadata only -- owner, object type,
-- counts. No end-user rows are selected or written to baseline.
--
--   cp examples/query_high.sql query.sql
--
-- config.sh:  BINDS=( "max_tables=4000" )
--             QUERY_TIMEOUT=300      <-- raise from 120, or the baseline CRASHes
--
-- Planted problems: everything in MEDIUM, plus a fourth correlated probe
-- against dba_indexes, and a driver widened to nearly the whole catalog.
--
-- Deliberately NOT used here: a correlated probe against dba_dependencies.
-- Measured on ORAWALLET it blows past 300s on its own -- the baseline itself
-- records as a CRASH and there is nothing to tune. If you want it as a talking
-- point, mention it; do not put it in the query.
-- ---------------------------------------------------------------------------

SELECT   u.owner,
         u.object_type,
         COUNT(*)              AS object_count,
         SUM(u.segment_count)  AS segment_count,
         SUM(u.column_count)   AS column_count,
         SUM(u.index_count)    AS index_count,
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
                 (SELECT COUNT(*)
                    FROM dba_indexes i
                   WHERE i.table_owner = o.owner
                     AND i.table_name  = o.object_name)   AS index_count,
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
