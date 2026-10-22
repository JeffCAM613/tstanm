-- ============================================================================
-- run/apply - Anonymize
-- ============================================================================
-- Sent to the worker session (as OP) after record.sql, for a run. Disables
-- the triggers of OP, applies the inventory - free text, identifiers, then
-- labels and attributes, each column in its own transaction - enables the
-- triggers again and ends the run COMPLETED.
--
-- The triggers are enabled again on every way out: a failure (FAILED) and a
-- stop request (STOPPED, between two columns) included. What was done stays
-- done, and a new run resumes from there with the same translations.
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
   op.anon_engine.set_triggers(FALSE);
   BEGIN
      op.anon_engine.apply_inventory;
   EXCEPTION
      WHEN OTHERS THEN
         v_code   := SQLCODE;
         v_error  := SQLERRM;
         v_status := CASE WHEN v_code = -20018 THEN 'STOPPED' ELSE 'FAILED' END;
         op.anon_engine.set_triggers(TRUE);
         op.anon_engine.finish_run(v_status, v_error);
         DBMS_OUTPUT.PUT_LINE('ANON_RESULT|' || v_status || '|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
         RETURN;
   END;
   op.anon_engine.set_triggers(TRUE);
   op.anon_engine.print_summary;
   op.anon_engine.finish_run('COMPLETED');
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|COMPLETED');
END;
/
