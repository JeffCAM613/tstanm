-- ============================================================================
-- Assertions - the core fixture after one EXECUTE run with every switch on
-- ============================================================================
-- Run as SYS. Prints one PASS or FAIL line per assertion; run_regression.sh
-- counts them. Every value checked is fictional (fixture_data.sql).
--
-- Expected values are looked up through the mapping rather than hard-coded:
-- "the party SHRD" means anon_meta.code_map's PARTY translation of SHRD, so the
-- assertions test the domain each value came from, not a particular number.
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

   -- The translation of one identity, by domain.
   FUNCTION tr(p_domain IN VARCHAR2, p_old IN VARCHAR2) RETURN VARCHAR2 IS
   BEGIN
      RETURN '(SELECT c.new_code FROM anon_meta.identity_inventory i JOIN anon_meta.code_map c'
          || ' ON c.category = i.map_category AND c.old_code = i.old_code'
          || ' WHERE i.domain = ''' || p_domain || ''' AND i.old_code = ''' || p_old || ''')';
   END tr;

   PROCEDURE category_is(p_domain IN VARCHAR2, p_code IN VARCHAR2, p_category IN VARCHAR2,
                         p_reason IN VARCHAR2 DEFAULT NULL) IS
   BEGIN
      check_eq('classified ' || p_code || ' as ' || p_category
               || CASE WHEN p_reason IS NOT NULL THEN ' (' || p_reason || ')' END,
               'SELECT category || ''/'' || x_reason FROM anon_meta.identity_inventory'
            || ' WHERE domain = ''' || p_domain || ''' AND old_code = ''' || p_code || '''',
               p_category || '/' || p_reason);
   END category_is;
BEGIN
   SELECT MAX(run_id) INTO v_run FROM anon_meta.anon_run
    WHERE run_mode = 'EXECUTE' AND status = 'COMPLETED';

   -- --- Section 7A: one category per party, in the approved order ----------
   category_is('PARTY', 'ENTN', 'ENTITY');
   category_is('PARTY', 'PCUS', 'PORTFOLIO');
   category_is('PARTY', 'CPTN', 'COUNTERPARTY');
   category_is('PARTY', 'CPTC', 'COUNTERPARTY');
   category_is('PARTY', 'EOVL', 'ENTITY');
   category_is('PARTY', 'POVL', 'PORTFOLIO');
   category_is('PARTY', 'NFLG', 'UNCLASSIFIED_PARTY', 'UNKNOWN_FLAG');
   category_is('PARTY', 'IFLG', 'UNCLASSIFIED_PARTY', 'UNKNOWN_FLAG');
   category_is('PARTY', 'NMEN', 'UNCLASSIFIED_PARTY', 'MISSING_MASTER');
   category_is('PARTY', 'NMCP', 'UNCLASSIFIED_PARTY', 'MISSING_MASTER');
   -- Part 2, item 7: flag N and no structure node at all is an archived
   -- party, a counterparty; flag O and no node is still X_.
   category_is('PARTY', 'NSTN', 'COUNTERPARTY');
   check_eq('  ... a T_ value, its master and its references alike',
      'SELECT CASE WHEN ' || tr('PARTY', 'NSTN') || ' LIKE ''T\_%'' ESCAPE ''\'' THEN ''T_'' END'
   || ' || ''/'' || (SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'NSTN') || ')'
   || ' || ''/'' || (SELECT COUNT(*) FROM op.histo_operation WHERE id = 4 AND entite = ' || tr('PARTY', 'NSTN') || ')'
   || ' FROM dual', 'T_/1/1');
   category_is('PARTY', 'NSTO', 'UNCLASSIFIED_PARTY', 'NO_STRUCTURE');
   category_is('PARTY', 'NCLN', 'UNCLASSIFIED_PARTY', 'UNKNOWN_CLASSIFICATION');
   category_is('PARTY', 'NCLO', 'PORTFOLIO');
   category_is('PARTY', 'EDUP', 'ENTITY');
   category_is('PARTY', 'SHRD', 'ENTITY');
   category_is('PARTY', 'Z',    'ENTITY');
   check_eq('entity precedence logged for EOVL only',
      'SELECT LISTAGG(old_code, '','') WITHIN GROUP (ORDER BY old_code) FROM anon_meta.identity_plan'
   || ' WHERE run_id = ' || v_run || ' AND entity_overlap = ''Y''', 'EOVL');
   -- 17 from tiers and structure, and X: found only in a party column.
   check_eq('18 parties, each with exactly one translation',
      'SELECT COUNT(*) FROM anon_meta.identity_inventory i WHERE domain = ''PARTY'''
   || ' AND (SELECT COUNT(*) FROM anon_meta.code_map c WHERE c.old_code = i.old_code'
   || '      AND c.category IN (''ENTITY'',''PORTFOLIO'',''COUNTERPARTY'',''UNCLASSIFIED_PARTY'')) = 1',
      '18');

   -- --- Part 2, item 3: a code found only in a party column ----------------
   check_eq('found only in references: X is X_, missing master, reference only',
      'SELECT category || ''/'' || x_reason || ''/'' || membership FROM anon_meta.identity_inventory'
   || ' WHERE domain = ''PARTY'' AND old_code = ''X''',
      'UNCLASSIFIED_PARTY/MISSING_MASTER/REFERENCE_ONLY');
   check_eq('  ... and its reference renamed',
      'SELECT COUNT(*) FROM op.histo_operation WHERE id = 4 AND contrepartie = ' || tr('PARTY', 'X'), '1');
   check_eq('  ... where it was found is recorded, by column',
      'SELECT LOWER(table_name || ''.'' || column_name) || '' '' || n_rows FROM anon_meta.reference_harvest'
   || ' WHERE run_id = ' || v_run || ' AND old_code = ''X''', 'histo_operation.contrepartie 1');
   check_eq('[no-harvest] columns are not read: no IBAN, no condition code captured',
      'SELECT COUNT(*) FROM anon_meta.identity_inventory WHERE old_code IN (''XX00TESTIBAN0000000001'', ''CND01'')',
      '0');
   check_eq('  ... and both stay as they are',
      'SELECT (SELECT tiers_iban_compte FROM op.histo_operation WHERE id = 1) || ''/'''
   || ' || (SELECT code FROM op.echelle_condition) FROM dual', 'XX00TESTIBAN0000000001/CND01');

   -- --- Section 2: the account union ------------------------------------------
   category_is('ACCOUNT', 'SHRD', 'BANK_ACCOUNT');
   check_eq('account sources: MASTER_ONLY 3, BOTH 3, STRUCTURE_ONLY 1',
      'SELECT LISTAGG(membership || '' '' || n, '', '') WITHIN GROUP (ORDER BY membership)'
   || ' FROM (SELECT membership, COUNT(*) n FROM anon_meta.identity_inventory'
   || '        WHERE domain = ''ACCOUNT'' GROUP BY membership)',
      'BOTH 3, MASTER_ONLY 3, STRUCTURE_ONLY 1');
   check_eq('FLAG_GERE is no selection gate (BKNULL, BKONLY mapped)',
      'SELECT COUNT(*) FROM anon_meta.identity_inventory WHERE domain = ''ACCOUNT'''
   || ' AND old_code IN (''BKNULL'', ''BKONLY'')', '2');

   -- --- Defect B: the account node takes its master's CB_, not the party's ---
   check_eq('shared text: account master holds the ACCOUNT translation',
      'SELECT COUNT(*) FROM op.compte_banque WHERE code = ' || tr('ACCOUNT', 'SHRD'), '1');
   check_eq('shared text: account node holds the SAME account translation',
      'SELECT COUNT(*) FROM op.structure WHERE ecran = ''w_compte_banque'''
   || ' AND code = ' || tr('ACCOUNT', 'SHRD'), '1');
   check_eq('shared text: party node keeps the PARTY translation',
      'SELECT COUNT(*) FROM op.structure WHERE ecran = ''w_tiers'' AND code = ' || tr('PARTY', 'SHRD'), '1');
   check_eq('shared text: party and account translations differ',
      'SELECT CASE WHEN ' || tr('PARTY', 'SHRD') || ' <> ' || tr('ACCOUNT', 'SHRD')
   || ' THEN ''different'' END FROM dual', 'different');

   -- --- Defect A: a party reference never receives a CB_ value --------------

   check_eq('party columns holding SHRD got the PARTY translation, not CB_',
      'SELECT COUNT(*) FROM op.histo_operation WHERE id = 3 AND contrepartie = ' || tr('PARTY', 'SHRD')
   || ' AND entite = ' || tr('PARTY', 'SHRD'), '1');
   check_eq('account columns holding SHRD got the account translation',
      'SELECT COUNT(*) FROM op.histo_operation WHERE id = 3 AND compte_tiers = ' || tr('ACCOUNT', 'SHRD')
   || ' AND compte_entite = ' || tr('ACCOUNT', 'SHRD'), '1');
   check_eq('tiers.code holds no CB_ value',
      'SELECT COUNT(*) FROM op.tiers WHERE code LIKE ''CB\_%'' ESCAPE ''\''', '0');
   check_eq('no party column holds an account translation',
      'SELECT COUNT(*) FROM op.histo_operation h WHERE h.entite IN (SELECT new_code FROM anon_meta.code_map'
   || ' WHERE category = ''BANK_ACCOUNT'') OR h.contrepartie IN (SELECT new_code FROM anon_meta.code_map'
   || ' WHERE category = ''BANK_ACCOUNT'')', '0');

   -- --- Section 4: structure.pere takes its PARENT's typed translation ------
   check_eq('account node under a party: pere is the party translation',
      'SELECT COUNT(*) FROM op.structure WHERE code = ' || tr('ACCOUNT', 'SHRD')
   || ' AND pere = ' || tr('PARTY', 'ENTN'), '1');
   check_eq('parent known only as an account: pere is the account translation',
      'SELECT COUNT(*) FROM op.structure WHERE code = ' || tr('ACCOUNT', 'CHLD')
   || ' AND pere = ' || tr('ACCOUNT', 'BKONLY'), '1');

   -- --- STRUCTURE_ONLY and duplicated sources ----------------------------------
   check_eq('structure-only account node renamed with its own translation',
      'SELECT COUNT(*) FROM op.structure WHERE code = ' || tr('ACCOUNT', 'NODEONLY'), '1');
   check_eq('  ... and its references follow',
      'SELECT COUNT(*) FROM op.compte_regle WHERE id = 2 AND compte = ' || tr('ACCOUNT', 'NODEONLY'), '1');
   check_eq('duplicate account nodes: both rows, one identity',
      'SELECT COUNT(*) FROM op.structure WHERE code = ' || tr('ACCOUNT', 'BKDUP'), '2');

   -- --- One-character identifiers: no short-code exception -----------------
   check_eq('one-character party Z renamed in master and reference',
      'SELECT COUNT(*) FROM op.histo_operation WHERE id = 2 AND entite = ' || tr('PARTY', 'Z'), '1');
   check_eq('one-character account Q renamed in master and references',
      'SELECT COUNT(*) FROM op.compte_regle WHERE id = 1 AND compte = ' || tr('ACCOUNT', 'Q'), '1');
   check_eq('no raw one-character identifier left',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ''Z''', '0');

   -- --- MIXED: one-domain values take that domain's translation -------------
   check_eq('MIXED: party value got the party translation',
      'SELECT COUNT(*) FROM op.ventiler_compte WHERE id = 1 AND valeur_1 = ' || tr('PARTY', 'CPTC'), '1');
   check_eq('MIXED: account value got the account translation',
      'SELECT COUNT(*) FROM op.ventiler_compte WHERE id = 1 AND valeur_2 = ' || tr('ACCOUNT', 'BKNULL'), '1');
   check_eq('MIXED: a value that is no identifier stays',
      'SELECT valeur_1 FROM op.ventiler_compte WHERE id = 2', 'EUR');

   -- --- Compensateur: the identity's ordinary translation -------------------
   check_eq('compensateur uses the ordinary translation',
      'SELECT COUNT(*) FROM op.histo_operation WHERE id = 1 AND compensateur = entite'
   || ' AND entite = ' || tr('PARTY', 'ENTN'), '1');

   -- --- Labels and attributes: mapped value, NULL kept per field -------------
   check_eq('tiers description = owner translation',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'ENTN') || ' AND description = code', '1');

   check_eq('populated fields masked, each empty sibling stays empty',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'ENTN')
   || ' AND adresse1 = code AND adresse2 IS NULL AND telephone = code AND fax IS NULL AND nom_pp IS NULL',
      '1');
   check_eq('X_ owner: description and phone masked, an empty field kept',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'NFLG')
   || ' AND description = code AND telephone = code AND fax IS NULL', '1');
   check_eq('archived counterparty (no structure node): description, address, phone, name masked',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'NSTN')
   || ' AND description = code AND adresse1 = code AND adresse2 = code AND telephone = code'
   || ' AND email_adress = code AND nom_pp = code AND dpt_naissance = code AND fax IS NULL', '1');
   check_eq('counterparty contact fields masked too (PARTY scope)',
      'SELECT COUNT(*) FROM op.tiers WHERE code = ' || tr('PARTY', 'CPTN')
   || ' AND telephone = code AND fax = code', '1');
   check_eq('account label and attribute masked, empty one kept',
      'SELECT COUNT(*) FROM op.compte_banque WHERE code = ' || tr('ACCOUNT', 'SHRD')
   || ' AND description = code AND groupe_1 = code AND groupe_2 IS NULL', '1');
   check_eq('account node label = account translation, party node label = party translation',
      'SELECT COUNT(*) FROM op.structure WHERE (code = ' || tr('ACCOUNT', 'SHRD') || ' AND ecran = ''w_compte_banque'''
   || ' AND description = code) OR (code = ' || tr('PARTY', 'SHRD') || ' AND ecran = ''w_tiers'' AND description = code)',
      '2');

   -- --- Fields left out of the inventory are untouched -------------------------
   check_eq('natural-person flag untouched',
      'SELECT LISTAGG(DISTINCT NVL(flag_pp, ''-''), '','') WITHIN GROUP (ORDER BY NVL(flag_pp, ''-'')) FROM op.tiers', '-,N,O');
   check_eq('tiers_entite discriminator untouched',
      'SELECT LISTAGG(tiers_entite, '','') WITHIN GROUP (ORDER BY id) FROM op.val_ssi_account', 'T,E');

   -- --- Free text ------------------------------------------------------------
   check_eq('NOT NULL free text overwritten with the marker',
      'SELECT description FROM op.histo_pricing_groupe WHERE id = 1', 'ANONYMIZED');
   check_eq('free text emptied',
      'SELECT COUNT(*) FROM op.histo_operation WHERE description IS NOT NULL OR tiers_libelle IS NOT NULL'
   || ' OR groupe_1 IS NOT NULL', '0');
   -- Part 2, item 1: a bank's name, a party code and an account code alike.
   check_eq('tiers_domicile emptied - free text, whatever it holds',
      'SELECT COUNT(*) FROM op.histo_operation WHERE tiers_domicile IS NOT NULL', '0');
   -- Part 2, item 5C: NULL refused at run time (a NOT NULL constraint that is
   -- not validated): the marker, and no warning.
   check_eq('free text that refuses NULL gets the marker',
      'SELECT description FROM op.utilisateur WHERE code = ''U1''', 'ANONYMIZED');
   check_eq('  ... with nothing to report',
      'SELECT COUNT(*) FROM anon_meta.anon_step_log WHERE run_id = ' || v_run
   || ' AND status IN (''ERROR'', ''REVIEW'') ', '0');

   -- --- Part 2, item 2B: a report's lines, by the kind of report -------------
   check_eq('account report: the line''s code is the account''s translation',
      'SELECT COUNT(*) FROM op.param_fiche_val_detail WHERE id = 1 AND code = ' || tr('ACCOUNT', 'BKONLY'), '1');
   check_eq('cash-flow report: codes untouched, even one equal to a party''s',
      'SELECT LISTAGG(code, '','') WITHIN GROUP (ORDER BY id) FROM op.param_fiche_val_detail'
   || ' WHERE code_tableau = ''FLOWS''', 'ENTN,FLX01');
   check_eq('every line''s label emptied',
      'SELECT COUNT(*) FROM op.param_fiche_val_detail WHERE description IS NOT NULL', '0');

   -- --- EPF view: one applied translation per identity -----------------------
   check_eq('EPF view: one row per identity',
      'SELECT COUNT(*) FROM atrace.ref_tables_modif', '25');
   check_eq('EPF view: SHRD once as tiers, once as compte_banque, different values',
      'SELECT COUNT(DISTINCT new_value) FROM atrace.ref_tables_modif WHERE old_value = ''SHRD''', '2');

   -- --- Mapping: X_ format, uniqueness, allocation order ----------------------
   check_eq('X_ translations have the X_ format',
      'SELECT COUNT(*) FROM anon_meta.code_map WHERE category = ''UNCLASSIFIED_PARTY'''
   || ' AND NOT REGEXP_LIKE(new_code, ''^X_[0-9]{7}$'')', '0');
   check_eq('allocation follows the binary order of the original',
      'SELECT new_code FROM anon_meta.code_map WHERE category = ''ENTITY'' AND old_code = ''EDUP''',
      'E_0000001');
END;
/

EXIT SUCCESS
