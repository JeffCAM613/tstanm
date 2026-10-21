-- ============================================================================
-- Regression fixture - part 2 of the fix instructions
-- ============================================================================
-- Run as SYS after fixture_data.sql. The cases of items 2A, 3, 4, 5 and 6 of
-- "fixes+needed_in_v4-part2.txt", every one of which must end in PASS - the
-- ones still left for review are added by run_regression.sh (S21). Every value
-- is invented. assert_part2.sql checks the outcome.
-- ============================================================================

SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

-- ----------------------------------------------------------------------------
-- Items 2A and 3: codes found only in references - their master was deleted
-- ----------------------------------------------------------------------------
--   GONEP  in a party column, no tiers row, no node      -> X_, reference only
--   GONEA  in an account column, no account, no node     -> CB_, reference only
--   Q      an ACCOUNT's code in a party column           -> a party X_ as well
--   PCUS   a PARTY's code in an account column           -> an account CB_ as well
--   ' '    blank, in an account column                   -> no code at all
INSERT INTO op.compte_regle (id, entite, compte) VALUES (4, 'GONEP', 'GONEA');
INSERT INTO op.compte_regle (id, entite, compte) VALUES (5, 'Q', 'PCUS');
INSERT INTO op.compte_regle (id, entite, compte) VALUES (6, NULL, ' ');

-- ----------------------------------------------------------------------------
-- Items 4 and 5: the structure, tree by tree
-- ----------------------------------------------------------------------------
--   Compta - a folder tree ([folders: ...] on structure.code):
--     SHRD    folder row (no screen) named after SHRD, a party AND an
--             account: the party's translation, its label too
--     BKONLY  folder row named after an account only: the account's
--     ACTIF   folder row named after no one: keeps its code, its text emptied
--     C512    a node on another screen, under ACTIF: untouched
--   PosteFlux - not a folder tree:
--     CPTN    folder row whose code is a party's: keeps it, its text emptied
--     FLX1    a node on another screen under it: untouched, and so is its pere
--   Titre - not a folder tree:
--     Z       a node on another screen whose code is a party's: untouched
--   KIDP, KIDA  children of SHRD - in the Entite tree, where SHRD is a party
--             node, and in the Compte tree, where it is an account node: each
--             follows the parent of its own tree
INSERT INTO op.structure (code, structure, ecran, pere, description)
SELECT 'SHRD',   'Compta',    NULL,              NULL,    'Client group'          FROM dual UNION ALL
SELECT 'BKONLY', 'Compta',    NULL,              'SHRD',  'Bank of the client'    FROM dual UNION ALL
SELECT 'ACTIF',  'Compta',    NULL,              'SHRD',  'Assets of the client'  FROM dual UNION ALL
SELECT 'C512',   'Compta',    'w_compte_compta', 'ACTIF', 'Account 512'           FROM dual UNION ALL
SELECT 'CPTN',   'PosteFlux', NULL,              NULL,    'Flows of the client'   FROM dual UNION ALL
SELECT 'FLX1',   'PosteFlux', 'w_poste_flux',    'CPTN',  'Flow 1'                FROM dual UNION ALL
SELECT 'Z',      'Titre',     'w_titre',         NULL,    'Security Z'            FROM dual UNION ALL
SELECT 'KIDP',   'Entite',    'w_tiers',         'SHRD',  NULL                    FROM dual UNION ALL
SELECT 'KIDA',   'Compte',    'w_compte_banque', 'SHRD',  NULL                    FROM dual;

-- ----------------------------------------------------------------------------
-- Item 6: MIXED breakdowns ([group: code] on ventiler_compte)
-- ----------------------------------------------------------------------------
--   CONV_BQ  an account and SHRD (a party AND an account) -> SHRD takes CB_
--   CONV_CC  a party and SHRD                             -> SHRD takes E_
INSERT INTO op.ventiler_compte (id, code, valeur_1, valeur_2)
SELECT 10, 'CONV_BQ', 'BKONLY', NULL FROM dual UNION ALL
SELECT 11, 'CONV_BQ', 'SHRD',   NULL FROM dual UNION ALL
SELECT 12, 'CONV_CC', 'CPTC',   NULL FROM dual UNION ALL
SELECT 13, 'CONV_CC', 'SHRD',   NULL FROM dual;

COMMIT;

PROMPT part 2 fixture loaded
EXIT SUCCESS
