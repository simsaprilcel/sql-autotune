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

WITH tabs AS (
         SELECT /*+ NO_MERGE */ o.owner, o.object_type, o.object_name, o.subobject_name
           FROM dba_objects o
          WHERE o.object_type = 'TABLE'
            AND o.object_name NOT LIKE 'BIN$%'),
     scoped AS (
         SELECT owner
           FROM tabs
          GROUP BY owner
         HAVING COUNT(*) < :max_tables),
     seg AS (
         SELECT owner, segment_name, COUNT(*) AS cnt
           FROM dba_segments
          GROUP BY owner, segment_name)
SELECT   t.owner,
         t.object_type,
         COUNT(*)             AS object_count,
         SUM(NVL(s.cnt, 0))   AS segment_count
    FROM tabs t
    JOIN scoped b ON b.owner = t.owner
    LEFT JOIN seg s ON s.owner = t.owner AND s.segment_name = t.object_name
   WHERE t.subobject_name IS NULL
GROUP BY t.owner, t.object_type
ORDER BY t.owner, t.object_type;
