-- ============================================================================
-- run/stop - Ask a run to stop
-- ============================================================================
-- Sent by the wrapper (run_op_anonymization.bat or .sh) to its monitor
-- session (as OP) on Ctrl+C. The run reads the request between two columns:
-- it completes the column it is working on, enables the triggers of OP again,
-- and ends STOPPED. Can also be run by hand, from any session as OP:
--
--   sqlplus op/<password>@<database> @op/sql/run/stop.sql <run id>
--
-- Prints ANON_STOP|REQUESTED, or ANON_STOP|FAILED|<message>.
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_error VARCHAR2(4000);
BEGIN
   op.anon_engine.request_stop(TO_NUMBER('&1'));
   DBMS_OUTPUT.PUT_LINE('ANON_STOP|REQUESTED');
EXCEPTION
   WHEN OTHERS THEN
      v_error := SQLERRM;
      DBMS_OUTPUT.PUT_LINE('ANON_STOP|FAILED|' || REPLACE(v_error, CHR(10), ' '));
END;
/
