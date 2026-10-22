-- ============================================================================
-- run/plan - Checks and plan of a run (read-only)
-- ============================================================================
-- Sent to the worker session (as OP) after start.sql. Runs the preflight:
-- the inventory against the database, the identities captured and
-- classified, each one's translation planned, and every check recorded in
-- anon_meta.anon_check. Nothing in OP changes. A run its checks find unsafe
-- ends REFUSED here; any other error ends it FAILED.
--
-- Prints the engine's lines, then
--   ANON_RESULT|OK | REFUSED|<code>|<message> | FAILED|<code>|<message>
--   ANON_CHECK|<seq>|<code>|<needed>|<status>|<state>|<title>|<measure>|<what happens>|<what to do>
--   ANON_IDENTITIES|<parties>|<bank accounts>|<found now>|<recorded before>
--   ANON_SCOPE|<identifier columns>|<free-text columns>|<label columns>|<attribute columns>
--   ANON_ESTIMATE|<seconds>|<basis>|<dry run>    a run only, after a dry run on this database
-- Counts and names of columns only: never an identifier.
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_code  NUMBER;
   v_error VARCHAR2(4000);
BEGIN
   op.anon_engine.preflight;
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|OK');
EXCEPTION
   WHEN OTHERS THEN
      v_code  := SQLCODE;
      v_error := SQLERRM;
      IF v_code IN (-20011, -20012, -20013, -20016) THEN
         op.anon_engine.finish_run('REFUSED', v_error);
         DBMS_OUTPUT.PUT_LINE('ANON_RESULT|REFUSED|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
      ELSE
         op.anon_engine.finish_run('FAILED', v_error);
         DBMS_OUTPUT.PUT_LINE('ANON_RESULT|FAILED|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
      END IF;
END;
/

SELECT 'ANON_CHECK|' || seq || '|' || code || '|' || needed || '|' || status || '|' || state || '|' || title
       || '|' || measure || '|' || what_happens || '|' || what_to_do
  FROM anon_meta.anon_check
 WHERE run_id = op.anon_engine.current_run_id
 ORDER BY seq;

SELECT 'ANON_IDENTITIES|' || COUNT(CASE WHEN domain = 'PARTY' THEN 1 END)
       || '|' || COUNT(CASE WHEN domain = 'ACCOUNT' THEN 1 END)
       || '|' || COUNT(CASE WHEN identity_status = 'NEW' THEN 1 END)
       || '|' || COUNT(CASE WHEN identity_status = 'KNOWN' THEN 1 END)
  FROM anon_meta.identity_plan
 WHERE run_id = op.anon_engine.current_run_id;

-- The columns each kind of work covers in this database.
SELECT 'ANON_SCOPE|' || COUNT(CASE WHEN i.rule = 'CODE' THEN 1 END)
       || '|' || COUNT(CASE WHEN i.rule = 'NULL_OUT' THEN 1 END)
       || '|' || COUNT(CASE WHEN i.rule = 'DESCRIPTION' THEN 1 END)
       || '|' || COUNT(CASE WHEN i.rule = 'SELF_CODE' THEN 1 END)
  FROM anon_meta.anon_inventory i
 WHERE EXISTS (SELECT 1 FROM all_tab_columns c
                WHERE c.owner = 'OP' AND c.table_name = i.table_name AND c.column_name = i.column_name);

-- For a run: what the latest dry run on this database said it would take.
SELECT 'ANON_ESTIMATE|' || op.anon_engine.estimate(d.run_id) || '|R-' || LPAD(d.run_id, 6, '0')
  FROM anon_meta.anon_run r
  JOIN anon_meta.anon_run d
    ON d.run_id = (SELECT MAX(x.run_id) FROM anon_meta.anon_run x
                    WHERE x.run_mode = 'DRYRUN' AND x.status = 'COMPLETED' AND x.db_name = r.db_name
                      AND x.run_id < r.run_id)
 WHERE r.run_id = op.anon_engine.current_run_id
   AND r.run_mode = 'EXECUTE';
