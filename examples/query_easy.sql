-- ---------------------------------------------------------------------------
-- CATALOG DEMO -- EASY          measured on ORAWALLET: baseline ~22s, tuned ~6s
--
-- Table/segment inventory for every schema except the handful of very large
-- vendor schemas. Reads only the data dictionary, so it runs anywhere the
-- account holds SELECT_CATALOG_ROLE. Output is DBA metadata only -- owner,
-- object type, counts. No end-user rows are selected or written to baseline.
--
--   cp examples/query_easy.sql query.sql
--
-- config.sh:  BINDS=( "max_tables=500" )
--
-- Planted problem: one correlated scalar subquery against dba_segments,
-- evaluated once per driving row. dba_segments is a complex UNION ALL view
-- with no usable index on (owner, segment_name), so every probe is a scan.
-- Cost scales with tables inspected, not with the 86 rows returned.
-- ---------------------------------------------------------------------------

SELECT   d.owner,
         d.object_type,
         COUNT(*)              AS object_count,
         SUM(d.segment_count)  AS segment_count
    FROM (SELECT o.owner,
                 o.object_type,
                 o.object_name,
                 (SELECT COUNT(*)
                    FROM dba_segments s
                   WHERE s.owner        = o.owner
                     AND s.segment_name = o.object_name)  AS segment_count
            FROM dba_objects o
           WHERE o.object_type = 'TABLE'
             AND o.object_name NOT LIKE 'BIN$%'
             AND o.subobject_name IS NULL
             AND o.owner IN (SELECT o2.owner
                               FROM dba_objects o2
                              WHERE o2.object_type = 'TABLE'
                                AND o2.object_name NOT LIKE 'BIN$%'
                              GROUP BY o2.owner
                             HAVING COUNT(*) < :max_tables)) d
GROUP BY d.owner, d.object_type
ORDER BY d.owner, d.object_type;
