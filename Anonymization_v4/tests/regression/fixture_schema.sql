-- ============================================================================
-- Regression fixture - a small fictional OP schema
-- ============================================================================
-- Run as SYS on a DISPOSABLE database (a local container is ideal - see
-- README.md). Creates user OP and the tables the regression cases need, every
-- one of them EMPTY; fixture_data.sql fills them.
--
-- It refuses to touch an OP schema that it did not create itself: an OP user
-- without the marker table op.anon_fixture_marker is a real application schema.
--
--   sqlplus "sys/<pwd>@<host>:<port>/<service> as sysdba" @fixture_schema.sql
-- ============================================================================

SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK OFF
SET VERIFY OFF
WHENEVER SQLERROR EXIT FAILURE

DECLARE
   v_user   NUMBER;
   v_marker NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_user FROM dba_users WHERE username = 'OP';
   SELECT COUNT(*) INTO v_marker FROM dba_tables WHERE owner = 'OP' AND table_name = 'ANON_FIXTURE_MARKER';

   IF v_user > 0 AND v_marker = 0 THEN
      RAISE_APPLICATION_ERROR(-20900,
         'An OP schema exists here and it is not a regression fixture. This suite drops and '
      || 'recreates OP - run it only on a disposable database.');
   END IF;

   IF v_user > 0 THEN
      EXECUTE IMMEDIATE 'DROP USER op CASCADE';
   END IF;
   FOR u IN (SELECT username FROM dba_users WHERE username IN ('ANON_META', 'ATRACE')) LOOP
      EXECUTE IMMEDIATE 'DROP USER ' || u.username || ' CASCADE';
   END LOOP;

   EXECUTE IMMEDIATE 'CREATE USER op IDENTIFIED BY op DEFAULT TABLESPACE users QUOTA UNLIMITED ON users';
   EXECUTE IMMEDIATE 'GRANT CREATE SESSION, CREATE TABLE, CREATE TRIGGER, CREATE VIEW TO op';
END;
/

CREATE TABLE op.anon_fixture_marker (created_at DATE DEFAULT SYSDATE);
INSERT INTO op.anon_fixture_marker VALUES (SYSDATE);

-- ----------------------------------------------------------------------------
-- The three identity sources
-- ----------------------------------------------------------------------------
CREATE TABLE op.tiers (
   code              VARCHAR2(20) NOT NULL,
   flag_portefeuille VARCHAR2(1),
   description       VARCHAR2(60),
   adresse1          VARCHAR2(60),
   adresse2          VARCHAR2(60),
   adresse3          VARCHAR2(60),
   adresse4          VARCHAR2(60),
   adresse5          VARCHAR2(60),
   telephone         VARCHAR2(30),
   fax               VARCHAR2(30),
   email_adress      VARCHAR2(80),
   nom_pp            VARCHAR2(40),
   prenom_pp         VARCHAR2(40),
   telex             VARCHAR2(30),
   dpt_naissance     VARCHAR2(20),
   groupe_1          VARCHAR2(30),
   groupe_2          VARCHAR2(30),
   groupe_3          VARCHAR2(30),
   sector            VARCHAR2(30),
   seniority         VARCHAR2(30),
   type_interne      VARCHAR2(30),
   flag_pp           VARCHAR2(1),
   entite_pere       VARCHAR2(20),
   tiers_conso       VARCHAR2(20)
);

CREATE TABLE op.structure (
   code        VARCHAR2(20),
   structure   VARCHAR2(20),
   ecran       VARCHAR2(30),
   pere        VARCHAR2(20),
   description VARCHAR2(60)
);

CREATE TABLE op.compte_banque (
   code                VARCHAR2(20) NOT NULL,
   flag_gere           VARCHAR2(1),
   description         VARCHAR2(60),
   entite              VARCHAR2(20),
   banque              VARCHAR2(20),
   portefeuille_defaut VARCHAR2(20),
   compte_previs_glob  VARCHAR2(20),
   code_bban           VARCHAR2(30),
   groupe_1            VARCHAR2(30),
   groupe_2            VARCHAR2(30),
   groupe_3            VARCHAR2(30)
);

-- ----------------------------------------------------------------------------
-- References of every column domain
-- ----------------------------------------------------------------------------
-- PARTY, BANK_ACCOUNT, MIXED and free text on one history table.
-- tiers_domicile: a bank's or branch's name - free text. tiers_iban_compte: an
-- account NUMBER, marked [no-harvest] - never captured as an account code.
CREATE TABLE op.histo_operation (
   id                NUMBER,
   entite            VARCHAR2(20),
   contrepartie      VARCHAR2(20),
   compensateur      VARCHAR2(20),
   clearing_member   VARCHAR2(20),
   compte_tiers      VARCHAR2(20),
   compte_entite     VARCHAR2(20),
   tiers_libelle     VARCHAR2(60),
   tiers_domicile    VARCHAR2(50),
   tiers_iban_compte VARCHAR2(34),
   description       VARCHAR2(60),
   groupe_1          VARCHAR2(30)
);

-- MIXED: a breakdown value that may be any kind of code. code is the
-- breakdown ([group: code]): each holds one kind of code.
CREATE TABLE op.ventiler_compte (
   id       NUMBER,
   code     VARCHAR2(20),
   valeur_1 VARCHAR2(20),
   valeur_2 VARCHAR2(20)
);

-- A valuation report and its lines: only a report of type FicValComp lists
-- bank accounts ([only-where: ...]); another lists cash-flow posts, whose
-- codes may equal a party's.
CREATE TABLE op.param_fiche_en_valeur (
   code VARCHAR2(20),
   type VARCHAR2(20)
);
CREATE TABLE op.param_fiche_val_detail (
   id           NUMBER,
   code_tableau VARCHAR2(20),
   code         VARCHAR2(20),
   description  VARCHAR2(60)
);

-- Interest-scale conditions: a CODE,PARTY column marked [no-harvest] - its
-- codes are conditions, not deleted parties.
CREATE TABLE op.echelle_condition (
   code    VARCHAR2(20),
   libelle VARCHAR2(40)
);

-- The analytical-account exception: MIXED by a site override.
CREATE TABLE op.param_cpta_reg_gen (
   id          NUMBER,
   portefeuille VARCHAR2(20),
   compte_ana   VARCHAR2(20)
);

-- A plain account reference and a plain party reference.
CREATE TABLE op.compte_regle (
   id     NUMBER,
   entite VARCHAR2(20),
   compte VARCHAR2(20)
);

-- A one-character discriminator the shipped inventory no longer lists.
CREATE TABLE op.val_ssi_account (
   id           NUMBER,
   tiers_entite VARCHAR2(1),
   compte       VARCHAR2(20)
);

-- NOT NULL free text: masked with the marker instead of emptied.
CREATE TABLE op.histo_pricing_groupe (
   id          NUMBER,
   description VARCHAR2(40) NOT NULL
);

-- A NOT NULL constraint that is not validated: the dictionary calls the
-- column nullable, and setting it to NULL fails with ORA-01407. Free text that
-- refuses NULL gets the marker instead.
CREATE TABLE op.utilisateur (
   code        VARCHAR2(20),
   description VARCHAR2(60)
);
ALTER TABLE op.utilisateur MODIFY (description NOT NULL ENABLE NOVALIDATE);

-- Only used by the cases that add their own inventory rows: a one-character
-- free-text column (must be processed, not skipped as a "checkbox") and a NOT
-- NULL number listed as free text (no valid masking value - must block).
CREATE TABLE op.anon_fixture_extra (
   id          NUMBER,
   one_char    VARCHAR2(1),
   locked_num  NUMBER NOT NULL
);

GRANT SELECT ON sys.dba_users TO op;

PROMPT fixture schema ready
EXIT SUCCESS
