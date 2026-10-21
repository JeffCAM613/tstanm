-- ============================================================================
-- Regression fixture - cases that must be left for REVIEW
-- ============================================================================
-- Run as SYS after fixture_data.sql. Adds values whose domain the data cannot
-- establish: a text that is a party AND an account, in a MIXED column with no
-- breakdown to settle it. None may be guessed: each must stay unchanged and be
-- reported, and verification must answer REVIEW REQUIRED, not PASS.
--
-- Also two cases that used to be left for review and no longer are (part 2 of
-- the fix instructions, items 4 and 5): a node on another screen keeps its
-- code without being reported, and a parent that is a party node AND an
-- account node is the one in its child's own tree.
-- ============================================================================

SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

--   OSCN  flag N, its only node is on another screen  -> X_ NO_PARTY_SCREEN;
--         the other-screen node itself keeps its code
--   EOSC  flag N, Entite on w_tiers AND a node on another screen
--                                                     -> ENTITY; the other-
--         screen node keeps its code
INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('OSCN', 'N', 'Other screen party');
INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('EOSC', 'N', 'Entity elsewhere too');

INSERT INTO op.structure (code, structure, ecran, pere, description)
SELECT 'OSCN', 'Entite',      'w_autre', NULL,   'Other screen node' FROM dual UNION ALL
SELECT 'EOSC', 'Entite',      'w_tiers', NULL,   NULL                FROM dual UNION ALL
SELECT 'EOSC', 'CustomClass', 'w_autre', NULL,   NULL                FROM dual UNION ALL
-- A parent whose text is a party node (Entite) AND an account node (Compte):
-- AMBC is in the Compte tree, so its parent is the account node.
SELECT 'AMBC', 'Compte',      'w_tiers', 'SHRD', NULL                FROM dual;

INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('AMBC', 'N', 'Child of an ambiguous parent');

-- MIXED columns holding the text that is both a party and an account, with no
-- breakdown to settle it.
INSERT INTO op.ventiler_compte (id, valeur_1, valeur_2) VALUES (3, 'SHRD', NULL);
INSERT INTO op.histo_operation (id, entite, clearing_member) VALUES (5, 'EOSC', 'SHRD');

COMMIT;

PROMPT review fixture loaded
EXIT SUCCESS
