-- ============================================================================
-- 21 - Validate the loaded inventory
-- ============================================================================
-- Runs after the generated INSERT file. Confirms something was loaded, that
-- every row pairs a rule with a category the engine actually enforces, and
-- records the breakdown in the run log so the log says exactly what scope was
-- used.
--
-- Takes no parameters.
--
-- ----------------------------------------------------------------------------
-- WHICH CATEGORY A RULE MAY USE
--
--   CODE         PARTY         party identifiers only - E_, P_, T_, X_
--                BANK_ACCOUNT  bank-account identifiers only - CB_
--                MIXED         reviewed columns that hold either; a value
--                              that is both a party and an account is left
--                              alone and reported for review
--                NODE_ROLE     structure.code and structure.pere only: the
--                              domain comes from each row's node role
--   DESCRIPTION  PARTY, BANK_ACCOUNT, NODE_ROLE (structure only), or one party
--   SELF_CODE    category - ENTITY, PORTFOLIO, COUNTERPARTY, UNCLASSIFIED_PARTY
--   NULL_OUT     NONE
--
-- ANY is refused. It would mean "whichever domain matches this text" - and a
-- party reference could then receive a bank account's replacement. Each
-- column says which domain it holds.
--
-- ENTITY, PORTFOLIO, COUNTERPARTY and UNCLASSIFIED_PARTY are refused on CODE.
-- A single-category lookup would leave an unclassified (X_) party untouched in
-- a column that holds parties.
--
-- A few contracts are fixed, because the identity model depends on them:
--   tiers.code is PARTY, compte_banque.code is BANK_ACCOUNT, structure.code
--   and structure.pere are NODE_ROLE; tiers labels and attributes belong to
--   parties and compte_banque ones to accounts.
--
-- ----------------------------------------------------------------------------
-- COLUMN OPTIONS - the [bracketed] words of the notes field
--
--   [no-harvest]     CODE,PARTY or CODE,BANK_ACCOUNT. Without it, a value of
--                    the column that is no identity of its domain is the code
--                    of a master row deleted in the past, and is captured as
--                    one (a party X_ MISSING_MASTER, an account CB_). With it,
--                    such a value is something else - a BBAN, an IBAN, a
--                    condition code - and stays as it is.
--   [only-where: <col> in <table>.<col> where <col> = <value>]
--                    CODE. The column holds identifiers only on the rows whose
--                    <col> names a <table> row with that value; the other rows
--                    are left out of the renaming, the harvest and the checks.
--   [group: <col>]   CODE,MIXED. Rows with the same <col> hold one kind of
--                    code: a value that is a party AND an account takes the
--                    kind of the group's other values. Without one, or when
--                    the group holds both kinds, it is left for review.
--   [folders: <tree> <tree> ...]
--                    structure.code. The structure trees whose folder rows -
--                    rows with no screen - are named after clients: such a row
--                    whose code is a party or account identifier is renamed.
--
-- They are parsed here into anon_inventory (harvest, row_scope, group_by,
-- folder_trees), where the engine and the verifier read them. An option that
-- is misspelt or on the wrong kind of column stops the run here.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF

DECLARE
   v_total   PLS_INTEGER;
   v_base    PLS_INTEGER;
   v_custom  PLS_INTEGER;
   v_bad     PLS_INTEGER := 0;

   PROCEDURE bad(p_table IN VARCHAR2, p_column IN VARCHAR2, p_rule IN VARCHAR2,
                 p_category IN VARCHAR2, p_source IN VARCHAR2, p_why IN VARCHAR2) IS
   BEGIN
      v_bad := v_bad + 1;
      DBMS_OUTPUT.PUT_LINE('  INVALID  ' || LOWER(p_table) || '.' || LOWER(p_column) || ','
                        || p_rule || ',' || p_category || '  (' || LOWER(p_source) || ')');
      DBMS_OUTPUT.PUT_LINE('           ' || p_why);
   END bad;
BEGIN
   SELECT COUNT(*) INTO v_total FROM anon_meta.anon_inventory;

   IF v_total = 0 THEN
      RAISE_APPLICATION_ERROR(-20020,
         'The inventory is empty. config/inventory_op.csv was not found, or every line in it '
      || 'was a comment. There is nothing to anonymize - stopping before any changes are made.');
   END IF;

   SELECT COUNT(*) INTO v_base   FROM anon_meta.anon_inventory WHERE source = 'BASE';
   SELECT COUNT(*) INTO v_custom FROM anon_meta.anon_inventory WHERE source = 'CUSTOM';

   DBMS_OUTPUT.PUT_LINE('  loaded ............ ' || v_total || ' items');
   DBMS_OUTPUT.PUT_LINE('    shipped ......... ' || v_base);
   DBMS_OUTPUT.PUT_LINE('    site-specific ... ' || v_custom);

   -- A rule paired with a category it cannot apply would silently do nothing,
   -- or - worse - something other than what the row says. Catch every one
   -- here, rather than at run time.
   FOR r IN (SELECT table_name, column_name, rule, category, source
               FROM anon_meta.anon_inventory
              ORDER BY seq) LOOP

      IF r.category = 'ANY' THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'ANY is not accepted: name the domain the column holds - PARTY, '
          || 'BANK_ACCOUNT, or MIXED once reviewed (CODE); PARTY or a party category '
          || '(DESCRIPTION, SELF_CODE).');

      ELSIF r.rule = 'NULL_OUT' AND r.category <> 'NONE' THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'NULL_OUT requires category NONE - free text is never category-dependent.');

      ELSIF r.rule <> 'NULL_OUT' AND r.category = 'NONE' THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             r.rule || ' needs a domain; NONE is for NULL_OUT only.');

      ELSIF r.rule = 'CODE'
            AND r.category NOT IN ('PARTY', 'BANK_ACCOUNT', 'MIXED', 'NODE_ROLE') THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'a CODE column takes PARTY, BANK_ACCOUNT or MIXED. A single party category '
          || 'would leave an unclassified (X_) party in this column untouched - use PARTY.');

      ELSIF r.category = 'NODE_ROLE'
            AND NOT (r.table_name = 'STRUCTURE'
                     AND (   (r.rule = 'CODE' AND r.column_name IN ('CODE', 'PERE'))
                          OR  r.rule IN ('DESCRIPTION', 'SELF_CODE'))) THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'NODE_ROLE is the structure handler: structure.code and structure.pere (CODE), '
          || 'and structure labels and attributes.');

      ELSIF r.table_name = 'STRUCTURE' AND r.column_name IN ('CODE', 'PERE')
            AND NOT (r.rule = 'CODE' AND r.category = 'NODE_ROLE') THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'structure holds party AND account nodes: its code and pere must be CODE,NODE_ROLE '
          || 'so each row takes the translation of its own role.');

      ELSIF r.table_name = 'TIERS' AND r.column_name = 'CODE'
            AND NOT (r.rule = 'CODE' AND r.category = 'PARTY') THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'tiers.code is the party master: it must be CODE,PARTY.');

      ELSIF r.table_name = 'COMPTE_BANQUE' AND r.column_name = 'CODE'
            AND NOT (r.rule = 'CODE' AND r.category = 'BANK_ACCOUNT') THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'compte_banque.code is the account master: it must be CODE,BANK_ACCOUNT.');

      ELSIF r.rule IN ('DESCRIPTION', 'SELF_CODE') AND r.table_name = 'TIERS'
            AND r.category NOT IN ('PARTY', 'ENTITY', 'PORTFOLIO', 'COUNTERPARTY',
                                   'UNCLASSIFIED_PARTY') THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'a tiers row is owned by a party: use PARTY or one party category.');

      ELSIF r.rule IN ('DESCRIPTION', 'SELF_CODE') AND r.table_name = 'COMPTE_BANQUE'
            AND r.category <> 'BANK_ACCOUNT' THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'a compte_banque row is owned by a bank account: use BANK_ACCOUNT.');

      ELSIF r.rule IN ('DESCRIPTION', 'SELF_CODE') AND r.category = 'MIXED' THEN
         bad(r.table_name, r.column_name, r.rule, r.category, r.source,
             'MIXED is for CODE columns; a label or attribute has one owner.');
      END IF;
   END LOOP;

   -- The column options. Every CODE,PARTY and CODE,BANK_ACCOUNT column is
   -- harvested unless its notes say [no-harvest].
   UPDATE anon_meta.anon_inventory
      SET harvest      = CASE WHEN rule = 'CODE' AND category IN ('PARTY', 'BANK_ACCOUNT') THEN 'Y' END,
          row_scope    = NULL,
          group_by     = NULL,
          folder_trees = NULL;

   FOR r IN (SELECT ROWID AS rid, table_name, column_name, rule, category, source, notes
               FROM anon_meta.anon_inventory
              WHERE INSTR(notes, '[') > 0
              ORDER BY seq) LOOP
      DECLARE
         c_scope CONSTANT VARCHAR2(300) :=
            '^\[only-where:\s*([a-z][a-z0-9_$#]*)\s+in\s+([a-z][a-z0-9_$#]*)\.([a-z][a-z0-9_$#]*)'
         || '\s+where\s+([a-z][a-z0-9_$#]*)\s*=\s*([a-z0-9_-]+)\s*\]$';
         c_group CONSTANT VARCHAR2(100) := '^\[group:\s*([a-z][a-z0-9_$#]*)\s*\]$';
         c_trees CONSTANT VARCHAR2(100) := '^\[folders:\s*([a-z0-9_ -]*[a-z0-9_-])\s*\]$';
         v_opt   VARCHAR2(500);
         v_n     PLS_INTEGER := 1;
      BEGIN
         LOOP
            v_opt := REGEXP_SUBSTR(r.notes, '\[[^]]*\]', 1, v_n);
            EXIT WHEN v_opt IS NULL;
            v_n := v_n + 1;

            IF REGEXP_LIKE(v_opt, '^\[no-harvest\]$', 'i') THEN
               IF r.rule = 'CODE' AND r.category IN ('PARTY', 'BANK_ACCOUNT') THEN
                  UPDATE anon_meta.anon_inventory SET harvest = 'N' WHERE ROWID = r.rid;
               ELSE
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      '[no-harvest] is for CODE,PARTY and CODE,BANK_ACCOUNT columns.');
               END IF;

            ELSIF REGEXP_LIKE(v_opt, '^\[only-where:', 'i') THEN
               IF NOT REGEXP_LIKE(v_opt, c_scope, 'i') THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      v_opt || ' - write it [only-where: <col> in <table>.<col> where <col> = <value>].');
               ELSIF r.rule <> 'CODE' OR r.category = 'NODE_ROLE' THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      '[only-where: ...] is for CODE columns other than structure.');
               ELSE
                  -- Built from names and a value the pattern has already
                  -- limited to letters, digits and _ $ # -: nothing else can
                  -- reach the statement.
                  UPDATE anon_meta.anon_inventory
                     SET row_scope = 'EXISTS (SELECT 1 FROM op.'
                                  || LOWER(REGEXP_SUBSTR(v_opt, c_scope, 1, 1, 'i', 2)) || ' scope_row'
                                  || ' WHERE scope_row.' || LOWER(REGEXP_SUBSTR(v_opt, c_scope, 1, 1, 'i', 3))
                                  || ' = t.' || LOWER(REGEXP_SUBSTR(v_opt, c_scope, 1, 1, 'i', 1))
                                  || ' AND scope_row.' || LOWER(REGEXP_SUBSTR(v_opt, c_scope, 1, 1, 'i', 4))
                                  || ' = ''' || REGEXP_SUBSTR(v_opt, c_scope, 1, 1, 'i', 5) || ''')'
                   WHERE ROWID = r.rid;
               END IF;

            ELSIF REGEXP_LIKE(v_opt, '^\[group:', 'i') THEN
               IF NOT REGEXP_LIKE(v_opt, c_group, 'i') THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      v_opt || ' - write it [group: <col>].');
               ELSIF NOT (r.rule = 'CODE' AND r.category = 'MIXED') THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      '[group: ...] is for CODE,MIXED columns.');
               ELSE
                  UPDATE anon_meta.anon_inventory
                     SET group_by = UPPER(REGEXP_SUBSTR(v_opt, c_group, 1, 1, 'i', 1))
                   WHERE ROWID = r.rid;
               END IF;

            ELSIF REGEXP_LIKE(v_opt, '^\[folders:', 'i') THEN
               IF NOT REGEXP_LIKE(v_opt, c_trees, 'i') THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      v_opt || ' - write it [folders: <tree> <tree> ...], the trees separated by spaces.');
               ELSIF NOT (r.table_name = 'STRUCTURE' AND r.column_name = 'CODE') THEN
                  bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                      '[folders: ...] is for structure.code.');
               ELSE
                  -- ',Entite,Compte,' - a tree is in the list when
                  -- INSTR(folder_trees, ',' || structure || ',') > 0.
                  UPDATE anon_meta.anon_inventory
                     SET folder_trees = ',' || REGEXP_REPLACE(REGEXP_SUBSTR(v_opt, c_trees, 1, 1, 'i', 1),
                                                              ' +', ',') || ','
                   WHERE ROWID = r.rid;
               END IF;

            ELSE
               bad(r.table_name, r.column_name, r.rule, r.category, r.source,
                   'unknown option ' || v_opt || '. The options are [no-harvest], [only-where: ...], '
                || '[group: ...] and [folders: ...]; a note must not use [ ] otherwise.');
            END IF;
         END LOOP;
      END;
   END LOOP;
   COMMIT;

   IF v_bad > 0 THEN
      RAISE_APPLICATION_ERROR(-20021,
         v_bad || ' inventory row(s) cannot be applied as written - a rule with a category that '
      || 'cannot apply, or a column option that is misspelt or misplaced - listed above. '
      || 'Nothing has been changed. Correct them in config/inventory_op_custom.csv.');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- Breakdown, so the run log records exactly what scope was loaded.
-- ----------------------------------------------------------------------------
COLUMN rule     FORMAT A14
COLUMN category FORMAT A20
COLUMN items    FORMAT 9999
SET HEADING ON

PROMPT
SELECT rule, category, COUNT(*) AS items
  FROM anon_meta.anon_inventory
 GROUP BY rule, category
 ORDER BY DECODE(rule, 'NULL_OUT', 1, 'CODE', 2, 'DESCRIPTION', 3, 4), category;

SET HEADING OFF
PROMPT
