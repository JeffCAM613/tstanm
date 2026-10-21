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
-- anon_meta.anon_inventory, anon_meta.anon_run and the run's switches. This
-- script performs no verification of its own.
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
-- THE VERDICT
--
--   PASS        every protection on, nothing original left, nothing pending
--   FAIL        client data still present where it should have been replaced
--   REVIEW      client values deliberately left unchanged - their role or
--               domain is ambiguous - until a reviewed decision covers them
--   INCOMPLETE  nothing exposed where protection was on, but a protection was
--               switched off: partial anonymization
--
-- A zero-exposure figure is never shown as complete coverage while anything is
-- left for review or switched off.
--
-- ----------------------------------------------------------------------------
-- CLEAN vs EXPOSED
--
--   Rows     every row in the column
--   Exposed  rows still holding an original client value where they should not
--   Clean    Rows - Exposed - review - switched off
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
   v_identities NUMBER;
   v_clean     NUMBER := 0;
   v_exposed   NUMBER := 0;
   v_review    NUMBER := 0;
   v_off       NUMBER := 0;
   v_skipped   NUMBER := 0;
   v_warned    NUMBER;
   v_verdict   VARCHAR2(12);

   v_prev_tab  VARCHAR2(128);
   v_shown     PLS_INTEGER;

   -- One status per inventory column. The verifier may check a column in
   -- several parts - structure.code once per node role - so its rows are
   -- folded here by the column they belong to, the worst status winning.
   TYPE t_col IS RECORD (status VARCHAR2(10), total NUMBER, bad NUMBER, detail VARCHAR2(4000));
   TYPE t_cols IS TABLE OF t_col INDEX BY VARCHAR2(300);
   g_cols t_cols;

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

   FUNCTION rank_of(p_status IN VARCHAR2) RETURN PLS_INTEGER IS
   BEGIN
      RETURN CASE p_status WHEN 'FAIL' THEN 6 WHEN 'REVIEW' THEN 5 WHEN 'DISABLED' THEN 4
                           WHEN 'WARN' THEN 3 WHEN 'PASS' THEN 2 WHEN 'SKIP' THEN 1 ELSE 0 END;
   END rank_of;

   FUNCTION status_cell(p_status IN VARCHAR2, p_detail IN VARCHAR2) RETURN VARCHAR2 IS
      v_cls   VARCHAR2(10);
      v_label VARCHAR2(30);
   BEGIN
      CASE p_status
         WHEN 'PASS'     THEN v_cls := 'pass';   v_label := 'Pass';
         WHEN 'FAIL'     THEN v_cls := 'fail';   v_label := 'Exposed';
         WHEN 'REVIEW'   THEN v_cls := 'review'; v_label := 'Review';
         WHEN 'DISABLED' THEN v_cls := 'off';    v_label := 'Switched off';
         WHEN 'WARN'     THEN v_cls := 'warn';   v_label := 'Warn';
         WHEN 'INFO'     THEN v_cls := 'skip';   v_label := 'Info';
         ELSE
            v_cls := 'skip';
            v_label := CASE
                          WHEN p_detail LIKE '%code column%' THEN 'No code col'
                          WHEN p_detail IS NULL              THEN 'Not checked'
                          ELSE 'Not present'
                       END;
      END CASE;
      RETURN '<span class="st ' || v_cls || '">' || v_label || '</span>';
   END status_cell;

   FUNCTION rule_tag(p IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN '<span class="tag ' || LOWER(p) || '">' || p || '</span>';
   END rule_tag;

   FUNCTION col_of(p_table IN VARCHAR2, p_column IN VARCHAR2) RETURN t_col IS
      v_key VARCHAR2(300) := LOWER(p_table) || '.' || LOWER(p_column);
      v_none t_col;
   BEGIN
      IF g_cols.EXISTS(v_key) THEN
         RETURN g_cols(v_key);
      END IF;
      RETURN v_none;
   END col_of;

   ------------------------------------------------------------ one section --
   PROCEDURE inventory_section(p_source IN VARCHAR2, p_title IN VARCHAR2,
                               p_file IN VARCHAR2, p_note IN VARCHAR2) IS
      v_tot NUMBER := 0; v_cln NUMBER := 0; v_exp NUMBER := 0; v_rev NUMBER := 0;
      v_off NUMBER := 0; v_skp NUMBER := 0;
      c     t_col;
   BEGIN
      FOR i IN (SELECT table_name, column_name FROM anon_meta.anon_inventory WHERE source = p_source) LOOP
         c := col_of(i.table_name, i.column_name);
         v_tot := v_tot + 1;
         CASE c.status
            WHEN 'PASS'     THEN v_cln := v_cln + 1;
            WHEN 'FAIL'     THEN v_exp := v_exp + NVL(c.bad, 0);
            WHEN 'REVIEW'   THEN v_rev := v_rev + NVL(c.bad, 0);
            WHEN 'DISABLED' THEN v_off := v_off + NVL(c.bad, 0);
            WHEN 'WARN'     THEN v_cln := v_cln + 1;
            ELSE v_skp := v_skp + 1;
         END CASE;
      END LOOP;

      IF v_tot = 0 THEN RETURN; END IF;

      w('<section>');
      w('  <div class="shead"><h2>' || p_title || '</h2>');
      w('    <span class="file mono">' || p_file || '</span>');
      w('    <span class="tally">' || n(v_tot) || ' columns &middot; ' || n(v_cln)
        || ' clean &middot; ' || n(v_exp) || ' rows exposed &middot; ' || n(v_rev)
        || ' rows for review &middot; ' || n(v_off) || ' rows switched off &middot; ' || n(v_skp)
        || ' not checked</span></div>');
      w('  <div class="note">' || p_note || '</div>');
      w('  <table><thead><tr><th>Table</th><th>Column</th><th>Rule</th><th>Domain</th>'
        || '<th class="num">Rows</th><th class="num">Exposed / held</th><th>Status</th></tr></thead><tbody>');

      v_prev_tab := '~';
      -- Problems first within each table, so nothing needing action can be
      -- buried a few hundred rows down.
      FOR i IN (SELECT table_name, column_name, rule, category
                  FROM anon_meta.anon_inventory
                 WHERE source = p_source
                 ORDER BY table_name, column_name) LOOP
         IF i.table_name <> v_prev_tab THEN
            w('    <tr class="grp"><td colspan="7">' || LOWER(i.table_name) || '</td></tr>');
            v_prev_tab := i.table_name;
         END IF;

         c := col_of(i.table_name, i.column_name);
         w('    <tr' || CASE c.status WHEN 'FAIL' THEN ' class="is-fail"'
                                      WHEN 'REVIEW' THEN ' class="is-review"'
                                      WHEN 'DISABLED' THEN ' class="is-off"' ELSE '' END || '>'
           || '<td class="tbl-name">' || LOWER(i.table_name) || '</td>'
           || '<td class="col-name">' || LOWER(i.column_name) || '</td>'
           || '<td>' || rule_tag(i.rule) || '</td>'
           || '<td class="cat">' || i.category || '</td>'
           || '<td class="num">' || n(c.total) || '</td>'
           || '<td class="num' || CASE WHEN c.status = 'FAIL' THEN ' bad' END || '">'
           || CASE WHEN c.status IN ('FAIL', 'REVIEW', 'DISABLED') THEN n(c.bad) ELSE '&mdash;' END || '</td>'
           || '<td>' || status_cell(c.status, c.detail) || '</td></tr>');
      END LOOP;

      w('  </tbody></table>');
      w('</section>');
   END inventory_section;

BEGIN
   ------------------------------------------------------------ gather facts --
   SELECT MAX(run_id) INTO v_run_id
     FROM anon_meta.anon_run WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED';
   IF v_run_id IS NULL THEN
      SELECT MAX(run_id) INTO v_run_id FROM anon_meta.anon_run;
   END IF;

   BEGIN
      SELECT run_mode, TO_CHAR(started_at, 'YYYY-MM-DD HH24:MI:SS')
        INTO v_run_mode, v_run_when
        FROM anon_meta.anon_run WHERE run_id = v_run_id;
   EXCEPTION WHEN OTHERS THEN v_run_mode := '?'; v_run_when := '?';
   END;

   SELECT NVL(SUM(rows_affected), 0), NVL(ROUND(SUM(elapsed_ms)/1000), 0)
     INTO v_rows_done, v_secs
     FROM anon_meta.anon_step_log
    WHERE run_id = v_run_id AND phase NOT IN ('PREFLIGHT', 'METADATA') AND status <> 'REVIEW';

   SELECT COUNT(*) INTO v_items    FROM anon_meta.anon_inventory;
   SELECT COUNT(*) INTO v_mappings FROM anon_meta.code_map;
   SELECT MAX(total_rows) INTO v_identities
     FROM anon_meta.verify_result WHERE part = 'IDENTITY' AND check_name = 'identities by category';

   -- Fold the per-column checks into one status per inventory column.
   FOR v IN (SELECT REGEXP_REPLACE(check_name, ' \[[^]]*\]$', '') AS base,
                    status, total_rows, bad_rows, detail
               FROM anon_meta.verify_result
              WHERE part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                AND check_name NOT LIKE '%[empty fields kept]'
                AND check_name LIKE '%.%') LOOP
      IF NOT g_cols.EXISTS(v.base) THEN
         g_cols(v.base).status := v.status;
         g_cols(v.base).total  := v.total_rows;
         g_cols(v.base).bad    := CASE WHEN v.status IN ('FAIL', 'REVIEW', 'DISABLED') THEN v.bad_rows END;
         g_cols(v.base).detail := v.detail;
      ELSE
         g_cols(v.base).total := NVL(g_cols(v.base).total, 0) + NVL(v.total_rows, 0);
         IF rank_of(v.status) > rank_of(g_cols(v.base).status) THEN
            g_cols(v.base).status := v.status;
            g_cols(v.base).detail := v.detail;
            g_cols(v.base).bad    := v.bad_rows;
         ELSIF v.status = g_cols(v.base).status AND v.status IN ('FAIL', 'REVIEW', 'DISABLED') THEN
            g_cols(v.base).bad := NVL(g_cols(v.base).bad, 0) + NVL(v.bad_rows, 0);
         END IF;
      END IF;
   END LOOP;

   FOR i IN (SELECT table_name, column_name FROM anon_meta.anon_inventory) LOOP
      DECLARE
         c t_col := col_of(i.table_name, i.column_name);
      BEGIN
         CASE c.status
            WHEN 'PASS'     THEN v_clean   := v_clean + 1;
            WHEN 'WARN'     THEN v_clean   := v_clean + 1;
            WHEN 'FAIL'     THEN v_exposed := v_exposed + NVL(c.bad, 0);
            WHEN 'REVIEW'   THEN v_review  := v_review + NVL(c.bad, 0);
            WHEN 'DISABLED' THEN v_off     := v_off + NVL(c.bad, 0);
            ELSE v_skipped := v_skipped + 1;
         END CASE;
      END;
   END LOOP;

   SELECT COUNT(*) INTO v_warned FROM anon_meta.verify_result WHERE status = 'WARN';

   -- The verdict, from every part - the same rule the verifier applies.
   SELECT CASE WHEN COUNT(CASE WHEN status = 'FAIL'     THEN 1 END) > 0 THEN 'FAIL'
               WHEN COUNT(CASE WHEN status = 'REVIEW'   THEN 1 END) > 0 THEN 'REVIEW'
               WHEN COUNT(CASE WHEN status = 'DISABLED' THEN 1 END) > 0 THEN 'INCOMPLETE'
               ELSE 'PASS' END
     INTO v_verdict
     FROM anon_meta.verify_result;

   ------------------------------------------------------------------- head --
   w('<!doctype html>');
   w('<html lang="en"><head><meta charset="utf-8">');
   w('<meta name="viewport" content="width=device-width,initial-scale=1">');
   w('<title>OP Anonymization Report - ' || esc(v_db) || '</title>');
   w('<style>');
   w(':root{--ink:#1a1d21;--ink-2:#4a5159;--ink-3:#767e87;--line:#e3e6ea;--line-2:#eef0f3;');
   w('--bg:#f6f7f9;--card:#fff;--pass:#1a7f4b;--pass-bg:#e8f5ee;--fail:#b4232a;--fail-bg:#fdeceb;');
   w('--warn:#8a6100;--warn-bg:#fdf3e0;--review:#9a4d00;--review-bg:#fdeedd;--off:#475569;--off-bg:#eef1f5;');
   w('--skip:#767e87;--skip-bg:#f0f2f4;--accent:#1d4ed8}');
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
   w('.verdict.review{background:var(--review-bg);border-color:#f2d2ae}');
   w('.verdict.incomplete{background:var(--off-bg);border-color:#cfd6df}');
   w('.verdict .badge{font-size:26px;font-weight:700;letter-spacing:.02em;white-space:nowrap}');
   w('.verdict.pass .badge{color:var(--pass)}.verdict.fail .badge{color:var(--fail)}');
   w('.verdict.review .badge{color:var(--review)}.verdict.incomplete .badge{color:var(--off)}');
   w('.verdict .msg{font-size:14px;color:var(--ink-2)}.verdict .msg b{color:var(--ink)}');
   w('.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin-bottom:30px}');
   w('.tile{background:var(--card);border:1px solid var(--line);border-radius:9px;padding:14px 16px}');
   w('.tile .n{font-size:24px;font-weight:650;letter-spacing:-.02em;font-variant-numeric:tabular-nums}');
   w('.tile .l{font-size:11.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--ink-3);margin-top:3px}');
   w('.tile.good .n{color:var(--pass)}.tile.bad .n{color:var(--fail)}');
   w('.tile.review .n{color:var(--review)}.tile.off .n{color:var(--off)}');
   w('section{background:var(--card);border:1px solid var(--line);border-radius:10px;margin-bottom:22px;overflow:hidden}');
   w('.shead{padding:15px 20px;border-bottom:1px solid var(--line);display:flex;align-items:baseline;');
   w('justify-content:space-between;gap:16px;flex-wrap:wrap}');
   w('.shead h2{font-size:15.5px;margin:0;letter-spacing:-.005em}');
   w('.shead .file{font-size:12.5px;color:var(--ink-3)}');
   w('.shead .tally{font-size:12.5px;color:var(--ink-2);font-variant-numeric:tabular-nums}');
   w('.note{padding:11px 20px;background:#fafbfc;border-bottom:1px solid var(--line-2);font-size:12.5px;color:var(--ink-2)}');
   w('.scroll{overflow-x:auto}');
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
   w('.st.review{color:var(--review)}.st.review::before{background:var(--review)}');
   w('.st.off{color:var(--off)}.st.off::before{background:var(--off)}');
   w('.st.warn{color:var(--warn)}.st.warn::before{background:var(--warn)}');
   w('.st.skip{color:var(--skip)}.st.skip::before{background:var(--skip)}');
   w('tr.is-fail td{background:var(--fail-bg)}tr.is-review td{background:var(--review-bg)}');
   w('tr.is-off td{background:var(--off-bg)}tr.is-warn td{background:var(--warn-bg)}');
   w('footer{margin-top:34px;padding-top:18px;border-top:1px solid var(--line);font-size:12.5px;color:var(--ink-3)}');
   w('footer code{background:#eef0f3;padding:1px 5px;border-radius:3px}');
   w('@media (max-width:640px){.wrap{padding:20px 16px 48px}.verdict{flex-direction:column;align-items:flex-start}}');
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
      w('Every protection was on. No original identifier and no free-text value survived anywhere '
        || 'the inventory covers, and nothing was left for review.<br>');
   ELSIF v_verdict = 'FAIL' THEN
      w('<div class="verdict fail"><div class="badge">FAIL</div><div class="msg">');
      w('<b>Client data is still present.</b> Every exposed column is listed below in red.<br>');
   ELSIF v_verdict = 'REVIEW' THEN
      w('<div class="verdict review"><div class="badge">REVIEW REQUIRED</div><div class="msg">');
      w('<b>Not complete anonymization yet.</b> Some client values were deliberately left unchanged '
        || 'because their role or domain could not be established. They are listed under '
        || '&ldquo;Needs attention&rdquo;; each needs a reviewed decision.<br>');
   ELSE
      w('<div class="verdict incomplete"><div class="badge">INCOMPLETE</div><div class="msg">');
      w('<b>Partial anonymization.</b> Nothing was exposed where protection was switched on, but at '
        || 'least one protection was switched off, so original values remain by configuration.<br>');
   END IF;
   w('<b>' || n(v_items) || '</b> inventory columns &middot; <b>' || n(v_clean)
     || '</b> verified clean &middot; <b>' || n(v_exposed)
     || '</b> rows exposed &middot; <b>' || n(v_review) || '</b> rows for review &middot; <b>'
     || n(v_off) || '</b> rows switched off &middot; <b>' || n(v_skipped)
     || '</b> not present on this instance');
   w('</div></div>');

   ------------------------------------------------------------------ tiles --
   w('<div class="tiles">');
   w('<div class="tile"><div class="n">' || n(v_items) || '</div><div class="l">Columns in scope</div></div>');
   w('<div class="tile good"><div class="n">' || n(v_clean) || '</div><div class="l">Verified clean</div></div>');
   w('<div class="tile' || CASE WHEN v_exposed > 0 THEN ' bad' END || '"><div class="n">'
     || n(v_exposed) || '</div><div class="l">Rows exposed</div></div>');
   w('<div class="tile' || CASE WHEN v_review > 0 THEN ' review' END || '"><div class="n">'
     || n(v_review) || '</div><div class="l">Rows for review</div></div>');
   w('<div class="tile' || CASE WHEN v_off > 0 THEN ' off' END || '"><div class="n">'
     || n(v_off) || '</div><div class="l">Rows switched off</div></div>');
   w('<div class="tile"><div class="n">' || n(v_identities) || '</div><div class="l">Identities</div></div>');
   w('<div class="tile"><div class="n">' || n(v_mappings) || '</div><div class="l">Identifiers mapped</div></div>');
   w('<div class="tile"><div class="n">' || short_n(v_rows_done) || '</div><div class="l">Rows changed</div></div>');
   w('</div>');

   ------------------------------------------------------- needs attention --
   SELECT COUNT(*) INTO v_shown
     FROM anon_meta.verify_result WHERE status IN ('FAIL', 'REVIEW', 'DISABLED', 'WARN');
   w('<section><div class="shead"><h2>Needs attention</h2>');
   w('<span class="tally">' || n(v_shown) || ' check(s)</span></div>');
   IF v_shown = 0 THEN
      w('<div class="note">Nothing. Every check passed, every protection was on.</div>');
   ELSE
      w('<div class="note"><b>Exposed</b>: original client values where they should have been '
        || 'replaced. <b>Review</b>: values deliberately left unchanged because their role or domain '
        || 'is ambiguous. <b>Switched off</b>: kept by configuration. <b>Warn</b>: worth a look, not '
        || 'part of the verdict.</div>');
      w('<div class="scroll"><table><thead><tr><th>Part</th><th>Check</th><th class="num">Rows</th>'
        || '<th>Status</th><th>Detail</th></tr></thead><tbody>');
      FOR a IN (SELECT part, check_name, bad_rows, status, detail
                  FROM anon_meta.verify_result
                 WHERE status IN ('FAIL', 'REVIEW', 'DISABLED', 'WARN')
                 ORDER BY DECODE(status, 'FAIL', 1, 'REVIEW', 2, 'DISABLED', 3, 4), part, check_name) LOOP
         w('<tr class="is-' || CASE a.status WHEN 'FAIL' THEN 'fail' WHEN 'REVIEW' THEN 'review'
                                             WHEN 'DISABLED' THEN 'off' ELSE 'warn' END || '">'
           || '<td class="tbl-name">' || INITCAP(a.part) || '</td>'
           || '<td class="col-name">' || esc(a.check_name) || '</td>'
           || '<td class="num">' || n(a.bad_rows) || '</td>'
           || '<td>' || status_cell(a.status, a.detail) || '</td>'
           || '<td>' || esc(a.detail) || '</td></tr>');
      END LOOP;
      w('</tbody></table></div>');
   END IF;
   w('</section>');

   ------------------------------------------------------------- identities --
   w('<section><div class="shead"><h2>Identities</h2>');
   w('<span class="tally">' || n(v_identities) || ' captured before the run changed anything</span></div>');
   w('<div class="note">Every party and bank account, classified once from the data. A party the data '
     || 'cannot classify is <b>UNCLASSIFIED_PARTY</b> (X_), with the reason recorded &mdash; the reason '
     || 'is what the data showed, not a business category. A text that is both a party and a bank '
     || 'account keeps one translation for each.</div>');
   w('<table><thead><tr><th>Check</th><th>Status</th><th>Detail</th></tr></thead><tbody>');
   FOR m IN (SELECT check_name, status, bad_rows, detail
               FROM anon_meta.verify_result
              WHERE part = 'IDENTITY'
              ORDER BY DECODE(status, 'FAIL', 1, 'REVIEW', 2, 'PASS', 3, 4), check_name) LOOP
      w('<tr><td>' || esc(INITCAP(SUBSTR(m.check_name, 1, 1)) || SUBSTR(m.check_name, 2)) || '</td>'
        || '<td>' || status_cell(m.status, m.detail) || '</td>'
        || '<td>' || CASE WHEN m.status IN ('FAIL', 'REVIEW') THEN n(m.bad_rows) || ' &mdash; ' END
        || esc(m.detail) || '</td></tr>');
   END LOOP;
   w('</tbody></table></section>');

   ---------------------------------------------------- unclassified parties --
   -- Counts by reason, with the reason in words, and where their X_ values
   -- went by table. From the run's plan and step log - no identifier, and no
   -- check of its own.
   SELECT COUNT(*) INTO v_shown
     FROM anon_meta.identity_plan
    WHERE run_id = v_run_id AND domain = 'PARTY' AND category = 'UNCLASSIFIED_PARTY';
   IF v_shown > 0 THEN
      DECLARE
         v_x_rows NUMBER;
      BEGIN
         SELECT NVL(SUM(x_rows), 0) INTO v_x_rows
           FROM anon_meta.anon_step_log
          WHERE run_id = v_run_id AND phase = 'CODE' AND x_rows > 0;

         w('<section><div class="shead"><h2>Unclassified parties (X_)</h2>');
         w('<span class="tally">' || n(v_shown) || ' parties &middot; ' || n(v_x_rows)
           || ' identifier rows renamed to X_ by this run</span></div>');
         w('<div class="note">Parties whose kind &mdash; entity, portfolio or counterparty &mdash; the '
           || 'data does not establish. They are anonymized like every other party, with an X_ value; '
           || 'the reason says what the data was missing. <b>Tiers</b>, <b>w_tiers node</b>, '
           || '<b>Other screen</b> and <b>Only in references</b> count the parties found there, not '
           || 'rows; one found only in references is a party whose tiers row was deleted.</div>');
         w('<div class="scroll"><table><thead><tr><th>Reason</th><th class="num">Parties</th>'
           || '<th class="num">Tiers</th><th class="num">w_tiers node</th><th class="num">Other screen</th>'
           || '<th class="num">Only in references</th><th>Why they are X_</th></tr></thead><tbody>');
         FOR r IN (SELECT p.x_reason, NVL(MAX(d.label), LOWER(p.x_reason)) AS label, MAX(d.why) AS why,
                          COUNT(*)                                                     AS parties,
                          COUNT(CASE WHEN p.has_master = 'Y' THEN 1 END)              AS in_tiers,
                          COUNT(CASE WHEN p.has_party_node = 'Y' THEN 1 END)          AS party_node,
                          COUNT(CASE WHEN p.has_other_screen_node = 'Y' THEN 1 END)   AS other_screen,
                          COUNT(CASE WHEN p.membership = 'REFERENCE_ONLY' THEN 1 END) AS refs_only
                     FROM anon_meta.identity_plan p
                     LEFT JOIN anon_meta.unclassified_reason d ON d.x_reason = p.x_reason
                    WHERE p.run_id = v_run_id AND p.domain = 'PARTY'
                      AND p.category = 'UNCLASSIFIED_PARTY'
                    GROUP BY p.x_reason
                    ORDER BY MAX(d.sort_order), p.x_reason) LOOP
            w('<tr><td class="col-name">' || esc(INITCAP(SUBSTR(r.label, 1, 1)) || SUBSTR(r.label, 2))
              || '</td><td class="num">' || n(r.parties) || '</td><td class="num">' || n(r.in_tiers)
              || '</td><td class="num">' || n(r.party_node) || '</td><td class="num">' || n(r.other_screen)
              || '</td><td class="num">' || n(r.refs_only) || '</td><td>' || esc(r.why) || '</td></tr>');
         END LOOP;
         w('</tbody></table></div>');

         w('<div class="note">Where their X_ values went: identifier rows renamed by this run, by '
           || 'table.</div>');
         w('<table><thead><tr><th>Table</th><th class="num">Columns</th>'
           || '<th class="num">Rows renamed to X_</th></tr></thead><tbody>');
         IF v_x_rows = 0 THEN
            w('<tr><td colspan="3">None by this run &mdash; already renamed by an earlier run, or '
              || 'renaming of unclassified parties was switched off.</td></tr>');
         END IF;
         -- n_x, not x_rows: an alias with the column's name would shadow it in
         -- ORDER BY.
         FOR t IN (SELECT REGEXP_SUBSTR(object_name, '^[^.]+')                AS table_name,
                          COUNT(DISTINCT REGEXP_SUBSTR(object_name, '^[^ ]+')) AS cols,
                          SUM(x_rows)                                          AS n_x
                     FROM anon_meta.anon_step_log
                    WHERE run_id = v_run_id AND phase = 'CODE' AND x_rows > 0
                    GROUP BY REGEXP_SUBSTR(object_name, '^[^.]+')
                    ORDER BY n_x DESC, table_name) LOOP
            w('<tr><td class="tbl-name">' || esc(t.table_name) || '</td><td class="num">' || n(t.cols)
              || '</td><td class="num">' || n(t.n_x) || '</td></tr>');
         END LOOP;
         w('</tbody></table></section>');
      END;
   END IF;

   -------------------------------------------------------- the switches --
   w('<section><div class="shead"><h2>Switches used</h2>');
   w('<span class="tally">run #' || v_run_id || '</span></div>');
   w('<div class="note">Three independent switches per category. Labels and attributes are masked '
     || 'with the identity&rsquo;s safe replacement, so they can be masked while the identifier is '
     || 'kept. Free text is always erased.</div>');
   w('<table><thead><tr><th>Category</th><th>Rename identifiers</th><th>Mask descriptions</th>'
     || '<th>Mask attributes</th></tr></thead><tbody>');
   FOR s IN (SELECT category, id_on, desc_on, attr_on
               FROM anon_meta.anon_run_setting
              WHERE run_id = v_run_id
              ORDER BY DECODE(category, 'ENTITY', 1, 'PORTFOLIO', 2, 'COUNTERPARTY', 3,
                                        'UNCLASSIFIED_PARTY', 4, 5)) LOOP
      w('<tr><td class="col-name">' || INITCAP(REPLACE(s.category, '_', ' ')) || '</td>'
        || '<td>' || CASE s.id_on   WHEN 'Y' THEN '<span class="st pass">On</span>' ELSE '<span class="st off">Off</span>' END || '</td>'
        || '<td>' || CASE s.desc_on WHEN 'Y' THEN '<span class="st pass">On</span>' ELSE '<span class="st off">Off</span>' END || '</td>'
        || '<td>' || CASE s.attr_on WHEN 'Y' THEN '<span class="st pass">On</span>' ELSE '<span class="st off">Off</span>' END || '</td></tr>');
   END LOOP;
   w('</tbody></table></section>');

   -------------------------------------------------------- by treatment --
   w('<section><div class="shead"><h2>Coverage by treatment</h2>');
   SELECT COUNT(DISTINCT table_name) INTO v_shown FROM anon_meta.anon_inventory;
   w('<span class="tally">' || n(v_items) || ' columns &middot; ' || v_shown || ' tables</span></div>');
   w('<table><thead><tr><th>Rule</th><th>What it does</th><th class="num">Columns</th>'
     || '<th class="num">Clean</th><th class="num">Exposed</th><th class="num">Review</th>'
     || '<th class="num">Off</th><th class="num">Not checked</th></tr></thead><tbody>');
   FOR t IN (SELECT DISTINCT rule FROM anon_meta.anon_inventory
              ORDER BY DECODE(rule, 'CODE', 1, 'NULL_OUT', 2, 'DESCRIPTION', 3, 4)) LOOP
      DECLARE
         v_c NUMBER := 0; v_cl NUMBER := 0; v_ex NUMBER := 0; v_rv NUMBER := 0;
         v_of NUMBER := 0; v_sk NUMBER := 0;
         c t_col;
      BEGIN
         FOR i IN (SELECT table_name, column_name FROM anon_meta.anon_inventory WHERE rule = t.rule) LOOP
            c := col_of(i.table_name, i.column_name);
            v_c := v_c + 1;
            CASE c.status
               WHEN 'PASS'     THEN v_cl := v_cl + 1;
               WHEN 'WARN'     THEN v_cl := v_cl + 1;
               WHEN 'FAIL'     THEN v_ex := v_ex + NVL(c.bad, 0);
               WHEN 'REVIEW'   THEN v_rv := v_rv + NVL(c.bad, 0);
               WHEN 'DISABLED' THEN v_of := v_of + NVL(c.bad, 0);
               ELSE v_sk := v_sk + 1;
            END CASE;
         END LOOP;
         w('<tr><td>' || rule_tag(t.rule) || '</td><td>'
           || CASE t.rule
                 WHEN 'CODE'        THEN 'Identifier replaced by its typed translation'
                 WHEN 'NULL_OUT'    THEN 'Free text emptied, or masked where NOT NULL'
                 WHEN 'DESCRIPTION' THEN 'Label set to its owner&rsquo;s replacement'
                 WHEN 'SELF_CODE'   THEN 'Attribute set to its owner&rsquo;s replacement; empty stays empty'
              END
           || '</td><td class="num">' || n(v_c) || '</td><td class="num">' || n(v_cl)
           || '</td><td class="num' || CASE WHEN v_ex > 0 THEN ' bad' END || '">' || n(v_ex)
           || '</td><td class="num">' || n(v_rv) || '</td><td class="num">' || n(v_of)
           || '</td><td class="num">' || n(v_sk) || '</td></tr>');
      END;
   END LOOP;
   w('</tbody></table></section>');

   ------------------------------------------------------ the two inventories --
   inventory_section('BASE', 'Shipped inventory', 'config/inventory_op.csv',
      '<b>Exposed / held</b> counts the rows behind the status: originals left exposed, values left '
   || 'for review, or values kept because a switch was off. <b>Rows</b> is the whole column, so a large '
   || 'table with nothing exposed is a column fully accounted for. <b>Domain</b> is what the column '
   || 'holds: PARTY, BANK_ACCOUNT, MIXED, or NODE_ROLE for the structure tree.');

   inventory_section('CUSTOM', 'Custom-added inventory', 'config/inventory_op_custom.csv',
      'Columns added or corrected outside the shipped list. A row here <b>overrides</b> the '
   || 'shipped inventory for the same table and column.');

   ------------------------------------------------------------- not present --
   SELECT COUNT(*) INTO v_shown
     FROM anon_meta.anon_inventory i
    WHERE NOT EXISTS (SELECT 1 FROM anon_meta.verify_result r
                       WHERE r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                         AND r.status <> 'SKIP'
                         AND REGEXP_REPLACE(r.check_name, ' \[[^]]*\]$', '')
                             = LOWER(i.table_name) || '.' || LOWER(i.column_name));

   IF v_shown > 0 THEN
      w('<section><div class="shead"><h2>Not checked on this instance</h2>');
      w('<span class="tally">' || n(v_shown) || ' columns</span></div>');
      w('<div class="note">Expected. The inventory covers several KTP/CTI versions, so a column '
        || 'absent here simply does not exist in this one. Each was resolved against the data '
        || 'dictionary before the run started.</div>');
      w('<table><thead><tr><th>Table</th><th class="num">Columns</th><th>Reason</th></tr>'
        || '</thead><tbody>');
      FOR s IN (SELECT i.table_name,
                       COUNT(*) AS cols,
                       MIN(NVL(r.detail, 'not checked')) AS reason
                  FROM anon_meta.anon_inventory i
                  LEFT JOIN anon_meta.verify_result r
                         ON r.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                        AND r.check_name = LOWER(i.table_name) || '.' || LOWER(i.column_name)
                 WHERE NOT EXISTS (SELECT 1 FROM anon_meta.verify_result r2
                                    WHERE r2.part IN ('RESIDUAL', 'FREETEXT', 'LABELS')
                                      AND r2.status <> 'SKIP'
                                      AND REGEXP_REPLACE(r2.check_name, ' \[[^]]*\]$', '')
                                          = LOWER(i.table_name) || '.' || LOWER(i.column_name))
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
              WHERE part = 'MAPPING' AND status <> 'INFO'
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
        || '<td>' || status_cell('INFO', NULL) || '</td><td></td></tr>');
   END LOOP;
   w('</tbody></table></section>');

   ----------------------------------------------------------------- footer --
   w('<footer>Generated by <code>verify/generate_report.sql</code> from '
     || '<code>anon_meta.verify_result</code>. It renders stored results and re-runs no checks, '
     || 'so it can be regenerated at any time.<br>');
   w('Detail is queryable: <code>SELECT * FROM anon_meta.verify_result WHERE status NOT IN '
     || '(&#39;PASS&#39;, &#39;INFO&#39;, &#39;SKIP&#39;);</code></footer>');
   w('</div></body></html>');
END;
/

SPOOL OFF

SET DEFINE ON
PROMPT
PROMPT Report written to &report_file
PROMPT

EXIT SUCCESS
