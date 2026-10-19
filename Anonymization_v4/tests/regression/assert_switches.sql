-- ============================================================================
-- Assertions - one combination of the three switches, for every category
-- ============================================================================
--   @assert_switches.sql <id y|n> <description y|n> <attributes y|n>
--
-- Run as SYS after one EXECUTE run on the core fixture in which ALL FIVE
-- categories had that combination. Eight runs cover the eight combinations of
-- section 5B for every category, unclassified parties included.
--
-- For one representative identity per category it checks:
--   a translation exists         exactly when any switch is on
--   identifiers and references   renamed when ID is on, ORIGINAL when off
--   the description              the identity's translation when DESCRIPTION
--                                is on - also when its ID was kept - else the
--                                original label
--   attributes and addresses     likewise under ATTRIBUTES; an empty one stays
--                                empty either way
--   the EPF view                 lists the identity only when its ID was renamed
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DEFINE sw_id   = &1
DEFINE sw_desc = &2
DEFINE sw_attr = &3

DECLARE
   v_id   BOOLEAN := LOWER('&sw_id')   = 'y';
   v_desc BOOLEAN := LOWER('&sw_desc') = 'y';
   v_attr BOOLEAN := LOWER('&sw_attr') = 'y';
   v_tag  VARCHAR2(20) := '[&sw_id/&sw_desc/&sw_attr] ';

   PROCEDURE check_eq(p_name IN VARCHAR2, p_sql IN VARCHAR2, p_expect IN VARCHAR2) IS
      v VARCHAR2(4000);
   BEGIN
      EXECUTE IMMEDIATE p_sql INTO v;
      IF (v = p_expect) OR (v IS NULL AND p_expect IS NULL) THEN
         DBMS_OUTPUT.PUT_LINE('PASS  ' || v_tag || p_name);
      ELSE
         DBMS_OUTPUT.PUT_LINE('FAIL  ' || v_tag || p_name || '   got [' || v || '] expected [' || p_expect || ']');
      END IF;
   EXCEPTION
      WHEN OTHERS THEN
         DBMS_OUTPUT.PUT_LINE('FAIL  ' || v_tag || p_name || '   ' || SQLERRM);
   END check_eq;

   FUNCTION tr(p_domain IN VARCHAR2, p_old IN VARCHAR2) RETURN VARCHAR2 IS
      v VARCHAR2(80);
   BEGIN
      SELECT MAX(c.new_code) INTO v
        FROM anon_meta.identity_inventory i
        JOIN anon_meta.code_map c ON c.category = i.map_category AND c.old_code = i.old_code
       WHERE i.domain = p_domain AND i.old_code = p_old;
      RETURN v;
   END tr;

   -- One identity: its master row, one reference, its label, its attributes.
   PROCEDURE identity(
      p_label     IN VARCHAR2,
      p_domain    IN VARCHAR2,
      p_old       IN VARCHAR2,
      p_master    IN VARCHAR2,       -- table holding code / description / attributes
      p_ref_sql   IN VARCHAR2,       -- SELECT returning the reference value
      p_desc_orig IN VARCHAR2,
      p_attr_col  IN VARCHAR2,       -- a populated attribute
      p_attr_orig IN VARCHAR2,
      p_null_col  IN VARCHAR2)       -- an empty attribute of the same owner
   IS
      v_new  VARCHAR2(80) := tr(p_domain, p_old);
      v_code VARCHAR2(80);
   BEGIN
      check_eq(p_label || ': translation exists only when a switch is on',
               'SELECT CASE WHEN ''' || v_new || ''' IS NULL THEN ''none'' ELSE ''one'' END FROM dual',
               CASE WHEN v_id OR v_desc OR v_attr THEN 'one' ELSE 'none' END);

      v_code := CASE WHEN v_id THEN v_new ELSE p_old END;
      check_eq(p_label || ': master identifier ' || CASE WHEN v_id THEN 'renamed' ELSE 'kept' END,
               'SELECT COUNT(*) FROM op.' || p_master || ' WHERE code = ''' || v_code || '''', '1');
      check_eq(p_label || ': reference ' || CASE WHEN v_id THEN 'renamed' ELSE 'kept' END,
               p_ref_sql, v_code);

      check_eq(p_label || ': description ' || CASE WHEN v_desc THEN 'masked' ELSE 'kept' END,
               'SELECT description FROM op.' || p_master || ' WHERE code = ''' || v_code || '''',
               CASE WHEN v_desc THEN v_new ELSE p_desc_orig END);

      check_eq(p_label || ': attribute ' || CASE WHEN v_attr THEN 'masked' ELSE 'kept' END,
               'SELECT ' || p_attr_col || ' FROM op.' || p_master || ' WHERE code = ''' || v_code || '''',
               CASE WHEN v_attr THEN v_new ELSE p_attr_orig END);

      check_eq(p_label || ': empty attribute stays empty',
               'SELECT NVL(' || p_null_col || ', ''<empty>'') FROM op.' || p_master
            || ' WHERE code = ''' || v_code || '''', '<empty>');

      check_eq(p_label || ': in the EPF view only when renamed',
               'SELECT COUNT(*) FROM atrace.ref_tables_modif WHERE old_value = ''' || p_old || ''''
            || ' AND table_name = ''' || CASE p_domain WHEN 'ACCOUNT' THEN 'compte_banque' ELSE 'tiers' END
            || '''', CASE WHEN v_id THEN '1' ELSE '0' END);

      -- A description or attribute never receives the ORIGINAL identifier as
      -- its "mask" - the trap when ID renaming is off.
      check_eq(p_label || ': original code never written as a mask',
               'SELECT COUNT(*) FROM op.' || p_master || ' WHERE code = ''' || v_code || ''''
            || ' AND (description = ''' || p_old || ''' OR ' || p_attr_col || ' = ''' || p_old || ''')',
               '0');
   END identity;
BEGIN
   identity('entity ENTN', 'PARTY', 'ENTN', 'tiers',
            'SELECT entite FROM op.histo_operation WHERE id = 1',
            'Entity N Ltd', 'telephone', '0101', 'fax');
   identity('portfolio PCUS', 'PARTY', 'PCUS', 'tiers',
            'SELECT portefeuille FROM op.param_cpta_reg_gen WHERE id = 1',
            'Custom portfolio', 'groupe_1', 'GRP-B', 'adresse1');
   identity('counterparty CPTN', 'PARTY', 'CPTN', 'tiers',
            'SELECT compensateur FROM op.histo_operation WHERE id = 2',
            'Counterparty N', 'adresse1', '2 Cpty Street', 'adresse2');
   identity('unclassified NSTN', 'PARTY', 'NSTN', 'tiers',
            'SELECT entite FROM op.histo_operation WHERE id = 4',
            'Orphan party N', 'nom_pp', 'Durand', 'fax');
   identity('bank account SHRD', 'ACCOUNT', 'SHRD', 'compte_banque',
            'SELECT compte_tiers FROM op.histo_operation WHERE id = 3',
            'Shared account', 'groupe_1', 'ACC-GRP', 'groupe_2');
END;
/

EXIT SUCCESS
