-- ============================================================================
-- 30 - anon_engine package
-- ============================================================================
-- The whole anonymization engine. Everything it does is driven by
-- anon_meta.anon_inventory and by the identity plan it builds from the data;
-- there are no hardcoded table or column names outside the three core tables
-- the identities are read from (tiers, compte_banque, structure).
--
-- Run as OP. The package is owned by OP so that it can modify OP tables under
-- definer rights without needing privileges granted through a role.
--
-- ----------------------------------------------------------------------------
-- IDENTITIES ARE TYPED
--
-- Every original code belongs to a DOMAIN, and only that domain's translation
-- is ever written where it is used:
--
--   PARTY    a tiers row, a w_tiers structure node, or a confirmed reference.
--            Classified once into exactly one category:
--              PORTFOLIO          P_  flag_portefeuille 'O' + a w_tiers node
--              ENTITY             E_  flag 'N' + an Entite w_tiers node
--              COUNTERPARTY       T_  flag 'N' + another w_tiers node, no Entite
--              UNCLASSIFIED_PARTY X_  anything else, with a recorded reason
--   ACCOUNT  a compte_banque row or a Compte/w_compte_banque node.
--              BANK_ACCOUNT       CB_
--
-- The same text can be a party AND an account. They are different objects and
-- each keeps its own replacement; the shared text proves nothing.
--
-- v4 before this used one unrestricted lookup (code_map_any) for everything
-- but bank-account columns. A party with no party mapping then picked up a
-- bank account's CB_ value, and an account node picked up a party's E_ value.
-- ============================================================================

SET DEFINE OFF
SET FEEDBACK OFF
SET ECHO OFF

CREATE OR REPLACE PACKAGE op.anon_engine AS

   -- Prefixes for generated identifiers. E_/P_/T_/CB_ kept from v3 so
   -- anonymized data looks the same as it always has. X_ is new: a party whose
   -- category the data cannot establish.
   c_prefix_entity       CONSTANT VARCHAR2(4) := 'E_';
   c_prefix_portfolio    CONSTANT VARCHAR2(4) := 'P_';
   c_prefix_counterparty CONSTANT VARCHAR2(4) := 'T_';
   c_prefix_unclassified CONSTANT VARCHAR2(4) := 'X_';
   c_prefix_bank_account CONSTANT VARCHAR2(4) := 'CB_';

   -- Number of digits after the prefix. 7 gives room for 10M codes per
   -- category; widest generated value is CB_ + 7 = 10 characters.
   c_code_digits CONSTANT PLS_INTEGER := 7;

   -- Tables at or above this row count get a PARALLEL hint. Below it the
   -- coordination overhead outweighs the benefit.
   c_parallel_threshold CONSTANT NUMBER := 100000;

   -- What a NULL_OUT column is set to when it cannot be set to NULL.
   --
   -- A NOT NULL free-text column would raise ORA-01407 on SET ... = NULL and
   -- take the run with it. Leaving it alone leaves the client data in place.
   -- Overwriting with a fixed marker removes the content, which is the point,
   -- and keeps the constraint satisfied.
   --
   -- Truncated to the column width where necessary. A NOT NULL column that is
   -- not character-typed has no valid masking value at all, and preflight
   -- refuses to start rather than skip it.
   c_mask_text CONSTANT VARCHAR2(30) := 'ANONYMIZED';

   -- Set the run parameters. Each switch is y or n (also yes/no, true/false,
   -- 1/0, o/n); anything else is an error rather than a silent "no". A switch
   -- left NULL takes its default: every masking switch defaults to y.
   --
   -- Per category, three INDEPENDENT operations:
   --   p_<category>       rename identifiers and their typed references
   --   p_<category>_desc  mask descriptions / display labels
   --   p_<category>_attr  mask sensitive attributes, addresses included
   PROCEDURE configure(
      p_mode                   IN VARCHAR2,            -- EXECUTE | DRYRUN
      p_entity                 IN VARCHAR2 DEFAULT 'Y',
      p_portfolio              IN VARCHAR2 DEFAULT 'Y',
      p_counterparty           IN VARCHAR2 DEFAULT 'Y',
      p_unclassified           IN VARCHAR2 DEFAULT 'Y',
      p_bank_account           IN VARCHAR2 DEFAULT 'Y',
      p_entity_desc            IN VARCHAR2 DEFAULT 'Y',
      p_portfolio_desc         IN VARCHAR2 DEFAULT 'Y',
      p_counterparty_desc      IN VARCHAR2 DEFAULT 'Y',
      p_unclassified_desc      IN VARCHAR2 DEFAULT 'Y',
      p_bank_account_desc      IN VARCHAR2 DEFAULT 'Y',
      p_entity_attr            IN VARCHAR2 DEFAULT 'Y',
      p_portfolio_attr         IN VARCHAR2 DEFAULT 'Y',
      p_counterparty_attr      IN VARCHAR2 DEFAULT 'Y',
      p_unclassified_attr      IN VARCHAR2 DEFAULT 'Y',
      p_bank_account_attr      IN VARCHAR2 DEFAULT 'Y',
      p_parallel_degree        IN VARCHAR2 DEFAULT '4',
      p_fail_on_missing        IN VARCHAR2 DEFAULT 'N',
      p_approve_structure_only IN VARCHAR2 DEFAULT 'N');

   PROCEDURE start_run;
   PROCEDURE finish_run(p_status IN VARCHAR2, p_error IN VARCHAR2 DEFAULT NULL);
   FUNCTION  current_run_id RETURN NUMBER;

   -- Everything that must be known before a single target row changes:
   --   1. resolve every inventory row against the data dictionary and check
   --      that what it writes fits the column
   --   2. capture the identities, classify them, decide each one's single
   --      translation - reusing, never regenerating - and check the result
   -- Raises if anything would make the run unsafe. A dry run stops after
   -- estimating against this same plan.
   PROCEDURE preflight;

   -- Persist the planned translations (EXECUTE only) and build the typed
   -- lookups the apply phase reads. An existing translation is REUSED, never
   -- regenerated - that is what makes a failed run resumable.
   PROCEDURE generate_code_map;

   -- Walk the inventory and apply it.
   PROCEDURE apply_inventory;

   PROCEDURE set_triggers(p_enable IN BOOLEAN);

   PROCEDURE print_summary;

END anon_engine;
/

SHOW ERRORS


CREATE OR REPLACE PACKAGE BODY op.anon_engine AS

   -- ---------------------------------------------------------------- state --
   TYPE t_names IS TABLE OF VARCHAR2(30);
   TYPE t_flags IS TABLE OF VARCHAR2(1) INDEX BY VARCHAR2(30);

   g_run_id                 NUMBER;
   g_mode                   VARCHAR2(10) := 'DRYRUN';
   g_dry_run                BOOLEAN      := TRUE;
   g_parallel_degree        PLS_INTEGER  := 4;
   g_fail_on_missing        BOOLEAN      := FALSE;
   g_approve_structure_only BOOLEAN      := FALSE;

   -- The three switches of each category: 'Y' or 'N'.
   g_id   t_flags;
   g_desc t_flags;
   g_attr t_flags;

   g_count_ok          PLS_INTEGER := 0;
   g_count_noop        PLS_INTEGER := 0;
   g_count_skipped     PLS_INTEGER := 0;
   g_count_disabled    PLS_INTEGER := 0;
   g_count_review      PLS_INTEGER := 0;
   g_count_error       PLS_INTEGER := 0;
   g_rows_total        NUMBER      := 0;

   -- Preflight findings that make the run unsafe. Every one is also logged
   -- with status ERROR, so the full list is queryable afterwards.
   g_blocking          PLS_INTEGER := 0;


   -- =========================================================================
   -- Helpers
   -- =========================================================================

   -- The five categories, in display order. The four party categories first.
   FUNCTION categories RETURN t_names IS
   BEGIN
      RETURN t_names('ENTITY', 'PORTFOLIO', 'COUNTERPARTY', 'UNCLASSIFIED_PARTY', 'BANK_ACCOUNT');
   END categories;


   -- No ELSE branch that returns a value: an unknown category must never be
   -- treated as one of the others. That is the trap the old engine's
   -- ELSE 4 priority set - anything unrecognised tied with BANK_ACCOUNT.
   FUNCTION prefix_of(p_category IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN CASE p_category
                WHEN 'ENTITY'             THEN c_prefix_entity
                WHEN 'PORTFOLIO'          THEN c_prefix_portfolio
                WHEN 'COUNTERPARTY'       THEN c_prefix_counterparty
                WHEN 'UNCLASSIFIED_PARTY' THEN c_prefix_unclassified
                WHEN 'BANK_ACCOUNT'       THEN c_prefix_bank_account
             END;
   END prefix_of;


   FUNCTION label_of(p_category IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN CASE p_category
                WHEN 'ENTITY'             THEN 'Entity'
                WHEN 'PORTFOLIO'          THEN 'Portfolio'
                WHEN 'COUNTERPARTY'       THEN 'Counterparty'
                WHEN 'UNCLASSIFIED_PARTY' THEN 'Unclassified party'
                WHEN 'BANK_ACCOUNT'       THEN 'Bank account'
             END;
   END label_of;


   -- Whether any of the given categories has the switch on.
   FUNCTION any_on(p_flags IN t_flags, p_categories IN t_names) RETURN BOOLEAN IS
   BEGIN
      FOR i IN 1 .. p_categories.COUNT LOOP
         IF p_flags(p_categories(i)) = 'Y' THEN
            RETURN TRUE;
         END IF;
      END LOOP;
      RETURN FALSE;
   END any_on;


   FUNCTION party_categories RETURN t_names IS
   BEGIN
      RETURN t_names('ENTITY', 'PORTFOLIO', 'COUNTERPARTY', 'UNCLASSIFIED_PARTY');
   END party_categories;


   -- The categories a rule's inventory category can touch.
   FUNCTION categories_of(p_category IN VARCHAR2) RETURN t_names IS
   BEGIN
      IF p_category = 'PARTY' THEN
         RETURN party_categories;
      ELSIF p_category IN ('MIXED', 'NODE_ROLE') THEN
         RETURN categories;
      END IF;
      RETURN t_names(p_category);
   END categories_of;


   -- Log one step. Autonomous so entries are visible from another session while
   -- the run is still going, and survive a rollback of the work they describe.
   PROCEDURE log_step(
      p_phase   IN VARCHAR2,
      p_object  IN VARCHAR2,
      p_rule    IN VARCHAR2,
      p_status  IN VARCHAR2,
      p_rows    IN NUMBER   DEFAULT NULL,
      p_ms      IN NUMBER   DEFAULT NULL,
      p_message IN VARCHAR2 DEFAULT NULL)
   IS
      PRAGMA AUTONOMOUS_TRANSACTION;
   BEGIN
      INSERT INTO anon_meta.anon_step_log
         (run_id, phase, object_name, rule, status, rows_affected, elapsed_ms, message)
      VALUES
         (g_run_id, p_phase, p_object, p_rule, p_status, p_rows, p_ms, SUBSTR(p_message, 1, 4000));
      COMMIT;

      -- Preflight is logged but NOT counted. It reports on every inventory item
      -- before the work starts, and the apply phase then reports on the same
      -- items again - so counting both made every missing object appear twice.
      -- On TANM7881 that showed "skipped 304" for 152 actual objects.
      --
      -- The summary describes the WORK done, so it counts the phases that do
      -- work: MAPPING, NULL_OUT, CODE, DESCRIPTION, SELF_CODE, TRIGGERS.
      -- METADATA is the run's own bookkeeping, not work on the data.
      IF p_phase NOT IN ('PREFLIGHT', 'METADATA') THEN
         CASE p_status
            WHEN 'OK'       THEN g_count_ok       := g_count_ok + 1;
            WHEN 'NOOP'     THEN g_count_noop     := g_count_noop + 1;
            WHEN 'SKIPPED'  THEN g_count_skipped  := g_count_skipped + 1;
            WHEN 'DISABLED' THEN g_count_disabled := g_count_disabled + 1;
            WHEN 'REVIEW'   THEN g_count_review   := g_count_review + 1;
            WHEN 'ERROR'    THEN g_count_error    := g_count_error + 1;
            ELSE NULL;
         END CASE;

         -- REVIEW rows were deliberately NOT changed, so they are not work done.
         IF p_status <> 'REVIEW' THEN
            g_rows_total := g_rows_total + NVL(p_rows, 0);
         END IF;
      END IF;
   END log_step;


   PROCEDURE say(p_text IN VARCHAR2) IS
   BEGIN
      DBMS_OUTPUT.PUT_LINE(p_text);
   END say;


   -- Report one inventory item on screen in a fixed-width form so a long run
   -- stays readable.
   PROCEDURE report(p_object IN VARCHAR2, p_status IN VARCHAR2, p_rows IN NUMBER DEFAULT NULL) IS
      v_detail VARCHAR2(60);
   BEGIN
      v_detail := CASE
                     WHEN p_status = 'OK'     THEN TO_CHAR(p_rows, 'FM999,999,999') || ' rows'
                     WHEN p_status = 'DRYRUN' THEN TO_CHAR(p_rows, 'FM999,999,999') || ' rows would change'
                     WHEN p_status = 'NOOP'   THEN 'no rows matched'
                     WHEN p_status = 'REVIEW' THEN TO_CHAR(p_rows, 'FM999,999,999') || ' rows left for review'
                     ELSE ''
                  END;
      say('    ' || RPAD(SUBSTR(p_object, 1, 52), 54) || RPAD(p_status, 10) || v_detail);
   END report;


   -- A preflight finding that makes the run unsafe: logged, shown, counted.
   PROCEDURE block(p_object IN VARCHAR2, p_message IN VARCHAR2, p_rows IN NUMBER DEFAULT NULL) IS
   BEGIN
      g_blocking := g_blocking + 1;
      log_step('PREFLIGHT', p_object, NULL, 'ERROR', p_rows, NULL, p_message);
      say('    BLOCKED     ' || p_object);
      say('                ' || p_message);
   END block;


   FUNCTION column_exists(p_table IN VARCHAR2, p_column IN VARCHAR2) RETURN BOOLEAN IS
      v_count PLS_INTEGER;
   BEGIN
      SELECT COUNT(*) INTO v_count
        FROM all_tab_columns
       WHERE owner = 'OP'
         AND table_name  = UPPER(p_table)
         AND column_name = UPPER(p_column);
      RETURN v_count > 0;
   END column_exists;


   -- Deliberately resolved through all_tab_columns rather than all_tables: the
   -- inventory includes a few updatable views (vue_affilie_tiers,
   -- vue_affilie_compte), and all_tables does not list views, so an all_tables
   -- check would silently skip them.
   FUNCTION table_exists(p_table IN VARCHAR2) RETURN BOOLEAN IS
      v_count PLS_INTEGER;
   BEGIN
      SELECT COUNT(*) INTO v_count
        FROM all_tab_columns
       WHERE owner = 'OP' AND table_name = UPPER(p_table) AND ROWNUM = 1;
      RETURN v_count > 0;
   END table_exists;


   -- PARALLEL hint, but only where it pays. Missing statistics are treated as
   -- "probably big" - the tables that matter here are the ones nobody has
   -- gathered stats on recently.
   FUNCTION parallel_hint(p_table IN VARCHAR2) RETURN VARCHAR2 IS
      v_rows NUMBER;
   BEGIN
      IF g_parallel_degree <= 1 THEN
         RETURN '';
      END IF;

      SELECT MAX(num_rows) INTO v_rows
        FROM all_tables
       WHERE owner = 'OP' AND table_name = UPPER(p_table);

      IF v_rows IS NULL OR v_rows >= c_parallel_threshold THEN
         RETURN '/*+ PARALLEL(' || g_parallel_degree || ') */ ';
      END IF;
      RETURN '';
   END parallel_hint;


   FUNCTION elapsed_ms(p_start IN NUMBER) RETURN NUMBER IS
   BEGIN
      -- DBMS_UTILITY.GET_TIME counts hundredths of a second.
      RETURN (DBMS_UTILITY.GET_TIME - p_start) * 10;
   END elapsed_ms;


   FUNCTION n(p IN NUMBER) RETURN VARCHAR2 IS
   BEGIN
      RETURN TO_CHAR(NVL(p, 0), 'FM999,999,999');
   END n;


   -- Width of the widest replacement a rule with this inventory category can
   -- write. A party column holds E_/P_/T_/X_ values, an account column CB_.
   FUNCTION needed_width(p_category IN VARCHAR2) RETURN PLS_INTEGER IS
      v_party   PLS_INTEGER := GREATEST(LENGTH(c_prefix_entity), LENGTH(c_prefix_portfolio),
                                        LENGTH(c_prefix_counterparty), LENGTH(c_prefix_unclassified))
                               + c_code_digits;
      v_account PLS_INTEGER := LENGTH(c_prefix_bank_account) + c_code_digits;
   BEGIN
      RETURN CASE
                WHEN p_category = 'BANK_ACCOUNT' THEN v_account
                WHEN p_category IN ('PARTY', 'ENTITY', 'PORTFOLIO', 'COUNTERPARTY',
                                    'UNCLASSIFIED_PARTY') THEN v_party
                ELSE GREATEST(v_party, v_account)
             END;
   END needed_width;


   -- =========================================================================
   -- Lifecycle
   -- =========================================================================

   PROCEDURE configure(
      p_mode                   IN VARCHAR2,
      p_entity                 IN VARCHAR2 DEFAULT 'Y',
      p_portfolio              IN VARCHAR2 DEFAULT 'Y',
      p_counterparty           IN VARCHAR2 DEFAULT 'Y',
      p_unclassified           IN VARCHAR2 DEFAULT 'Y',
      p_bank_account           IN VARCHAR2 DEFAULT 'Y',
      p_entity_desc            IN VARCHAR2 DEFAULT 'Y',
      p_portfolio_desc         IN VARCHAR2 DEFAULT 'Y',
      p_counterparty_desc      IN VARCHAR2 DEFAULT 'Y',
      p_unclassified_desc      IN VARCHAR2 DEFAULT 'Y',
      p_bank_account_desc      IN VARCHAR2 DEFAULT 'Y',
      p_entity_attr            IN VARCHAR2 DEFAULT 'Y',
      p_portfolio_attr         IN VARCHAR2 DEFAULT 'Y',
      p_counterparty_attr      IN VARCHAR2 DEFAULT 'Y',
      p_unclassified_attr      IN VARCHAR2 DEFAULT 'Y',
      p_bank_account_attr      IN VARCHAR2 DEFAULT 'Y',
      p_parallel_degree        IN VARCHAR2 DEFAULT '4',
      p_fail_on_missing        IN VARCHAR2 DEFAULT 'N',
      p_approve_structure_only IN VARCHAR2 DEFAULT 'N')
   IS
      -- A value that is neither yes nor no is an error, not a quiet "no". A
      -- typo in a masking switch must not turn the masking off.
      FUNCTION flag(p_value IN VARCHAR2, p_name IN VARCHAR2, p_default IN VARCHAR2) RETURN VARCHAR2 IS
         v VARCHAR2(30) := UPPER(TRIM(p_value));
      BEGIN
         IF v IS NULL THEN
            RETURN p_default;
         ELSIF v IN ('Y', 'YES', 'TRUE', '1', 'O', 'OUI') THEN
            RETURN 'Y';
         ELSIF v IN ('N', 'NO', 'FALSE', '0', 'NON') THEN
            RETURN 'N';
         END IF;
         RAISE_APPLICATION_ERROR(-20014,
            p_name || ' must be y or n, not "' || SUBSTR(p_value, 1, 30) || '". Nothing has been changed.');
      END flag;
   BEGIN
      g_mode    := CASE WHEN UPPER(p_mode) = 'EXECUTE' THEN 'EXECUTE' ELSE 'DRYRUN' END;
      g_dry_run := (g_mode = 'DRYRUN');

      -- Three independent switches per category. Renaming identifiers is no
      -- longer a master switch: with ANONYMIZE_ENTITY=n and the description
      -- and attribute switches y, entity labels and attributes are still
      -- masked - with the entity's safe mapped value, never its original code.
      g_id('ENTITY')               := flag(p_entity,            'ANONYMIZE_ENTITY',                         'Y');
      g_id('PORTFOLIO')            := flag(p_portfolio,         'ANONYMIZE_PORTFOLIO',                      'Y');
      g_id('COUNTERPARTY')         := flag(p_counterparty,      'ANONYMIZE_COUNTERPARTY',                   'Y');
      g_id('UNCLASSIFIED_PARTY')   := flag(p_unclassified,      'ANONYMIZE_UNCLASSIFIED_PARTY',             'Y');
      g_id('BANK_ACCOUNT')         := flag(p_bank_account,      'ANONYMIZE_BANK_ACCOUNT',                   'Y');

      g_desc('ENTITY')             := flag(p_entity_desc,       'ANONYMIZE_ENTITY_DESCRIPTION',             'Y');
      g_desc('PORTFOLIO')          := flag(p_portfolio_desc,    'ANONYMIZE_PORTFOLIO_DESCRIPTION',          'Y');
      g_desc('COUNTERPARTY')       := flag(p_counterparty_desc, 'ANONYMIZE_COUNTERPARTY_DESCRIPTION',       'Y');
      g_desc('UNCLASSIFIED_PARTY') := flag(p_unclassified_desc, 'ANONYMIZE_UNCLASSIFIED_PARTY_DESCRIPTION', 'Y');
      g_desc('BANK_ACCOUNT')       := flag(p_bank_account_desc, 'ANONYMIZE_BANK_ACCOUNT_DESCRIPTION',       'Y');

      g_attr('ENTITY')             := flag(p_entity_attr,       'ANONYMIZE_ENTITY_ATTRIBUTES',              'Y');
      g_attr('PORTFOLIO')          := flag(p_portfolio_attr,    'ANONYMIZE_PORTFOLIO_ATTRIBUTES',           'Y');
      g_attr('COUNTERPARTY')       := flag(p_counterparty_attr, 'ANONYMIZE_COUNTERPARTY_ATTRIBUTES',        'Y');
      g_attr('UNCLASSIFIED_PARTY') := flag(p_unclassified_attr, 'ANONYMIZE_UNCLASSIFIED_PARTY_ATTRIBUTES',  'Y');
      g_attr('BANK_ACCOUNT')       := flag(p_bank_account_attr, 'ANONYMIZE_BANK_ACCOUNT_ATTRIBUTES',        'Y');

      BEGIN
         g_parallel_degree := GREATEST(1, LEAST(32, TO_NUMBER(NVL(TRIM(p_parallel_degree), '4'))));
      EXCEPTION
         WHEN VALUE_ERROR THEN
            RAISE_APPLICATION_ERROR(-20014,
               'PARALLEL_DEGREE must be a number, not "' || SUBSTR(p_parallel_degree, 1, 30)
            || '". Nothing has been changed.');
      END;

      g_fail_on_missing        := flag(p_fail_on_missing, 'FAIL_ON_MISSING_OBJECT', 'N') = 'Y';
      g_approve_structure_only := flag(p_approve_structure_only,
                                       'APPROVE_STRUCTURE_ONLY_ACCOUNTS', 'N') = 'Y';
   END configure;


   PROCEDURE start_run IS
      v_cats  t_names := categories;
      v_cat   VARCHAR2(30);
      v_i     VARCHAR2(1);
      v_d     VARCHAR2(1);
      v_a     VARCHAR2(1);
      v_id    VARCHAR2(200);
      v_desc  VARCHAR2(200);
      v_attr  VARCHAR2(200);
      v_on    PLS_INTEGER := 0;
      v_config VARCHAR2(2000);

      PROCEDURE add(p_list IN OUT VARCHAR2, p_value IN VARCHAR2) IS
      BEGIN
         p_list := CASE WHEN p_list IS NULL THEN p_value ELSE p_list || ',' || p_value END;
      END add;
   BEGIN
      FOR i IN 1 .. v_cats.COUNT LOOP
         IF g_id(v_cats(i))   = 'Y' THEN add(v_id,   v_cats(i)); v_on := v_on + 1; END IF;
         IF g_desc(v_cats(i)) = 'Y' THEN add(v_desc, v_cats(i)); v_on := v_on + 1; END IF;
         IF g_attr(v_cats(i)) = 'Y' THEN add(v_attr, v_cats(i)); v_on := v_on + 1; END IF;
      END LOOP;

      SELECT anon_meta.seq_anon_run.NEXTVAL INTO g_run_id FROM dual;

      -- Built in PL/SQL: a BOOLEAN cannot appear inside a SQL statement before
      -- Oracle 23.
      v_config := '{"identifiers":"'  || v_id
               || '","descriptions":"' || v_desc
               || '","attributes":"'   || v_attr
               || '","parallel":'       || g_parallel_degree
               || ',"fail_on_missing":"' || CASE WHEN g_fail_on_missing THEN 'Y' ELSE 'N' END
               || '","approve_structure_only_accounts":"'
               || CASE WHEN g_approve_structure_only THEN 'Y' ELSE 'N' END || '"}';

      INSERT INTO anon_meta.anon_run (run_id, run_mode, status, db_name, os_user, config_json)
      VALUES (g_run_id, g_mode, 'RUNNING',
              SYS_CONTEXT('USERENV', 'DB_NAME'),
              SYS_CONTEXT('USERENV', 'OS_USER'),
              v_config);

      -- The switches in a form SQL can join to: the plan, the verifier and the
      -- report all read what THIS run used.
      FOR i IN 1 .. v_cats.COUNT LOOP
         v_cat := v_cats(i);
         v_i   := g_id(v_cat);
         v_d   := g_desc(v_cat);
         v_a   := g_attr(v_cat);
         INSERT INTO anon_meta.anon_run_setting (run_id, category, id_on, desc_on, attr_on)
         VALUES (g_run_id, v_cat, v_i, v_d, v_a);
      END LOOP;
      COMMIT;

      say('');
      say('  Run id .............. ' || g_run_id);
      say('  Mode ................ ' || g_mode ||
          CASE WHEN g_dry_run THEN '   (no changes will be made)' ELSE '' END);
      say('');
      say('  Category                    Rename IDs   Descriptions   Attributes');
      say('  --------------------------  -----------  -------------  ----------');
      FOR i IN 1 .. v_cats.COUNT LOOP
         say('  ' || RPAD(label_of(v_cats(i)) || ' (' || prefix_of(v_cats(i)) || ')', 28)
                  || RPAD(LOWER(g_id(v_cats(i))), 13) || RPAD(LOWER(g_desc(v_cats(i))), 15)
                  || LOWER(g_attr(v_cats(i))));
      END LOOP;
      say('  Free text (NULL_OUT)        always - not affected by any switch');
      say('');
      say('  Parallel degree ..... ' || g_parallel_degree);
      say('  Structure-only accounts approved ... '
          || CASE WHEN g_approve_structure_only THEN 'y' ELSE 'n' END);
      say('');

      -- The switches used to be nested: ANONYMIZE_<CATEGORY>=n switched off its
      -- descriptions and attributes as well. They are now independent, so a
      -- configuration written for the old behaviour can mask more than its
      -- author expected. Say so, on every run where it applies.
      FOR i IN 1 .. v_cats.COUNT LOOP
         IF g_id(v_cats(i)) = 'N' AND (g_desc(v_cats(i)) = 'Y' OR g_attr(v_cats(i)) = 'Y') THEN
            say('  NOTE  ANONYMIZE_' || v_cats(i) || '=n now switches off ONLY the renaming of');
            say('        identifiers. Its descriptions and attributes are still masked, because');
            say('        their own switches are y. Older versions skipped all three. To leave');
            say('        everything of this category untouched, set all three switches to n.');
            say('');
         END IF;
      END LOOP;

      IF v_on = 0 THEN
         say('  NOTE  Every switch is n. Only free text (NULL_OUT) will be erased, and the');
         say('        verification result can be no better than INCOMPLETE.');
         say('');
      END IF;
   END start_run;


   PROCEDURE finish_run(p_status IN VARCHAR2, p_error IN VARCHAR2 DEFAULT NULL) IS
   BEGIN
      UPDATE anon_meta.anon_run
         SET status      = p_status,
             finished_at = SYSTIMESTAMP,
             error_text  = SUBSTR(p_error, 1, 4000)
       WHERE run_id = g_run_id;
      COMMIT;
   END finish_run;


   FUNCTION current_run_id RETURN NUMBER IS
   BEGIN
      RETURN g_run_id;
   END current_run_id;


   -- =========================================================================
   -- Preflight, part 1 - the inventory against the data dictionary
   -- =========================================================================

   PROCEDURE check_inventory(p_missing OUT PLS_INTEGER) IS
      v_missing_table  PLS_INTEGER := 0;
      v_missing_column PLS_INTEGER := 0;
      v_too_narrow     PLS_INTEGER := 0;
      v_wrong_type     PLS_INTEGER := 0;
      v_unmaskable     PLS_INTEGER := 0;
      v_masked         PLS_INTEGER := 0;
      v_ok             PLS_INTEGER := 0;
      v_width          PLS_INTEGER;
      v_type           VARCHAR2(30);
      v_nullable       VARCHAR2(1);
      v_needed         PLS_INTEGER;
      v_object         VARCHAR2(300);
   BEGIN
      -- Every inventory row is processed by its rule. There is no exception for
      -- narrow columns or short values any more: a column listed in the
      -- inventory is a column someone decided holds client data. A control
      -- field that must not be touched is left OUT of the inventory, where the
      -- decision is visible - not guessed from its width.
      FOR r IN (SELECT table_name, column_name, rule, category
                  FROM anon_meta.anon_inventory
                 ORDER BY seq) LOOP

         v_object := LOWER(r.table_name) || '.' || LOWER(r.column_name);

         IF NOT table_exists(r.table_name) THEN
            v_missing_table := v_missing_table + 1;
            log_step('PREFLIGHT', v_object, r.rule, 'SKIPPED', NULL, NULL, 'table not found');
            CONTINUE;
         ELSIF NOT column_exists(r.table_name, r.column_name) THEN
            v_missing_column := v_missing_column + 1;
            log_step('PREFLIGHT', v_object, r.rule, 'SKIPPED', NULL, NULL, 'column not found');
            CONTINUE;
         END IF;

         SELECT MAX(char_length), MAX(data_type), MAX(nullable)
           INTO v_width, v_type, v_nullable
           FROM all_tab_columns
          WHERE owner = 'OP'
            AND table_name  = UPPER(r.table_name)
            AND column_name = UPPER(r.column_name);

         IF r.rule IN ('CODE', 'DESCRIPTION', 'SELF_CODE') THEN
            -- A column that receives a generated identifier has to be able to
            -- hold one: character typed, and wide enough for the widest value
            -- its domain can produce. v3 checked neither, so a mismatch
            -- surfaced as ORA-12899 or ORA-01722 partway through a run.
            v_needed := needed_width(r.category);

            -- DESCRIPTION and SELF_CODE find their owner through the table's
            -- code column, so an older schema without one cannot support them.
            IF r.rule IN ('DESCRIPTION', 'SELF_CODE')
               AND NOT column_exists(r.table_name, 'code') THEN
               v_missing_column := v_missing_column + 1;
               log_step('PREFLIGHT', v_object, r.rule, 'SKIPPED', NULL, NULL,
                        'table has no code column to find the owning identity');

            ELSIF v_type NOT IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
               v_wrong_type := v_wrong_type + 1;
               log_step('PREFLIGHT', v_object, r.rule, 'ERROR', NULL, NULL,
                        'column is ' || v_type || '; a generated identifier is text');
               say('    WRONG TYPE  ' || v_object || '  (' || v_type || ')');

            ELSIF v_width < v_needed THEN
               v_too_narrow := v_too_narrow + 1;
               log_step('PREFLIGHT', v_object, r.rule, 'ERROR', NULL, NULL,
                        'column holds ' || v_width || ' chars; ' || r.rule || ' ' || r.category
                     || ' writes values of up to ' || v_needed || '. Correct the inventory rule or '
                     || 'the schema - the column is not skipped and the value is never truncated.');
               say('    TOO NARROW  ' || v_object || '  (' || v_type || '(' || v_width || ') < '
                   || v_needed || ')');

            ELSE
               v_ok := v_ok + 1;
            END IF;

         ELSE
            -- NULL_OUT. A nullable column is emptied. A NOT NULL character
            -- column is overwritten with the marker, cut to its width. A NOT
            -- NULL column of any other type has no valid masking value: it is
            -- not skipped and it is not reported clean - the run does not start.
            IF v_nullable = 'N' AND v_type NOT IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
               v_unmaskable := v_unmaskable + 1;
               log_step('PREFLIGHT', v_object, r.rule, 'ERROR', NULL, NULL,
                        'NOT NULL ' || v_type || ' - it can be neither emptied nor masked. Remove it '
                     || 'from the inventory with a recorded decision, or change the schema.');
               say('    NO MASK     ' || v_object || '  (NOT NULL ' || v_type || ')');
            ELSE
               IF v_nullable = 'N' THEN
                  v_masked := v_masked + 1;
                  log_step('PREFLIGHT', v_object, r.rule, 'OK', NULL, NULL,
                           'NOT NULL - overwritten with ''' || SUBSTR(c_mask_text, 1, v_width)
                        || ''' instead of emptied');
               END IF;
               v_ok := v_ok + 1;
            END IF;
         END IF;
      END LOOP;

      say('    resolved .......... ' || v_ok);
      say('    missing tables .... ' || v_missing_table);
      say('    missing columns ... ' || v_missing_column);
      say('    too narrow ........ ' || v_too_narrow);
      say('    wrong type ........ ' || v_wrong_type);
      say('    cannot be masked .. ' || v_unmaskable);
      IF v_masked > 0 THEN
         say('    NOT NULL free text  ' || v_masked || '   (overwritten with a marker instead of emptied)');
      END IF;
      say('');

      g_blocking := g_blocking + v_too_narrow + v_wrong_type + v_unmaskable;
      p_missing  := v_missing_table + v_missing_column;
   END check_inventory;


   -- =========================================================================
   -- Preflight, part 2 - the identity plan
   -- =========================================================================

   -- Capture every identity, classify it, and decide its single translation.
   --
   -- One statement reads the three core tables, so the whole inventory comes
   -- from one consistent view of the data. Rows an earlier run already renamed
   -- are resolved back to their original through THEIR OWN domain's mapping -
   -- so a resumed run sees the same identities as the first, and a value of the
   -- wrong domain sitting in a master row stays visible instead of being
   -- mistaken for a new identity.
   PROCEDURE capture_identities IS
      v_sql VARCHAR2(32767);
   BEGIN
      v_sql := q'[
INSERT INTO anon_meta.identity_plan
   (run_id, domain, old_code, identity_status, category, x_reason, membership,
    has_master, flag_state, has_party_node, has_entity_node, has_other_class_node,
    has_other_screen_node, has_account_node, entity_overlap, class_now,
    seen_renamed, map_category, new_code, map_status)
WITH pmap AS (
   SELECT i.old_code, c.new_code
     FROM anon_meta.identity_inventory i
     JOIN anon_meta.code_map c ON c.category = i.map_category AND c.old_code = i.old_code
    WHERE i.domain = 'PARTY'
), amap AS (
   SELECT i.old_code, c.new_code
     FROM anon_meta.identity_inventory i
     JOIN anon_meta.code_map c ON c.category = i.map_category AND c.old_code = i.old_code
    WHERE i.domain = 'ACCOUNT'
), tm AS (
   SELECT NVL(m.old_code, x.code) AS k, x.flag_portefeuille AS flag,
          NVL2(m.old_code, 1, 0) AS r
     FROM op.tiers x
     LEFT JOIN pmap m ON m.new_code = x.code
    WHERE x.code IS NOT NULL
), bm AS (
   SELECT NVL(m.old_code, x.code) AS k, MAX(NVL2(m.old_code, 1, 0)) AS r
     FROM op.compte_banque x
     LEFT JOIN amap m ON m.new_code = x.code
    WHERE x.code IS NOT NULL
    GROUP BY NVL(m.old_code, x.code)
), nd AS (
   SELECT CASE WHEN x.structure = 'Compte' AND x.ecran = 'w_compte_banque' THEN 'A'
               WHEN x.ecran = 'w_tiers' THEN 'P'
               ELSE 'O' END AS role,
          x.structure AS cls,
          CASE WHEN x.structure = 'Compte' AND x.ecran = 'w_compte_banque' THEN NVL(am.old_code, x.code)
               WHEN x.ecran = 'w_tiers' THEN NVL(pm.old_code, x.code)
               ELSE x.code END AS k,
          CASE WHEN x.structure = 'Compte' AND x.ecran = 'w_compte_banque' THEN NVL2(am.old_code, 1, 0)
               WHEN x.ecran = 'w_tiers' THEN NVL2(pm.old_code, 1, 0)
               ELSE 0 END AS r
     FROM op.structure x
     LEFT JOIN pmap pm ON pm.new_code = x.code
     LEFT JOIN amap am ON am.new_code = x.code
    WHERE x.code IS NOT NULL
), nf AS (
   SELECT k,
          MAX(CASE WHEN role = 'P' THEN 1 ELSE 0 END)                       AS party_node,
          MAX(CASE WHEN role = 'P' AND cls = 'Entite' THEN 1 ELSE 0 END)    AS entity_node,
          MAX(CASE WHEN role = 'P' AND cls <> 'Entite' THEN 1 ELSE 0 END)   AS other_class_node,
          MAX(CASE WHEN role = 'O' THEN 1 ELSE 0 END)                       AS other_screen_node,
          MAX(CASE WHEN role = 'A' THEN 1 ELSE 0 END)                       AS account_node,
          MAX(CASE WHEN role = 'P' THEN r ELSE 0 END)                       AS party_node_r,
          MAX(CASE WHEN role = 'A' THEN r ELSE 0 END)                       AS account_node_r
     FROM nd
    GROUP BY k
), tf AS (
   SELECT k,
          COUNT(*) AS n_master,
          MAX(r) AS master_r,
          CASE WHEN COUNT(DISTINCT NVL(flag, '~')) > 1 THEN 'CONFLICT'
               WHEN MAX(flag) = 'O' THEN 'O'
               WHEN MAX(flag) = 'N' THEN 'N'
               WHEN MAX(flag) IS NULL THEN 'NULL'
               ELSE 'OTHER' END AS flag_state
     FROM tm
    GROUP BY k
), keys AS (
         SELECT 'PARTY' AS domain, k FROM tm
   UNION SELECT 'PARTY', k FROM nd WHERE role = 'P'
   UNION SELECT 'PARTY', old_code FROM anon_meta.confirmed_identity WHERE domain = 'PARTY'
   UNION SELECT 'PARTY', old_code FROM anon_meta.identity_inventory WHERE domain = 'PARTY'
   UNION SELECT 'ACCOUNT', k FROM bm
   UNION SELECT 'ACCOUNT', k FROM nd WHERE role = 'A'
   UNION SELECT 'ACCOUNT', old_code FROM anon_meta.confirmed_identity WHERE domain = 'ACCOUNT'
   UNION SELECT 'ACCOUNT', old_code FROM anon_meta.identity_inventory WHERE domain = 'ACCOUNT'
), f AS (
   SELECT ky.domain, ky.k,
          NVL(tf.n_master, 0)                     AS n_master,
          tf.flag_state,
          CASE WHEN bm.k IS NULL THEN 0 ELSE 1 END AS in_bank,
          NVL(nf.party_node, 0)                   AS party_node,
          NVL(nf.entity_node, 0)                  AS entity_node,
          NVL(nf.other_class_node, 0)             AS other_class_node,
          NVL(nf.other_screen_node, 0)            AS other_screen_node,
          NVL(nf.account_node, 0)                 AS account_node,
          CASE WHEN ky.domain = 'ACCOUNT'
               THEN GREATEST(NVL(bm.r, 0), NVL(nf.account_node_r, 0))
               ELSE GREATEST(NVL(tf.master_r, 0), NVL(nf.party_node_r, 0)) END AS seen_r,
          ii.category                             AS known_category,
          ii.x_reason                             AS known_reason,
          ii.membership                           AS known_membership,
          ii.map_category                         AS known_map_category,
          cm.new_code                             AS known_new_code
     FROM keys ky
     LEFT JOIN tf ON tf.k = ky.k
     LEFT JOIN bm ON bm.k = ky.k
     LEFT JOIN nf ON nf.k = ky.k
     LEFT JOIN anon_meta.identity_inventory ii ON ii.domain = ky.domain AND ii.old_code = ky.k
     LEFT JOIN anon_meta.code_map cm ON cm.category = ii.map_category AND cm.old_code = ii.old_code
), c AS (
   SELECT f.*,
          -- Section 2A, in its exclusive order. A missing master is X_ even for
          -- a Compte/w_tiers node; an O flag needs a w_tiers node of any
          -- classification; ENTITY wins over another classification on the
          -- same party; a NULL classification is not a counterparty.
          CASE WHEN domain = 'ACCOUNT'                                 THEN 'BANK_ACCOUNT'
               WHEN n_master = 0                                       THEN 'UNCLASSIFIED_PARTY'
               WHEN flag_state = 'O' AND party_node = 1                THEN 'PORTFOLIO'
               WHEN flag_state = 'N' AND entity_node = 1               THEN 'ENTITY'
               WHEN flag_state = 'N' AND other_class_node = 1          THEN 'COUNTERPARTY'
               ELSE 'UNCLASSIFIED_PARTY' END AS cls_category,
          CASE WHEN domain = 'ACCOUNT'                                 THEN NULL
               WHEN n_master = 0                                       THEN 'MISSING_MASTER'
               WHEN party_node = 0 AND other_screen_node = 0           THEN 'NO_STRUCTURE'
               WHEN party_node = 0                                     THEN 'NO_PARTY_SCREEN'
               WHEN flag_state NOT IN ('O', 'N')                       THEN 'UNKNOWN_FLAG'
               ELSE 'UNKNOWN_CLASSIFICATION' END AS cls_reason,
          CASE WHEN domain = 'ACCOUNT' THEN
                    CASE WHEN in_bank = 1 AND account_node = 1 THEN 'BOTH'
                         WHEN in_bank = 1                      THEN 'MASTER_ONLY'
                         WHEN account_node = 1                 THEN 'STRUCTURE_ONLY'
                         ELSE 'REFERENCE_ONLY' END
               ELSE CASE WHEN n_master > 0 AND party_node = 1  THEN 'BOTH'
                         WHEN n_master > 0                     THEN 'MASTER_ONLY'
                         WHEN party_node = 1                   THEN 'STRUCTURE_ONLY'
                         ELSE 'REFERENCE_ONLY' END
          END AS cls_membership,
          CASE WHEN domain = 'ACCOUNT' THEN in_bank + account_node
               ELSE n_master + party_node END AS presence
     FROM f
)
SELECT :run_id, domain, k,
       CASE WHEN known_category IS NULL THEN 'NEW' ELSE 'KNOWN' END,
       NVL(known_category, cls_category),
       CASE WHEN known_category IS NOT NULL THEN known_reason
            WHEN cls_category = 'UNCLASSIFIED_PARTY' THEN cls_reason END,
       NVL(known_membership, cls_membership),
       CASE WHEN domain = 'ACCOUNT' THEN DECODE(in_bank, 1, 'Y', 'N')
            WHEN n_master > 0 THEN 'Y' ELSE 'N' END,
       CASE WHEN domain = 'PARTY' THEN flag_state END,
       DECODE(party_node, 1, 'Y', 'N'),
       DECODE(entity_node, 1, 'Y', 'N'),
       DECODE(other_class_node, 1, 'Y', 'N'),
       DECODE(other_screen_node, 1, 'Y', 'N'),
       DECODE(account_node, 1, 'Y', 'N'),
       CASE WHEN domain = 'PARTY' AND flag_state = 'N' AND entity_node = 1
                 AND other_class_node = 1 THEN 'Y' ELSE 'N' END,
       CASE WHEN presence > 0 THEN cls_category END,
       DECODE(seen_r, 1, 'Y', 'N'),
       known_map_category,
       known_new_code,
       CASE WHEN known_map_category IS NULL THEN NULL
            WHEN known_new_code IS NULL THEN 'MISSING'
            ELSE 'EXISTING' END
  FROM c]';

      EXECUTE IMMEDIATE v_sql USING g_run_id;
   EXCEPTION
      WHEN OTHERS THEN
         IF SQLCODE = -12899 THEN
            RAISE_APPLICATION_ERROR(-20016,
               'An identifier in tiers, compte_banque or structure is longer than the 80 '
            || 'characters anon_meta can record. Nothing has been changed.');
         END IF;
         RAISE;
   END capture_identities;


   -- A NEW identity can already have rows in code_map: from an earlier version
   -- of this tool, or from an earlier import of the same client's data. Such a
   -- row is REUSED, never regenerated, when it is unambiguous - a party with a
   -- single earlier party translation keeps it. Two or more earlier party
   -- translations for one party are reused only if one of them matches the
   -- category the party has now; otherwise there is no safe choice and the run
   -- stops. The unused ones are counted as superseded.
   PROCEDURE adopt_existing_maps IS
   BEGIN
      MERGE INTO anon_meta.identity_plan p
      USING (SELECT domain, old_code, map_category, new_code, n, has_match
               FROM (SELECT q.domain, q.old_code, c.category AS map_category, c.new_code,
                            COUNT(*) OVER (PARTITION BY q.domain, q.old_code) AS n,
                            MAX(CASE WHEN c.category = q.category THEN 1 ELSE 0 END)
                               OVER (PARTITION BY q.domain, q.old_code) AS has_match,
                            ROW_NUMBER() OVER (PARTITION BY q.domain, q.old_code
                                               ORDER BY CASE WHEN c.category = q.category THEN 0 ELSE 1 END,
                                                        c.category) AS rn
                       FROM anon_meta.identity_plan q
                       JOIN anon_meta.code_map c
                         ON c.old_code = q.old_code
                        AND (   (q.domain = 'ACCOUNT' AND c.category = 'BANK_ACCOUNT')
                             OR (q.domain = 'PARTY'   AND c.category IN ('ENTITY', 'PORTFOLIO',
                                                        'COUNTERPARTY', 'UNCLASSIFIED_PARTY')))
                      WHERE q.run_id = g_run_id
                        AND q.identity_status = 'NEW')
              WHERE rn = 1) s
         ON (p.run_id = g_run_id AND p.domain = s.domain AND p.old_code = s.old_code)
       WHEN MATCHED THEN UPDATE SET
            p.map_category = CASE WHEN s.n > 1 AND s.has_match = 0 THEN NULL ELSE s.map_category END,
            p.new_code     = CASE WHEN s.n > 1 AND s.has_match = 0 THEN NULL ELSE s.new_code END,
            p.map_status   = CASE WHEN s.n > 1 AND s.has_match = 0 THEN 'CONFLICT' ELSE 'EXISTING' END;

      -- Earlier translations of the same identity that are not its one
      -- translation. Reported; never used. If one of them is found in the data
      -- after the run, the verifier fails it.
      UPDATE anon_meta.identity_plan p
         SET superseded_maps =
                (SELECT COUNT(*)
                   FROM anon_meta.code_map c
                  WHERE c.old_code = p.old_code
                    AND (   (p.domain = 'ACCOUNT' AND c.category = 'BANK_ACCOUNT')
                         OR (p.domain = 'PARTY'   AND c.category IN ('ENTITY', 'PORTFOLIO',
                                                     'COUNTERPARTY', 'UNCLASSIFIED_PARTY')))
                    AND (p.map_category IS NULL OR c.category <> p.map_category))
       WHERE p.run_id = g_run_id;
   END adopt_existing_maps;


   -- What does a structure.pere holding this text point at?
   --
   -- Decided from the nodes that existed before anything was renamed, never
   -- from the child row: an account node's parent is often a party node.
   --
   --   exactly one kind of node carries the text   -> that kind
   --   no node carries it                          -> the one domain it is an
   --                                                  identity of, if only one
   --   party AND account nodes (or another screen) -> AMBIGUOUS: left alone and
   --                                                  reported for review
   PROCEDURE resolve_parent_roles IS
   BEGIN
      MERGE INTO anon_meta.identity_plan p
      USING (SELECT old_code,
                    CASE WHEN pn + an + onn = 1 THEN
                              CASE WHEN pn = 1 THEN 'PARTY' WHEN an = 1 THEN 'ACCOUNT' ELSE 'OTHER' END
                         WHEN pn + an + onn = 0 THEN
                              CASE WHEN pi = 1 AND ai = 1 THEN 'AMBIGUOUS'
                                   WHEN pi = 1 THEN 'PARTY'
                                   ELSE 'ACCOUNT' END
                         ELSE 'AMBIGUOUS' END AS parent_role
               FROM (SELECT old_code,
                            MAX(CASE WHEN domain = 'PARTY'   AND has_party_node   = 'Y' THEN 1 ELSE 0 END) AS pn,
                            MAX(CASE WHEN domain = 'ACCOUNT' AND has_account_node = 'Y' THEN 1 ELSE 0 END) AS an,
                            MAX(CASE WHEN has_other_screen_node = 'Y'                   THEN 1 ELSE 0 END) AS onn,
                            MAX(CASE WHEN domain = 'PARTY'   THEN 1 ELSE 0 END)                            AS pi,
                            MAX(CASE WHEN domain = 'ACCOUNT' THEN 1 ELSE 0 END)                            AS ai
                       FROM anon_meta.identity_plan
                      WHERE run_id = g_run_id
                      GROUP BY old_code)) s
         ON (p.run_id = g_run_id AND p.old_code = s.old_code)
       WHEN MATCHED THEN UPDATE SET p.parent_role = s.parent_role;
   END resolve_parent_roles;


   -- Each identity's three switches. Normally those of its category. When its
   -- one translation belongs to a different category - an earlier translation
   -- kept after the data changed - an operation runs only if BOTH categories
   -- allow it, so recategorising can never get round a switch that is off.
   PROCEDURE apply_switches IS
   BEGIN
      UPDATE anon_meta.identity_plan p
         SET id_on =
                CASE WHEN (SELECT s.id_on FROM anon_meta.anon_run_setting s
                            WHERE s.run_id = p.run_id AND s.category = p.category) = 'Y'
                      AND (   p.map_category IS NULL OR p.map_category = p.category
                           OR (SELECT s.id_on FROM anon_meta.anon_run_setting s
                                WHERE s.run_id = p.run_id AND s.category = p.map_category) = 'Y')
                     THEN 'Y' ELSE 'N' END,
             desc_on =
                CASE WHEN (SELECT s.desc_on FROM anon_meta.anon_run_setting s
                            WHERE s.run_id = p.run_id AND s.category = p.category) = 'Y'
                      AND (   p.map_category IS NULL OR p.map_category = p.category
                           OR (SELECT s.desc_on FROM anon_meta.anon_run_setting s
                                WHERE s.run_id = p.run_id AND s.category = p.map_category) = 'Y')
                     THEN 'Y' ELSE 'N' END,
             attr_on =
                CASE WHEN (SELECT s.attr_on FROM anon_meta.anon_run_setting s
                            WHERE s.run_id = p.run_id AND s.category = p.category) = 'Y'
                      AND (   p.map_category IS NULL OR p.map_category = p.category
                           OR (SELECT s.attr_on FROM anon_meta.anon_run_setting s
                                WHERE s.run_id = p.run_id AND s.category = p.map_category) = 'Y')
                     THEN 'Y' ELSE 'N' END
       WHERE p.run_id = g_run_id;
   END apply_switches;


   -- New translations, appended after every existing one of the same category.
   --
   -- A translation is needed when ANY of the identity's three switches is on -
   -- a label masked while the identifier stays original still needs a safe
   -- value. Existing rows are never renumbered or regenerated, so extending a
   -- map that already exists cannot move an identity to a different value. The
   -- order is the binary order of the original text, so the same data always
   -- gets the same numbers.
   PROCEDURE allocate_maps IS
      v_cats   t_names := categories;
      v_cat    VARCHAR2(30);
      v_prefix VARCHAR2(4);
      v_base   NUMBER;
      v_need   NUMBER;
      v_digits PLS_INTEGER := c_code_digits;
      v_limit  NUMBER := POWER(10, c_code_digits) - 1;
   BEGIN
      FOR i IN 1 .. v_cats.COUNT LOOP
         v_cat    := v_cats(i);
         v_prefix := prefix_of(v_cat);

         SELECT COUNT(*) INTO v_need
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id
            AND category = v_cat
            AND map_category IS NULL
            AND map_status IS NULL
            AND (id_on = 'Y' OR desc_on = 'Y' OR attr_on = 'Y');

         IF v_need > 0 THEN
            SELECT NVL(MAX(TO_NUMBER(SUBSTR(new_code, LENGTH(v_prefix) + 1))), 0)
              INTO v_base
              FROM anon_meta.code_map
             WHERE category = v_cat
               AND REGEXP_LIKE(new_code, '^' || v_prefix || '[0-9]{' || v_digits || '}$');

            IF v_base + v_need > v_limit THEN
               block(LOWER(v_cat) || ' mapping',
                     v_need || ' new ' || v_prefix || ' identifiers do not fit after the existing '
                  || v_base || ' in ' || v_digits || ' digits.', v_need);
            ELSE
               MERGE INTO anon_meta.identity_plan p
               USING (SELECT domain, old_code,
                             ROW_NUMBER() OVER (ORDER BY NLSSORT(old_code, 'NLS_SORT=BINARY')) AS rn
                        FROM anon_meta.identity_plan
                       WHERE run_id = g_run_id
                         AND category = v_cat
                         AND map_category IS NULL
                         AND map_status IS NULL
                         AND (id_on = 'Y' OR desc_on = 'Y' OR attr_on = 'Y')) s
                  ON (p.run_id = g_run_id AND p.domain = s.domain AND p.old_code = s.old_code)
                WHEN MATCHED THEN UPDATE SET
                     p.map_category = v_cat,
                     p.new_code     = v_prefix || LPAD(TO_CHAR(v_base + s.rn), v_digits, '0'),
                     p.map_status   = 'NEW';
            END IF;
         END IF;
      END LOOP;

      -- Everything left needs no translation this run: all three switches off
      -- and nothing to reuse.
      UPDATE anon_meta.identity_plan
         SET map_status = 'NONE'
       WHERE run_id = g_run_id
         AND map_status IS NULL;
   END allocate_maps;


   -- Everything that makes the plan unsafe stops the run before any target row
   -- changes. Everything that is merely unusual is reported.
   PROCEDURE validate_plan IS
      v_n NUMBER;
   BEGIN
      -- Original text that looks exactly like a generated replacement. Either
      -- the data was anonymized before without the mapping that would prove it,
      -- or a real code collides with the generated format. Both are unsafe:
      -- the first would translate a translation, the second would make an
      -- original indistinguishable from a replacement.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan p
       WHERE p.run_id = g_run_id
         AND p.identity_status = 'NEW'
         AND REGEXP_LIKE(p.old_code, '^(E|P|T|X|CB)_[0-9]{' || c_code_digits || '}$')
         AND NOT EXISTS (SELECT 1 FROM anon_meta.code_map c WHERE c.new_code = p.old_code);
      IF v_n > 0 THEN
         block('identity inventory',
               v_n || ' identifier(s) in tiers, compte_banque or structure look like generated '
            || 'replacements but no mapping owns them. This copy looks already anonymized without '
            || 'trustworthy provenance - reimport the raw data.', v_n);
      END IF;

      -- A replacement from code_map found where an original should be, and not
      -- one this domain's translations can explain: an account node holding a
      -- party's E_ value, a tiers row holding a CB_ value, or a translation
      -- from an earlier version whose roles cannot be trusted. Lookup logic
      -- cannot undo a substitution that has already happened.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan p
       WHERE p.run_id = g_run_id
         AND p.identity_status = 'NEW'
         AND EXISTS (SELECT 1 FROM anon_meta.code_map c WHERE c.new_code = p.old_code);
      IF v_n > 0 THEN
         block('mapping history',
               v_n || ' master or structure row(s) already hold a replacement value that is not '
            || 'their own domain''s translation. This copy was anonymized before with incompatible '
            || 'mappings. Reimport the raw data; a repair in place needs a reviewed migration.', v_n);
      END IF;

      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND map_status = 'CONFLICT';
      IF v_n > 0 THEN
         block('mapping history',
               v_n || ' party identit(ies) have two or more earlier translations in code_map and '
            || 'none matches their category now. One party must have exactly one translation; '
            || 'choosing one would silently change values already written.', v_n);
      END IF;

      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND map_status = 'MISSING';
      IF v_n > 0 THEN
         block('mapping history',
               v_n || ' recorded identit(ies) point at a translation that is no longer in '
            || 'code_map. Their provenance is lost.', v_n);
      END IF;

      -- Account nodes with no account master: a deliberate extension of the
      -- account population, which has to be approved for this client.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id
         AND identity_status = 'NEW'
         AND domain = 'ACCOUNT'
         AND membership = 'STRUCTURE_ONLY';
      IF v_n > 0 AND NOT g_approve_structure_only THEN
         block('account scope',
               v_n || ' Compte/w_compte_banque structure node(s) have no compte_banque row. Confirm '
            || 'that these nodes are bank-account identities for this client, then set '
            || 'APPROVE_STRUCTURE_ONLY_ACCOUNTS=y. Scope review needed before any update.', v_n);
      END IF;

      -- Every replacement - kept or new - must be unique, and must not equal
      -- any original. Either failure would let one value mean two things.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan p
       WHERE p.run_id = g_run_id
         AND p.map_status = 'NEW'
         AND EXISTS (SELECT 1 FROM anon_meta.code_map c WHERE c.new_code = p.new_code);
      IF v_n > 0 THEN
         block('mapping', v_n || ' planned replacement(s) already exist in code_map.', v_n);
      END IF;

      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan p
       WHERE p.run_id = g_run_id
         AND p.new_code IS NOT NULL
         AND EXISTS (SELECT 1 FROM anon_meta.identity_plan q
                      WHERE q.run_id = g_run_id AND q.old_code = p.new_code);
      IF v_n > 0 THEN
         block('mapping', v_n || ' replacement(s) equal an original identifier.', v_n);
      END IF;

      -- Every identity that needs a translation has exactly one, of its own
      -- domain. Guaranteed by construction; checked because the consequence of
      -- being wrong is a silent leak.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id
         AND (id_on = 'Y' OR desc_on = 'Y' OR attr_on = 'Y')
         AND (   new_code IS NULL
              OR (domain = 'ACCOUNT' AND map_category <> 'BANK_ACCOUNT')
              OR (domain = 'PARTY'   AND map_category NOT IN ('ENTITY', 'PORTFOLIO',
                                                              'COUNTERPARTY', 'UNCLASSIFIED_PARTY')))
         AND map_status NOT IN ('CONFLICT', 'MISSING');
      IF v_n > 0 THEN
         block('mapping', v_n || ' identit(ies) needing a translation have none of their own domain.', v_n);
      END IF;
   END validate_plan;


   -- Counts only: never an identifier.
   PROCEDURE report_plan IS
      v_cats    t_names := categories;
      v_cat     VARCHAR2(30);
      v_total   NUMBER;
      v_new     NUMBER;
      v_known   NUMBER;
      v_n       NUMBER;
      v_line    VARCHAR2(400);
      v_db      VARCHAR2(400);
      v_created VARCHAR2(30);
      v_t       NUMBER;
      v_s       NUMBER;
      v_b       NUMBER;
   BEGIN
      say('    Identities');

      -- Bank accounts, by where they were found.
      SELECT COUNT(*),
             COUNT(CASE WHEN identity_status = 'NEW' THEN 1 END)
        INTO v_total, v_new
        FROM anon_meta.identity_plan WHERE run_id = g_run_id AND domain = 'ACCOUNT';

      SELECT LISTAGG(LOWER(REPLACE(membership, '_', ' ')) || ' ' || TO_CHAR(cnt, 'FM999,999,999'), ' . ')
                WITHIN GROUP (ORDER BY DECODE(membership, 'MASTER_ONLY', 1, 'BOTH', 2,
                                              'STRUCTURE_ONLY', 3, 4))
        INTO v_line
        FROM (SELECT membership, COUNT(*) AS cnt
                FROM anon_meta.identity_plan
               WHERE run_id = g_run_id AND domain = 'ACCOUNT'
               GROUP BY membership);
      say('      bank accounts ............. ' || RPAD(n(v_total), 10) || NVL(v_line, '-'));
      log_step('PREFLIGHT', 'identities: bank accounts', NULL, 'OK', v_total, NULL,
               'membership: ' || NVL(v_line, 'none'));

      -- Parties, by category.
      SELECT COUNT(*) INTO v_total
        FROM anon_meta.identity_plan WHERE run_id = g_run_id AND domain = 'PARTY';
      say('      parties ................... ' || n(v_total));
      FOR i IN 1 .. v_cats.COUNT LOOP
         v_cat := v_cats(i);
         CONTINUE WHEN v_cat = 'BANK_ACCOUNT';
         SELECT COUNT(*) INTO v_n
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id AND domain = 'PARTY' AND category = v_cat;
         v_line := NULL;
         IF v_cats(i) = 'UNCLASSIFIED_PARTY' THEN
            SELECT LISTAGG(LOWER(REPLACE(x_reason, '_', ' ')) || ' ' || TO_CHAR(cnt, 'FM999,999,999'), ' . ')
                      WITHIN GROUP (ORDER BY x_reason)
              INTO v_line
              FROM (SELECT x_reason, COUNT(*) AS cnt
                      FROM anon_meta.identity_plan
                     WHERE run_id = g_run_id AND category = 'UNCLASSIFIED_PARTY'
                     GROUP BY x_reason);
         END IF;
         say('        ' || RPAD(LOWER(label_of(v_cats(i))) || ' (' || prefix_of(v_cats(i)) || ') ', 24, '.')
             || ' ' || RPAD(n(v_n), 10) || v_line);
         log_step('PREFLIGHT', 'identities: ' || LOWER(v_cats(i)), NULL, 'OK', v_n, NULL, v_line);
      END LOOP;

      SELECT COUNT(*) INTO v_n
        FROM (SELECT old_code FROM anon_meta.identity_plan WHERE run_id = g_run_id
               GROUP BY old_code HAVING COUNT(DISTINCT domain) = 2);
      say('      same text, party AND account ' || n(v_n)
          || CASE WHEN v_n > 0 THEN '   (each keeps its own translation)' END);

      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan WHERE run_id = g_run_id AND entity_overlap = 'Y';
      say('      entity precedence applied . ' || n(v_n)
          || CASE WHEN v_n > 0 THEN '   (flag N with Entite and other w_tiers nodes: E_ only)' END);
      IF v_n > 0 THEN
         log_step('PREFLIGHT', 'identities: entity precedence', NULL, 'OK', v_n, NULL,
                  'flag N parties with both Entite and other w_tiers nodes, given one ENTITY translation');
      END IF;

      SELECT COUNT(CASE WHEN identity_status = 'NEW' THEN 1 END),
             COUNT(CASE WHEN identity_status = 'KNOWN' THEN 1 END)
        INTO v_new, v_known
        FROM anon_meta.identity_plan WHERE run_id = g_run_id;
      say('      found this run ............ ' || n(v_new)
          || '   already recorded ' || n(v_known));

      -- Drift: the recorded category is kept - a replacement already written
      -- does not change silently - but someone has to look at why.
      SELECT COUNT(*) INTO v_n
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id
         AND (   (identity_status = 'KNOWN' AND class_now IS NOT NULL AND class_now <> category)
              OR (map_category IS NOT NULL AND map_category <> category));
      IF v_n > 0 THEN
         say('      REVIEW  ' || n(v_n) || ' identit(ies) would be classified differently today than');
         say('              their recorded translation. The recorded one is kept.');
         log_step('PREFLIGHT', 'identities: classification drift', NULL, 'REVIEW', v_n, NULL,
                  'recorded translation kept; master data changed since it was made, or an earlier '
               || 'translation of another category was reused');
      END IF;

      say('');
      say('    Translations');
      FOR i IN 1 .. v_cats.COUNT LOOP
         v_cat := v_cats(i);
         SELECT COUNT(CASE WHEN map_status = 'EXISTING' THEN 1 END),
                COUNT(CASE WHEN map_status = 'NEW' THEN 1 END),
                COUNT(CASE WHEN map_status = 'NONE' THEN 1 END)
           INTO v_known, v_new, v_n
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id
            AND NVL(map_category, category) = v_cat;
         say('      ' || RPAD(LOWER(label_of(v_cats(i))) || ' ', 28, '.') || ' reused ' || RPAD(n(v_known), 9)
             || CASE WHEN g_dry_run THEN 'would add ' ELSE 'to add ' END || RPAD(n(v_new), 9)
             || CASE WHEN v_n > 0 THEN 'not needed ' || n(v_n) END);
      END LOOP;

      SELECT NVL(SUM(superseded_maps), 0) INTO v_n
        FROM anon_meta.identity_plan WHERE run_id = g_run_id;
      IF v_n > 0 THEN
         say('      earlier translations superseded ' || n(v_n) || '   (kept in code_map, never used)');
         log_step('PREFLIGHT', 'mapping: superseded', NULL, 'REVIEW', v_n, NULL,
                  'earlier translations of an identity that are not its one translation');
      END IF;
      say('');

      -- The dataset, as counts, so the run record says what it ran against.
      SELECT MAX(TO_CHAR(created, 'YYYY-MM-DD HH24:MI:SS')) INTO v_created
        FROM all_users WHERE username = 'OP';
      EXECUTE IMMEDIATE 'SELECT (SELECT COUNT(*) FROM op.tiers), (SELECT COUNT(*) FROM op.structure), '
                     || '(SELECT COUNT(*) FROM op.compte_banque) FROM dual' INTO v_t, v_s, v_b;
      SELECT COUNT(CASE WHEN domain = 'PARTY' THEN 1 END),
             COUNT(CASE WHEN domain = 'ACCOUNT' THEN 1 END),
             COUNT(CASE WHEN identity_status = 'NEW' THEN 1 END)
        INTO v_total, v_n, v_new
        FROM anon_meta.identity_plan WHERE run_id = g_run_id;
      v_db := '{"db":"' || SYS_CONTEXT('USERENV', 'DB_NAME') || '","op_created":"' || v_created
           || '","tiers":' || v_t || ',"structure":' || v_s || ',"compte_banque":' || v_b
           || ',"party_identities":' || v_total || ',"account_identities":' || v_n
           || ',"new_identities":' || v_new || '}';
      UPDATE anon_meta.anon_run SET dataset_json = v_db WHERE run_id = g_run_id;
      COMMIT;
   END report_plan;


   PROCEDURE build_plan IS
      v_missing VARCHAR2(400);
   BEGIN
      -- The identity sources. Everything else in the engine tolerates a missing
      -- object, but if the schema cannot even describe its own parties and
      -- accounts there is nothing to anonymize - so say which piece is absent
      -- rather than letting a raw ORA-00942 surface from a dynamic statement.
      IF NOT column_exists('structure', 'code')          THEN v_missing := v_missing || ' structure.code';          END IF;
      IF NOT column_exists('structure', 'structure')     THEN v_missing := v_missing || ' structure.structure';     END IF;
      IF NOT column_exists('structure', 'ecran')         THEN v_missing := v_missing || ' structure.ecran';         END IF;
      IF NOT column_exists('tiers', 'code')              THEN v_missing := v_missing || ' tiers.code';              END IF;
      IF NOT column_exists('tiers', 'flag_portefeuille') THEN v_missing := v_missing || ' tiers.flag_portefeuille'; END IF;
      IF NOT column_exists('compte_banque', 'code')      THEN v_missing := v_missing || ' compte_banque.code';      END IF;

      IF v_missing IS NOT NULL THEN
         RAISE_APPLICATION_ERROR(-20013,
            'The core entity tables are not shaped as expected on this instance. Missing:'
         || v_missing || '. Identifiers are derived from these, so nothing can be mapped. '
         || 'Nothing has been changed.');
      END IF;

      -- Keep this run's plan, and the plan of the latest completed EXECUTE run -
      -- the verifier checks the data against that one.
      DELETE FROM anon_meta.identity_plan
       WHERE run_id = g_run_id
          OR run_id <> NVL((SELECT MAX(run_id) FROM anon_meta.anon_run
                             WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED'), -1);
      COMMIT;

      capture_identities;
      adopt_existing_maps;
      resolve_parent_roles;
      apply_switches;
      allocate_maps;
      COMMIT;

      validate_plan;
      report_plan;
   END build_plan;


   PROCEDURE preflight IS
      v_missing PLS_INTEGER;
   BEGIN
      say('  --- Preflight -------------------------------------------------');
      g_blocking := 0;

      check_inventory(v_missing);
      build_plan;

      IF g_blocking > 0 THEN
         RAISE_APPLICATION_ERROR(-20011,
            g_blocking || ' preflight finding(s) make this run unsafe. Nothing has been changed. '
         || 'The list is in anon_meta.anon_step_log: '
         || 'SELECT object_name, message FROM anon_meta.anon_step_log '
         || 'WHERE run_id = ' || g_run_id || ' AND status = ''ERROR'';');
      END IF;

      IF g_fail_on_missing AND v_missing > 0 THEN
         RAISE_APPLICATION_ERROR(-20012,
            v_missing || ' inventory item(s) do not exist on this '
         || 'instance and FAIL_ON_MISSING_OBJECT=y. Nothing has been changed.');
      END IF;
   END preflight;


   -- =========================================================================
   -- Mapping persistence and lookups
   -- =========================================================================

   -- The typed lookups the apply phase reads. Built from the plan in both
   -- modes, so a dry run estimates exactly what an EXECUTE run would do.
   PROCEDURE build_lookups IS
   BEGIN
      DELETE FROM anon_meta.code_lookup;

      -- One lookup per domain. A party column never sees an account's
      -- translation, and an account column never sees a party's.
      INSERT INTO anon_meta.code_lookup (domain, old_code, new_code)
      SELECT domain, old_code, new_code
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND id_on = 'Y' AND new_code IS NOT NULL;

      -- MIXED: a value known in exactly one domain takes that domain's
      -- translation. A value known in both is AMBIGUOUS - left as it is and
      -- reported, never guessed.
      INSERT INTO anon_meta.code_lookup (domain, old_code, new_code)
      SELECT 'MIXED', p.old_code, p.new_code
        FROM anon_meta.identity_plan p
       WHERE p.run_id = g_run_id AND p.id_on = 'Y' AND p.new_code IS NOT NULL
         AND NOT EXISTS (SELECT 1 FROM anon_meta.identity_plan q
                          WHERE q.run_id = g_run_id AND q.old_code = p.old_code
                            AND q.domain <> p.domain);

      INSERT INTO anon_meta.code_lookup (domain, old_code, new_code)
      SELECT 'AMBIGUOUS', old_code, NULL
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id
       GROUP BY old_code
      HAVING COUNT(DISTINCT domain) = 2;

      -- structure.pere: the translation of the domain its parent role names.
      INSERT INTO anon_meta.code_lookup (domain, old_code, new_code)
      SELECT 'PERE', old_code, new_code
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND parent_role = domain
         AND id_on = 'Y' AND new_code IS NOT NULL;

      INSERT INTO anon_meta.code_lookup (domain, old_code, new_code)
      SELECT DISTINCT 'PERE_REVIEW', old_code, NULL
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND parent_role IN ('AMBIGUOUS', 'OTHER');

      -- Owner keys for DESCRIPTION and SELF_CODE: the original and the
      -- replacement both lead to the same identity and its one safe value.
      DELETE FROM anon_meta.owner_key;
      INSERT INTO anon_meta.owner_key (domain, key_code, new_code, category, desc_on, attr_on)
      SELECT domain, old_code, new_code, category, desc_on, attr_on
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND new_code IS NOT NULL AND (desc_on = 'Y' OR attr_on = 'Y')
      UNION ALL
      SELECT domain, new_code, new_code, category, desc_on, attr_on
        FROM anon_meta.identity_plan
       WHERE run_id = g_run_id AND new_code IS NOT NULL AND (desc_on = 'Y' OR attr_on = 'Y');

      COMMIT;
   END build_lookups;


   PROCEDURE generate_code_map IS
      v_cats    t_names := categories;
      v_cat     VARCHAR2(30);
      v_reused  NUMBER;
      v_new     NUMBER;
      v_unused  NUMBER;
      v_start   NUMBER;
   BEGIN
      say('  --- Identifier mapping ----------------------------------------');

      FOR i IN 1 .. v_cats.COUNT LOOP
         v_cat   := v_cats(i);
         v_start := DBMS_UTILITY.GET_TIME;

         SELECT COUNT(CASE WHEN map_status = 'EXISTING' THEN 1 END),
                COUNT(CASE WHEN map_status = 'NEW' THEN 1 END),
                COUNT(CASE WHEN new_code IS NOT NULL AND id_on = 'N' AND desc_on = 'N'
                            AND attr_on = 'N' THEN 1 END)
           INTO v_reused, v_new, v_unused
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id AND map_category = v_cat;

         IF g_id(v_cats(i)) = 'N' AND g_desc(v_cats(i)) = 'N' AND g_attr(v_cats(i)) = 'N' THEN
            -- No new translation for a category with every switch off. One
            -- that already exists stays in code_map, unused by this run.
            log_step('MAPPING', v_cats(i), 'CODE', 'DISABLED', NULL, NULL,
                     CASE WHEN v_unused > 0 THEN v_unused || ' existing translation(s) kept, unused' END);
            report(v_cats(i), 'DISABLED');
         ELSIF g_dry_run THEN
            log_step('MAPPING', v_cats(i), 'CODE', 'DRYRUN', v_new, elapsed_ms(v_start),
                     v_reused || ' existing translation(s) reused');
            say('    ' || RPAD(v_cats(i), 54) || RPAD('DRYRUN', 10) || n(v_reused) || ' reused, '
                || n(v_new) || ' would be added');
         ELSE
            log_step('MAPPING', v_cats(i), 'CODE', CASE WHEN v_new > 0 THEN 'OK' ELSE 'NOOP' END,
                     v_new, elapsed_ms(v_start), v_reused || ' existing translation(s) reused');
            say('    ' || RPAD(v_cats(i), 54) || RPAD(CASE WHEN v_new > 0 THEN 'OK' ELSE 'REUSED' END, 10)
                || n(v_reused) || ' reused, ' || n(v_new) || ' added');
         END IF;
      END LOOP;

      IF NOT g_dry_run THEN
         -- Persist before anything is changed. New identities are recorded with
         -- the category and reason they were captured with, new translations
         -- are appended, and an identity recorded earlier without a translation
         -- gets the one allocated now.
         INSERT INTO anon_meta.identity_inventory
                (domain, old_code, category, x_reason, membership, map_category, first_run_id)
         SELECT domain, old_code, category, x_reason, membership, map_category, run_id
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id AND identity_status = 'NEW';

         INSERT INTO anon_meta.code_map (category, old_code, new_code, run_id)
         SELECT map_category, old_code, new_code, run_id
           FROM anon_meta.identity_plan
          WHERE run_id = g_run_id AND map_status = 'NEW';

         MERGE INTO anon_meta.identity_inventory i
         USING (SELECT domain, old_code, map_category
                  FROM anon_meta.identity_plan
                 WHERE run_id = g_run_id AND identity_status = 'KNOWN' AND map_status = 'NEW') s
            ON (i.domain = s.domain AND i.old_code = s.old_code)
          WHEN MATCHED THEN UPDATE SET i.map_category = s.map_category
                                 WHERE i.map_category IS NULL;
         COMMIT;
      END IF;

      build_lookups;
      say('');
   END generate_code_map;


   -- =========================================================================
   -- Applying the inventory
   -- =========================================================================

   -- One typed lookup over one column, optionally limited to the rows of one
   -- role. The lookup domain is the ONLY source of replacements: there is no
   -- fallback to another domain when this one has no translation.
   PROCEDURE apply_lookup(
      p_table   IN VARCHAR2,
      p_column  IN VARCHAR2,
      p_lookup  IN VARCHAR2,
      p_filter  IN VARCHAR2,
      p_object  IN VARCHAR2,
      p_enabled IN BOOLEAN)
   IS
      v_start NUMBER := DBMS_UTILITY.GET_TIME;
      v_where VARCHAR2(4000);
      v_rows  NUMBER;
   BEGIN
      IF NOT p_enabled THEN
         log_step('CODE', p_object, 'CODE', 'DISABLED', NULL, NULL,
                  'identifier renaming is off for every category this column can hold');
         report(p_object, 'DISABLED');
         RETURN;
      END IF;

      v_where := 't.' || p_column || ' IN (SELECT l.old_code FROM anon_meta.code_lookup l'
              || ' WHERE l.domain = ''' || p_lookup || ''')'
              || CASE WHEN p_filter IS NOT NULL THEN ' AND ' || p_filter END;

      IF g_dry_run THEN
         EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM op.' || p_table || ' t WHERE ' || v_where INTO v_rows;
         log_step('CODE', p_object, 'CODE', 'DRYRUN', v_rows, elapsed_ms(v_start));
         report(p_object, 'DRYRUN', v_rows);
         RETURN;
      END IF;

      -- A correlated UPDATE rather than a MERGE: MERGE cannot update a column
      -- that appears in its ON clause (ORA-38104).
      EXECUTE IMMEDIATE
         'UPDATE ' || parallel_hint(p_table) || 'op.' || p_table || ' t '
      || '   SET t.' || p_column || ' = (SELECT l.new_code FROM anon_meta.code_lookup l'
      || '                                WHERE l.domain = ''' || p_lookup || ''''
      || '                                  AND l.old_code = t.' || p_column || ') '
      || ' WHERE ' || v_where;
      v_rows := SQL%ROWCOUNT;
      COMMIT;

      log_step('CODE', p_object, 'CODE',
               CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows, elapsed_ms(v_start));
      report(p_object, CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows);

   EXCEPTION
      WHEN OTHERS THEN
         log_step('CODE', p_object, 'CODE', 'ERROR', NULL, elapsed_ms(v_start), SQLERRM);
         say('    ERROR on ' || p_object || ': ' || SQLERRM);
         RAISE;
   END apply_lookup;


   -- Rows deliberately left unchanged because their role or domain cannot be
   -- established. Counted in both modes and logged REVIEW: they are client
   -- values still in place, and the verifier will not report a PASS while
   -- they remain.
   PROCEDURE count_review(
      p_table   IN VARCHAR2,
      p_column  IN VARCHAR2,
      p_set     IN VARCHAR2,
      p_filter  IN VARCHAR2,
      p_object  IN VARCHAR2,
      p_message IN VARCHAR2)
   IS
      v_rows NUMBER;
   BEGIN
      EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM op.' || p_table || ' t WHERE t.' || p_column
                     || ' IN (' || p_set || ')'
                     || CASE WHEN p_filter IS NOT NULL THEN ' AND ' || p_filter END
         INTO v_rows;

      IF v_rows > 0 THEN
         log_step('CODE', p_object, 'CODE', 'REVIEW', v_rows, NULL, p_message);
         report(p_object, 'REVIEW', v_rows);
      END IF;
   END count_review;


   -- One CODE column, by its domain.
   PROCEDURE apply_code(p_table IN VARCHAR2, p_column IN VARCHAR2, p_category IN VARCHAR2) IS
      v_object   VARCHAR2(300) := LOWER(p_table) || '.' || LOWER(p_column);
      c_account  CONSTANT VARCHAR2(100) := 't.structure = ''Compte'' AND t.ecran = ''w_compte_banque''';
      c_party    CONSTANT VARCHAR2(100) := 't.ecran = ''w_tiers''';
      c_other    CONSTANT VARCHAR2(200) := 'NOT (NVL(t.structure, ''~'') = ''Compte'' AND '
                                        || 'NVL(t.ecran, ''~'') = ''w_compte_banque'') '
                                        || 'AND NVL(t.ecran, ''~'') <> ''w_tiers''';
   BEGIN
      IF NOT column_exists(p_table, p_column) THEN
         log_step('CODE', v_object, 'CODE', 'SKIPPED', NULL, NULL, 'object not found');
         report(v_object, 'SKIPPED');
         RETURN;
      END IF;

      IF p_category = 'PARTY' THEN
         apply_lookup(p_table, p_column, 'PARTY', NULL, v_object, any_on(g_id, party_categories));

      ELSIF p_category = 'BANK_ACCOUNT' THEN
         apply_lookup(p_table, p_column, 'ACCOUNT', NULL, v_object, g_id('BANK_ACCOUNT') = 'Y');

      ELSIF p_category = 'MIXED' THEN
         apply_lookup(p_table, p_column, 'MIXED', NULL, v_object, any_on(g_id, categories));
         count_review(p_table, p_column,
                      'SELECT l.old_code FROM anon_meta.code_lookup l WHERE l.domain = ''AMBIGUOUS''',
                      NULL, v_object || ' [party AND account]',
                      'values that are both a party and a bank-account identifier - left unchanged; '
                   || 'a reviewed decision on what this column holds is needed');

      ELSIF p_category = 'NODE_ROLE' AND UPPER(p_table) = 'STRUCTURE' AND UPPER(p_column) = 'CODE' THEN
         -- A structure node is a party node or an account node by its screen,
         -- never by its text. The two predicates are disjoint, so no row can be
         -- rewritten by both - processing order is not what keeps them apart.
         apply_lookup(p_table, p_column, 'ACCOUNT', c_account, v_object || ' [account nodes]',
                      g_id('BANK_ACCOUNT') = 'Y');
         apply_lookup(p_table, p_column, 'PARTY', c_party, v_object || ' [party nodes]',
                      any_on(g_id, party_categories));
         count_review(p_table, p_column,
                      'SELECT p.old_code FROM anon_meta.identity_plan p WHERE p.run_id = '
                   || g_run_id, c_other, v_object || ' [other screens]',
                      'nodes on other screens whose code is a client identifier - left unchanged; '
                   || 'their role needs a reviewed decision');

      ELSIF p_category = 'NODE_ROLE' AND UPPER(p_table) = 'STRUCTURE' AND UPPER(p_column) = 'PERE' THEN
         -- The parent's own typed translation - never the child's domain.
         apply_lookup(p_table, p_column, 'PERE', NULL, v_object, any_on(g_id, categories));
         count_review(p_table, p_column,
                      'SELECT l.old_code FROM anon_meta.code_lookup l WHERE l.domain = ''PERE_REVIEW''',
                      NULL, v_object || ' [parent role unresolved]',
                      'parents whose text is a party and an account node, or a node on another '
                   || 'screen - left unchanged; the intended parent needs review');

      ELSE
         RAISE_APPLICATION_ERROR(-20015,
            v_object || ': category ' || p_category || ' is not valid for a CODE rule. '
         || '21_validate_inventory.sql should have stopped this.');
      END IF;
   END apply_code;


   -- All NULL_OUT columns of one table, in a single statement.
   --
   -- Grouping matters: histo_reglement has four such columns and is one of the
   -- largest tables in the schema. Four separate statements would mean four
   -- full scans.
   PROCEDURE apply_null_out(p_table IN VARCHAR2) IS
      v_start    NUMBER := DBMS_UTILITY.GET_TIME;
      v_set      VARCHAR2(4000);
      v_where    VARCHAR2(4000);
      v_cols     VARCHAR2(1000);
      v_sql      VARCHAR2(8000);
      v_rows     NUMBER;
      v_present  PLS_INTEGER := 0;
      v_object   VARCHAR2(300);
      v_nullable VARCHAR2(1);
      v_type     VARCHAR2(30);
      v_width    PLS_INTEGER;
      v_mask     VARCHAR2(30);
   BEGIN
      IF NOT table_exists(p_table) THEN
         FOR r IN (SELECT column_name FROM anon_meta.anon_inventory
                    WHERE table_name = p_table AND rule = 'NULL_OUT') LOOP
            log_step('NULL_OUT', LOWER(p_table) || '.' || LOWER(r.column_name), 'NULL_OUT',
                     'SKIPPED', NULL, NULL, 'table not found');
         END LOOP;
         report(LOWER(p_table) || '.*', 'SKIPPED');
         RETURN;
      END IF;

      FOR r IN (SELECT column_name FROM anon_meta.anon_inventory
                 WHERE table_name = p_table AND rule = 'NULL_OUT'
                 ORDER BY seq) LOOP

         IF NOT column_exists(p_table, r.column_name) THEN
            log_step('NULL_OUT', LOWER(p_table) || '.' || LOWER(r.column_name), 'NULL_OUT',
                     'SKIPPED', NULL, NULL, 'column not found');
            CONTINUE;
         END IF;

         SELECT MAX(nullable), MAX(data_type), MAX(char_length)
           INTO v_nullable, v_type, v_width
           FROM all_tab_columns
          WHERE owner = 'OP'
            AND table_name  = UPPER(p_table)
            AND column_name = UPPER(r.column_name);

         IF v_nullable = 'N' THEN
            -- Cannot be emptied - SET ... = NULL would raise ORA-01407 and take
            -- the run with it. Overwrite with a marker instead: the client data
            -- is still removed, and the constraint is still satisfied.
            --
            -- A NOT NULL column that is not character-typed has no marker.
            -- Preflight refuses to start on one, so reaching it here means the
            -- preflight was bypassed: fail rather than skip it quietly.
            IF v_type NOT IN ('VARCHAR2', 'CHAR', 'NVARCHAR2', 'NCHAR') THEN
               RAISE_APPLICATION_ERROR(-20017,
                  LOWER(p_table) || '.' || LOWER(r.column_name) || ' is NOT NULL ' || v_type
               || ' and can be neither emptied nor masked.');
            END IF;

            v_mask := SUBSTR(c_mask_text, 1, v_width);
            v_present := v_present + 1;
            v_set   := v_set   || CASE WHEN v_set   IS NULL THEN '' ELSE ', ' END
                               || r.column_name || ' = ''' || v_mask || '''';
            -- Excluding rows already masked keeps a re-run a no-op.
            v_where := v_where || CASE WHEN v_where IS NULL THEN '' ELSE ' OR ' END
                               || r.column_name || ' <> ''' || v_mask || '''';
            v_cols  := v_cols  || CASE WHEN v_cols  IS NULL THEN '' ELSE ',' END
                               || LOWER(r.column_name) || '(masked)';
            CONTINUE;
         END IF;

         v_present := v_present + 1;
         v_set   := v_set   || CASE WHEN v_set   IS NULL THEN '' ELSE ', ' END
                            || r.column_name || ' = NULL';
         v_where := v_where || CASE WHEN v_where IS NULL THEN '' ELSE ' OR ' END
                            || r.column_name || ' IS NOT NULL';
         v_cols  := v_cols  || CASE WHEN v_cols  IS NULL THEN '' ELSE ',' END
                            || LOWER(r.column_name);
      END LOOP;

      IF v_present = 0 THEN
         RETURN;
      END IF;

      v_object := LOWER(p_table) || '.[' || v_cols || ']';

      IF g_dry_run THEN
         EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM op.' || p_table || ' WHERE ' || v_where INTO v_rows;
         log_step('NULL_OUT', v_object, 'NULL_OUT', 'DRYRUN', v_rows, elapsed_ms(v_start));
         report(v_object, 'DRYRUN', v_rows);
         RETURN;
      END IF;

      v_sql := 'UPDATE ' || parallel_hint(p_table) || 'op.' || p_table
            || ' SET ' || v_set || ' WHERE ' || v_where;

      EXECUTE IMMEDIATE v_sql;
      v_rows := SQL%ROWCOUNT;
      COMMIT;

      log_step('NULL_OUT', v_object, 'NULL_OUT',
               CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows, elapsed_ms(v_start));
      report(v_object, CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows);

   EXCEPTION
      WHEN OTHERS THEN
         log_step('NULL_OUT', v_object, 'NULL_OUT', 'ERROR', NULL, elapsed_ms(v_start), SQLERRM);
         say('    ERROR on ' || v_object || ': ' || SQLERRM);
         RAISE;
   END apply_null_out;


   -- DESCRIPTION and SELF_CODE columns of one table sharing one category, for
   -- the owners of one domain, in a single statement.
   --
   -- Both rules write the OWNING IDENTITY'S mapped value - never the row's own
   -- code column. That matters when renaming is off for the category: the code
   -- column then still holds the original, and copying it into a label would
   -- be no mask at all. The owner is found through owner_key, which knows the
   -- identity by its original and by its replacement, so this works whether or
   -- not the identifier phase renamed the row.
   --
   --   SELF_CODE   each field keeps its NULL. An empty phone number is not
   --               client data, and a populated sibling must not fill it in -
   --               the old grouped statement did exactly that.
   --   DESCRIPTION a label: set even when empty, so a screen shows the safe
   --               value rather than a blank.
   PROCEDURE merge_owned(
      p_table    IN VARCHAR2,
      p_rule     IN VARCHAR2,
      p_columns  IN t_names,
      p_domain   IN VARCHAR2,
      p_category IN VARCHAR2,
      p_filter   IN VARCHAR2,
      p_object   IN VARCHAR2)
   IS
      v_start  NUMBER := DBMS_UTILITY.GET_TIME;
      v_switch VARCHAR2(10) := CASE p_rule WHEN 'SELF_CODE' THEN 'attr_on' ELSE 'desc_on' END;
      v_set    VARCHAR2(4000);
      v_change VARCHAR2(4000);
      v_join   VARCHAR2(2000);
      v_rows   NUMBER;
   BEGIN
      FOR i IN 1 .. p_columns.COUNT LOOP
         IF p_rule = 'SELF_CODE' THEN
            v_set := v_set || CASE WHEN v_set IS NULL THEN '' ELSE ', ' END
                  || 't.' || p_columns(i) || ' = CASE WHEN t.' || p_columns(i)
                  || ' IS NOT NULL THEN s.new_code END';
            v_change := v_change || CASE WHEN v_change IS NULL THEN '' ELSE ' OR ' END
                     || '(t.' || p_columns(i) || ' IS NOT NULL AND t.' || p_columns(i) || ' <> s.new_code)';
         ELSE
            v_set := v_set || CASE WHEN v_set IS NULL THEN '' ELSE ', ' END
                  || 't.' || p_columns(i) || ' = s.new_code';
            v_change := v_change || CASE WHEN v_change IS NULL THEN '' ELSE ' OR ' END
                     || '(t.' || p_columns(i) || ' IS NULL OR t.' || p_columns(i) || ' <> s.new_code)';
         END IF;
      END LOOP;

      v_join := ' FROM op.' || p_table || ' t'
             || ' JOIN anon_meta.owner_key k ON k.domain = ''' || p_domain || ''''
             || ' AND k.key_code = t.code AND k.' || v_switch || ' = ''Y'''
             || CASE WHEN p_category IS NOT NULL THEN ' AND k.category = ''' || p_category || '''' END
             || CASE WHEN p_filter IS NOT NULL THEN ' WHERE ' || p_filter END;

      IF g_dry_run THEN
         EXECUTE IMMEDIATE 'SELECT COUNT(*)' || v_join
                        || CASE WHEN p_filter IS NOT NULL THEN ' AND (' ELSE ' WHERE (' END
                        || REPLACE(v_change, 's.new_code', 'k.new_code') || ')'
            INTO v_rows;
         log_step(p_rule, p_object, p_rule, 'DRYRUN', v_rows, elapsed_ms(v_start));
         report(p_object, 'DRYRUN', v_rows);
         RETURN;
      END IF;

      EXECUTE IMMEDIATE
         'MERGE INTO op.' || p_table || ' t'
      || ' USING (SELECT t.ROWID AS rid, k.new_code' || v_join || ') s'
      || '    ON (t.ROWID = s.rid)'
      || '  WHEN MATCHED THEN UPDATE SET ' || v_set
      || '       WHERE ' || v_change;
      v_rows := SQL%ROWCOUNT;
      COMMIT;

      log_step(p_rule, p_object, p_rule,
               CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows, elapsed_ms(v_start));
      report(p_object, CASE WHEN v_rows > 0 THEN 'OK' ELSE 'NOOP' END, v_rows);

   EXCEPTION
      WHEN OTHERS THEN
         log_step(p_rule, p_object, p_rule, 'ERROR', NULL, elapsed_ms(v_start), SQLERRM);
         say('    ERROR on ' || p_object || ': ' || SQLERRM);
         RAISE;
   END merge_owned;


   PROCEDURE apply_self_code(
      p_table    IN VARCHAR2,
      p_category IN VARCHAR2,
      p_rule     IN VARCHAR2)
   IS
      v_object   VARCHAR2(300);
      v_columns  t_names := t_names();
      v_names    VARCHAR2(1000);
      v_switches t_flags;
      c_account  CONSTANT VARCHAR2(100) := 't.structure = ''Compte'' AND t.ecran = ''w_compte_banque''';
      c_party    CONSTANT VARCHAR2(100) := 't.ecran = ''w_tiers''';
   BEGIN
      v_object := LOWER(p_table) || '.[' || LOWER(p_rule) || '/' || LOWER(p_category) || ']';

      IF NOT table_exists(p_table) OR NOT column_exists(p_table, 'code') THEN
         log_step(p_rule, v_object, p_rule, 'SKIPPED', NULL, NULL,
                  'table or its code column not found');
         report(v_object, 'SKIPPED');
         RETURN;
      END IF;

      -- DESCRIPTION and SELF_CODE are gated by their own switches - labels by
      -- _DESCRIPTION, attributes and addresses by _ATTRIBUTES - and neither
      -- depends on whether identifiers are renamed.
      IF p_rule = 'SELF_CODE' THEN
         v_switches := g_attr;
      ELSE
         v_switches := g_desc;
      END IF;

      IF NOT any_on(v_switches, categories_of(p_category)) THEN
         log_step(p_rule, v_object, p_rule, 'DISABLED');
         report(v_object, 'DISABLED');
         RETURN;
      END IF;

      FOR r IN (SELECT column_name FROM anon_meta.anon_inventory
                 WHERE table_name = p_table AND rule = p_rule AND category = p_category
                 ORDER BY seq) LOOP
         IF NOT column_exists(p_table, r.column_name) THEN
            log_step(p_rule, LOWER(p_table) || '.' || LOWER(r.column_name), p_rule,
                     'SKIPPED', NULL, NULL, 'column not found');
            CONTINUE;
         END IF;
         v_columns.EXTEND;
         v_columns(v_columns.COUNT) := r.column_name;
         v_names := v_names || CASE WHEN v_names IS NULL THEN '' ELSE ',' END || LOWER(r.column_name);
      END LOOP;

      IF v_columns.COUNT = 0 THEN
         RETURN;
      END IF;

      v_object := LOWER(p_table) || '.[' || v_names || ']';

      IF p_category = 'NODE_ROLE' THEN
         -- A node's label belongs to the identity its role names.
         IF v_switches('BANK_ACCOUNT') = 'Y' THEN
            merge_owned(p_table, p_rule, v_columns, 'ACCOUNT', NULL, c_account,
                        v_object || ' [account nodes]');
         END IF;
         IF any_on(v_switches, party_categories) THEN
            merge_owned(p_table, p_rule, v_columns, 'PARTY', NULL, c_party,
                        v_object || ' [party nodes]');
         END IF;
      ELSIF p_category = 'BANK_ACCOUNT' THEN
         merge_owned(p_table, p_rule, v_columns, 'ACCOUNT', NULL, NULL, v_object);
      ELSIF p_category = 'PARTY' THEN
         merge_owned(p_table, p_rule, v_columns, 'PARTY', NULL, NULL, v_object);
      ELSIF p_category IN ('ENTITY', 'PORTFOLIO', 'COUNTERPARTY', 'UNCLASSIFIED_PARTY') THEN
         merge_owned(p_table, p_rule, v_columns, 'PARTY', p_category, NULL, v_object);
      ELSE
         RAISE_APPLICATION_ERROR(-20015,
            v_object || ': category ' || p_category || ' is not valid for a ' || p_rule || ' rule. '
         || '21_validate_inventory.sql should have stopped this.');
      END IF;
   END apply_self_code;


   -- NULL counts of every SELF_CODE column before masking, so the verifier can
   -- prove that no empty field was filled in.
   PROCEDURE capture_baseline IS
      v_total NUMBER;
      v_null  NUMBER;
   BEGIN
      DELETE FROM anon_meta.field_baseline
       WHERE run_id <> NVL((SELECT MAX(run_id) FROM anon_meta.anon_run
                             WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED'), -1);

      FOR r IN (SELECT table_name, column_name FROM anon_meta.anon_inventory
                 WHERE rule = 'SELF_CODE' ORDER BY seq) LOOP
         CONTINUE WHEN NOT column_exists(r.table_name, r.column_name);
         EXECUTE IMMEDIATE 'SELECT COUNT(*), COUNT(*) - COUNT(' || r.column_name || ') FROM op.'
                        || r.table_name INTO v_total, v_null;
         INSERT INTO anon_meta.field_baseline (run_id, table_name, column_name, total_rows, null_rows)
         VALUES (g_run_id, r.table_name, r.column_name, v_total, v_null);
      END LOOP;
      COMMIT;
   END capture_baseline;


   PROCEDURE apply_inventory IS
      v_rows NUMBER;
   BEGIN
      -- Order is not arbitrary.
      --
      -- 1. NULL_OUT first. Clearing the free text on the big history tables up
      --    front is what keeps the whole run inside 20-40 minutes.
      -- 2. CODE second.
      -- 3. DESCRIPTION and SELF_CODE last. They find their owner by original
      --    or replacement, so they no longer depend on step 2 having run - the
      --    order is kept so that the log reads the way it always has.

      -- ORDER BY MIN(seq) keeps the inventory's own order, so the sequence of
      -- work matches the CSV and the log reads in the same order as the file.
      --
      -- MIN(seq) is deliberately NOT given an alias of "seq": an alias with the
      -- same name as the column shadows it in ORDER BY, which turns MIN(seq)
      -- into MIN(MIN(seq)) and fails with ORA-00935.
      say('  --- Free text and PII -----------------------------------------');
      FOR t IN (SELECT table_name
                  FROM anon_meta.anon_inventory
                 WHERE rule = 'NULL_OUT'
                 GROUP BY table_name
                 ORDER BY MIN(seq)) LOOP
         apply_null_out(t.table_name);
      END LOOP;
      say('');

      say('  --- Identifiers -----------------------------------------------');
      FOR r IN (SELECT table_name, column_name, category
                  FROM anon_meta.anon_inventory
                 WHERE rule = 'CODE'
                 ORDER BY seq) LOOP
         apply_code(r.table_name, r.column_name, r.category);
      END LOOP;

      -- Record which translations are now applied to identifiers IN THIS DATA:
      -- renamed by this run, or found already renamed by an earlier run on the
      -- same data. EPF cascades only those. A translation used only to mask a
      -- label must not rename anything downstream - and neither must one that
      -- was applied to a previous import of the data, now replaced by raw data.
      IF NOT g_dry_run THEN
         UPDATE anon_meta.code_map c
            SET c.id_applied =
                   (SELECT CASE WHEN p.id_on = 'Y' OR p.seen_renamed = 'Y' THEN 'Y' END
                      FROM anon_meta.identity_plan p
                     WHERE p.run_id = g_run_id
                       AND p.map_category = c.category
                       AND p.old_code = c.old_code)
          WHERE (c.category, c.old_code) IN (SELECT p.map_category, p.old_code
                                               FROM anon_meta.identity_plan p
                                              WHERE p.run_id = g_run_id
                                                AND p.new_code IS NOT NULL);
         SELECT COUNT(*) INTO v_rows
           FROM anon_meta.identity_plan p
          WHERE p.run_id = g_run_id AND p.new_code IS NOT NULL
            AND (p.id_on = 'Y' OR p.seen_renamed = 'Y');
         COMMIT;
         log_step('METADATA', 'code_map.id_applied', NULL, 'OK', v_rows, NULL,
                  'translations applied to identifiers in this data');
      END IF;
      say('');

      say('  --- Labels and attributes -------------------------------------');
      IF NOT g_dry_run THEN
         capture_baseline;
      END IF;
      FOR g IN (SELECT table_name, category, rule
                  FROM anon_meta.anon_inventory
                 WHERE rule IN ('DESCRIPTION', 'SELF_CODE')
                 GROUP BY table_name, category, rule
                 ORDER BY MIN(seq)) LOOP
         apply_self_code(g.table_name, g.category, g.rule);
      END LOOP;
      say('');
   END apply_inventory;


   -- =========================================================================
   -- Triggers
   -- =========================================================================

   PROCEDURE set_triggers(p_enable IN BOOLEAN) IS
      v_action  VARCHAR2(10) := CASE WHEN p_enable THEN 'ENABLE' ELSE 'DISABLE' END;
      v_done    PLS_INTEGER := 0;
      v_failed  PLS_INTEGER := 0;
      v_start   NUMBER := DBMS_UTILITY.GET_TIME;
   BEGIN
      FOR t IN (SELECT trigger_name FROM all_triggers WHERE owner = 'OP') LOOP
         BEGIN
            EXECUTE IMMEDIATE 'ALTER TRIGGER op."' || t.trigger_name || '" ' || v_action;
            v_done := v_done + 1;
         EXCEPTION
            WHEN OTHERS THEN
               v_failed := v_failed + 1;
         END;
      END LOOP;

      log_step('TRIGGERS', v_action, NULL,
               CASE WHEN v_failed = 0 THEN 'OK' ELSE 'NOOP' END,
               v_done, elapsed_ms(v_start),
               CASE WHEN v_failed > 0 THEN v_failed || ' could not be altered' END);

      say('    triggers ' || LOWER(v_action) || 'd: ' || v_done
          || CASE WHEN v_failed > 0 THEN '   (' || v_failed || ' failed)' ELSE '' END);
   END set_triggers;


   -- =========================================================================
   -- Summary
   -- =========================================================================

   PROCEDURE print_summary IS
      v_elapsed NUMBER;
   BEGIN
      SELECT NVL(SUM(elapsed_ms), 0) / 1000 INTO v_elapsed
        FROM anon_meta.anon_step_log WHERE run_id = g_run_id;

      say('');
      say('  ==============================================================');
      say('   Run ' || g_run_id || ' summary (' || g_mode || ')');
      say('  ==============================================================');
      say('    applied ........... ' || g_count_ok);
      say('    no rows matched ... ' || g_count_noop);
      say('    skipped ........... ' || g_count_skipped || '   (not present on this instance)');
      say('    disabled .......... ' || g_count_disabled || '   (excluded by configuration)');
      say('    review required ... ' || g_count_review || '   (left unchanged: role or domain ambiguous)');
      say('    errors ............ ' || g_count_error);
      say('    rows affected ..... ' || TO_CHAR(g_rows_total, 'FM999,999,999,999'));
      say('    step time ......... ' || TO_CHAR(ROUND(v_elapsed), 'FM999,999') || 's');
      say('  ==============================================================');

      IF g_count_review > 0 THEN
         say('');
         say('    ' || g_count_review || ' item(s) hold values that were deliberately left alone');
         say('    because their role could not be established. They are client');
         say('    identifiers still in place; verification reports REVIEW until a');
         say('    reviewed decision covers them:');
         say('      SELECT object_name, rows_affected, message FROM anon_meta.anon_step_log');
         say('       WHERE run_id = ' || g_run_id || ' AND status = ''REVIEW'';');
      END IF;

      IF g_count_noop > 0 THEN
         say('');
         say('    ' || g_count_noop || ' item(s) matched no rows. That is expected for a');
         say('    column that was already clean, but on a column you expected to');
         say('    change it means the name is wrong or the mapping is empty:');
         say('      SELECT object_name FROM anon_meta.anon_step_log');
         say('       WHERE run_id = ' || g_run_id || ' AND status = ''NOOP'';');
      END IF;
      say('');
   END print_summary;

END anon_engine;
/

SHOW ERRORS

SET DEFINE ON
