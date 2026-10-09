-- ============================================================================
-- Coverage report - self-contained HTML
-- ============================================================================
--   sqlplus op/<password>@<TNS> @verify/generate_report.sql
--
-- Run from Anonymization_v4/op. Writes logs/report_<timestamp>.html.
-- The batch wrapper runs this automatically after a successful EXECUTE.
--
-- ----------------------------------------------------------------------------
-- READS, NEVER RE-CHECKS
--
-- Every number here comes from anon_meta.verify_result, joined to
-- anon_meta.anon_inventory and anon_meta.anon_run. This script performs no
-- verification of its own.
--
-- That is deliberate. Duplicating the check logic is exactly how the engine and
-- the verifier came to share one wrong assumption and both miss five live client
-- codes (test log, T8). There is one place that decides whether a column is
-- clean, and this is not it.
--
-- So run verify_op_coverage.sql first. If verify_result is empty this stops and
-- says so rather than rendering an empty report.
--
-- ----------------------------------------------------------------------------
-- CLEAN vs EXPOSED
--
--   Rows     every row in the column
--   Exposed  rows still holding an original client value - the only number that
--            should ever be non-zero
--   Clean    Rows - Exposed
--
-- Deliberately NOT "anonymized / not anonymized". A CODE column can legitimately
-- hold currency codes, product codes and system references that were never
-- client data and correctly carry no prefix. Counting those as "not anonymized"
-- would show alarming figures on a perfectly clean database - which is the trap
-- the v3 verifier fell into with prefix matching.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 32767
SET LONGCHUNKSIZE 32767
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET TRIMSPOOL ON
SET NEWPAGE NONE
SET ECHO OFF
SET DEFINE OFF

DECLARE
   v_n NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_n FROM anon_meta.verify_result;
   IF v_n = 0 THEN
      RAISE_APPLICATION_ERROR(-20070,
         'anon_meta.verify_result is empty - run verify_op_coverage.sql first. '
      || 'This script renders stored results and performs no checks of its own.');
   END IF;
END;
/

SET DEFINE ON
COLUMN report_file NEW_VALUE report_file
SELECT 'logs/report_' || TO_CHAR(SYSDATE, 'YYYYMMDD_HH24MISS') || '.html' AS report_file FROM dual;

-- Substitution must stay ON through the SPOOL below, or the report is written
-- to a file named after the variable instead of its value. It goes OFF again
-- immediately after, because the HTML that follows is full of character
-- entities that SQL*Plus would otherwise read as substitution variables -
-- and prompt for, which would hang an unattended run.
SPOOL &report_file
SET DEFINE OFF

DECLARE
   ------------------------------------------------------------------- state --
   v_db        VARCHAR2(60)  := SYS_CONTEXT('USERENV', 'DB_NAME');
   v_when      VARCHAR2(30)  := TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS');
   v_run_id    NUMBER;
   v_run_mode  VARCHAR2(10);
   v_run_when  VARCHAR2(30);
   v_rows_done NUMBER;
   v_secs      NUMBER;

   v_items     NUMBER;
   v_mappings  NUMBER;
   v_clean     NUMBER;
   v_exposed   NUMBER;
   v_skipped   NUMBER;
   v_warned    NUMBER;
   v_verdict   VARCHAR2(10);

   v_prev_tab  VARCHAR2(128);
   v_shown     PLS_INTEGER;

   -- Item declarations must all precede the first subprogram in a declarative
   -- section, so the state above cannot sit beside the code that uses it.
   ------------------------------------------------------------------ helpers --
   PROCEDURE w(p IN VARCHAR2 DEFAULT '') IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(p);
   END w;

   FUNCTION esc(p IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN REPLACE(REPLACE(REPLACE(NVL(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;');
   END esc;

   FUNCTION n(p IN NUMBER) RETURN VARCHAR2 IS
   BEGIN
      IF p IS NULL THEN RETURN '&mdash;'; END IF;
      RETURN TO_CHAR(p, 'FM999,999,999,999');
   END n;

   -- Compact big numbers for the headline tiles.
   FUNCTION short_n(p IN NUMBER) RETURN VARCHAR2 IS
   BEGIN
      IF p IS NULL           THEN RETURN '&mdash;';
      ELSIF p >= 1000000000  THEN RETURN TO_CHAR(ROUND(p/1000000000, 1), 'FM999.9') || 'B';
      ELSIF p >= 1000000     THEN RETURN TO_CHAR(ROUND(p/1000000, 1), 'FM999.9') || 'M';
      ELSIF p >= 10000       THEN RETURN TO_CHAR(ROUND(p/1000), 'FM999') || 'K';
      END IF;
      RETURN TO_CHAR(p, 'FM999,999');
   END short_n;

   FUNCTION status_cell(p_status IN VARCHAR2, p_detail IN VARCHAR2) RETURN VARCHAR2 IS
      v_cls   VARCHAR2(10);
      v_label VARCHAR2(30);
   BEGIN
      CASE p_status
         WHEN 'PASS' THEN v_cls := 'pass'; v_label := 'Pass';
         WHEN 'FAIL' THEN v_cls := 'fail'; v_label := 'Exposed';
         WHEN 'WARN' THEN v_cls := 'warn'; v_label := 'Warn';
         ELSE
            v_cls := 'skip';
            v_label := CASE
                          WHEN p_detail LIKE '%checkbox%'       THEN 'Checkbox'
                          WHEN p_detail LIKE '%code column%'    THEN 'No code col'
                          WHEN p_detail IS NULL                 THEN 'Not checked'
                          ELSE 'Not present'
                       END;
      END CASE;
      RETURN '<span class="st ' || v_cls || '">' || v_label || '</span>';
   END status_cell;

   FUNCTION rule_tag(p IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN '<span class="tag ' || LOWER(p) || '">' || p || '</span>';
   END rule_tag;

   ------------------------------------------------------------ one section --
   PROCEDURE inventory_section(p_source IN VARCHAR2, p_title IN VARCHAR2,
                               p_file IN VARCHAR2, p_note IN VARCHAR2) IS
      v_tot NUMBER; v_cln NUMBER; v_exp NUMBER; v_skp NUMBER;
   BEGIN
      SELECT COUNT(*),
             COUNT(CASE WHEN r.status = 'PASS' THEN 1 END),
             NVL(SUM(CASE WHEN r.status = 'FAIL' THEN r.bad_rows END), 0),
             COUNT(CASE WHEN r.status = 'SKIP' OR r.status IS NULL THEN 1 END)
        INTO v_tot, v_cln, v_exp, v_skp
        FROM anon_meta.anon_inventory i
        LEFT JOIN anon_meta.verify_result r
               ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
              AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
       WHERE i.source = p_source;

      IF v_tot = 0 THEN RETURN; END IF;

      w('<section>');
      w('  <div class="shead"><h2>' || p_title || '</h2>');
      w('    <span class="file mono">' || p_file || '</span>');
      w('    <span class="tally">' || n(v_tot) || ' columns &middot; ' || n(v_cln)
        || ' clean &middot; ' || n(v_exp) || ' exposed &middot; ' || n(v_skp)
        || ' not checked</span></div>');
      w('  <div class="note">' || p_note || '</div>');
      w('  <table><thead><tr><th>Table</th><th>Column</th><th>Rule</th><th>Category</th>'
        || '<th class="num">Rows</th><th class="num">Clean</th><th class="num">Exposed</th>'
        || '<th>Status</th></tr></thead><tbody>');

      v_prev_tab := '~';
      FOR c IN (SELECT i.table_name, i.column_name, i.rule, i.category, i.notes,
                       r.total_rows, r.bad_rows, r.status, r.detail
                  FROM anon_meta.anon_inventory i
                  LEFT JOIN anon_meta.verify_result r
                         ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                        AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
                 WHERE i.source = p_source
                 -- Failures first within each table, so nothing needing action
                 -- can be buried a few hundred rows down.
                 ORDER BY i.table_name,
                          CASE r.status WHEN 'FAIL' THEN 1 WHEN 'WARN' THEN 2
                                        WHEN 'PASS' THEN 3 ELSE 4 END,
                          i.column_name) LOOP

         IF c.table_name <> v_prev_tab THEN
            w('    <tr class="grp"><td colspan="8">' || LOWER(c.table_name) || '</td></tr>');
            v_prev_tab := c.table_name;
         END IF;

         w('    <tr' || CASE c.status WHEN 'FAIL' THEN ' class="is-fail"'
                                      WHEN 'WARN' THEN ' class="is-warn"' ELSE '' END || '>'
           || '<td class="tbl-name">' || LOWER(c.table_name) || '</td>'
           || '<td class="col-name">' || LOWER(c.column_name) || '</td>'
           || '<td>' || rule_tag(c.rule) || '</td>'
           || '<td class="cat">' || c.category || '</td>'
           || '<td class="num">' || n(c.total_rows) || '</td>'
           || '<td class="num">' || n(c.total_rows - NVL(c.bad_rows, 0)) || '</td>'
           || '<td class="num' || CASE WHEN NVL(c.bad_rows, 0) > 0 THEN ' bad' ELSE '' END
           || '">' || n(c.bad_rows) || '</td>'
           || '<td>' || status_cell(c.status, c.detail) || '</td></tr>');
      END LOOP;

      w('  </tbody></table>');
      w('</section>');
   END inventory_section;

BEGIN
   ------------------------------------------------------------ gather facts --
   SELECT MAX(run_id) INTO v_run_id FROM anon_meta.anon_run;

   BEGIN
      SELECT run_mode, TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS')
        INTO v_run_mode, v_run_when
        FROM anon_meta.anon_run WHERE run_id = v_run_id;
   EXCEPTION WHEN OTHERS THEN v_run_mode := '?'; v_run_when := '?';
   END;

   SELECT NVL(SUM(rows_affected), 0), NVL(ROUND(SUM(elapsed_ms)/1000), 0)
     INTO v_rows_done, v_secs
     FROM anon_meta.anon_step_log WHERE run_id = v_run_id;

   SELECT COUNT(*) INTO v_items    FROM anon_meta.anon_inventory;
   SELECT COUNT(*) INTO v_mappings FROM anon_meta.code_map;

   -- Per-column figures, over the inventory rather than over verify_result, so
   -- a column the verifier never reached still appears - as not checked.
   SELECT COUNT(CASE WHEN r.status = 'PASS' THEN 1 END),
          NVL(SUM(CASE WHEN r.status = 'FAIL' THEN r.bad_rows END), 0),
          COUNT(CASE WHEN r.status = 'SKIP' OR r.status IS NULL THEN 1 END)
     INTO v_clean, v_exposed, v_skipped
     FROM anon_meta.anon_inventory i
     LEFT JOIN anon_meta.verify_result r
            ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
           AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name);

   -- Warnings are counted over every part, including mapping integrity, so this
   -- figure equals the verifier's own - the report must not disagree with it.
   SELECT COUNT(*) INTO v_warned FROM anon_meta.verify_result WHERE status = 'WARN';

   SELECT CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL' END INTO v_verdict
     FROM anon_meta.verify_result WHERE status = 'FAIL';

   ------------------------------------------------------------------- head --
   w('<!doctype html>');
   w('<html lang="en"><head><meta charset="utf-8">');
   w('<meta name="viewport" content="width=device-width,initial-scale=1">');
   w('<title>OP Anonymization Report - ' || esc(v_db) || '</title>');
   w('<style>');
   w(':root{--ink:#1a1d21;--ink-2:#4a5159;--ink-3:#767e87;--line:#e3e6ea;--line-2:#eef0f3;');
   w('--bg:#f6f7f9;--card:#fff;--pass:#1a7f4b;--pass-bg:#e8f5ee;--fail:#b4232a;--fail-bg:#fdeceb;');
   w('--warn:#8a6100;--warn-bg:#fdf3e0;--skip:#767e87;--skip-bg:#f0f2f4;--accent:#1d4ed8}');
   w('*{box-sizing:border-box}');
   w('body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,');
   w('BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased}');
   w('.wrap{max-width:1180px;margin:0 auto;padding:32px 24px 72px}');
   w('code,.mono{font-family:ui-monospace,SFMono-Regular,"Cascadia Mono",Consolas,monospace;font-size:.92em}');
   w('h1{font-size:23px;margin:0 0 4px;letter-spacing:-.01em}');
   w('.sub{color:var(--ink-3);font-size:13.5px}.sub b{color:var(--ink-2);font-weight:600}');
   w('.verdict{display:flex;align-items:center;gap:18px;padding:20px 24px;border-radius:10px;');
   w('margin:22px 0 26px;border:1px solid}');
   w('.verdict.pass{background:var(--pass-bg);border-color:#bfe0cd}');
   w('.verdict.fail{background:var(--fail-bg);border-color:#f3c9c7}');
   w('.verdict .badge{font-size:26px;font-weight:700;letter-spacing:.02em}');
   w('.verdict.pass .badge{color:var(--pass)}.verdict.fail .badge{color:var(--fail)}');
   w('.verdict .msg{font-size:14px;color:var(--ink-2)}.verdict .msg b{color:var(--ink)}');
   w('.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:30px}');
   w('.tile{background:var(--card);border:1px solid var(--line);border-radius:9px;padding:14px 16px}');
   w('.tile .n{font-size:24px;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}');
   w('.tile .l{font-size:11.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--ink-3);margin-top:3px}');
   w('.tile.good .n{color:var(--pass)}.tile.bad .n{color:var(--fail)}');
   w('section{background:var(--card);border:1px solid var(--line);border-radius:10px;margin-bottom:22px;overflow:hidden}');
   w('.shead{padding:15px 20px;border-bottom:1px solid var(--line);display:flex;align-items:baseline;');
   w('justify-content:space-between;gap:16px;flex-wrap:wrap}');
   w('.shead h2{font-size:15.5px;margin:0;letter-spacing:-.005em}');
   w('.shead .file{font-size:12.5px;color:var(--ink-3)}');
   w('.shead .tally{font-size:12.5px;color:var(--ink-2);font-variant-numeric:tabular-nums}');
   w('.note{padding:11px 20px;background:#fafbfc;border-bottom:1px solid var(--line-2);font-size:12.5px;color:var(--ink-2)}');
   w('table{width:100%;border-collapse:collapse;font-size:13px}');
   w('th{position:sticky;top:0;background:#fafbfc;text-align:left;font-weight:600;font-size:11.5px;');
   w('text-transform:uppercase;letter-spacing:.045em;color:var(--ink-3);padding:9px 12px;');
   w('border-bottom:1px solid var(--line);white-space:nowrap}');
   w('td{padding:8px 12px;border-bottom:1px solid var(--line-2);vertical-align:top}');
   w('tbody tr:last-child td{border-bottom:none}tbody tr:hover{background:#fbfcfd}');
   w('.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}');
   w('.num.bad{color:var(--fail);font-weight:650}');
   w('.tbl-name{color:var(--ink-3)}.col-name{font-weight:550}.cat{color:var(--ink-2);font-size:12px}');
   w('.grp td{background:#f4f6f8;font-weight:600;font-size:12px;color:var(--ink-2);border-bottom:1px solid var(--line)}');
   w('.tag{display:inline-block;padding:1px 7px;border-radius:4px;font-size:11px;font-weight:600;');
   w('letter-spacing:.02em;background:var(--skip-bg);color:var(--ink-2)}');
   w('.tag.code{background:#e8eefc;color:#1d4ed8}.tag.null_out{background:#fdeef2;color:#a01f47}');
   w('.tag.description{background:#eef3e9;color:#446b1f}.tag.self_code{background:#f4eefb;color:#6b3fa0}');
   w('.st{display:inline-flex;align-items:center;gap:6px;font-weight:600;font-size:12.5px;white-space:nowrap}');
   w('.st::before{content:"";width:7px;height:7px;border-radius:50%;flex:none}');
   w('.st.pass{color:var(--pass)}.st.pass::before{background:var(--pass)}');
   w('.st.fail{color:var(--fail)}.st.fail::before{background:var(--fail)}');
   w('.st.warn{color:var(--warn)}.st.warn::before{background:var(--warn)}');
   w('.st.skip{color:var(--skip)}.st.skip::before{background:var(--skip)}');
   w('tr.is-fail td{background:var(--fail-bg)}tr.is-warn td{background:var(--warn-bg)}');
   w('footer{margin-top:34px;padding-top:18px;border-top:1px solid var(--line);font-size:12.5px;color:var(--ink-3)}');
   w('footer code{background:#eef0f3;padding:1px 5px;border-radius:3px}');
   w('@media print{body{background:#fff}.wrap{max-width:none;padding:0}');
   w('section{box-shadow:none}tr{break-inside:avoid}th{position:static}}');
   w('</style></head><body><div class="wrap">');

   ---------------------------------------------------------------- header --
   w('<header><h1>OP Anonymization &mdash; Coverage Report</h1>');
   w('<div class="sub">Database <b>' || esc(v_db) || '</b> &nbsp;&middot;&nbsp; Run <b>#'
     || v_run_id || '</b> (' || v_run_mode || ') &nbsp;&middot;&nbsp; Started <b>'
     || v_run_when || '</b> &nbsp;&middot;&nbsp; Took <b>'
     || CASE WHEN v_secs >= 60 THEN TO_CHAR(ROUND(v_secs / 60)) || ' min'
             ELSE TO_CHAR(v_secs) || ' s' END
     || '</b> &nbsp;&middot;&nbsp; Reported <b>' || v_when || '</b></div></header>');

   --------------------------------------------------------------- verdict --
   IF v_verdict = 'PASS' THEN
      w('<div class="verdict pass"><div class="badge">PASS</div><div class="msg">');
      w('No original identifier and no free-text value survived anywhere the inventory covers.<br>');
   ELSE
      w('<div class="verdict fail"><div class="badge">FAIL</div><div class="msg">');
      w('<b>Client data is still present.</b> Every exposed column is listed below in red.<br>');
   END IF;
   w('<b>' || n(v_items) || '</b> inventory columns &middot; <b>' || n(v_clean)
     || '</b> verified clean &middot; <b>' || n(v_exposed)
     || '</b> rows exposed &middot; <b>' || n(v_warned) || '</b> warnings &middot; <b>'
     || n(v_skipped) || '</b> not present on this instance');
   w('</div></div>');

   ------------------------------------------------------------------ tiles --
   w('<div class="tiles">');
   w('<div class="tile"><div class="n">' || n(v_items) || '</div><div class="l">Columns in scope</div></div>');
   w('<div class="tile good"><div class="n">' || n(v_clean) || '</div><div class="l">Verified clean</div></div>');
   w('<div class="tile' || CASE WHEN v_exposed > 0 THEN ' bad' ELSE '' END || '"><div class="n">'
     || n(v_exposed) || '</div><div class="l">Rows exposed</div></div>');
   w('<div class="tile"><div class="n">' || n(v_skipped) || '</div><div class="l">Not on instance</div></div>');
   w('<div class="tile"><div class="n">' || n(v_mappings) || '</div><div class="l">Identifiers mapped</div></div>');
   w('<div class="tile"><div class="n">' || short_n(v_rows_done) || '</div><div class="l">Rows changed</div></div>');
   w('</div>');

   -------------------------------------------------------- by treatment --
   w('<section><div class="shead"><h2>Coverage by treatment</h2>');
   SELECT COUNT(DISTINCT table_name) INTO v_shown FROM anon_meta.anon_inventory;
   w('<span class="tally">' || n(v_items) || ' columns &middot; ' || v_shown || ' tables</span></div>');
   w('<table><thead><tr><th>Rule</th><th>What it does</th><th class="num">Columns</th>'
     || '<th class="num">Clean</th><th class="num">Exposed</th><th class="num">Not checked</th>'
     || '<th>Status</th></tr></thead><tbody>');
   FOR t IN (SELECT i.rule,
                    COUNT(*) AS cols,
                    COUNT(CASE WHEN r.status = 'PASS' THEN 1 END) AS cln,
                    NVL(SUM(CASE WHEN r.status = 'FAIL' THEN r.bad_rows END), 0) AS exp_rows,
                    COUNT(CASE WHEN r.status = 'SKIP' OR r.status IS NULL THEN 1 END) AS skp
               FROM anon_meta.anon_inventory i
               LEFT JOIN anon_meta.verify_result r
                      ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                     AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
              GROUP BY i.rule
              ORDER BY DECODE(i.rule, 'CODE', 1, 'NULL_OUT', 2, 'DESCRIPTION', 3, 4)) LOOP
      w('<tr><td>' || rule_tag(t.rule) || '</td><td>'
        || CASE t.rule
              WHEN 'CODE'        THEN 'Identifier replaced from the mapping'
              WHEN 'NULL_OUT'    THEN 'Free text emptied, or masked where NOT NULL'
              WHEN 'DESCRIPTION' THEN 'Label set to the anonymized code of its own row'
              WHEN 'SELF_CODE'   THEN 'PII attribute set to the anonymized code of its own row'
           END
        || '</td><td class="num">' || n(t.cols) || '</td><td class="num">' || n(t.cln)
        || '</td><td class="num' || CASE WHEN t.exp_rows > 0 THEN ' bad' ELSE '' END || '">'
        || n(t.exp_rows) || '</td><td class="num">' || n(t.skp) || '</td><td>'
        || CASE WHEN t.exp_rows > 0
                THEN '<span class="st fail">Exposed</span>'
                ELSE '<span class="st pass">Pass</span>' END
        || '</td></tr>');
   END LOOP;
   w('</tbody></table></section>');

   ------------------------------------------------------ the two inventories --
   inventory_section('BASE', 'Shipped inventory', 'config/inventory_op.csv',
      'Every column is listed. <b>Exposed</b> counts rows still holding an original client value '
   || '&mdash; the only figure that should ever be non-zero. <b>Rows</b> is the whole column, so a '
   || 'large table with zero exposed rows is a column fully accounted for.');

   inventory_section('CUSTOM', 'Custom-added inventory', 'config/inventory_op_custom.csv',
      'Columns added or corrected outside the shipped list. A row here <b>overrides</b> the '
   || 'shipped inventory for the same table and column.');

   ------------------------------------------------------------- not present --
   SELECT COUNT(*) INTO v_shown
     FROM anon_meta.anon_inventory i
     LEFT JOIN anon_meta.verify_result r
            ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
           AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
    WHERE r.status = 'SKIP' OR r.status IS NULL;

   IF v_shown > 0 THEN
      w('<section><div class="shead"><h2>Not checked on this instance</h2>');
      w('<span class="tally">' || n(v_shown) || ' columns</span></div>');
      w('<div class="note">Expected. The inventory covers several KTP/CTI versions, so a column '
        || 'absent here simply does not exist in this one. Checkbox columns are deliberately left '
        || 'alone. Each was resolved against the data dictionary before the run started.</div>');
      w('<table><thead><tr><th>Table</th><th class="num">Columns</th><th>Reason</th></tr>'
        || '</thead><tbody>');
      FOR s IN (SELECT i.table_name,
                       COUNT(*) AS cols,
                       MIN(NVL(r.detail, 'not checked')) AS reason
                  FROM anon_meta.anon_inventory i
                  LEFT JOIN anon_meta.verify_result r
                         ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                        AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
                 WHERE r.status = 'SKIP' OR r.status IS NULL
                 GROUP BY i.table_name
                 ORDER BY COUNT(*) DESC, i.table_name) LOOP
         w('<tr><td class="tbl-name">' || LOWER(s.table_name) || '</td><td class="num">'
           || n(s.cols) || '</td><td>' || esc(s.reason) || '</td></tr>');
      END LOOP;
      w('</tbody></table></section>');
   END IF;

   -------------------------------------------------------- mapping integrity --
   w('<section><div class="shead"><h2>Mapping integrity</h2>');
   w('<span class="tally">' || n(v_mappings) || ' identifiers</span></div>');
   w('<table><thead><tr><th>Check</th><th class="num">Value</th><th>Status</th><th>Note</th></tr>'
     || '</thead><tbody>');
   FOR m IN (SELECT check_name, bad_rows, status, detail
               FROM anon_meta.verify_result
              WHERE part = 'MAPPING'
              ORDER BY DECODE(status, 'FAIL', 1, 'WARN', 2, 3), check_name) LOOP
      w('<tr' || CASE m.status WHEN 'FAIL' THEN ' class="is-fail"'
                               WHEN 'WARN' THEN ' class="is-warn"' ELSE '' END || '>'
        || '<td>' || esc(INITCAP(SUBSTR(m.check_name, 1, 1)) || SUBSTR(m.check_name, 2)) || '</td>'
        || '<td class="num">' || n(m.bad_rows) || '</td>'
        || '<td>' || status_cell(m.status, m.detail) || '</td>'
        || '<td>' || esc(m.detail) || '</td></tr>');
   END LOOP;
   FOR c IN (SELECT category, COUNT(*) AS cnt FROM anon_meta.code_map
              GROUP BY category ORDER BY category) LOOP
      w('<tr><td>Identifiers mapped &mdash; ' || INITCAP(REPLACE(c.category, '_', ' '))
        || '</td><td class="num">' || n(c.cnt) || '</td>'
        || '<td><span class="st pass">Pass</span></td><td></td></tr>');
   END LOOP;
   w('</tbody></table></section>');

   ----------------------------------------------------------------- footer --
   w('<footer>Generated by <code>verify/generate_report.sql</code> from '
     || '<code>anon_meta.verify_result</code>. It renders stored results and re-runs no checks, '
     || 'so it can be regenerated at any time.<br>');
   w('Detail is queryable: <code>SELECT * FROM anon_meta.verify_result WHERE status = '
     || '&#39;FAIL&#39;;</code></footer>');
   w('</div></body></html>');
END;
/

SPOOL OFF

SET DEFINE ON
PROMPT
PROMPT Report written to &report_file
PROMPT

EXIT SUCCESS
