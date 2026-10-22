-- ============================================================================
-- run/count - The work of a dry run (read-only)
-- ============================================================================
-- Sent to the worker session (as OP) after plan.sql, for a dry run. Counts,
-- table by table and column by column, what a run would change - against the
-- same plan a run would apply - and ends the run COMPLETED. Nothing in OP or
-- in the translations changes. A stop request (stop.sql) ends it STOPPED
-- between two columns.
--
-- Prints the engine's lines, then
--   ANON_RESULT|COMPLETED | STOPPED|<code>|<message> | FAILED|<code>|<message>
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_code   NUMBER;
   v_error  VARCHAR2(4000);
   v_status VARCHAR2(20);
BEGIN
   op.anon_engine.generate_code_map;
   op.anon_engine.apply_inventory;
   op.anon_engine.print_summary;
   op.anon_engine.finish_run('COMPLETED');
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|COMPLETED');
EXCEPTION
   WHEN OTHERS THEN
      v_code   := SQLCODE;
      v_error  := SQLERRM;
      v_status := CASE WHEN v_code = -20018 THEN 'STOPPED' ELSE 'FAILED' END;
      op.anon_engine.finish_run(v_status, v_error);
      DBMS_OUTPUT.PUT_LINE('ANON_RESULT|' || v_status || '|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
END;
/
