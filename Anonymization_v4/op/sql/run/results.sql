-- ============================================================================
-- run/results - The figures of a run, for its screen and its report
-- ============================================================================
-- Sent by run_op_anonymization.bat to its monitor session (as OP) once the
-- run has ended - and, after a run, once it has been verified. Everything the
-- end of the run on the screen and report.html show comes from these lines.
--
-- READS, NEVER RE-CHECKS. Every figure comes from what the run and the
-- verification recorded in anon_meta: one place decides whether a column is
-- clean, and this is not it.
--
-- Counts, and names of tables and columns, only - never an identifier. The
-- queries that list the unclassified parties (ANON_R_XSQL) are printed for
-- the operator to run, never run here.
--
--   @results.sql <run id>
--
-- Prints, one line each, fields separated by |:
--   ANON_R_RUN       run, mode, status, started, finished, seconds, database,
--                    version, error
--   ANON_R_CONFIG    the run's switches and options, as recorded (JSON)
--   ANON_R_DATASET   what the run found, as counts (JSON)
--   ANON_R_SETTING   category, rename, labels, attributes (y/n)
--   ANON_R_CHECK     as plan.sql's ANON_CHECK
--   ANON_R_IDENT     category, found, new translations, reused, found now
--   ANON_R_ACCOUNTS  bank accounts: in compte_banque only, both, only on the
--                    structure, only in references
--   ANON_R_IDNOTES   same text party AND account, entity precedence,
--                    classification drift, earlier translations superseded
--   ANON_R_XREASON   reason, order, label, parties, in tiers, on a w_tiers
--                    node, on another screen, only in references, brief
--   ANON_R_XWHY / ANON_R_XFIX   reason, text
--   ANON_R_XSQL      reason, one line of the query that lists them
--   ANON_R_XTABLE    table, rows given an X_ value, columns
--   ANON_R_HARVEST   domain, codes found only in references, columns, rows
--   ANON_R_ITEM      seq, table, column, rule, category, source,
--                    HERE | NO_TABLE | NO_COLUMN
--   ANON_R_STEP      step id, phase, status, rows, rows to X_, ms, object,
--                    message (ERROR and REVIEW rows)
--   ANON_R_ESTIMATE  seconds, basis - a completed dry run
--   ANON_R_TRIGGERS  triggers of OP
--   ANON_R_V         part, status, bad rows, rows, check, detail - the
--                    verification of a completed run, when it is the one
--                    verified last
--   ANON_R_END
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET LONG 32767 LONGCHUNKSIZE 32767
SET DEFINE ON
WHENEVER SQLERROR CONTINUE

DEFINE run_id = &1

-- ---------------------------------------------------------------- the run --
SELECT 'ANON_R_RUN|' || run_id || '|' || run_mode || '|' || status
       || '|' || TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS') || '|' || TO_CHAR(finished_at, 'YYYY-MM-DD HH24:MI:SS')
       || '|' || ROUND((CAST(NVL(finished_at, SYSTIMESTAMP) AS DATE) - CAST(started_at AS DATE)) * 86400)
       || '|' || db_name || '|' || tool_version
       || '|' || REPLACE(REPLACE(error_text, CHR(10), ' '), '|', '/')
  FROM anon_meta.anon_run
 WHERE run_id = &run_id;

SELECT 'ANON_R_CONFIG|' || config_json FROM anon_meta.anon_run WHERE run_id = &run_id;
SELECT 'ANON_R_DATASET|' || dataset_json FROM anon_meta.anon_run WHERE run_id = &run_id;

SELECT 'ANON_R_SETTING|' || category || '|' || id_on || '|' || desc_on || '|' || attr_on
  FROM anon_meta.anon_run_setting
 WHERE run_id = &run_id
 ORDER BY DECODE(category, 'ENTITY', 1, 'PORTFOLIO', 2, 'COUNTERPARTY', 3, 'UNCLASSIFIED_PARTY', 4, 5);

SELECT 'ANON_R_CHECK|' || seq || '|' || code || '|' || needed || '|' || status || '|' || state || '|' || title
       || '|' || measure || '|' || what_happens || '|' || what_to_do
  FROM anon_meta.anon_check
 WHERE run_id = &run_id
 ORDER BY seq;

-- ----------------------------------------------------------- identities --
SELECT 'ANON_R_IDENT|' || c.category || '|' || COUNT(p.old_code)
       || '|' || COUNT(CASE WHEN p.map_status = 'NEW' THEN 1 END)
       || '|' || COUNT(CASE WHEN p.map_status = 'EXISTING' THEN 1 END)
       || '|' || COUNT(CASE WHEN p.identity_status = 'NEW' THEN 1 END)
  FROM (SELECT 'ENTITY' AS category, 1 AS o FROM dual
        UNION ALL SELECT 'PORTFOLIO', 2 FROM dual
        UNION ALL SELECT 'COUNTERPARTY', 3 FROM dual
        UNION ALL SELECT 'UNCLASSIFIED_PARTY', 4 FROM dual
        UNION ALL SELECT 'BANK_ACCOUNT', 5 FROM dual) c
  LEFT JOIN anon_meta.identity_plan p
         ON p.run_id = &run_id AND p.category = c.category
 GROUP BY c.category, c.o
 ORDER BY c.o;

SELECT 'ANON_R_ACCOUNTS|' || COUNT(CASE WHEN membership = 'MASTER_ONLY' THEN 1 END)
       || '|' || COUNT(CASE WHEN membership = 'BOTH' THEN 1 END)
       || '|' || COUNT(CASE WHEN membership = 'STRUCTURE_ONLY' THEN 1 END)
       || '|' || COUNT(CASE WHEN membership = 'REFERENCE_ONLY' THEN 1 END)
  FROM anon_meta.identity_plan
 WHERE run_id = &run_id AND domain = 'ACCOUNT';

SELECT 'ANON_R_IDNOTES|'
       || (SELECT COUNT(*) FROM (SELECT old_code FROM anon_meta.identity_plan WHERE run_id = &run_id
                                  GROUP BY old_code HAVING COUNT(DISTINCT domain) = 2))
       || '|' || (SELECT COUNT(*) FROM anon_meta.identity_plan WHERE run_id = &run_id AND entity_overlap = 'Y')
       || '|' || (SELECT COUNT(*) FROM anon_meta.identity_plan
                   WHERE run_id = &run_id
                     AND (   (identity_status = 'KNOWN' AND class_now IS NOT NULL AND class_now <> category)
                          OR (map_category IS NOT NULL AND map_category <> category)))
       || '|' || (SELECT NVL(SUM(superseded_maps), 0) FROM anon_meta.identity_plan WHERE run_id = &run_id)
  FROM dual;

-- ------------------------------------------------ unclassified parties --
SELECT 'ANON_R_XREASON|' || p.x_reason || '|' || MAX(d.sort_order) || '|' || NVL(MAX(d.label), LOWER(p.x_reason))
       || '|' || COUNT(*)
       || '|' || COUNT(CASE WHEN p.has_master = 'Y' THEN 1 END)
       || '|' || COUNT(CASE WHEN p.has_party_node = 'Y' THEN 1 END)
       || '|' || COUNT(CASE WHEN p.has_other_screen_node = 'Y' THEN 1 END)
       || '|' || COUNT(CASE WHEN p.membership = 'REFERENCE_ONLY' THEN 1 END)
       || '|' || MAX(d.brief)
  FROM anon_meta.identity_plan p
  LEFT JOIN anon_meta.unclassified_reason d ON d.x_reason = p.x_reason
 WHERE p.run_id = &run_id AND p.domain = 'PARTY' AND p.category = 'UNCLASSIFIED_PARTY'
 GROUP BY p.x_reason
 ORDER BY MAX(d.sort_order), p.x_reason;

SELECT 'ANON_R_XWHY|' || d.x_reason || '|' || d.why
  FROM anon_meta.unclassified_reason d
 WHERE d.x_reason IN (SELECT p.x_reason FROM anon_meta.identity_plan p
                       WHERE p.run_id = &run_id AND p.domain = 'PARTY' AND p.category = 'UNCLASSIFIED_PARTY')
 ORDER BY d.sort_order;

SELECT 'ANON_R_XFIX|' || d.x_reason || '|' || d.fix
  FROM anon_meta.unclassified_reason d
 WHERE d.x_reason IN (SELECT p.x_reason FROM anon_meta.identity_plan p
                       WHERE p.run_id = &run_id AND p.domain = 'PARTY' AND p.category = 'UNCLASSIFIED_PARTY')
 ORDER BY d.sort_order;

-- The query of each reason, line by line, for this run.
SELECT 'ANON_R_XSQL|' || d.x_reason || '|'
       || REGEXP_SUBSTR(REPLACE(d.list_sql, ':run_id', '&run_id'), '[^' || CHR(10) || ']+', 1, l.n)
  FROM anon_meta.unclassified_reason d
 CROSS JOIN (SELECT LEVEL AS n FROM dual CONNECT BY LEVEL <= 60) l
 WHERE d.x_reason IN (SELECT p.x_reason FROM anon_meta.identity_plan p
                       WHERE p.run_id = &run_id AND p.domain = 'PARTY' AND p.category = 'UNCLASSIFIED_PARTY')
   AND l.n <= REGEXP_COUNT(d.list_sql, '[^' || CHR(10) || ']+')
 ORDER BY d.sort_order, l.n;

-- Where their X_ values went (or would go), by table. The total is not
-- aliased x_rows: an alias with a column's name shadows it in ORDER BY.
SELECT 'ANON_R_XTABLE|' || tbl || '|' || SUM(x_rows) || '|' || COUNT(DISTINCT col)
  FROM (SELECT REGEXP_SUBSTR(object_name, '^[^.]+') AS tbl, REGEXP_SUBSTR(object_name, '^[^ ]+') AS col, x_rows
          FROM anon_meta.anon_step_log
         WHERE run_id = &run_id AND phase = 'CODE' AND x_rows > 0)
 GROUP BY tbl
 ORDER BY SUM(x_rows) DESC, tbl;

SELECT 'ANON_R_HARVEST|' || domain || '|' || COUNT(DISTINCT old_code)
       || '|' || COUNT(DISTINCT table_name || '.' || column_name) || '|' || SUM(n_rows)
  FROM anon_meta.reference_harvest
 WHERE run_id = &run_id
 GROUP BY domain
 ORDER BY DECODE(domain, 'PARTY', 1, 2);

-- -------------------------------------------------------- the inventory --
SELECT 'ANON_R_ITEM|' || i.seq || '|' || LOWER(i.table_name) || '|' || LOWER(i.column_name) || '|' || i.rule
       || '|' || i.category || '|' || i.source
       || '|' || CASE WHEN c.column_name IS NOT NULL THEN 'HERE'
                      WHEN t.table_name IS NOT NULL THEN 'NO_COLUMN'
                      ELSE 'NO_TABLE' END
  FROM anon_meta.anon_inventory i
  LEFT JOIN all_tab_columns c
         ON c.owner = 'OP' AND c.table_name = i.table_name AND c.column_name = i.column_name
  LEFT JOIN (SELECT DISTINCT table_name FROM all_tab_columns WHERE owner = 'OP') t
         ON t.table_name = i.table_name
 ORDER BY i.seq;

-- ------------------------------------------------------------- the work --
SELECT 'ANON_R_STEP|' || step_id || '|' || phase || '|' || status || '|' || rows_affected || '|' || x_rows
       || '|' || elapsed_ms || '|' || object_name
       || '|' || CASE WHEN status IN ('ERROR', 'REVIEW') THEN REPLACE(REPLACE(message, CHR(10), ' '), '|', '/') END
  FROM anon_meta.anon_step_log
 WHERE run_id = &run_id
   AND phase IN ('MAPPING', 'NULL_OUT', 'CODE', 'DESCRIPTION', 'SELF_CODE', 'TRIGGERS')
 ORDER BY step_id;

SELECT 'ANON_R_ESTIMATE|' || op.anon_engine.estimate(run_id)
  FROM anon_meta.anon_run
 WHERE run_id = &run_id AND run_mode = 'DRYRUN' AND status = 'COMPLETED';

SELECT 'ANON_R_TRIGGERS|' || COUNT(*) FROM all_triggers WHERE owner = 'OP';

-- ----------------------------------------------------- the verification --
-- anon_meta.verify_result holds the latest verification, which is of the
-- latest completed run: printed only when that is this run.
SELECT 'ANON_R_V|' || v.part || '|' || v.status || '|' || v.bad_rows || '|' || v.total_rows || '|' || v.check_name
       || '|' || CASE WHEN v.status NOT IN ('PASS', 'SKIP') THEN REPLACE(REPLACE(v.detail, CHR(10), ' '), '|', '/') END
  FROM anon_meta.verify_result v
 WHERE &run_id = (SELECT MAX(r.run_id) FROM anon_meta.anon_run r
                   WHERE r.run_mode = 'EXECUTE' AND r.status = 'COMPLETED')
 ORDER BY DECODE(v.part, 'SETUP', 0, 'IDENTITY', 1, 'RESIDUAL', 2, 'FREETEXT', 3, 'LABELS', 4,
                         'MAPPING', 5, 'SETTINGS', 6, 'PREFIX', 7, 8), v.checked_at;

PROMPT ANON_R_END
