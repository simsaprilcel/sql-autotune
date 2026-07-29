-- ---------------------------------------------------------------------------
-- The starting query for the demo. Copy it over query.sql to run the loop:
--
--   cp examples/slow_query.sql query.sql
--   ./start.sh 10
--
-- It calls demo_get_dept_desc() once per row, twice per row in fact (SELECT
-- and GROUP BY), so the PL/SQL-to-SQL context switch dominates the runtime.
-- The rewrite the agent should find is a JOIN to demo_dept.
-- ---------------------------------------------------------------------------

SELECT e.dept_code,
       demo_get_dept_desc(e.dept_code)  AS dept_desc,
       COUNT(*)                         AS enrollments,
       COUNT(DISTINCT e.person_id)      AS students,
       SUM(e.credits)                   AS total_credits
  FROM demo_enrollment e
 WHERE e.term_code = :term_code
 GROUP BY e.dept_code, demo_get_dept_desc(e.dept_code)
 ORDER BY e.dept_code;
