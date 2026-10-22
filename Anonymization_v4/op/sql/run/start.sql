-- ============================================================================
-- run/start - Configure and open a run
-- ============================================================================
-- Sent by the wrapper (run_op_anonymization.bat or .sh) to its worker session
-- (as OP), once the engine is installed and the inventory loaded and
-- validated. The run then exists in anon_meta.anon_run, and the session's
-- module names it.
--
--   @start.sql <mode> <ent> <ptf> <cpty> <uncl> <acct>
--              <ent_desc> <ptf_desc> <cpty_desc> <uncl_desc> <acct_desc>
--              <ent_attr> <ptf_attr> <cpty_attr> <uncl_attr> <acct_attr>
--              <parallel> <fail_on_missing> <approve_structure_only>
--
-- mode is EXECUTE or DRYRUN; every switch y or n.
--
-- Prints the engine's lines, then
--   ANON_RUN|<run id>|<tool version>
--   ANON_RESULT|OK                        or ANON_RESULT|FAILED|<code>|<message>
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DECLARE
   v_code  NUMBER;
   v_error VARCHAR2(4000);
BEGIN
   op.anon_engine.configure(
      p_mode                   => '&1',
      p_entity                 => '&2',
      p_portfolio              => '&3',
      p_counterparty           => '&4',
      p_unclassified           => '&5',
      p_bank_account           => '&6',
      p_entity_desc            => '&7',
      p_portfolio_desc         => '&8',
      p_counterparty_desc      => '&9',
      p_unclassified_desc      => '&10',
      p_bank_account_desc      => '&11',
      p_entity_attr            => '&12',
      p_portfolio_attr         => '&13',
      p_counterparty_attr      => '&14',
      p_unclassified_attr      => '&15',
      p_bank_account_attr      => '&16',
      p_parallel_degree        => '&17',
      p_fail_on_missing        => '&18',
      p_approve_structure_only => '&19');
   op.anon_engine.start_run;
   DBMS_OUTPUT.PUT_LINE('ANON_RUN|' || op.anon_engine.current_run_id || '|' || op.anon_engine.tool_version);
   DBMS_OUTPUT.PUT_LINE('ANON_RESULT|OK');
EXCEPTION
   WHEN OTHERS THEN
      v_code  := SQLCODE;
      v_error := SQLERRM;
      DBMS_OUTPUT.PUT_LINE('ANON_RESULT|FAILED|' || v_code || '|' || REPLACE(v_error, CHR(10), ' '));
END;
/
