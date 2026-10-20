-- ============================================================================
-- OP Anonymization - Coverage Verification
-- ============================================================================
-- Proves that the anonymization actually removed what it was supposed to.
--
--   sqlplus op/<password>@<TNS>      @verify/verify_op_coverage.sql
--   sqlplus sys/<password>@<TNS> as sysdba @verify/verify_op_coverage.sql
--
-- Results are also written to anon_meta.verify_result:
--   SELECT * FROM anon_meta.verify_result WHERE status NOT IN ('PASS', 'INFO');
--
-- ----------------------------------------------------------------------------
-- THE VERDICT, AND THE EXIT CODE THAT CARRIES IT
-- ----------------------------------------------------------------------------
--   PASS        0  every protection on, nothing original left, nothing pending
--   FAIL        2  an original value is still where it should have been
--                  replaced, or a replacement of the wrong domain is present
--   REVIEW      3  values were deliberately left unchanged because their role
--                  or domain is ambiguous - a reviewed decision is needed
--   INCOMPLETE  4  no exposure where protection was on, but a protection was
--                  switched off: partial anonymization, never a full PASS
--   (1 means the verifier itself could not run.)
--
-- A zero-residual result is NOT presented as complete coverage when something
-- was left for review or switched off.
--
-- ----------------------------------------------------------------------------
-- WHAT THIS CHECKS, AND WHY IT IS BUILT THIS WAY
-- ----------------------------------------------------------------------------
-- The checks are driven by anon_meta.anon_inventory - the same list the engine
-- worked from - and by the identity PLAN of the last completed run, captured
-- before anything was changed. After a run the original values are gone from
-- the data; only the plan still knows what each identity was, which domain it
-- belongs to and what its one translation is. Checking against the plan is
-- what lets this say "this account node holds a PARTY replacement", not just
-- "no original is left".
--
-- The primary test is RESIDUAL DETECTION, typed: for every identifier column,
-- is any value still present that the plan records as an ORIGINAL - of the
-- column's own domain, or of the other one? And is any replacement of the
-- WRONG domain present? Those questions have definite answers.
--
-- Prefix tests are informational only. In Oracle '_' is a wildcard, so
-- LIKE 'E_%' matched a real code EUR; and many values legitimately carry no
-- prefix. Every prefix test here uses ESCAPE, and none decides PASS or FAIL.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET LINESIZE 200
SET TAB OFF
SET PAGESIZE 0
SET FEEDBACK OFF
SET VERIFY OFF
SET HEADING OFF
SET TRIMSPOOL ON

VARIABLE verdict_rc NUMBER
EXEC :verdict_rc := 1

WHENEVER SQLERROR EXIT FAILURE

DECLARE
   c_pass     CONSTANT VARCHAR2(10) := 'PASS';
   c_fail     CONSTANT VARCHAR2(10) := 'FAIL';
   c_review   CONSTANT VARCHAR2(10) := 'REVIEW';
   c_disabled CONSTANT VARCHAR2(10) := 'DISABLED';
   c_warn     CONSTANT VARCHAR2(10) := 'WARN';
   c_info     CONSTANT VARCHAR2(10) := 'INFO';
   c_skip     CONSTANT VARCHAR2(10) := 'SKIP';

   -- Must match anon_engine.c_mask_text. A NOT NULL free-text column cannot be
   -- set to NULL, so the engine writes this instead - both mean the client
   -- content is gone.
   c_mask CONSTANT VARCHAR2(30) := 'ANONYMIZED';

   v_passed   PLS_INTEGER := 0;
   v_failed   PLS_INTEGER := 0;
   v_review   PLS_INTEGER := 0;
   v_disabled PLS_INTEGER := 0;
   v_warned   PLS_INTEGER := 0;
   v_skipped  PLS_INTEGER := 0;

   v_run      NUMBER;
   v_plan     NUMBER;
   v_mappings NUMBER;
   v_items    NUMBER;
   v_n_check  NUMBER;
   v_n_fail   NUMBER;
   v_verdict  VARCHAR2(12);

   -- -------------------------------------------------------------------------
   PROCEDURE say(p_text IN VARCHAR2 DEFAULT '') IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(p_text);
   END say;


   PROCEDURE heading(p_text IN VARCHAR2) IS
   BEGIN
      say;
      say('====================================================================');
      say(' ' || p_text);
      say('====================================================================');
   END heading;


   FUNCTION object_exists(p_table IN VARCHAR2, p_column IN VARCHAR2) RETURN BOOLEAN IS
      v_n PLS_INTEGER;
   BEGIN
      SELECT COUNT(*) INTO v_n
        FROM all_tab_columns
       WHERE owner = 'OP'
         AND table_name  = UPPER(p_table)
         AND column_name = UPPER(p_column);
      RETURN v_n > 0;
   END object_exists;


   FUNCTION n(p IN NUMBER) RETURN VARCHAR2 IS
   BEGIN
      RETURN TO_CHAR(NVL(p, 0), 'FM999,999,999');
   END n;


   PROCEDURE record(
      p_part        IN VARCHAR2,
      p_check       IN VARCHAR2,
      p_expectation IN VARCHAR2,
      p_total       IN NUMBER,
      p_bad         IN NUMBER,
      p_status      IN VARCHAR2,
      p_detail      IN VARCHAR2 DEFAULT NULL)
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
      INSERT INTO anon_meta.verify_result
         (part, check_name, expectation, total_rows, bad_rows, status, detail)
      VALUES
         (p_part, p_check, p_expectation, p_total, p_bad, p_status, SUBSTR(p_detail, 1, 4000));
      COMMIT;

      CASE p_status
         WHEN c_pass     THEN v_passed   := v_passed + 1;
         WHEN c_fail     THEN v_failed   := v_failed + 1;
         WHEN c_review   THEN v_review   := v_review + 1;
         WHEN c_disabled THEN v_disabled := v_disabled + 1;
         WHEN c_warn     THEN v_warned   := v_warned + 1;
         ELSE NULL;
      END CASE;
   END record;


   -- Only what needs attention is printed. A clean run of 600 checks would
   -- otherwise bury its own result in 600 lines of PASS.
   PROCEDURE show(p_status IN VARCHAR2, p_check IN VARCHAR2, p_bad IN NUMBER, p_of IN NUMBER,
                  p_note IN VARCHAR2) IS
   BEGIN
      say('  ' || RPAD(p_status, 9) || RPAD(SUBSTR(p_check, 1, 46), 48)
               || n(p_bad) || CASE WHEN p_of IS NOT NULL THEN ' of ' || n(p_of) END
               || '  ' || p_note);
   END show;


   -- One check that counts a problem: FAIL when there is any.
   PROCEDURE expect_zero(p_part IN VARCHAR2, p_check IN VARCHAR2, p_sql IN VARCHAR2,
                         p_detail IN VARCHAR2) IS
      v_bad NUMBER;
   BEGIN
      EXECUTE IMMEDIATE p_sql INTO v_bad;
      IF v_bad = 0 THEN
         record(p_part, p_check, '0', NULL, 0, c_pass);
      ELSE
         record(p_part, p_check, '0', NULL, v_bad, c_fail, p_detail);
         show('FAIL', p_check, v_bad, NULL, p_detail);
      END IF;
   END expect_zero;


   -- The status of one column, from what was found in it. A failure outranks a
   -- review, which outranks a protection that was switched off.
   PROCEDURE classify(
      p_part     IN VARCHAR2,
      p_check    IN VARCHAR2,
      p_expect   IN VARCHAR2,
      p_total    IN NUMBER,
      p_fail     IN NUMBER,
      p_fail_why IN VARCHAR2,
      p_review   IN NUMBER,
      p_off      IN NUMBER,
      p_unknown  IN NUMBER DEFAULT 0)
   IS
      v_detail VARCHAR2(4000);
   BEGIN
      v_detail := CASE WHEN p_unknown > 0
                       THEN n(p_unknown) || ' value(s) are no recorded identifier - see PART 2 summary. '
                  END;
      IF p_fail > 0 THEN
         record(p_part, p_check, p_expect, p_total, p_fail, c_fail, p_fail_why || '. ' || v_detail);
         show('FAIL', p_check, p_fail, p_total, p_fail_why);
      ELSIF p_review > 0 THEN
         record(p_part, p_check, p_expect, p_total, p_review, c_review,
                'left unchanged: the role or domain of these values is ambiguous. ' || v_detail);
         show('REVIEW', p_check, p_review, p_total, 'left unchanged - role or domain ambiguous');
      ELSIF p_off > 0 THEN
         record(p_part, p_check, p_expect, p_total, p_off, c_disabled,
                'original values kept because their category''s switch is off. ' || v_detail);
         show('DISABLED', p_check, p_off, p_total, 'kept - switched off');
      ELSE
         record(p_part, p_check, p_expect, p_total, 0, c_pass, v_detail);
      END IF;
   END classify;

BEGIN

   -- =========================================================================
   heading('OP ANONYMIZATION - COVERAGE VERIFICATION');
   -- =========================================================================

   SELECT MAX(run_id) INTO v_run
     FROM anon_meta.anon_run
    WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED';

   SELECT COUNT(*) INTO v_mappings FROM anon_meta.code_map;
   SELECT COUNT(*) INTO v_items    FROM anon_meta.anon_inventory;
   SELECT COUNT(*) INTO v_plan     FROM anon_meta.identity_plan WHERE run_id = v_run;

   say(' Database ......... ' || SYS_CONTEXT('USERENV', 'DB_NAME'));
   say(' Checked at ....... ' || TO_CHAR(SYSTIMESTAMP, 'YYYY-MM-DD HH24:MI:SS'));
   say(' Verified run ..... ' || NVL(TO_CHAR(v_run), 'none'));
   say(' Inventory items .. ' || v_items);
   say(' Identities ....... ' || n(v_plan));
   say(' Mappings ......... ' || n(v_mappings));

   -- Keep only the current verification's results.
   DELETE FROM anon_meta.verify_result;
   COMMIT;

   IF v_run IS NULL OR v_plan = 0 THEN
      say;
      say(' There is no completed anonymization run with an identity plan to');
      say(' verify against. Run the anonymization first.');
      record('SETUP', 'completed run with an identity plan', 'present', 0, 0, c_fail,
             'nothing to verify - no completed EXECUTE run has a plan');
      RAISE_APPLICATION_ERROR(-20030,
         'No completed anonymization run with an identity plan - nothing to verify.');
   END IF;

   -- One row per original and per replacement, saying what it is. Every column
   -- check below is a single join against this.
   DELETE FROM anon_meta.verify_key;
   INSERT INTO anon_meta.verify_key
          (key_code, p_old, p_old_on, a_old, a_old_on, p_new, a_new, stray_new,
           pere_role, pere_on, pere_bad)
   SELECT key_code, MAX(p_old), MAX(p_old_on), MAX(a_old), MAX(a_old_on), MAX(p_new), MAX(a_new),
          MAX(stray_new), MAX(pere_role), MAX(pere_on), MAX(pere_bad)
     FROM (SELECT p.old_code AS key_code,
                  CASE WHEN p.domain = 'PARTY'   THEN 'Y' END AS p_old,
                  CASE WHEN p.domain = 'PARTY'   THEN p.id_on END AS p_old_on,
                  CASE WHEN p.domain = 'ACCOUNT' THEN 'Y' END AS a_old,
                  CASE WHEN p.domain = 'ACCOUNT' THEN p.id_on END AS a_old_on,
                  NULL AS p_new, NULL AS a_new, NULL AS stray_new,
                  p.parent_role AS pere_role,
                  CASE WHEN p.parent_role = p.domain THEN p.id_on END AS pere_on,
                  NULL AS pere_bad
             FROM anon_meta.identity_plan p
            WHERE p.run_id = v_run
           UNION ALL
           SELECT p.new_code, NULL, NULL, NULL, NULL,
                  CASE WHEN p.domain = 'PARTY'   THEN 'Y' END,
                  CASE WHEN p.domain = 'ACCOUNT' THEN 'Y' END,
                  NULL, NULL, NULL,
                  CASE WHEN NVL(p.parent_role, p.domain) <> p.domain THEN 'Y' END
             FROM anon_meta.identity_plan p
            WHERE p.run_id = v_run AND p.new_code IS NOT NULL
           UNION ALL
           SELECT c.new_code, NULL, NULL, NULL, NULL, NULL, NULL, 'Y', NULL, NULL, NULL
             FROM anon_meta.code_map c
            WHERE NOT EXISTS (SELECT 1 FROM anon_meta.identity_plan p
                               WHERE p.run_id = v_run AND p.new_code = c.new_code))
    GROUP BY key_code;
   COMMIT;


   -- =========================================================================
   heading('PART 1 - IDENTITIES   (captured before the run changed anything)');
   -- =========================================================================
   say(' Every identity has exactly one translation of its own domain, and the');
   say(' masters and nodes that hold it carry that translation.');
   say;

   DECLARE
      v_line VARCHAR2(4000);
      v_n    NUMBER;
   BEGIN
      expect_zero('IDENTITY', 'each identity needing a translation has one',
         'SELECT COUNT(*) FROM anon_meta.identity_plan WHERE run_id = ' || v_run
      || ' AND (id_on = ''Y'' OR desc_on = ''Y'' OR attr_on = ''Y'') AND new_code IS NULL',
         'identities with a switch on but no translation');

      expect_zero('IDENTITY', 'translations are of the identity''s own domain',
         'SELECT COUNT(*) FROM anon_meta.identity_plan WHERE run_id = ' || v_run
      || ' AND new_code IS NOT NULL AND ((domain = ''ACCOUNT'' AND map_category <> ''BANK_ACCOUNT'')'
      || ' OR (domain = ''PARTY'' AND map_category NOT IN (''ENTITY'', ''PORTFOLIO'', '
      || '''COUNTERPARTY'', ''UNCLASSIFIED_PARTY'')))',
         'a party translated as an account, or an account as a party');

      expect_zero('IDENTITY', 'each party has one translation',
         'SELECT COUNT(*) FROM (SELECT old_code FROM anon_meta.identity_plan WHERE run_id = ' || v_run
      || ' AND domain = ''PARTY'' AND new_code IS NOT NULL GROUP BY old_code HAVING COUNT(*) > 1)',
         'one party with two translations');

      expect_zero('IDENTITY', 'every unclassified party has its reason',
         'SELECT COUNT(*) FROM anon_meta.identity_plan WHERE run_id = ' || v_run
      || ' AND category = ''UNCLASSIFIED_PARTY'' AND x_reason IS NULL',
         'X_ parties without a recorded reason');

      -- Masters and nodes. Every account node that has a master shares its
      -- replacement - also when a party has the same text.
      expect_zero('IDENTITY', 'account masters carry their translation',
         'SELECT COUNT(*) FROM anon_meta.identity_plan p WHERE p.run_id = ' || v_run
      || ' AND p.domain = ''ACCOUNT'' AND p.id_on = ''Y'' AND p.has_master = ''Y'''
      || ' AND NOT EXISTS (SELECT 1 FROM op.compte_banque b WHERE b.code = p.new_code)',
         'compte_banque rows without their CB_ replacement');

      expect_zero('IDENTITY', 'account nodes carry their master''s translation',
         'SELECT COUNT(*) FROM anon_meta.identity_plan p WHERE p.run_id = ' || v_run
      || ' AND p.domain = ''ACCOUNT'' AND p.id_on = ''Y'' AND p.has_account_node = ''Y'''
      || ' AND NOT EXISTS (SELECT 1 FROM op.structure s WHERE s.code = p.new_code'
      || ' AND s.ecran = ''w_compte_banque'')',
         'w_compte_banque nodes without the CB_ replacement of their account');

      expect_zero('IDENTITY', 'party masters carry their translation',
         'SELECT COUNT(*) FROM anon_meta.identity_plan p WHERE p.run_id = ' || v_run
      || ' AND p.domain = ''PARTY'' AND p.id_on = ''Y'' AND p.has_master = ''Y'''
      || ' AND NOT EXISTS (SELECT 1 FROM op.tiers t WHERE t.code = p.new_code)',
         'tiers rows without their party replacement');

      expect_zero('IDENTITY', 'party nodes carry their party''s translation',
         'SELECT COUNT(*) FROM anon_meta.identity_plan p WHERE p.run_id = ' || v_run
      || ' AND p.domain = ''PARTY'' AND p.id_on = ''Y'' AND p.has_party_node = ''Y'''
      || ' AND NOT EXISTS (SELECT 1 FROM op.structure s WHERE s.code = p.new_code'
      || ' AND s.ecran = ''w_tiers'')',
         'w_tiers nodes without their party''s replacement');

      -- Drift: kept, never silently re-categorised - but someone has to look.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = v_run
         AND (   (identity_status = 'KNOWN' AND class_now IS NOT NULL AND class_now <> category)
              OR (map_category IS NOT NULL AND map_category <> category));
      IF v_n > 0 THEN
         record('IDENTITY', 'classification unchanged since capture', '0', v_plan, v_n, c_review,
                'identities the data would classify differently today; their recorded '
             || 'translation was kept. Confirm or plan a consistent migration.');
         show('REVIEW', 'classification unchanged since capture', v_n, NULL,
              'recorded translation kept');
      ELSE
         record('IDENTITY', 'classification unchanged since capture', '0', v_plan, 0, c_pass);
      END IF;

      -- The shape of the identity inventory - counts only.
      SELECT LISTAGG(category || '=' || cnt, '  ') WITHIN GROUP (ORDER BY category)
        INTO v_line
        FROM (SELECT category, COUNT(*) AS cnt FROM anon_meta.identity_plan
               WHERE run_id = v_run GROUP BY category);
      record('IDENTITY', 'identities by category', 'informational', v_plan, NULL, c_info, v_line);
      say('  INFO     ' || v_line);

      SELECT LISTAGG(domain || ' ' || membership || '=' || cnt, '  ')
                WITHIN GROUP (ORDER BY domain, membership)
        INTO v_line
        FROM (SELECT domain, membership, COUNT(*) AS cnt FROM anon_meta.identity_plan
               WHERE run_id = v_run GROUP BY domain, membership);
      record('IDENTITY', 'identities by source', 'informational', v_plan, NULL, c_info, v_line);
      say('  INFO     ' || v_line);

      SELECT LISTAGG(x_reason || '=' || cnt, '  ') WITHIN GROUP (ORDER BY x_reason)
        INTO v_line
        FROM (SELECT x_reason, COUNT(*) AS cnt FROM anon_meta.identity_plan
               WHERE run_id = v_run AND category = 'UNCLASSIFIED_PARTY' GROUP BY x_reason);
      IF v_line IS NOT NULL THEN
         record('IDENTITY', 'unclassified parties (X_) by reason', 'informational', NULL, NULL,
                c_info, v_line);
         say('  INFO     X_ ' || v_line);
      END IF;

      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan WHERE run_id = v_run AND entity_overlap = 'Y';
      IF v_n > 0 THEN
         record('IDENTITY', 'entity precedence applied', 'informational', NULL, v_n, c_info,
                'flag N parties with both Entite and other w_tiers nodes - one ENTITY translation');
         say('  INFO     entity precedence applied to ' || n(v_n) || ' part(ies)');
      END IF;

      SELECT COUNT(*) INTO v_n
        FROM (SELECT old_code FROM anon_meta.identity_plan WHERE run_id = v_run
               GROUP BY old_code HAVING COUNT(DISTINCT domain) = 2);
      record('IDENTITY', 'same text, party and account', 'informational', NULL, v_n, c_info,
             'each keeps its own translation');
      IF v_n > 0 THEN
         say('  INFO     ' || n(v_n) || ' text(s) are both a party and a bank account - '
             || 'each keeps its own translation');
      END IF;
   END;

   SELECT COUNT(*), COUNT(CASE WHEN status = c_fail THEN 1 END)
     INTO v_n_check, v_n_fail
     FROM anon_meta.verify_result WHERE part = 'IDENTITY' AND status <> c_info;
   say;
   say('  checked ' || v_n_check || ', failed ' || v_n_fail);


   -- =========================================================================
   heading('PART 2 - RESIDUAL IDENTIFIERS   (the primary test)');
   -- =========================================================================
   say(' For every identifier column: is an ORIGINAL value of its domain still');
   say(' there, an original of the OTHER domain, or a replacement of the wrong');
   say(' domain? Only what needs attention is listed.');
   say;

   DECLARE
      v_obj      VARCHAR2(300);
      v_total    NUMBER;
      v_on       NUMBER;
      v_off      NUMBER;
      v_other    NUMBER;
      v_wrong    NUMBER;
      v_stray    NUMBER;
      v_ambig    NUMBER;
      v_unknown  NUMBER;
      v_unk_cols NUMBER := 0;
      v_unk_rows NUMBER := 0;

      -- One pass over one column, every question answered at once.
      PROCEDURE scan(p_table IN VARCHAR2, p_column IN VARCHAR2, p_domain IN VARCHAR2,
                     p_filter IN VARCHAR2) IS
         v_own_on  VARCHAR2(400);
         v_own_off VARCHAR2(400);
         v_oth     VARCHAR2(400);
         v_wr      VARCHAR2(400);
         v_amb     VARCHAR2(400);
      BEGIN
         IF p_domain = 'PARTY' THEN
            v_own_on  := 'k.p_old_on = ''Y''';
            v_own_off := 'k.p_old = ''Y'' AND k.p_old_on = ''N''';
            v_oth     := 'k.a_old = ''Y'' AND k.p_old IS NULL';
            v_wr      := 'k.a_new = ''Y''';
            v_amb     := '1 = 0';
         ELSIF p_domain = 'ACCOUNT' THEN
            v_own_on  := 'k.a_old_on = ''Y''';
            v_own_off := 'k.a_old = ''Y'' AND k.a_old_on = ''N''';
            v_oth     := 'k.p_old = ''Y'' AND k.a_old IS NULL';
            v_wr      := 'k.p_new = ''Y''';
            v_amb     := '1 = 0';
         ELSIF p_domain = 'MIXED' THEN
            v_own_on  := '(k.p_old_on = ''Y'' AND k.a_old IS NULL) OR (k.a_old_on = ''Y'' AND k.p_old IS NULL)';
            v_own_off := '(k.p_old_on = ''N'' AND k.a_old IS NULL) OR (k.a_old_on = ''N'' AND k.p_old IS NULL)';
            v_oth     := '1 = 0';
            v_wr      := '1 = 0';
            v_amb     := 'k.p_old = ''Y'' AND k.a_old = ''Y''';
         ELSIF p_domain = 'OTHER_NODE' THEN
            -- A node on another screen is never renamed: an identifier there is
            -- left for review. A replacement there is not this run's doing.
            v_own_on  := '1 = 0';
            v_own_off := '1 = 0';
            v_oth     := '1 = 0';
            v_wr      := 'k.p_new = ''Y'' OR k.a_new = ''Y''';
            v_amb     := 'k.p_old = ''Y'' OR k.a_old = ''Y''';
         ELSIF p_domain = 'PERE' THEN
            -- The parent's typed translation, decided before the run.
            v_own_on  := 'k.pere_role IN (''PARTY'', ''ACCOUNT'') AND k.pere_on = ''Y''';
            v_own_off := 'k.pere_role IN (''PARTY'', ''ACCOUNT'') AND NVL(k.pere_on, ''N'') = ''N''';
            v_oth     := '1 = 0';
            v_wr      := 'k.pere_bad = ''Y''';
            v_amb     := 'k.pere_role IN (''AMBIGUOUS'', ''OTHER'')';
         END IF;

         EXECUTE IMMEDIATE
            'SELECT COUNT(*),'
         || ' COUNT(CASE WHEN ' || v_own_on  || ' THEN 1 END),'
         || ' COUNT(CASE WHEN ' || v_own_off || ' THEN 1 END),'
         || ' COUNT(CASE WHEN ' || v_oth     || ' THEN 1 END),'
         || ' COUNT(CASE WHEN ' || v_wr      || ' THEN 1 END),'
         || ' COUNT(CASE WHEN k.stray_new = ''Y'' THEN 1 END),'
         || ' COUNT(CASE WHEN ' || v_amb     || ' THEN 1 END),'
         || ' COUNT(CASE WHEN t.' || p_column || ' IS NOT NULL AND k.key_code IS NULL THEN 1 END)'
         || '  FROM op.' || p_table || ' t'
         || '  LEFT JOIN anon_meta.verify_key k ON k.key_code = t.' || p_column
         || CASE WHEN p_filter IS NOT NULL THEN ' WHERE ' || p_filter END
            INTO v_total, v_on, v_off, v_other, v_wrong, v_stray, v_ambig, v_unknown;
      END scan;

      PROCEDURE judge(p_check IN VARCHAR2, p_domain IN VARCHAR2, p_track_unknown IN BOOLEAN) IS
         v_why VARCHAR2(400);
      BEGIN
         v_why := CASE
                     WHEN v_on > 0 THEN n(v_on) || ' original(s) of this column''s domain remain'
                     WHEN v_other > 0 THEN n(v_other) || ' original(s) of the OTHER domain remain - '
                          || 'the column may hold both; review its category'
                     WHEN v_wrong > 0 THEN n(v_wrong) || ' replacement(s) of the wrong domain are present'
                     WHEN v_stray > 0 THEN n(v_stray) || ' replacement(s) that are no identity''s own'
                  END;
         classify('RESIDUAL', p_check, 'no original value remains', v_total,
                  v_on + v_other + v_wrong + v_stray, v_why, v_ambig, v_off,
                  CASE WHEN p_track_unknown THEN v_unknown ELSE 0 END);
         IF p_track_unknown AND v_unknown > 0 THEN
            v_unk_cols := v_unk_cols + 1;
            v_unk_rows := v_unk_rows + v_unknown;
         END IF;
      END judge;
   BEGIN
      FOR r IN (SELECT table_name, column_name, category
                  FROM anon_meta.anon_inventory
                 WHERE rule = 'CODE'
                 ORDER BY seq) LOOP

         v_obj := LOWER(r.table_name) || '.' || LOWER(r.column_name);

         IF NOT object_exists(r.table_name, r.column_name) THEN
            v_skipped := v_skipped + 1;
            record('RESIDUAL', v_obj, 'no original value remains', NULL, NULL, c_skip,
                   'not present on this instance');
            CONTINUE;
         END IF;

         IF r.category = 'NODE_ROLE' AND r.column_name = 'CODE' THEN
            -- A node's role is its screen alone.
            scan(r.table_name, r.column_name, 'ACCOUNT', 't.ecran = ''w_compte_banque''');
            judge(v_obj || ' [account nodes]', 'ACCOUNT', FALSE);
            scan(r.table_name, r.column_name, 'PARTY', 't.ecran = ''w_tiers''');
            judge(v_obj || ' [party nodes]', 'PARTY', FALSE);
            scan(r.table_name, r.column_name, 'OTHER_NODE',
                 'NVL(t.ecran, ''~'') NOT IN (''w_compte_banque'', ''w_tiers'')');
            judge(v_obj || ' [other screens]', 'OTHER_NODE', FALSE);
         ELSIF r.category = 'NODE_ROLE' AND r.column_name = 'PERE' THEN
            scan(r.table_name, r.column_name, 'PERE', NULL);
            judge(v_obj, 'PERE', FALSE);
         ELSE
            scan(r.table_name, r.column_name,
                 CASE r.category WHEN 'BANK_ACCOUNT' THEN 'ACCOUNT' WHEN 'MIXED' THEN 'MIXED'
                                 ELSE 'PARTY' END, NULL);
            judge(v_obj, r.category, TRUE);
         END IF;
      END LOOP;

      -- Values in identifier columns that are no recorded original and no
      -- replacement. Many are legitimate - a currency, a product, a system code.
      -- A dangling reference to a party that no longer exists is client data,
      -- though, and is in scope only once confirmed (anon_meta.confirmed_identity).
      IF v_unk_rows > 0 THEN
         record('RESIDUAL', 'values that are no recorded identifier', 'review if client data',
                NULL, v_unk_rows, c_warn,
                n(v_unk_rows) || ' value(s) in ' || v_unk_cols || ' column(s). Not proof of a leak; '
             || 'a sensitive one belongs in anon_meta.confirmed_identity.');
         say('  WARN     ' || n(v_unk_rows) || ' value(s) in ' || v_unk_cols
             || ' column(s) are no recorded identifier - review if client data');
      END IF;
   END;

   SELECT COUNT(*), COUNT(CASE WHEN status = c_fail THEN 1 END)
     INTO v_n_check, v_n_fail
     FROM anon_meta.verify_result WHERE part = 'RESIDUAL' AND status <> c_warn;
   say;
   say('  checked ' || v_n_check || ', failed ' || v_n_fail);


   -- =========================================================================
   heading('PART 3 - FREE TEXT AND PII');
   -- =========================================================================
   say(' Columns that should be entirely empty. Any surviving value is a leak.');
   say;

   DECLARE
      v_bad      NUMBER;
      v_total    NUMBER;
      v_obj      VARCHAR2(300);
      v_nullable VARCHAR2(1);
      v_type     VARCHAR2(30);
   BEGIN
      FOR r IN (SELECT table_name, column_name
                  FROM anon_meta.anon_inventory
                 WHERE rule = 'NULL_OUT'
                 ORDER BY seq) LOOP

         v_obj := LOWER(r.table_name) || '.' || LOWER(r.column_name);

         IF NOT object_exists(r.table_name, r.column_name) THEN
            v_skipped := v_skipped + 1;
            record('FREETEXT', v_obj, 'all NULL', NULL, NULL, c_skip,
                   'not present on this instance');
            CONTINUE;
         END IF;

         SELECT MAX(nullable), MAX(data_type) INTO v_nullable, v_type
           FROM all_tab_columns
          WHERE owner = 'OP' AND table_name = r.table_name AND column_name = r.column_name;

         -- A NOT NULL column cannot be emptied, so the engine overwrites it with
         -- a fixed marker instead. Both outcomes mean the client content is
         -- gone, so both count as clean.
         --
         -- This shares a DEFINITION with the engine - what an anonymized value
         -- looks like - which is legitimate, in the same way the check knows the
         -- generated prefixes. It is not sharing an ASSUMPTION about where to
         -- look; that is the mistake that let param_cpta_reg_gen.compte_ana pass
         -- with live data in it.
         IF v_type IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
            EXECUTE IMMEDIATE
               'SELECT COUNT(*), COUNT(CASE WHEN ' || r.column_name || ' IS NOT NULL'
            || '                             AND ' || r.column_name || ' <> ''' || c_mask || ''''
            || '                             AND ' || r.column_name || ' <> SUBSTR(''' || c_mask
            || '''                                 , 1, LENGTH(' || r.column_name || '))'
            || '                            THEN 1 END)'
            || '  FROM op.' || r.table_name
               INTO v_total, v_bad;
         ELSE
            EXECUTE IMMEDIATE
               'SELECT COUNT(*), COUNT(' || r.column_name || ') FROM op.' || r.table_name
               INTO v_total, v_bad;
         END IF;

         IF v_bad = 0 THEN
            record('FREETEXT', v_obj, 'empty or masked', v_total, 0, c_pass);
         ELSE
            -- Including a NOT NULL non-character column: it has no valid
            -- masking value, preflight refuses to start on one, and it is never
            -- reported as clean.
            record('FREETEXT', v_obj, 'empty or masked', v_total, v_bad, c_fail,
                   CASE WHEN v_nullable = 'N' AND v_type NOT IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR')
                        THEN 'NOT NULL ' || v_type || ' - it can be neither emptied nor masked; '
                          || 'the content is still present'
                        ELSE 'free text or PII survived' END);
            show('FAIL', v_obj, v_bad, v_total, 'values still present');
         END IF;
      END LOOP;
   END;

   SELECT COUNT(*), COUNT(CASE WHEN status = c_fail THEN 1 END)
     INTO v_n_check, v_n_fail
     FROM anon_meta.verify_result WHERE part = 'FREETEXT';
   say;
   say('  checked ' || v_n_check || ', failed ' || v_n_fail);


   -- =========================================================================
   heading('PART 4 - LABELS AND ATTRIBUTES');
   -- =========================================================================
   say(' Each label or attribute must hold its owner''s safe replacement - never');
   say(' its original code - whether or not the identifier was renamed. An');
   say(' empty attribute must still be empty.');
   say;

   DECLARE
      v_obj     VARCHAR2(300);
      v_total   NUMBER;
      v_bad     NUMBER;
      v_off     NUMBER;
      v_switch  VARCHAR2(10);
      v_bad_sql VARCHAR2(400);
      v_off_sql VARCHAR2(400);
      v_keys    VARCHAR2(1000);

      PROCEDURE check_owned(p_table IN VARCHAR2, p_column IN VARCHAR2, p_rule IN VARCHAR2,
                            p_domain IN VARCHAR2, p_category IN VARCHAR2, p_filter IN VARCHAR2,
                            p_check IN VARCHAR2) IS
      BEGIN
         v_switch := CASE p_rule WHEN 'SELF_CODE' THEN 'attr_on' ELSE 'desc_on' END;
         IF p_rule = 'SELF_CODE' THEN
            v_bad_sql := 't.' || p_column || ' IS NOT NULL AND t.' || p_column || ' <> k.new_code';
         ELSE
            v_bad_sql := 't.' || p_column || ' IS NULL OR t.' || p_column || ' <> k.new_code';
         END IF;
         v_off_sql := 't.' || p_column || ' IS NOT NULL AND (k.new_code IS NULL OR t.'
                   || p_column || ' <> k.new_code)';

         -- The owner is found by its original OR its replacement, so a row is
         -- checked whether or not its identifier was renamed.
         v_keys := '(SELECT domain, old_code AS key_code, new_code, category, desc_on, attr_on'
                || '   FROM anon_meta.identity_plan WHERE run_id = ' || v_run
                || ' UNION ALL'
                || ' SELECT domain, new_code, new_code, category, desc_on, attr_on'
                || '   FROM anon_meta.identity_plan WHERE run_id = ' || v_run
                || '    AND new_code IS NOT NULL)';

         EXECUTE IMMEDIATE
            'SELECT COUNT(*),'
         || ' COUNT(CASE WHEN k.' || v_switch || ' = ''Y'' AND (' || v_bad_sql || ') THEN 1 END),'
         || ' COUNT(CASE WHEN k.' || v_switch || ' = ''N'' AND (' || v_off_sql || ') THEN 1 END)'
         || '  FROM op.' || p_table || ' t'
         || '  JOIN ' || v_keys || ' k ON k.domain = ''' || p_domain || ''' AND k.key_code = t.code'
         || CASE WHEN p_category IS NOT NULL THEN ' AND k.category = ''' || p_category || '''' END
         || CASE WHEN p_filter IS NOT NULL THEN ' WHERE ' || p_filter END
            INTO v_total, v_bad, v_off;

         classify('LABELS', p_check, 'holds its owner''s replacement', v_total, v_bad,
                  n(v_bad) || ' row(s) hold something other than their owner''s replacement',
                  0, v_off);
      END check_owned;
   BEGIN
      FOR r IN (SELECT table_name, column_name, category, rule
                  FROM anon_meta.anon_inventory
                 WHERE rule IN ('DESCRIPTION', 'SELF_CODE')
                 ORDER BY seq) LOOP

         v_obj := LOWER(r.table_name) || '.' || LOWER(r.column_name);

         IF NOT object_exists(r.table_name, r.column_name)
            OR NOT object_exists(r.table_name, 'code') THEN
            v_skipped := v_skipped + 1;
            record('LABELS', v_obj, 'holds its owner''s replacement', NULL, NULL, c_skip,
                   'not present on this instance');
            CONTINUE;
         END IF;

         IF r.category = 'NODE_ROLE' THEN
            check_owned(r.table_name, r.column_name, r.rule, 'ACCOUNT', NULL,
                        't.ecran = ''w_compte_banque''', v_obj || ' [account nodes]');
            check_owned(r.table_name, r.column_name, r.rule, 'PARTY', NULL,
                        't.ecran = ''w_tiers''', v_obj || ' [party nodes]');
         ELSIF r.category = 'BANK_ACCOUNT' THEN
            check_owned(r.table_name, r.column_name, r.rule, 'ACCOUNT', NULL, NULL, v_obj);
         ELSIF r.category = 'PARTY' THEN
            check_owned(r.table_name, r.column_name, r.rule, 'PARTY', NULL, NULL, v_obj);
         ELSE
            check_owned(r.table_name, r.column_name, r.rule, 'PARTY', r.category, NULL, v_obj);
         END IF;
      END LOOP;

      -- SELF_CODE never fills an empty field: no column may have fewer NULLs
      -- than it had before the run masked it.
      FOR b IN (SELECT table_name, column_name, null_rows
                  FROM anon_meta.field_baseline
                 WHERE run_id = v_run
                 ORDER BY table_name, column_name) LOOP
         CONTINUE WHEN NOT object_exists(b.table_name, b.column_name);
         EXECUTE IMMEDIATE 'SELECT COUNT(*) - COUNT(' || b.column_name || ') FROM op.' || b.table_name
            INTO v_total;
         v_obj := LOWER(b.table_name) || '.' || LOWER(b.column_name) || ' [empty fields kept]';
         IF v_total < b.null_rows THEN
            record('LABELS', v_obj, 'no empty field filled in', b.null_rows, b.null_rows - v_total,
                   c_fail, 'empty fields were filled in by the run');
            show('FAIL', v_obj, b.null_rows - v_total, b.null_rows, 'empty fields filled in');
         ELSE
            record('LABELS', v_obj, 'no empty field filled in', b.null_rows, 0, c_pass);
         END IF;
      END LOOP;
   END;

   SELECT COUNT(*), COUNT(CASE WHEN status = c_fail THEN 1 END)
     INTO v_n_check, v_n_fail
     FROM anon_meta.verify_result WHERE part = 'LABELS';
   say;
   say('  checked ' || v_n_check || ', failed ' || v_n_fail);


   -- =========================================================================
   heading('PART 5 - MAPPING INTEGRITY');
   -- =========================================================================

   DECLARE
      v_by_cat VARCHAR2(400);
   BEGIN
      -- Two originals sharing one replacement would merge two real identities
      -- into one. A unique index makes this impossible, but verifying it costs
      -- nothing and the consequence of being wrong is severe.
      expect_zero('MAPPING', 'replacement identifiers are unique',
         'SELECT COUNT(*) FROM (SELECT new_code FROM anon_meta.code_map '
      || 'GROUP BY new_code HAVING COUNT(*) > 1)',
         'distinct originals share a replacement - identities merged');

      -- A replacement equal to an original would make the two
      -- indistinguishable - in the data and in every check here.
      expect_zero('MAPPING', 'no replacement equals an original',
         'SELECT COUNT(*) FROM anon_meta.code_map c WHERE EXISTS (SELECT 1 FROM '
      || 'anon_meta.identity_plan p WHERE p.run_id = ' || v_run || ' AND p.old_code = c.new_code)',
         'a replacement is also an original identifier');

      -- The recorded category decides the domain; the prefix is only how a
      -- replacement looks. Both must agree for every translation in use.
      expect_zero('MAPPING', 'translations have their category''s format',
         'SELECT COUNT(*) FROM anon_meta.identity_plan p WHERE p.run_id = ' || v_run
      || ' AND p.new_code IS NOT NULL AND NOT REGEXP_LIKE(p.new_code, ''^'' || '
      || 'CASE p.map_category WHEN ''ENTITY'' THEN ''E_'' WHEN ''PORTFOLIO'' THEN ''P_'' '
      || 'WHEN ''COUNTERPARTY'' THEN ''T_'' WHEN ''UNCLASSIFIED_PARTY'' THEN ''X_'' '
      || 'WHEN ''BANK_ACCOUNT'' THEN ''CB_'' END || ''[0-9]{7}$'')',
         'a translation whose value does not match its recorded category');

      expect_zero('MAPPING', 'every mapping has a known category',
         'SELECT COUNT(*) FROM anon_meta.code_map WHERE category NOT IN (''ENTITY'', '
      || '''PORTFOLIO'', ''COUNTERPARTY'', ''UNCLASSIFIED_PARTY'', ''BANK_ACCOUNT'')',
         'code_map rows of an unknown category');

      -- EPF looks values up one row per (table_name, old_value). Two would
      -- stop it with ORA-01427.
      expect_zero('MAPPING', 'EPF view has one row per identity',
         'SELECT COUNT(*) FROM (SELECT table_name, old_value FROM atrace.ref_tables_modif '
      || 'GROUP BY table_name, old_value HAVING COUNT(*) > 1)',
         'atrace.ref_tables_modif would give EPF two translations for one identity');

      SELECT LISTAGG(category || '=' || TO_CHAR(cnt), '  ') WITHIN GROUP (ORDER BY category)
        INTO v_by_cat
        FROM (SELECT category, COUNT(*) AS cnt FROM anon_meta.code_map GROUP BY category);
      record('MAPPING', 'mappings by category', 'informational', v_mappings, NULL, c_info, v_by_cat);
      say('  INFO     ' || v_by_cat);
   END;


   -- =========================================================================
   heading('PART 6 - PROTECTIONS SWITCHED OFF');
   -- =========================================================================
   say(' A protection that was switched off is reported with what it left in');
   say(' place. It is never a failure, and never a full pass.');
   say;

   DECLARE
      v_cnt NUMBER;
   BEGIN
      FOR s IN (SELECT category, id_on, desc_on, attr_on
                  FROM anon_meta.anon_run_setting
                 WHERE run_id = v_run
                 ORDER BY DECODE(category, 'ENTITY', 1, 'PORTFOLIO', 2, 'COUNTERPARTY', 3,
                                           'UNCLASSIFIED_PARTY', 4, 5)) LOOP
         SELECT COUNT(*) INTO v_cnt
           FROM anon_meta.identity_plan WHERE run_id = v_run AND category = s.category;

         IF s.id_on = 'N' AND v_cnt > 0 THEN
            record('SETTINGS', LOWER(s.category) || ': rename identifiers', 'on', v_cnt, v_cnt,
                   c_disabled, n(v_cnt) || ' identit(ies) keep their original code in every column');
            show('DISABLED', LOWER(s.category) || ': rename identifiers', v_cnt, NULL,
                 'originals kept');
         END IF;
         IF s.desc_on = 'N' AND v_cnt > 0 THEN
            record('SETTINGS', LOWER(s.category) || ': mask descriptions', 'on', v_cnt, v_cnt,
                   c_disabled, n(v_cnt) || ' identit(ies) keep their original labels');
            show('DISABLED', LOWER(s.category) || ': mask descriptions', v_cnt, NULL,
                 'labels kept');
         END IF;
         IF s.attr_on = 'N' AND v_cnt > 0 THEN
            record('SETTINGS', LOWER(s.category) || ': mask attributes', 'on', v_cnt, v_cnt,
                   c_disabled, n(v_cnt) || ' identit(ies) keep their attributes and addresses');
            show('DISABLED', LOWER(s.category) || ': mask attributes', v_cnt, NULL,
                 'attributes kept');
         END IF;
      END LOOP;

      SELECT COUNT(*) INTO v_cnt FROM anon_meta.verify_result WHERE part = 'SETTINGS';
      IF v_cnt = 0 THEN
         record('SETTINGS', 'every protection switched on', 'on', NULL, 0, c_pass);
         say('  every protection was switched on');
      END IF;
   END;


   -- =========================================================================
   heading('PART 7 - PREFIX CONFORMANCE   (informational)');
   -- =========================================================================
   say(' How much of each master identifier column carries a generated prefix.');
   say(' NOT a pass/fail test - PART 2 is the test that matters.');
   say;

   DECLARE
      v_total  NUMBER;
      v_pref   NUMBER;
      v_obj    VARCHAR2(300);
      v_pct    NUMBER;
      v_shown  PLS_INTEGER := 0;
   BEGIN
      FOR r IN (SELECT table_name, column_name
                  FROM anon_meta.anon_inventory
                 WHERE rule = 'CODE'
                   AND table_name IN ('TIERS', 'STRUCTURE', 'COMPTE_BANQUE')
                 ORDER BY seq) LOOP

         v_obj := LOWER(r.table_name) || '.' || LOWER(r.column_name);
         CONTINUE WHEN NOT object_exists(r.table_name, r.column_name);

         -- ESCAPE is what makes this correct. Without it '_' is a wildcard and
         -- 'E_%' matches EUR, EONIA, everything starting with E.
         EXECUTE IMMEDIATE
            'SELECT COUNT(*), COUNT(CASE WHEN ' || r.column_name || ' LIKE ''E\_%'' ESCAPE ''\'''
         || '                          OR ' || r.column_name || ' LIKE ''P\_%'' ESCAPE ''\'''
         || '                          OR ' || r.column_name || ' LIKE ''T\_%'' ESCAPE ''\'''
         || '                          OR ' || r.column_name || ' LIKE ''X\_%'' ESCAPE ''\'''
         || '                          OR ' || r.column_name || ' LIKE ''CB\_%'' ESCAPE ''\'''
         || '                         THEN 1 END)'
         || '  FROM op.' || r.table_name || ' WHERE ' || r.column_name || ' IS NOT NULL'
            INTO v_total, v_pref;

         v_pct := CASE WHEN v_total = 0 THEN NULL
                       ELSE ROUND(v_pref * 100 / v_total) END;

         record('PREFIX', v_obj, 'informational', v_total, v_total - v_pref, c_info,
                NVL(TO_CHAR(v_pct), 'n/a') || '% carry a generated prefix');

         say('  ' || RPAD(SUBSTR(v_obj, 1, 40), 42)
                  || LPAD(NVL(TO_CHAR(v_pct), 'n/a'), 5) || '%   '
                  || n(v_pref) || ' of ' || n(v_total));
         v_shown := v_shown + 1;
      END LOOP;

      IF v_shown = 0 THEN
         say('  (core tables not present on this instance)');
      END IF;
   END;


   -- =========================================================================
   heading('SUMMARY');
   -- =========================================================================

   v_verdict := CASE WHEN v_failed   > 0 THEN 'FAIL'
                     WHEN v_review   > 0 THEN 'REVIEW'
                     WHEN v_disabled > 0 THEN 'INCOMPLETE'
                     ELSE 'PASS' END;

   say(' passed ..... ' || v_passed);
   say(' failed ..... ' || v_failed);
   say(' review ..... ' || v_review   || '   (left unchanged: role or domain ambiguous)');
   say(' disabled ... ' || v_disabled || '   (protection switched off)');
   say(' warnings ... ' || v_warned);
   say(' skipped .... ' || v_skipped  || '   (not present on this instance)');
   say;
   say(' RESULT: ' || CASE v_verdict WHEN 'REVIEW' THEN 'REVIEW REQUIRED' ELSE v_verdict END);
   say;

   IF v_verdict = 'PASS' THEN
      say('  Every protection was on, no original identifier and no free-text');
      say('  value survived anywhere the inventory covers, and nothing was left');
      say('  for review.');
   ELSIF v_verdict = 'FAIL' THEN
      say('  ' || v_failed || ' check(s) failed. Client data is still present.');
   ELSIF v_verdict = 'REVIEW' THEN
      say('  ' || v_review || ' check(s) found client values deliberately left unchanged,');
      say('  because their role or domain could not be established. They are');
      say('  still in place: this is not complete anonymization until a reviewed');
      say('  decision covers them.');
   ELSE
      say('  No exposure where protection was on - but ' || v_disabled || ' protection(s)');
      say('  were switched off, so original values remain by configuration. This');
      say('  is partial anonymization.');
   END IF;
   IF v_verdict <> 'PASS' THEN
      say;
      say('  Full detail:');
      say('    SELECT part, check_name, status, bad_rows, detail FROM anon_meta.verify_result');
      say('     WHERE status NOT IN (''PASS'', ''INFO'', ''SKIP'') ORDER BY part;');
   END IF;
   IF v_warned > 0 THEN
      say;
      say('  ' || v_warned || ' warning(s) - not part of the verdict:');
      say('    SELECT check_name, bad_rows, detail FROM anon_meta.verify_result');
      say('     WHERE status = ''WARN'';');
   END IF;
   say('====================================================================');
   say;

   :verdict_rc := CASE v_verdict WHEN 'PASS' THEN 0 WHEN 'FAIL' THEN 2
                                 WHEN 'REVIEW' THEN 3 ELSE 4 END;
END;
/

EXIT :verdict_rc
