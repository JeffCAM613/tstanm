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
-- ANY is refused. It meant "whichever category matches this text", which is
-- how a party reference received a bank account's replacement. Each column
-- now says which domain it holds.
--
-- ENTITY, PORTFOLIO, COUNTERPARTY and UNCLASSIFIED_PARTY are refused on CODE.
-- A single-category lookup would leave an unclassified (X_) party untouched in
-- a column that holds parties. Before this version those values were accepted
-- and silently treated as ANY - the category said one thing and the engine
-- did another.
--
-- A few contracts are fixed, because the identity model depends on them:
--   tiers.code is PARTY, compte_banque.code is BANK_ACCOUNT, structure.code
--   and structure.pere are NODE_ROLE; tiers labels and attributes belong to
--   parties and compte_banque ones to accounts.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
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
             'ANY is no longer accepted: name the domain the column holds - PARTY, '
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

   IF v_bad > 0 THEN
      RAISE_APPLICATION_ERROR(-20021,
         v_bad || ' inventory row(s) pair a rule with a category that cannot apply - listed above. '
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
