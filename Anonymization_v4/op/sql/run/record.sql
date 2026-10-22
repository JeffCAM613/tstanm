-- ============================================================================
-- run/record - Record the translations of a run
-- ============================================================================
-- Sent to the worker session (as OP) after plan.sql and the confirmation,
-- for a run. Records the new identities and their translations in anon_meta
-- before anything in OP changes - an existing translation is reused, never
-- regenerated - and builds the typed lookups apply.sql reads.
--
-- Prints the engine's lines, then
--   ANON_RESULT|OK | STOPPED|<code>|<message> | FAILED|<code>|<message>
-- On STOPPED or FAILED the run is ended; nothing in OP has changed.
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
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|OK');
EXCEPTION
   WHEN OTHERS THEN
      v_code   := SQLCODE;
      v_error  := SQLERRM;
      v_status := CASE WHEN v_code = -20018 THEN 'STOPPED' ELSE 'FAILED' END;
      op.anon_engine.finish_run(v_status, v_error);
      DBMS_OUTPUT.PUT_LINE('ANON_RESULT|' || v_status || '|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
END;
/
