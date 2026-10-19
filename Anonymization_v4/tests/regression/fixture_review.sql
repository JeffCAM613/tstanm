-- ============================================================================
-- Regression fixture - cases that must be left for REVIEW
-- ============================================================================
-- Run as SYS after fixture_data.sql. Adds values whose role or domain the data
-- cannot establish. None may be guessed: each must stay unchanged and be
-- reported, and verification must answer REVIEW REQUIRED, not PASS.
-- ============================================================================

SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

--   OSCN  flag N, its only node is on another screen  -> X_ NO_PARTY_SCREEN;
--         the other-screen node itself is left for review
--   EOSC  flag N, Entite on w_tiers AND a node on another screen
--                                                     -> ENTITY; the other-
--         screen node is left for review (its role is not established)
INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('OSCN', 'N', 'Other screen party');
INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('EOSC', 'N', 'Entity elsewhere too');

INSERT INTO op.structure (code, structure, ecran, pere, description)
SELECT 'OSCN', 'Entite',      'w_autre', NULL,   'Other screen node' FROM dual UNION ALL
SELECT 'EOSC', 'Entite',      'w_tiers', NULL,   NULL                FROM dual UNION ALL
SELECT 'EOSC', 'CustomClass', 'w_autre', NULL,   NULL                FROM dual UNION ALL
-- A parent whose text is a party node AND an account node: which one is meant
-- cannot be established, so the reference is left as it is.
SELECT 'AMBC', 'Compte',      'w_tiers', 'SHRD', NULL                FROM dual;

INSERT INTO op.tiers (code, flag_portefeuille, description) VALUES ('AMBC', 'N', 'Child of an ambiguous parent');

-- A MIXED column holding the text that is both a party and an account.
INSERT INTO op.ventiler_compte (id, valeur_1, valeur_2) VALUES (3, 'SHRD', NULL);
INSERT INTO op.histo_operation (id, entite, clearing_member) VALUES (5, 'EOSC', 'SHRD');

COMMIT;

PROMPT review fixture loaded
EXIT SUCCESS
