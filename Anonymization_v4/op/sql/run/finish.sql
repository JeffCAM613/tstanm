-- ============================================================================
-- run/finish - End a run that does not go on
-- ============================================================================
-- Sent to the worker session (as OP) when the run stops between two of its
-- steps: CANCELLED when the run was not confirmed, STOPPED when Ctrl+C came
-- before its work began. Nothing in OP has changed at that point.
--
--   @finish.sql <CANCELLED | STOPPED>
--
-- Prints ANON_RESULT|OK, or ANON_RESULT|FAILED|<code>|<message>.
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_code  NUMBER;
   v_error VARCHAR2(4000);
BEGIN
   op.anon_engine.finish_run(UPPER('&1'),
                             CASE UPPER('&1') WHEN 'CANCELLED' THEN 'Not confirmed: nothing was changed.'
                                              ELSE 'Stopped on request before the work began: nothing was changed.' END);
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|OK');
EXCEPTION
   WHEN OTHERS THEN
      v_code  := SQLCODE;
      v_error := SQLERRM;
      DBMS_OUTPUT.PUT_LINE('ANON_RESULT|FAILED|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
END;
/
