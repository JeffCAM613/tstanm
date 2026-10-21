-- ============================================================================
-- Assertions - fixture_part2.sql after one EXECUTE run with every switch on
-- ============================================================================
-- Run as SYS. Prints one PASS or FAIL line per assertion; run_regression.sh
-- counts them. Expected values are looked up through the mapping, as in
-- assert_core.sql: "the party SHRD" is anon_meta.code_map's PARTY translation
-- of SHRD.
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
   v_run NUMBER;

   PROCEDURE check_eq(p_name IN VARCHAR2, p_sql IN VARCHAR2, p_expect IN VARCHAR2) IS
      v VARCHAR2(4000);
   BEGIN
      EXECUTE IMMEDIATE p_sql INTO v;
      IF (v = p_expect) OR (v IS NULL AND p_expect IS NULL) THEN
         DBMS_OUTPUT.PUT_LINE('PASS  ' || p_name);
      ELSE
         DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || '   got [' || v || '] expected [' || p_expect || ']');
      END IF;
   EXCEPTION
      WHEN OTHERS THEN
         DBMS_OUTPUT.PUT_LINE('FAIL  ' || p_name || '   ' || SQLERRM);
   END check_eq;

   FUNCTION tr(p_domain IN VARCHAR2, p_old IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN '(SELECT c.new_code FROM anon_meta.identity_inventory i JOIN anon_meta.code_map c'
          || ' ON c.category = i.map_category AND c.old_code = i.old_code'
          || ' WHERE i.domain = ''' || p_domain || ''' AND i.old_code = ''' || p_old || ''')';
   END tr;

   FUNCTION identity(p_domain IN VARCHAR2, p_old IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN 'SELECT category || ''/'' || x_reason || ''/'' || membership FROM anon_meta.identity_inventory'
          || ' WHERE domain = ''' || p_domain || ''' AND old_code = ''' || p_old || '''';
   END identity;

   -- One structure row, by its tree and its ORIGINAL code: what it holds now.
   FUNCTION node(p_tree IN VARCHAR2, p_code_sql IN VARCHAR2, p_what IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN 'SELECT ' || p_what || ' FROM op.structure WHERE structure = ''' || p_tree
          || ''' AND code = ' || p_code_sql;
   END node;
BEGIN
   SELECT MAX(run_id) INTO v_run FROM anon_meta.anon_run
    WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED';

   -- --- Items 2A and 3: codes found only in references ----------------------
   check_eq('a party column''s code with no master: X_, missing master, reference only',
      identity('PARTY', 'GONEP'), 'UNCLASSIFIED_PARTY/MISSING_MASTER/REFERENCE_ONLY');
   check_eq('an account column''s code with no master: CB_, reference only',
      identity('ACCOUNT', 'GONEA'), 'BANK_ACCOUNT//REFERENCE_ONLY');
   check_eq('  ... both renamed where they were found',
      'SELECT COUNT(*) FROM op.compte_regle WHERE id = 4 AND entite = ' || tr('PARTY', 'GONEP')
   || ' AND compte = ' || tr('ACCOUNT', 'GONEA'), '1');
   check_eq('an account''s code in a party column is a party of its own (X_)',
      identity('PARTY', 'Q'), 'UNCLASSIFIED_PARTY/MISSING_MASTER/REFERENCE_ONLY');
   check_eq('a party''s code in an account column is an account of its own (CB_)',
      identity('ACCOUNT', 'PCUS'), 'BANK_ACCOUNT//REFERENCE_ONLY');
   check_eq('  ... each column got the translation of the domain it holds',
      'SELECT COUNT(*) FROM op.compte_regle WHERE id = 5 AND entite = ' || tr('PARTY', 'Q')
   || ' AND compte = ' || tr('ACCOUNT', 'PCUS'), '1');
   check_eq('  ... and the masters kept their own: Q''s account, PCUS''s party',
      'SELECT (SELECT COUNT(*) FROM op.compte_banque WHERE code = ' || tr('ACCOUNT', 'Q') || ')'
   || ' + (SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'PCUS') || ') FROM dual', '2');
   check_eq('a blank value is no code: not captured, left as it is',
      'SELECT (SELECT COUNT(*) FROM anon_meta.identity_inventory WHERE TRIM(old_code) IS NULL)'
   || ' || ''/'' || (SELECT compte FROM op.compte_regle WHERE id = 6) || ''/'' FROM dual', '0/ /');

   -- --- Items 4 and 5: the structure, tree by tree ----------------------------
   check_eq('folder tree: a folder named after a party AND an account takes the party''s',
      node('Compta', tr('PARTY', 'SHRD'), 'COUNT(*)'), '1');
   check_eq('  ... and its label with it',
      node('Compta', tr('PARTY', 'SHRD'), 'CASE WHEN description = code THEN ''label = code'' END'),
      'label = code');
   check_eq('folder tree: a folder named after an account only takes the account''s, label too',
      node('Compta', tr('ACCOUNT', 'BKONLY'), 'CASE WHEN description = code THEN ''label = code'' END'),
      'label = code');
   check_eq('folder tree: a folder named after no one keeps its code, its text emptied',
      node('Compta', '''ACTIF''', 'NVL(description, ''<empty>'')'), '<empty>');
   check_eq('  ... the children of the renamed folder follow it: ACTIF and the BKONLY folder',
      'SELECT COUNT(*) FROM op.structure WHERE structure = ''Compta'' AND pere = ' || tr('PARTY', 'SHRD')
   || ' AND (code = ''ACTIF'' OR code = ' || tr('ACCOUNT', 'BKONLY') || ')', '2');
   check_eq('a node on another screen keeps its code, its label and its parent',
      'SELECT code || ''/'' || description || ''/'' || pere FROM op.structure WHERE structure = ''Compta'''
   || ' AND ecran = ''w_compte_compta''', 'C512/Account 512/ACTIF');
   check_eq('a folder row outside the folder trees keeps a party''s code, its text emptied',
      node('PosteFlux', '''CPTN''', 'NVL(description, ''<empty>'')'), '<empty>');
   check_eq('  ... and its child still points at it',
      'SELECT pere FROM op.structure WHERE structure = ''PosteFlux'' AND code = ''FLX1''', 'CPTN');
   check_eq('a node on another screen whose code is a party''s: untouched',
      node('Titre', '''Z''', 'description'), 'Security Z');
   check_eq('the same parent text in two trees: each child follows the parent of its own tree',
      'SELECT (SELECT COUNT(*) FROM op.structure WHERE structure = ''Entite'' AND code = ' || tr('PARTY', 'KIDP')
   || ' AND pere = ' || tr('PARTY', 'SHRD') || ')'
   || ' + (SELECT COUNT(*) FROM op.structure WHERE structure = ''Compte'' AND code = ' || tr('ACCOUNT', 'KIDA')
   || ' AND pere = ' || tr('ACCOUNT', 'SHRD') || ') FROM dual', '2');
   -- Every child of these trees had its parent in its own tree before the
   -- run; it still has. (The core fixture's other trees point across trees on
   -- purpose - parents with no node in the child's tree.)
   check_eq('every pere still points at a node of its own tree',
      'SELECT COUNT(*) FROM op.structure c WHERE c.pere IS NOT NULL'
   || ' AND (c.structure IN (''Compta'', ''PosteFlux'') OR c.code IN (' || tr('PARTY', 'KIDP') || ', '
   || tr('ACCOUNT', 'KIDA') || '))'
   || ' AND NOT EXISTS (SELECT 1 FROM op.structure p WHERE p.structure = c.structure AND p.code = c.pere)', '0');

   -- --- Item 6: MIXED breakdowns ----------------------------------------------
   check_eq('a breakdown of accounts: the value that is both takes the account''s',
      'SELECT COUNT(*) FROM op.ventiler_compte WHERE id = 11 AND valeur_1 = ' || tr('ACCOUNT', 'SHRD'), '1');
   check_eq('a breakdown of parties: the value that is both takes the party''s',
      'SELECT COUNT(*) FROM op.ventiler_compte WHERE id = 13 AND valeur_1 = ' || tr('PARTY', 'SHRD'), '1');

   -- --- Nothing for review ----------------------------------------------------
   check_eq('nothing left for review',
      'SELECT COUNT(*) FROM anon_meta.anon_step_log WHERE run_id = ' || v_run || ' AND status = ''REVIEW''', '0');
END;
/

EXIT SUCCESS
