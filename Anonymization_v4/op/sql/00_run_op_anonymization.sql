-- ============================================================================
-- 00 - OP anonymization orchestrator
-- ============================================================================
-- Entry point. Normally invoked by run_op_anonymization.bat, which collects the
-- configuration and generates the inventory load file.
--
-- To run it directly:
--   sqlplus /nolog @00_run_op_anonymization.sql <sid> <syspwd> <oppwd> \
--       <tbs_data> <tbs_index> <mode> \
--       <ent> <ptf> <cpty> <unclassified> <acct>                    (rename IDs) \
--       <ent_desc> <ptf_desc> <cpty_desc> <uncl_desc> <acct_desc>   (labels) \
--       <ent_attr> <ptf_attr> <cpty_attr> <uncl_attr> <acct_attr>   (attributes) \
--       <parallel> <fail_on_missing> <approve_structure_only> <inventory_data_file>
--
-- Parameters
--   &1  ORACLE_SID                  &14 ANONYMIZE_COUNTERPARTY_DESCRIPTION
--   &2  SYS password                &15 ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION
--   &3  OP password                 &16 ANONYMIZE_BANK_ACCOUNT_DESCRIPTION
--   &4  TABLESPACE_DATA             &17 ANONYMIZE_ENTITY_ATTRIBUTES
--   &5  TABLESPACE_INDEX            &18 ANONYMIZE_PORTFOLIO_ATTRIBUTES
--   &6  mode EXECUTE|DRYRUN         &19 ANONYMIZE_COUNTERPARTY_ATTRIBUTES
--   &7  ANONYMIZE_ENTITY            &20 ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES
--   &8  ANONYMIZE_PORTFOLIO         &21 ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES
--   &9  ANONYMIZE_COUNTERPARTY      &22 PARALLEL_DEGREE
--   &10 ANONYMIZE_UNCLASSIFIED_PARTY &23 FAIL_ON_MISSING_OBJECT
--   &11 ANONYMIZE_BANK_ACCOUNT      &24 APPROVE_STRUCTURE_ONLY_ACCOUNTS
--   &12 ANONYMIZE_ENTITY_DESCRIPTION &25 generated inventory INSERT file
--   &13 ANONYMIZE_PORTFOLIO_DESCRIPTION
--
-- Each category's three switches are independent: the first renames
-- identifiers, the second masks labels, the third masks attributes and
-- addresses. Free text (NULL_OUT) is always erased.
-- ============================================================================

DEFINE db_sid          = &1
DEFINE sys_password    = &2
DEFINE op_password     = &3
DEFINE tbs_data        = &4
DEFINE tbs_index       = &5
DEFINE run_mode        = &6
DEFINE do_entity       = &7
DEFINE do_portfolio    = &8
DEFINE do_counterparty = &9
DEFINE do_unclassified = &10
DEFINE do_account      = &11
DEFINE desc_entity     = &12
DEFINE desc_portfolio  = &13
DEFINE desc_cpty       = &14
DEFINE desc_uncl       = &15
DEFINE desc_account    = &16
DEFINE attr_entity     = &17
DEFINE attr_portfolio  = &18
DEFINE attr_cpty       = &19
DEFINE attr_uncl       = &20
DEFINE attr_account    = &21
DEFINE parallel_degree = &22
DEFINE fail_missing    = &23
DEFINE approve_struct  = &24
DEFINE inventory_data  = &25

SET ECHO OFF
SET VERIFY OFF
SET FEEDBACK OFF
SET HEADING OFF
SET LINESIZE 200
SET TAB OFF
SET PAGESIZE 0
SET TRIMSPOOL ON
SET SERVEROUTPUT ON SIZE UNLIMITED

-- Any error from here on aborts the run and returns a non-zero exit code.
-- v3 had no such policy: a failure scrolled past and the script reported
-- success regardless.
WHENEVER SQLERROR EXIT FAILURE
WHENEVER OSERROR EXIT FAILURE


-- ============================================================================
-- Connect and open the log
-- ============================================================================
-- The password is quoted so that one containing @ / " or other punctuation does
-- not get parsed as part of the connect string.
CONNECT sys/"&sys_password"@&db_sid AS SYSDBA

COLUMN log_file NEW_VALUE log_file
SELECT 'logs/op_anon_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') || '.log' AS log_file FROM dual;
SPOOL &log_file

PROMPT
PROMPT ====================================================================
PROMPT  KTP OP Anonymization (v4)
PROMPT ====================================================================


-- ============================================================================
-- Metadata schema (as SYS)
-- ============================================================================
-- @@ resolves relative to THIS script rather than the working directory, so the
-- orchestrator can be invoked from anywhere.
@@10_create_metadata_schema.sql &tbs_data &tbs_index


-- ============================================================================
-- Everything else runs as OP
-- ============================================================================
SET TERMOUT OFF
CONNECT op/"&op_password"@&db_sid
SET TERMOUT ON

-- Assert the connection immediately. TERMOUT OFF hides a failed CONNECT, and
-- SQL*Plus does not always treat one as a SQLERROR - so without this a bad
-- connect surfaces much later as ORA-03114 on whatever statement happens to run
-- next, naming the wrong culprit.
SET HEADING OFF
SELECT 'Connected as ' || USER || ' on ' || SYS_CONTEXT('USERENV', 'DB_NAME')
       || ' (session ' || SYS_CONTEXT('USERENV', 'SID') || ')' AS connected FROM dual;
SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF

@@30_install_engine.sql

-- Inventory load.
--
-- The table was cleared by 10_create_metadata_schema.sql as SYS, using TRUNCATE
-- rather than a DELETE here as OP - see the comment there for why.
--
-- The generated INSERT file is run directly rather than @-included from inside
-- another @-included script: a nested @ with the path arriving through a second
-- DEFINE names neither the file nor the line when it fails.
--
-- The path is echoed first so that a load failure says which file to look at.
PROMPT
PROMPT Inventory file: &inventory_data
@&inventory_data
@@21_validate_inventory.sql


-- ============================================================================
-- Configure and open the run
-- ============================================================================
BEGIN
   op.anon_engine.configure(
      p_mode                   => '&run_mode',
      p_entity                 => '&do_entity',
      p_portfolio              => '&do_portfolio',
      p_counterparty           => '&do_counterparty',
      p_unclassified           => '&do_unclassified',
      p_bank_account           => '&do_account',
      p_entity_desc            => '&desc_entity',
      p_portfolio_desc         => '&desc_portfolio',
      p_counterparty_desc      => '&desc_cpty',
      p_unclassified_desc      => '&desc_uncl',
      p_bank_account_desc      => '&desc_account',
      p_entity_attr            => '&attr_entity',
      p_portfolio_attr         => '&attr_portfolio',
      p_counterparty_attr      => '&attr_cpty',
      p_unclassified_attr      => '&attr_uncl',
      p_bank_account_attr      => '&attr_account',
      p_parallel_degree        => '&parallel_degree',
      p_fail_on_missing        => '&fail_missing',
      p_approve_structure_only => '&approve_struct');

   op.anon_engine.start_run;
END;
/


-- ============================================================================
-- Preflight - resolve the inventory and check it can be applied.
-- Raises before anything is modified if it cannot.
-- ============================================================================
BEGIN
   op.anon_engine.preflight;
EXCEPTION
   WHEN OTHERS THEN
      op.anon_engine.finish_run('FAILED', SQLERRM);
      RAISE;
END;
/


-- ============================================================================
-- Work
-- ============================================================================
PROMPT
PROMPT ====================================================================
PROMPT  Live progress is written to anon_meta.anon_step_log as it happens.
PROMPT  The output below appears only once each phase finishes, so to watch
PROMPT  a long run open a second session and use:
PROMPT      tests\manual\monitor_op_progress.sql
PROMPT ====================================================================

DECLARE
   v_error VARCHAR2(4000);
BEGIN
   IF '&run_mode' = 'DRYRUN' THEN
      -- Rehearsal: the same code path, counting instead of updating.
      op.anon_engine.generate_code_map;
      op.anon_engine.apply_inventory;
      op.anon_engine.print_summary;
      op.anon_engine.finish_run('COMPLETED');
      RETURN;
   END IF;

   -- Triggers off for the duration. The nested handler guarantees they come
   -- back on even when the run fails - leaving them disabled would leave the
   -- application silently broken.
   op.anon_engine.set_triggers(FALSE);

   BEGIN
      op.anon_engine.generate_code_map;
      op.anon_engine.apply_inventory;
   EXCEPTION
      WHEN OTHERS THEN
         v_error := SQLERRM;
         op.anon_engine.set_triggers(TRUE);
         op.anon_engine.finish_run('FAILED', v_error);
         RAISE;
   END;

   op.anon_engine.set_triggers(TRUE);
   op.anon_engine.print_summary;
   op.anon_engine.finish_run('COMPLETED');
END;
/


PROMPT
PROMPT ====================================================================
PROMPT  Complete
PROMPT ====================================================================
PROMPT
PROMPT  Next: verify the result.
PROMPT      sqlplus op/<password>@<TNS> @verify\verify_op_coverage.sql
PROMPT

SPOOL OFF
EXIT SUCCESS
