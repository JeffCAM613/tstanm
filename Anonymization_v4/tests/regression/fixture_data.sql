-- ============================================================================
-- Regression fixture - fictional data
-- ============================================================================
-- Run as SYS after fixture_schema.sql. Every value is invented.
--
-- Each identity is named after the case it exercises. The expected category,
-- reason and outcome of every one is asserted in assert_core.sql; the cases
-- come from section 7, 7A and 6 of "fixes+needed_in_v4.txt".
--
-- This is the CORE fixture: with every switch on and structure-only accounts
-- approved, a run on it must verify PASS. fixture_review.sql adds the cases
-- that must be left for review.
-- ============================================================================

SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

-- ----------------------------------------------------------------------------
-- Parties: tiers rows (code, flag_portefeuille, description, address, contact)
-- ----------------------------------------------------------------------------
--   ENTN  flag N + Entite node                    -> ENTITY
--   PCUS  flag O + custom-class node              -> PORTFOLIO
--   CPTN  flag N + custom-class node, no Entite   -> COUNTERPARTY
--   CPTC  flag N + Compte node on w_tiers         -> COUNTERPARTY
--   EOVL  flag N + Entite AND custom nodes        -> ENTITY (precedence, logged)
--   POVL  flag O + Entite AND custom nodes        -> PORTFOLIO
--   NFLG  flag NULL + Entite node                 -> X_  UNKNOWN_FLAG
--   IFLG  flag '?' + Entite node                  -> X_  UNKNOWN_FLAG
--   NSTN  flag N, no structure node at all        -> X_  NO_STRUCTURE (has
--                                                      description, address,
--                                                      phone - all must be masked)
--   NSTO  flag O, no structure node               -> X_  NO_STRUCTURE
--   NCLN  flag N + node with NULL classification  -> X_  UNKNOWN_CLASSIFICATION
--   NCLO  flag O + node with NULL classification  -> PORTFOLIO
--   EDUP  flag N + the same Entite node twice     -> ENTITY
--   SHRD  flag N + Entite node, AND a bank account with the same text
--                                                 -> ENTITY, with its own E_;
--                                                    the account keeps its CB_
--   Z     flag N + Entite node, one character     -> ENTITY (no short-code skip)
INSERT INTO op.tiers (code, flag_portefeuille, description, adresse1, adresse2, telephone, fax,
                      email_adress, nom_pp, dpt_naissance, groupe_1, flag_pp, entite_pere)
SELECT 'ENTN', 'N', 'Entity N Ltd',     '1 Entity Road', NULL, '0101', NULL, 'n@entity.test', NULL, '75', 'GRP-A', 'N', NULL FROM dual UNION ALL
SELECT 'PCUS', 'O', 'Custom portfolio', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'GRP-B', 'N', 'ENTN' FROM dual UNION ALL
SELECT 'CPTN', 'N', 'Counterparty N',   '2 Cpty Street', NULL, '0202', '0203', NULL, NULL, NULL, NULL, 'O', NULL FROM dual UNION ALL
SELECT 'CPTC', 'N', 'Counterparty C',   NULL, NULL, NULL, NULL, NULL, 'Martin', NULL, NULL, 'O', NULL FROM dual UNION ALL
SELECT 'EOVL', 'N', 'Overlap entity',   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'POVL', 'O', 'Overlap portfolio',NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'NFLG', NULL,'Null flag party',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM dual UNION ALL
SELECT 'IFLG', '?', 'Invalid flag',     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'NSTN', 'N', 'Orphan party N',   '9 Orphan Lane', 'Floor 2', '0909', NULL, 'o@orphan.test', 'Durand', '13', NULL, 'O', NULL FROM dual UNION ALL
SELECT 'NSTO', 'O', 'Orphan portfolio', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'NCLN', 'N', 'Null class N',     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'NCLO', 'O', 'Null class O',     NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'EDUP', 'N', 'Duplicate node',   NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'SHRD', 'N', 'Shared text party','5 Shared Ave', NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual UNION ALL
SELECT 'Z',    'N', 'One-char entity',  NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, 'N', NULL FROM dual;

-- ----------------------------------------------------------------------------
-- Structure nodes
-- ----------------------------------------------------------------------------
--   NMEN  an Entite node on w_tiers with NO tiers row       -> X_ MISSING_MASTER
--   NMCP  a Compte node on w_tiers with NO tiers row        -> X_ MISSING_MASTER
--         (the old engine made it a counterparty)
--   account nodes (Compte on w_compte_banque):
--     SHRD     same text as the party SHRD - must get the ACCOUNT's CB_
--     NODEONLY no compte_banque row: STRUCTURE_ONLY, needs approval
--     BKDUP    twice, plus a compte_banque row: one identity, BOTH
INSERT INTO op.structure (code, structure, ecran, pere, description)
SELECT 'ENTN',     'Entite',      'w_tiers',         NULL,     'Entity N node'     FROM dual UNION ALL
SELECT 'PCUS',     'CustomClass', 'w_tiers',         'ENTN',   'Portfolio node'    FROM dual UNION ALL
SELECT 'CPTN',     'CustomClass', 'w_tiers',         'ENTN',   NULL                FROM dual UNION ALL
SELECT 'CPTC',     'Compte',      'w_tiers',         'ENTN',   'Counterparty node' FROM dual UNION ALL
SELECT 'EOVL',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'EOVL',     'CustomClass', 'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'POVL',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'POVL',     'CustomClass', 'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'NFLG',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'IFLG',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'NMEN',     'Entite',      'w_tiers',         NULL,     'No master entite'  FROM dual UNION ALL
SELECT 'NMCP',     'Compte',      'w_tiers',         'ENTN',   'No master compte'  FROM dual UNION ALL
SELECT 'NCLN',     NULL,          'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'NCLO',     NULL,          'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'EDUP',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'EDUP',     'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
SELECT 'SHRD',     'Entite',      'w_tiers',         NULL,     'Shared party node' FROM dual UNION ALL
SELECT 'Z',        'Entite',      'w_tiers',         NULL,     NULL                FROM dual UNION ALL
-- account nodes; the parent of an account node is a PARTY node here
SELECT 'SHRD',     'Compte',      'w_compte_banque', 'ENTN',   'Shared account node' FROM dual UNION ALL
SELECT 'NODEONLY', 'Compte',      'w_compte_banque', 'ENTN',   'Node only account' FROM dual UNION ALL
SELECT 'BKDUP',    'Compte',      'w_compte_banque', 'ENTN',   NULL                FROM dual UNION ALL
SELECT 'BKDUP',    'Compte',      'w_compte_banque', 'ENTN',   NULL                FROM dual UNION ALL
-- a node whose parent exists only as a bank account (no node): ACCOUNT parent
SELECT 'CHLD',     'Compte',      'w_compte_banque', 'BKONLY', NULL                FROM dual;

-- ----------------------------------------------------------------------------
-- Bank accounts
-- ----------------------------------------------------------------------------
--   SHRD    flag_gere O, with a node                -> BANK_ACCOUNT, BOTH
--   BKONLY  flag_gere N, no node                    -> BANK_ACCOUNT, MASTER_ONLY
--   BKNULL  flag_gere NULL - not a selection gate   -> BANK_ACCOUNT, MASTER_ONLY
--   BKDUP   with two nodes                          -> one identity, BOTH
--   Q       one character                           -> BANK_ACCOUNT (no skip)
--   CHLD    the node above                          -> BOTH
INSERT INTO op.compte_banque (code, flag_gere, description, entite, banque, groupe_1, groupe_2)
SELECT 'SHRD',   'O', 'Shared account',  'SHRD', 'ENTN', 'ACC-GRP', NULL FROM dual UNION ALL
SELECT 'BKONLY', 'N', 'Master only',     'ENTN', NULL,   NULL,      NULL FROM dual UNION ALL
SELECT 'BKNULL', NULL,'Null gere',       'ENTN', NULL,   NULL,      NULL FROM dual UNION ALL
SELECT 'BKDUP',  'O', NULL,              'PCUS', NULL,   NULL,      NULL FROM dual UNION ALL
SELECT 'Q',      'O', 'One-char account',NULL,   NULL,   NULL,      NULL FROM dual UNION ALL
SELECT 'CHLD',   'O', NULL,              NULL,   NULL,   NULL,      NULL FROM dual;

-- ----------------------------------------------------------------------------
-- References
-- ----------------------------------------------------------------------------
-- histo_operation: PARTY columns, BANK_ACCOUNT columns, a MIXED column and
-- free text. Row 3 is THE regression: the same text SHRD in a party column and
-- in an account column must get two different replacements.
INSERT INTO op.histo_operation (id, entite, contrepartie, compensateur, clearing_member,
                                compte_tiers, compte_entite, tiers_libelle, description, groupe_1)
SELECT 1, 'ENTN', 'CPTC', 'ENTN', 'ENTN',   'BKONLY', 'BKNULL', 'Cpty C free text', 'free', 'g' FROM dual UNION ALL
SELECT 2, 'Z',    'NMCP', 'CPTN', 'BKONLY', 'Q',      NULL,     NULL,               NULL,   NULL FROM dual UNION ALL
SELECT 3, 'SHRD', 'SHRD', NULL,   NULL,     'SHRD',   'SHRD',   'Shared',           'x',    NULL FROM dual UNION ALL
SELECT 4, 'NSTN', 'X',    NULL,   'CPTN',   'NODEONLY', NULL,   NULL,               NULL,   NULL FROM dual;

INSERT INTO op.ventiler_compte (id, valeur_1, valeur_2)
SELECT 1, 'CPTC', 'BKNULL' FROM dual UNION ALL
SELECT 2, 'EUR',  NULL     FROM dual;

INSERT INTO op.param_cpta_reg_gen (id, portefeuille, compte_ana)
SELECT 1, 'PCUS', 'ENTN'   FROM dual UNION ALL
SELECT 2, 'NCLO', 'BKONLY' FROM dual;

INSERT INTO op.compte_regle (id, entite, compte)
SELECT 1, 'ENTN', 'Q'        FROM dual UNION ALL
SELECT 2, 'EOVL', 'NODEONLY' FROM dual UNION ALL
SELECT 3, 'NFLG', 'BKDUP'    FROM dual;

-- tiers_entite is a one-character discriminator the inventory no longer lists:
-- its 'T' and 'E' must be untouched.
INSERT INTO op.val_ssi_account (id, tiers_entite, compte)
SELECT 1, 'T', 'SHRD' FROM dual UNION ALL
SELECT 2, 'E', 'BKONLY' FROM dual;

INSERT INTO op.histo_pricing_groupe (id, description) VALUES (1, 'Real client pricing note');
INSERT INTO op.utilisateur (code, description) VALUES ('U1', 'Jane at the client');
INSERT INTO op.anon_fixture_extra (id, one_char, locked_num) VALUES (1, 'y', 7);

COMMIT;

PROMPT fixture data loaded
EXIT SUCCESS
