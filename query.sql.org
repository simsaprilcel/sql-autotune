-- ---------------------------------------------------------------------------
-- Drop the query you want optimized into this file. It is the ONLY file the
-- agent is allowed to edit.
--
-- Two requirements:
--
--   1. A deterministic ORDER BY. Correctness is enforced by a byte-for-byte
--      diff against the baseline, so any query whose row order can vary
--      between runs will produce spurious FAIL results. Order by enough
--      columns to make the result set unique.
--
--   2. Bind placeholders as :name, with values set in config.sh.
--
-- A runnable demonstration lives in examples/ — see examples/README.md.
-- ---------------------------------------------------------------------------

SELECT 'replace me' AS placeholder
  FROM dual
 ORDER BY 1;
