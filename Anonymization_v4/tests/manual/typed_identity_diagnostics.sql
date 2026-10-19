-- ============================================================================
-- Typed identity diagnostics - read-only, counts only
-- ============================================================================
--   sqlplus op/<password>@<TNS> @tests/manual/typed_identity_diagnostics.sql
--
-- Answers, on THIS database, the questions the identity model depends on -
-- before a run, on raw data. Every result is a count or a structure/screen
-- name: no identifier and no client value is printed, so the output can be
-- shared.
--
-- Needs nothing installed: it reads op.tiers, op.compte_banque and
-- op.structure only. Oracle 19 or later.
--
--   1  is this copy raw, or anonymized already?
--   2  bank accounts by where they are found
--   3  parties by category, and the X_ reasons
--   4  texts that are a party AND a bank account
--   5  structure nodes by role, and other-screen nodes holding an identifier
--   6  the parent contract: what a node's pere points at, by node role
-- ============================================================================

SET PAGESIZE 200
SET LINESIZE 200
SET FEEDBACK OFF
SET HEADING ON
COLUMN check_name   FORMAT A46
COLUMN detail       FORMAT A40
COLUMN structure    FORMAT A20
COLUMN ecran        FORMAT A28
COLUMN role         FORMAT A12
COLUMN child_role   FORMAT A10
COLUMN parent_roles FORMAT A30

PROMPT
PROMPT ==== 1. Raw or already anonymized ===========================================
PROMPT A raw copy shows 0. A run refuses to start on values that look generated but
PROMPT that no mapping owns - reimport the raw data instead.
SELECT 'tiers.code looking generated' AS check_name, COUNT(*) AS n
  FROM op.tiers WHERE REGEXP_LIKE(code, '^(E|P|T|X|CB)_[0-9]{7}$')
UNION ALL
SELECT 'compte_banque.code looking generated', COUNT(*)
  FROM op.compte_banque WHERE REGEXP_LIKE(code, '^(E|P|T|X|CB)_[0-9]{7}$')
UNION ALL
SELECT 'structure.code looking generated', COUNT(*)
  FROM op.structure WHERE REGEXP_LIKE(code, '^(E|P|T|X|CB)_[0-9]{7}$');

PROMPT
PROMPT ==== 2. Bank accounts: compte_banque UNION Compte/w_compte_banque nodes ======
PROMPT STRUCTURE_ONLY needs APPROVE_STRUCTURE_ONLY_ACCOUNTS=y.
WITH acc AS (
   SELECT code, MAX(m) AS m, MAX(nd) AS nd
     FROM (SELECT code, 1 AS m, 0 AS nd FROM op.compte_banque WHERE code IS NOT NULL
           UNION ALL
           SELECT code, 0, 1 FROM op.structure
            WHERE structure = 'Compte' AND ecran = 'w_compte_banque' AND code IS NOT NULL)
    GROUP BY code)
SELECT CASE WHEN m = 1 AND nd = 1 THEN 'BOTH'
            WHEN m = 1 THEN 'MASTER_ONLY'
            ELSE 'STRUCTURE_ONLY' END AS check_name,
       COUNT(*) AS n
  FROM acc
 GROUP BY CASE WHEN m = 1 AND nd = 1 THEN 'BOTH' WHEN m = 1 THEN 'MASTER_ONLY' ELSE 'STRUCTURE_ONLY' END
 ORDER BY 1;

PROMPT
PROMPT ==== 3. Parties: tiers UNION w_tiers nodes, classified ======================
PROMPT The same order as the engine. Account nodes are not a party's nodes.
WITH k AS (
   SELECT code FROM op.tiers WHERE code IS NOT NULL
   UNION
   SELECT code FROM op.structure WHERE ecran = 'w_tiers' AND code IS NOT NULL
), f AS (
   SELECT k.code,
          (SELECT COUNT(*) FROM op.tiers t WHERE t.code = k.code) AS n_master,
          (SELECT CASE WHEN COUNT(DISTINCT NVL(t.flag_portefeuille, '~')) > 1 THEN 'CONFLICT'
                       ELSE NVL(MAX(t.flag_portefeuille), 'NULL') END
             FROM op.tiers t WHERE t.code = k.code) AS flag,
          (SELECT COUNT(*) FROM op.structure s WHERE s.code = k.code AND s.ecran = 'w_tiers') AS n_party,
          (SELECT COUNT(*) FROM op.structure s WHERE s.code = k.code AND s.ecran = 'w_tiers'
              AND s.structure = 'Entite') AS n_entite,
          (SELECT COUNT(*) FROM op.structure s WHERE s.code = k.code AND s.ecran = 'w_tiers'
              AND s.structure <> 'Entite') AS n_other_class,
          (SELECT COUNT(*) FROM op.structure s WHERE s.code = k.code
              AND NVL(s.ecran, '~') <> 'w_tiers'
              AND NOT (NVL(s.structure, '~') = 'Compte' AND NVL(s.ecran, '~') = 'w_compte_banque')) AS n_other_screen
     FROM k
), c AS (
   SELECT CASE WHEN n_master = 0                              THEN 'UNCLASSIFIED_PARTY'
               WHEN flag = 'O' AND n_party > 0                THEN 'PORTFOLIO'
               WHEN flag = 'N' AND n_entite > 0               THEN 'ENTITY'
               WHEN flag = 'N' AND n_other_class > 0          THEN 'COUNTERPARTY'
               ELSE 'UNCLASSIFIED_PARTY' END AS category,
          CASE WHEN n_master = 0                              THEN 'MISSING_MASTER'
               WHEN n_party = 0 AND n_other_screen = 0        THEN 'NO_STRUCTURE'
               WHEN n_party = 0                               THEN 'NO_PARTY_SCREEN'
               WHEN flag NOT IN ('O', 'N')                    THEN 'UNKNOWN_FLAG'
               ELSE 'UNKNOWN_CLASSIFICATION' END AS reason,
          CASE WHEN flag = 'N' AND n_entite > 0 AND n_other_class > 0 THEN 1 ELSE 0 END AS overlap
     FROM f
)
SELECT category || CASE WHEN category = 'UNCLASSIFIED_PARTY' THEN ' / ' || reason END AS check_name,
       COUNT(*) AS n,
       SUM(overlap) AS entity_precedence
  FROM c
 GROUP BY category || CASE WHEN category = 'UNCLASSIFIED_PARTY' THEN ' / ' || reason END
 ORDER BY 1;

PROMPT
PROMPT ==== 4. Texts that are a party AND a bank account ===========================
PROMPT Each keeps its own translation. In a MIXED column such a value is left for review.
SELECT COUNT(*) AS same_text
  FROM (SELECT code FROM op.tiers UNION SELECT code FROM op.structure WHERE ecran = 'w_tiers') p
  JOIN (SELECT code FROM op.compte_banque
        UNION SELECT code FROM op.structure WHERE structure = 'Compte' AND ecran = 'w_compte_banque') a
    ON a.code = p.code;

PROMPT
PROMPT ==== 5. Structure nodes by role ==============================================
PROMPT An other-screen node holding an identifier is left unchanged and reported for
PROMPT review. Which screens they sit on decides the reviewed policy to add next.
WITH s AS (
   SELECT x.structure, x.ecran,
          CASE WHEN x.structure = 'Compte' AND x.ecran = 'w_compte_banque' THEN 'ACCOUNT NODE'
               WHEN x.ecran = 'w_tiers' THEN 'PARTY NODE'
               ELSE 'OTHER' END AS role,
          CASE WHEN EXISTS (SELECT 1 FROM op.tiers t WHERE t.code = x.code)
                 OR EXISTS (SELECT 1 FROM op.compte_banque b WHERE b.code = x.code)
                 OR EXISTS (SELECT 1 FROM op.structure s2 WHERE s2.code = x.code
                             AND (s2.ecran = 'w_tiers'
                                  OR (s2.structure = 'Compte' AND s2.ecran = 'w_compte_banque')))
               THEN 1 ELSE 0 END AS is_identifier
     FROM op.structure x
)
SELECT NVL(structure, '(null)') AS structure, NVL(ecran, '(null)') AS ecran, role,
       COUNT(*) AS nodes,
       SUM(CASE WHEN role = 'OTHER' THEN is_identifier ELSE 0 END) AS other_holding_identifier
  FROM s
 GROUP BY structure, ecran, role
 ORDER BY 4 DESC;

PROMPT ==== 6. The parent contract ==================================================
PROMPT For each child role, the roles of the nodes its pere could point at. A parent
PROMPT text carried by more than one role is AMBIGUOUS and left for review.
WITH n AS (
   SELECT code, pere,
          CASE WHEN structure = 'Compte' AND ecran = 'w_compte_banque' THEN 'ACCOUNT'
               WHEN ecran = 'w_tiers' THEN 'PARTY' ELSE 'OTHER' END AS role
     FROM op.structure
), pr AS (
   SELECT code, LISTAGG(DISTINCT role, '+') WITHIN GROUP (ORDER BY role) AS roles
     FROM n GROUP BY code
), ch AS (
   SELECT c.role AS child_role,
          NVL(pr.roles,
              CASE WHEN EXISTS (SELECT 1 FROM op.tiers t WHERE t.code = c.pere)
                     OR EXISTS (SELECT 1 FROM op.compte_banque b WHERE b.code = c.pere)
                   THEN '(no node: master only)' ELSE '(no node, no master)' END) AS parent_roles
     FROM n c
     LEFT JOIN pr ON pr.code = c.pere
    WHERE c.pere IS NOT NULL
)
SELECT child_role, parent_roles, COUNT(*) AS children
  FROM ch
 GROUP BY child_role, parent_roles
 ORDER BY 1, 3 DESC;

PROMPT
