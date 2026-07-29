-- ---------------------------------------------------------------------------
-- Demo fixture: reproduces the per-row PL/SQL function problem that
-- sql-autotune's top optimization strategy targets.
--
-- Run ONCE as a schema owner in a scratch/dev schema. This needs CREATE
-- privileges, so it is NOT run by the query-only account you tune with —
-- grant that account SELECT on the two tables and EXECUTE on the function.
--
--   sql owner/pass@DEV @examples/setup_demo.sql
-- ---------------------------------------------------------------------------

DROP TABLE demo_enrollment PURGE;
DROP TABLE demo_dept PURGE;

CREATE TABLE demo_dept (
    dept_code  VARCHAR2(4)  PRIMARY KEY,
    dept_desc  VARCHAR2(40) NOT NULL
);

CREATE TABLE demo_enrollment (
    person_id  NUMBER(10)   NOT NULL,
    term_code  VARCHAR2(6)  NOT NULL,
    dept_code  VARCHAR2(4)  NOT NULL,
    credits    NUMBER(4,1)  NOT NULL
);

INSERT INTO demo_dept (dept_code, dept_desc)
SELECT 'D' || LPAD(LEVEL, 3, '0'),
       'Department Number ' || LEVEL
  FROM dual
 CONNECT BY LEVEL <= 40;

-- ~200k enrollment rows across 4 terms.
INSERT /*+ APPEND */ INTO demo_enrollment (person_id, term_code, dept_code, credits)
SELECT MOD(LEVEL, 50000) + 1                            AS person_id,
       CASE MOD(LEVEL, 4)
            WHEN 0 THEN '202510' WHEN 1 THEN '202520'
            WHEN 2 THEN '202530' ELSE '202540' END      AS term_code,
       'D' || LPAD(MOD(LEVEL, 40) + 1, 3, '0')          AS dept_code,
       MOD(LEVEL, 5) + 1                                AS credits
  FROM dual
 CONNECT BY LEVEL <= 200000;

COMMIT;

-- The villain: a scalar function that wraps a single-row lookup. Every call
-- costs a PL/SQL-to-SQL context switch, so cost scales with row count.
CREATE OR REPLACE FUNCTION demo_get_dept_desc (p_dept_code IN VARCHAR2)
    RETURN VARCHAR2
IS
    l_desc demo_dept.dept_desc%TYPE;
BEGIN
    SELECT dept_desc INTO l_desc
      FROM demo_dept
     WHERE dept_code = p_dept_code;
    RETURN l_desc;
EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
END;
/

BEGIN
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'DEMO_ENROLLMENT');
    DBMS_STATS.GATHER_TABLE_STATS(USER, 'DEMO_DEPT');
END;
/
