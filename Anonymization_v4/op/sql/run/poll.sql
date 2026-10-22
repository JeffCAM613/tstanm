-- ============================================================================
-- run/poll - One look at a run while it works (read-only)
-- ============================================================================
-- Sent by the wrapper (run_op_anonymization.bat or .sh) to its monitor
-- session (as OP) about every two seconds while the worker session runs: what
-- the run has logged since the last look, where it is now, and the progress
-- of a long statement.
--
--   @poll.sql <run id> <last step id seen> <RUN | VERIFY>
--
-- All three arguments are always given: a missing one would make sqlplus
-- prompt for it, and read the next line of the session as its value.
--
-- Prints
--   ANON_STEP|<step id>|<phase>|<status>|<rows>|<rows to X_>|<ms>|<rule>|<object>|<message>
--   ANON_PROGRESS|<phase>|<stage>|<done>|<total>|<weight done>|<object weight>|<weight total>
--                |<seconds on the object>|<seconds in the phase>|<object>
--   ANON_LONGOP|<percent>|<seconds left>|<operation>
--   ANON_RUNSTATE|<status>|<stop requested>
--   ANON_VERIFY|<part>|<checks so far>                 with VERIFY
-- The message is printed for ERROR and REVIEW rows only. Counts and names of
-- tables and columns only: never an identifier.
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_run     NUMBER := TO_NUMBER('&1');
   v_after   NUMBER := TO_NUMBER('&2');
   v_pct     NUMBER;
   v_left    NUMBER;
   v_op      VARCHAR2(200);
BEGIN
   FOR s IN (SELECT step_id, phase, status, rows_affected, x_rows, elapsed_ms, rule, object_name, message
               FROM anon_meta.anon_step_log
              WHERE run_id = v_run AND step_id > v_after
              ORDER BY step_id
              FETCH FIRST 500 ROWS ONLY) LOOP
      DBMS_OUTPUT.PUT_LINE('ANON_STEP|' || s.step_id || '|' || s.phase || '|' || s.status || '|' || s.rows_affected
                        || '|' || s.x_rows || '|' || s.elapsed_ms || '|' || s.rule || '|' || s.object_name
                        || '|' || CASE WHEN s.status IN ('ERROR', 'REVIEW')
                                       THEN REPLACE(REPLACE(s.message, CHR(10), ' '), '|', '/') END);
   END LOOP;

   FOR p IN (SELECT phase, stage, items_done, items_total, weight_done, object_weight, weight_total, object_name,
                    ROUND((SYSDATE - CAST(object_started AS DATE)) * 86400) AS on_object,
                    ROUND((SYSDATE - CAST(phase_started AS DATE)) * 86400) AS in_phase,
                    CAST(object_started AS DATE) AS object_started
               FROM anon_meta.anon_progress
              WHERE run_id = v_run) LOOP
      DBMS_OUTPUT.PUT_LINE('ANON_PROGRESS|' || p.phase || '|' || p.stage || '|' || p.items_done || '|' || p.items_total
                        || '|' || p.weight_done || '|' || p.object_weight || '|' || p.weight_total
                        || '|' || p.on_object || '|' || p.in_phase || '|' || p.object_name);

      -- A long statement of the run's session (or of its parallel servers),
      -- begun on the object worked on now. Needs read access to the two
      -- views, granted by 10_create_metadata_schema.sql: without it, nothing
      -- is printed and the live view shows the tables and columns only.
      BEGIN
         EXECUTE IMMEDIATE q'[
            SELECT pct, time_remaining, opname
              FROM (SELECT ROUND(100 * l.sofar / l.totalwork) AS pct, l.time_remaining, l.opname
                      FROM v$session s
                      JOIN v$session_longops l
                        ON (l.sid = s.sid AND l.serial# = s.serial#) OR l.qcsid = s.sid
                     WHERE s.module = :module
                       AND l.totalwork > 0 AND l.sofar < l.totalwork
                       AND l.start_time >= :since
                     ORDER BY l.totalwork DESC)
             WHERE ROWNUM = 1]'
            INTO v_pct, v_left, v_op
            USING 'ANON R-' || LPAD(v_run, 6, '0'), p.object_started - 1 / 86400;
         DBMS_OUTPUT.PUT_LINE('ANON_LONGOP|' || v_pct || '|' || v_left || '|' || v_op);
      EXCEPTION
         WHEN OTHERS THEN
            NULL;   -- no long statement now, or no access to the views
      END;
   END LOOP;

   FOR r IN (SELECT status, stop_requested FROM anon_meta.anon_run WHERE run_id = v_run) LOOP
      DBMS_OUTPUT.PUT_LINE('ANON_RUNSTATE|' || r.status || '|' || r.stop_requested);
   END LOOP;

   IF UPPER('&3') = 'VERIFY' THEN
      FOR v IN (SELECT part, COUNT(*) AS checks FROM anon_meta.verify_result GROUP BY part) LOOP
         DBMS_OUTPUT.PUT_LINE('ANON_VERIFY|' || v.part || '|' || v.checks);
      END LOOP;
   END IF;
END;
/
