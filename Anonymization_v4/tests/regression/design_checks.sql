-- ============================================================================
-- Design checks - sections 7 and 7A of "fixes+needed_in_v4.txt"
-- ============================================================================
-- SELECT-only, on fictional inline data. These check the POLICY (the account
-- union with typed lookup, and the party classification order) - not the
-- engine, which assert_core.sql checks on real tables. Runs on any database.
--
-- One change from the specification: an account node is any node on the
-- w_compte_banque screen. The specification also required structure =
-- 'Compte'; the business confirmed (2026-10-20) that the screen alone decides.
--
-- Expected:
--   TYPED_ACCOUNT_DESIGN_CHECK          3 candidates, 0 inconsistent, 1 party node
--   PARTY_CLASSIFICATION_DESIGN_CHECK   16 cases, 0 mismatches, 4 E, 3 P, 1 T, 8 X
-- ============================================================================

SET HEADING OFF
SET FEEDBACK OFF
SET PAGESIZE 0
SET LINESIZE 200
WHENEVER SQLERROR EXIT FAILURE

-- TYPED_ACCOUNT_DESIGN_CHECK
WITH sample_bank AS (
 SELECT 'DEMO_SHARED' AS code, 'O' AS flag_gere FROM dual
 UNION ALL SELECT 'DEMO_BANK_ONLY', 'N' FROM dual
), sample_structure AS (
 SELECT 'DEMO_SHARED' AS code, 'Compte' AS structure,
 'w_compte_banque' AS ecran FROM dual
 UNION ALL SELECT 'DEMO_NODE_ONLY', 'Compte', 'w_compte_banque' FROM dual
 UNION ALL SELECT 'DEMO_SHARED', 'Entite', 'w_tiers' FROM dual
), account_candidates AS (
 SELECT code FROM sample_bank
 UNION
 SELECT code FROM sample_structure
 WHERE ecran='w_compte_banque'
), planned_map AS (
 SELECT 'BANK_ACCOUNT' AS category, 'DEMO_SHARED' AS old_code,
 'CB_DEMO_SHARED' AS new_code FROM dual
 UNION ALL SELECT 'BANK_ACCOUNT','DEMO_BANK_ONLY','CB_DEMO_BANK' FROM dual
 UNION ALL SELECT 'BANK_ACCOUNT','DEMO_NODE_ONLY','CB_DEMO_NODE' FROM dual
 UNION ALL SELECT 'ENTITY','DEMO_SHARED','E_DEMO_PARTY' FROM dual
), target_plan AS (
 SELECT 'BANK_MASTER' AS target_kind, code AS old_code,
 'BANK_ACCOUNT' AS required_category FROM sample_bank
 UNION ALL
 SELECT 'ACCOUNT_NODE', code, 'BANK_ACCOUNT' FROM sample_structure
 WHERE ecran='w_compte_banque'
 UNION ALL
 SELECT 'PARTY_NODE', code, 'ENTITY' FROM sample_structure
 WHERE structure='Entite' AND ecran='w_tiers'
), resolved AS (
 SELECT target.*, mapping.new_code
 FROM target_plan target
 LEFT JOIN planned_map mapping ON mapping.old_code=target.old_code
 AND mapping.category=target.required_category
)
SELECT CASE WHEN account_candidates = 3 AND inconsistent_account_targets = 0
                 AND separate_party_nodes = 1 THEN 'PASS' ELSE 'FAIL' END
    || '  TYPED_ACCOUNT_DESIGN_CHECK  candidates=' || account_candidates
    || ' inconsistent=' || inconsistent_account_targets
    || ' separate_party_nodes=' || separate_party_nodes
  FROM (
SELECT (SELECT COUNT(*) FROM account_candidates) AS account_candidates,
 (SELECT COUNT(*) FROM resolved target
 WHERE target.required_category='BANK_ACCOUNT'
 AND (target.new_code IS NULL OR NOT EXISTS (
 SELECT 1 FROM planned_map account_map
 WHERE account_map.category='BANK_ACCOUNT'
 AND account_map.old_code=target.old_code
 AND account_map.new_code=target.new_code
 ))) AS inconsistent_account_targets,
 (SELECT COUNT(*) FROM resolved party_node
 JOIN planned_map account_map ON account_map.old_code=party_node.old_code
 AND account_map.category='BANK_ACCOUNT'
 WHERE party_node.target_kind='PARTY_NODE'
 AND party_node.new_code<>account_map.new_code) AS separate_party_nodes
FROM dual);

-- PARTY_CLASSIFICATION_DESIGN_CHECK
WITH sample_party AS (
 SELECT 'ENTITY_N' AS case_id, 1 AS has_master, 'N' AS portfolio_flag,
 'ENTITY' AS expected_category FROM dual
 UNION ALL SELECT 'PORTFOLIO_CUSTOM',1,'O','PORTFOLIO' FROM dual
 UNION ALL SELECT 'COUNTERPARTY_N',1,'N','COUNTERPARTY' FROM dual
 UNION ALL SELECT 'ENTITY_OVERLAP',1,'N','ENTITY' FROM dual
 UNION ALL SELECT 'PORTFOLIO_OVERLAP',1,'O','PORTFOLIO' FROM dual
 UNION ALL SELECT 'NULL_FLAG',1,NULL,'UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'INVALID_FLAG',1,'?','UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NO_MASTER_ENTITE',0,NULL,'UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NO_MASTER_COMPTE',0,NULL,'UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NO_STRUCTURE_N',1,'N','UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NO_STRUCTURE_O',1,'O','UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NULL_CLASS_N',1,'N','UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'NULL_CLASS_O',1,'O','PORTFOLIO' FROM dual
 UNION ALL SELECT 'OTHER_SCREEN_N',1,'N','UNCLASSIFIED_PARTY' FROM dual
 UNION ALL SELECT 'ENTITY_OTHER_SCREEN',1,'N','ENTITY' FROM dual
 UNION ALL SELECT 'DUPLICATE_ENTITY',1,'N','ENTITY' FROM dual
), sample_node AS (
 SELECT case_id, 'Entite' AS structure, 'w_tiers' AS ecran
 FROM sample_party
 WHERE case_id IN ('ENTITY_N','ENTITY_OVERLAP','PORTFOLIO_OVERLAP',
 'NULL_FLAG','INVALID_FLAG','NO_MASTER_ENTITE','ENTITY_OTHER_SCREEN',
 'DUPLICATE_ENTITY')
 UNION ALL
 SELECT case_id,'CustomClass','w_tiers' FROM sample_party
 WHERE case_id IN ('PORTFOLIO_CUSTOM','COUNTERPARTY_N','ENTITY_OVERLAP',
 'PORTFOLIO_OVERLAP')
 UNION ALL SELECT 'NO_MASTER_COMPTE','Compte','w_tiers' FROM dual
 UNION ALL SELECT case_id,NULL,'w_tiers' FROM sample_party
 WHERE case_id IN ('NULL_CLASS_N','NULL_CLASS_O')
 UNION ALL SELECT 'OTHER_SCREEN_N','Entite','other_screen' FROM dual
 UNION ALL SELECT 'ENTITY_OTHER_SCREEN','CustomClass','other_screen' FROM dual
 UNION ALL SELECT 'DUPLICATE_ENTITY','Entite','w_tiers' FROM dual
), party_facts AS (
 SELECT party.*,
 CASE WHEN EXISTS (
 SELECT 1 FROM sample_node node
 WHERE node.case_id=party.case_id AND node.ecran='w_tiers'
 ) THEN 1 ELSE 0 END AS has_party_node,
 CASE WHEN EXISTS (
 SELECT 1 FROM sample_node node
 WHERE node.case_id=party.case_id AND node.ecran='w_tiers'
 AND node.structure='Entite'
 ) THEN 1 ELSE 0 END AS has_entity_node,
 CASE WHEN EXISTS (
 SELECT 1 FROM sample_node node
 WHERE node.case_id=party.case_id AND node.ecran='w_tiers'
 AND node.structure<>'Entite'
 ) THEN 1 ELSE 0 END AS has_non_entity_node
 FROM sample_party party
), classified AS (
 SELECT facts.*,
 CASE WHEN has_master=0 THEN 'UNCLASSIFIED_PARTY'
 WHEN portfolio_flag='O' AND has_party_node=1 THEN 'PORTFOLIO'
 WHEN portfolio_flag='N' AND has_entity_node=1 THEN 'ENTITY'
 WHEN portfolio_flag='N' AND has_non_entity_node=1
 AND has_entity_node=0 THEN 'COUNTERPARTY'
 ELSE 'UNCLASSIFIED_PARTY' END AS assigned_category
 FROM party_facts facts
)
SELECT CASE WHEN tested_cases = 16 AND mismatches = 0 AND entity_cases = 4 AND portfolio_cases = 3
                 AND counterparty_cases = 1 AND x_cases = 8 THEN 'PASS' ELSE 'FAIL' END
    || '  PARTY_CLASSIFICATION_DESIGN_CHECK  cases=' || tested_cases || ' mismatches=' || mismatches
    || ' E=' || entity_cases || ' P=' || portfolio_cases || ' T=' || counterparty_cases
    || ' X=' || x_cases
  FROM (
SELECT COUNT(*) AS tested_cases,
 COUNT(CASE WHEN assigned_category<>expected_category THEN 1 END) AS mismatches,
 COUNT(CASE WHEN assigned_category='ENTITY' THEN 1 END) AS entity_cases,
 COUNT(CASE WHEN assigned_category='PORTFOLIO' THEN 1 END) AS portfolio_cases,
 COUNT(CASE WHEN assigned_category='COUNTERPARTY' THEN 1 END) AS counterparty_cases,
 COUNT(CASE WHEN assigned_category='UNCLASSIFIED_PARTY' THEN 1 END) AS x_cases
FROM classified);

EXIT SUCCESS
