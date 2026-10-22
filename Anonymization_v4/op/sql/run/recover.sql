-- ============================================================================
-- run/recover - A run whose session was lost
-- ============================================================================
-- The engine enables the triggers of OP again on every way out of a run - a
-- failure and a stop included - but not when its own session is lost (the
-- connection broken, the window closed). Sent by run_op_anonymization.bat to
-- its monitor session (as OP) when that happens; can be run by hand from any
-- session as OP:
--
--   sqlplus op/<password>@<database> @op/sql/run/recover.sql <run id>
--
-- It changes nothing while the run's session is still in the database: a
-- lost connection does not stop a call that is under way, and the run then
-- ends by itself, its triggers enabled again. Otherwise it records the run
-- FAILED when it is still RUNNING and, when the run disabled the triggers of
-- OP and did not enable them again, enables every trigger of OP that is
-- disabled.
--
-- Prints ANON_RECOVER|<ACTIVE | ENDED>|<runs ended>|<triggers enabled>|<triggers that could not be>
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_run      NUMBER := TO_NUMBER('&1');
   v_active   NUMBER := 0;
   v_ended    NUMBER;
   v_disabled NUMBER;
   v_enabled  NUMBER;
   v_done     NUMBER := 0;
   v_failed   NUMBER := 0;
BEGIN
   -- The run's session names it in its module (anon_engine.start_run).
   BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM v$session WHERE module = :m'
         INTO v_active USING 'ANON R-' || LPAD(v_run, 6, '0');
   EXCEPTION
      WHEN OTHERS THEN
         v_active := 0;   -- no access to v$session: the run is taken as ended
   END;
   IF v_active > 0 THEN
      DBMS_OUTPUT.PUT_LINE('ANON_RECOVER|ACTIVE|0|0|0');
      RETURN;
   END IF;

   UPDATE anon_meta.anon_run
      SET status      = 'FAILED',
          finished_at = SYSTIMESTAMP,
          error_text  = 'The session of the run was lost; the run was ended by run/recover.sql.'
    WHERE run_id = v_run AND status = 'RUNNING';
   v_ended := SQL%ROWCOUNT;
   COMMIT;

   SELECT COUNT(CASE WHEN object_name = 'DISABLE' THEN 1 END), COUNT(CASE WHEN object_name = 'ENABLE' THEN 1 END)
     INTO v_disabled, v_enabled
     FROM anon_meta.anon_step_log
    WHERE run_id = v_run AND phase = 'TRIGGERS';
   IF v_disabled > v_enabled THEN
      FOR t IN (SELECT trigger_name FROM all_triggers WHERE owner = 'OP' AND status = 'DISABLED') LOOP
         BEGIN
            EXECUTE IMMEDIATE 'ALTER TRIGGER op."' || t.trigger_name || '" ENABLE';
            v_done := v_done + 1;
         EXCEPTION
            WHEN OTHERS THEN
               v_failed := v_failed + 1;
         END;
      END LOOP;
   END IF;
   DBMS_OUTPUT.PUT_LINE('ANON_RECOVER|ENDED|' || v_ended || '|' || v_done || '|' || v_failed);
END;
/
