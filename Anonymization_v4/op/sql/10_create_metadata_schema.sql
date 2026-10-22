-- ============================================================================
-- 10 - Metadata schema (anon_meta)
-- ============================================================================
-- Creates the schema that holds the code mapping, the identity inventory, the
-- loaded coverage inventory and the run log. Run as SYS.
--
-- IDEMPOTENT. Existing objects are kept, never recreated. The code mapping is
-- the only record of what the original values were: were it regenerated, a run
-- that stopped partway would leave renamed rows whose originals could no
-- longer be recovered. It survives every run, and a new run resumes against
-- it.
--
-- Objects created by an earlier version are MIGRATED in place: missing columns
-- are added and constraints are widened. Nothing that records an original value
-- is ever dropped.
--
-- Parameters: &1 = data tablespace   &2 = index tablespace
-- ============================================================================

DEFINE tbs_data  = &1
DEFINE tbs_index = &2

SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
SET FEEDBACK OFF
SET VERIFY OFF
SET ECHO OFF

PROMPT
PROMPT === Metadata schema (anon_meta) ===

-- ----------------------------------------------------------------------------
-- Schema owner
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = 'ANON_META';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE 'CREATE USER anon_meta IDENTIFIED BY anon_meta '
                     || 'DEFAULT TABLESPACE &tbs_data QUOTA UNLIMITED ON &tbs_data';
      DBMS_OUTPUT.PUT_LINE('  created user anon_meta');
   ELSE
      EXECUTE IMMEDIATE 'ALTER USER anon_meta QUOTA UNLIMITED ON &tbs_data';
      DBMS_OUTPUT.PUT_LINE('  user anon_meta already exists - kept');
   END IF;
END;
/

GRANT CREATE SESSION, CREATE TABLE, CREATE VIEW, CREATE SEQUENCE TO anon_meta;

-- ----------------------------------------------------------------------------
-- Privileges the engine needs. The engine is owned by OP and runs as OP, so it
-- must be able to read the dictionary and modify any OP table.
-- ----------------------------------------------------------------------------
GRANT SELECT ON sys.dba_users   TO op;
GRANT SELECT ON sys.dba_objects TO op;
GRANT SELECT ON sys.dba_tab_columns TO op;
GRANT CREATE PROCEDURE TO op;
GRANT SELECT ANY TABLE, INSERT ANY TABLE, UPDATE ANY TABLE, DELETE ANY TABLE TO op;
GRANT ALTER ANY TRIGGER TO op;

-- Read access to the run's own session, for the live view: the progress of a
-- long statement (v$session_longops) of the session whose module names the
-- run. Nothing else in these views is read.
GRANT SELECT ON sys.v_$session         TO op;
GRANT SELECT ON sys.v_$session_longops TO op;

-- ----------------------------------------------------------------------------
-- code_map - old identifier to new identifier, per category.
--
-- THE most important table here. It is the only record of what the original
-- values were. It is never dropped by a run; drop it by hand once the copy has
-- been verified and handed over.
--
-- The key is (category, old_code), not old_code alone: the same text can be a
-- party and a bank account at once, and each keeps its own replacement. The
-- replacement is unique across every category.
--
--   run_id      the run that allocated the row. NULL for a row allocated by an
--               earlier version, before identities were recorded by domain -
--               such a row is reused only when it agrees with the identity's
--               category.
--   id_applied  'Y' once a completed EXECUTE run has renamed this identity's
--               identifiers. A row created only to mask labels or attributes
--               stays NULL, so nothing downstream (EPF) renames with it.
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists
     FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'CODE_MAP';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
         CREATE TABLE anon_meta.code_map (
            category   VARCHAR2(20)  NOT NULL,
            old_code   VARCHAR2(80)  NOT NULL,
            new_code   VARCHAR2(80)  NOT NULL,
            created_at DATE DEFAULT SYSDATE NOT NULL,
            run_id     NUMBER,
            id_applied VARCHAR2(1),
            CONSTRAINT pk_code_map PRIMARY KEY (category, old_code)
               USING INDEX TABLESPACE &tbs_index
         ) TABLESPACE &tbs_data ]';

      -- Lookup path for every CODE update: WHERE old_code = <column value>
      EXECUTE IMMEDIATE 'CREATE INDEX anon_meta.ix_code_map_old '
                     || 'ON anon_meta.code_map(old_code) TABLESPACE &tbs_index';

      -- Uniqueness of the generated value is guaranteed by construction, but a
      -- constraint costs nothing and turns any generation bug into an immediate
      -- error rather than two entities silently sharing one identity.
      EXECUTE IMMEDIATE 'CREATE UNIQUE INDEX anon_meta.ux_code_map_new '
                     || 'ON anon_meta.code_map(new_code) TABLESPACE &tbs_index';

      DBMS_OUTPUT.PUT_LINE('  created anon_meta.code_map');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.code_map already exists - PRESERVED');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- anon_inventory - the loaded coverage definition.
--
-- Truncated and reloaded from the CSVs at the start of every run, so editing a
-- CSV is enough to change what happens. See config/inventory_op.csv.
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists
     FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'ANON_INVENTORY';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
         CREATE TABLE anon_meta.anon_inventory (
            table_name  VARCHAR2(128) NOT NULL,
            column_name VARCHAR2(128) NOT NULL,
            rule        VARCHAR2(20)  NOT NULL,
            category    VARCHAR2(20)  NOT NULL,
            source      VARCHAR2(10)  DEFAULT 'BASE' NOT NULL,
            notes       VARCHAR2(500),
            seq         NUMBER,
            CONSTRAINT pk_anon_inventory PRIMARY KEY (table_name, column_name)
               USING INDEX TABLESPACE &tbs_index,
            CONSTRAINT ck_anon_inv_rule CHECK
               (rule IN ('CODE','NULL_OUT','DESCRIPTION','SELF_CODE'))
         ) TABLESPACE &tbs_data ]';
      DBMS_OUTPUT.PUT_LINE('  created anon_meta.anon_inventory');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.anon_inventory already exists');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- anon_run - one row per run.
--
--   status          RUNNING, then COMPLETED; FAILED on an error; REFUSED when
--                   the checks found the run unsafe (nothing changed);
--                   CANCELLED when it was not confirmed; STOPPED when it was
--                   asked to stop (Ctrl+C) and did so between two columns
--   config_json     the resolved switches and options
--   dataset_json    what the run found: database, schema and identity counts.
--                   Counts only - never an identifier.
--   tool_version    the version of the engine that made the run
--   stop_requested  Y once a stop was asked for; the engine reads it between
--                   two columns
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists
     FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'ANON_RUN';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
         CREATE TABLE anon_meta.anon_run (
            run_id       NUMBER        NOT NULL,
            run_mode     VARCHAR2(10)  NOT NULL,
            status       VARCHAR2(20)  NOT NULL,
            started_at   TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
            finished_at  TIMESTAMP,
            db_name      VARCHAR2(30),
            os_user      VARCHAR2(60),
            config_json  VARCHAR2(2000),
            error_text   VARCHAR2(4000),
            dataset_json VARCHAR2(2000),
            tool_version VARCHAR2(20),
            stop_requested VARCHAR2(1),
            CONSTRAINT pk_anon_run PRIMARY KEY (run_id)
               USING INDEX TABLESPACE &tbs_index,
            CONSTRAINT ck_anon_run_mode   CHECK (run_mode IN ('EXECUTE','DRYRUN')),
            CONSTRAINT ck_anon_run_status CHECK (status IN ('RUNNING','COMPLETED','FAILED',
                                                            'REFUSED','CANCELLED','STOPPED'))
         ) TABLESPACE &tbs_data ]';
      EXECUTE IMMEDIATE 'CREATE SEQUENCE anon_meta.seq_anon_run START WITH 1 INCREMENT BY 1 NOCACHE';
      DBMS_OUTPUT.PUT_LINE('  created anon_meta.anon_run');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.anon_run already exists');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- anon_step_log - one row per inventory item per run.
--
-- Written by an autonomous transaction so entries appear immediately and
-- survive a rollback of the work they describe. This is what makes a run
-- observable from a second session while it is still going, and what makes a
-- failed run diagnosable afterwards.
--
-- status:
--   OK        applied, n rows changed
--   NOOP      applied, 0 rows changed - already clean, or nothing matched.
--             Worth looking at: on a column you expected to change, this is the
--             signal that the column name is wrong or the mapping is empty.
--   SKIPPED   table or column does not exist here (ORA-00942 / ORA-00904)
--   DISABLED  excluded by configuration
--   REVIEW    n rows deliberately left unchanged because their role or domain
--             is ambiguous - a reviewed decision is needed before a privacy PASS
--   DRYRUN    would have changed n rows; nothing was written
--   ERROR     anything else - the run fails
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists
     FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'ANON_STEP_LOG';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
         CREATE TABLE anon_meta.anon_step_log (
            run_id        NUMBER        NOT NULL,
            logged_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
            phase         VARCHAR2(40)  NOT NULL,
            object_name   VARCHAR2(300),
            rule          VARCHAR2(20),
            status        VARCHAR2(20)  NOT NULL,
            rows_affected NUMBER,
            elapsed_ms    NUMBER,
            message       VARCHAR2(4000)
         ) TABLESPACE &tbs_data ]';
      EXECUTE IMMEDIATE 'CREATE INDEX anon_meta.ix_step_log_run '
                     || 'ON anon_meta.anon_step_log(run_id, logged_at) TABLESPACE &tbs_index';
      DBMS_OUTPUT.PUT_LINE('  created anon_meta.anon_step_log');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.anon_step_log already exists');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- verify_result - one row per verification check.
--
-- Written by op/verify/verify_op_coverage.sql. Kept so that a failure can be
-- queried afterwards rather than scraped out of terminal scrollback:
--   SELECT * FROM anon_meta.verify_result WHERE status NOT IN ('PASS', 'INFO');
--
-- status: PASS | FAIL | REVIEW | DISABLED | WARN | INFO | SKIP
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists
     FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'VERIFY_RESULT';

   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE q'[
         CREATE TABLE anon_meta.verify_result (
            checked_at   TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
            part         VARCHAR2(60) NOT NULL,
            check_name   VARCHAR2(300),
            expectation  VARCHAR2(200),
            total_rows   NUMBER,
            bad_rows     NUMBER,
            status       VARCHAR2(10) NOT NULL,
            detail       VARCHAR2(4000)
         ) TABLESPACE &tbs_data ]';
      DBMS_OUTPUT.PUT_LINE('  created anon_meta.verify_result');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.verify_result already exists');
   END IF;
END;
/

-- ----------------------------------------------------------------------------
-- Migrations of the objects above, and the tables added since they were first
-- created.
--
-- Everything in this block is idempotent: a column or table is only added when
-- missing, so it upgrades a schema created by an earlier version and does
-- nothing on one that is already current.
-- ----------------------------------------------------------------------------
DECLARE
   -- Item declarations must all precede the first subprogram in a declarative
   -- section.
   v_n    NUMBER;
   v_cond VARCHAR2(4000);

   PROCEDURE add_column(p_table IN VARCHAR2, p_column IN VARCHAR2, p_definition IN VARCHAR2) IS
      v_n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO v_n
        FROM dba_tab_columns
       WHERE owner = 'ANON_META' AND table_name = UPPER(p_table) AND column_name = UPPER(p_column);
      IF v_n = 0 THEN
         EXECUTE IMMEDIATE 'ALTER TABLE anon_meta.' || p_table || ' ADD (' || p_column || ' '
                        || p_definition || ')';
         DBMS_OUTPUT.PUT_LINE('  migrated anon_meta.' || LOWER(p_table) || ': added ' || LOWER(p_column));
      END IF;
   END add_column;

   PROCEDURE create_table(p_table IN VARCHAR2, p_ddl IN VARCHAR2) IS
      v_n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO v_n FROM dba_tables WHERE owner = 'ANON_META' AND table_name = UPPER(p_table);
      IF v_n = 0 THEN
         EXECUTE IMMEDIATE p_ddl || ' TABLESPACE &tbs_data';
         DBMS_OUTPUT.PUT_LINE('  created anon_meta.' || LOWER(p_table));
      END IF;
   END create_table;

   PROCEDURE create_index(p_index IN VARCHAR2, p_ddl IN VARCHAR2) IS
      v_n NUMBER;
   BEGIN
      SELECT COUNT(*) INTO v_n FROM dba_indexes WHERE owner = 'ANON_META' AND index_name = UPPER(p_index);
      IF v_n = 0 THEN
         EXECUTE IMMEDIATE p_ddl || ' TABLESPACE &tbs_index';
      END IF;
   END create_index;
BEGIN
   add_column('code_map', 'run_id',     'NUMBER');
   add_column('code_map', 'id_applied', 'VARCHAR2(1)');
   add_column('anon_run', 'dataset_json',   'VARCHAR2(2000)');
   add_column('anon_run', 'tool_version',   'VARCHAR2(20)');
   add_column('anon_run', 'stop_requested', 'VARCHAR2(1)');

   -- The run statuses REFUSED, CANCELLED and STOPPED, on a table created with
   -- RUNNING, COMPLETED and FAILED only.
   SELECT MAX(search_condition_vc) INTO v_cond
     FROM dba_constraints
    WHERE owner = 'ANON_META' AND table_name = 'ANON_RUN' AND constraint_name = 'CK_ANON_RUN_STATUS';
   IF v_cond IS NULL OR INSTR(v_cond, 'STOPPED') = 0 THEN
      IF v_cond IS NOT NULL THEN
         EXECUTE IMMEDIATE 'ALTER TABLE anon_meta.anon_run DROP CONSTRAINT ck_anon_run_status';
      END IF;
      EXECUTE IMMEDIATE q'[ALTER TABLE anon_meta.anon_run ADD CONSTRAINT ck_anon_run_status CHECK
         (status IN ('RUNNING', 'COMPLETED', 'FAILED', 'REFUSED', 'CANCELLED', 'STOPPED'))]';
      DBMS_OUTPUT.PUT_LINE('  migrated anon_meta.anon_run: statuses REFUSED, CANCELLED and STOPPED');
   END IF;

   -- Of the rows a CODE step changed (or a dry run would change), how many got
   -- an unclassified party's X_ value. Counts only; the run summary and the
   -- report add them up by table.
   add_column('anon_step_log', 'x_rows', 'NUMBER');

   -- The order the rows were written in, from a sequence: the live view reads
   -- only the rows after the last one it has shown.
   add_column('anon_step_log', 'step_id', 'NUMBER');
   SELECT COUNT(*) INTO v_n FROM dba_sequences WHERE sequence_owner = 'ANON_META' AND sequence_name = 'SEQ_STEP_LOG';
   IF v_n = 0 THEN
      EXECUTE IMMEDIATE 'CREATE SEQUENCE anon_meta.seq_step_log START WITH 1 INCREMENT BY 1 CACHE 100 ORDER';
      DBMS_OUTPUT.PUT_LINE('  created anon_meta.seq_step_log');
   END IF;
   create_index('ix_step_log_step',
      'CREATE INDEX anon_meta.ix_step_log_step ON anon_meta.anon_step_log(run_id, step_id)');

   -- anon_progress - where a run is now. One row per run, rewritten by the
   -- engine before each planning stage, table or column; read by the live
   -- view in a second session while the run works.
   --
   --   phase           PLAN | MAPPING | NULL_OUT | CODE | LABELS | DONE
   --   stage           what the engine does, in words
   --   items_done      tables or columns of the phase done, of items_total
   --   object_name     the table or column worked on now
   --   weight_done     the same, weighed by the rows of their tables (the
   --   weight_total    optimizer statistics), so that a bar moves with the
   --   object_weight   work rather than with the number of small tables
   create_table('anon_progress', q'[
      CREATE TABLE anon_meta.anon_progress (
         run_id          NUMBER        NOT NULL,
         phase           VARCHAR2(20)  NOT NULL,
         stage           VARCHAR2(100),
         items_done      NUMBER,
         items_total     NUMBER,
         object_name     VARCHAR2(300),
         object_weight   NUMBER,
         weight_done     NUMBER,
         weight_total    NUMBER,
         phase_started   TIMESTAMP,
         object_started  TIMESTAMP,
         updated_at      TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
         CONSTRAINT pk_anon_progress PRIMARY KEY (run_id) USING INDEX TABLESPACE &tbs_index
      )]');

   -- anon_check - the checks a run makes before it changes anything, met or
   -- not, by name. The run's screen and report show them as a table: what
   -- was measured and, for one not met, what happens and what to do.
   --
   --   needed   REQUIRED - not met, the run does not start
   --            OPTIONAL - not met, the run goes on and says so
   --            INFO     - says what the run will do with what it found
   --   status   MET | NOT_MET | NOTE (an INFO check that found something)
   --   state    the short state shown in the table ("14 nodes")
   --   measure  what was measured. Counts and column names only.
   create_table('anon_check', q'[
      CREATE TABLE anon_meta.anon_check (
         run_id        NUMBER         NOT NULL,
         seq           NUMBER         NOT NULL,
         code          VARCHAR2(30)   NOT NULL,
         title         VARCHAR2(100)  NOT NULL,
         needed        VARCHAR2(10)   NOT NULL,
         status        VARCHAR2(10)   NOT NULL,
         state         VARCHAR2(60),
         measure       VARCHAR2(1000),
         what_happens  VARCHAR2(1000),
         what_to_do    VARCHAR2(1000),
         checked_at    TIMESTAMP DEFAULT SYSTIMESTAMP NOT NULL,
         CONSTRAINT pk_anon_check PRIMARY KEY (run_id, code) USING INDEX TABLESPACE &tbs_index,
         CONSTRAINT ck_anon_check_needed CHECK (needed IN ('REQUIRED', 'OPTIONAL', 'INFO')),
         CONSTRAINT ck_anon_check_status CHECK (status IN ('MET', 'NOT_MET', 'NOTE'))
      )]');

   -- What the inventory's notes say about a column, in a form the engine and
   -- the verifier read directly. Filled by 21_validate_inventory.sql from the
   -- [bracketed] options in the notes field of the CSVs:
   --   harvest       CODE PARTY / BANK_ACCOUNT: Y unless [no-harvest] - a value
   --                 that is no identity is a code whose master was deleted
   --   row_scope     [only-where: ...] as a condition on the row (alias t)
   --   group_by      [group: col] on MIXED: a value that is a party AND an
   --                 account takes the domain of its group
   --   folder_trees  [folders: ...] on structure.code: the trees whose folder
   --                 rows (no screen) are renamed when their code is an identity
   add_column('anon_inventory', 'harvest',      'VARCHAR2(1)');
   add_column('anon_inventory', 'row_scope',    'VARCHAR2(1000)');
   add_column('anon_inventory', 'group_by',     'VARCHAR2(128)');
   add_column('anon_inventory', 'folder_trees', 'VARCHAR2(1000)');

   -- code_map_any - REMOVED.
   --
   -- It held one "winning" replacement per original text, chosen by a fixed
   -- category priority, and every CODE column except bank-account ones looked
   -- up through it. That is how a party reference could receive a bank
   -- account's CB_ value, and an account node a party's E_ value. Lookups are
   -- now typed by domain (code_lookup below, rebuilt every run from the plan).
   --
   -- It was a derived cache of code_map - "rebuilt every run, never edited by
   -- hand" - so dropping it loses nothing.
   SELECT COUNT(*) INTO v_n FROM dba_tables WHERE owner = 'ANON_META' AND table_name = 'CODE_MAP_ANY';
   IF v_n > 0 THEN
      EXECUTE IMMEDIATE 'DROP TABLE anon_meta.code_map_any PURGE';
      DBMS_OUTPUT.PUT_LINE('  dropped anon_meta.code_map_any (untyped lookup, replaced by code_lookup)');
   END IF;

   -- identity_inventory - every original identity, captured BEFORE it changes.
   --
   -- One row per (domain, old_code). Captured the first time an EXECUTE run
   -- sees the identity, from the raw data, and never re-captured: a later run -
   -- after a failure, or after master data was repaired - keeps the category
   -- and X_ reason recorded here. That is what keeps a replacement stable.
   --
   --   domain        PARTY    tiers.code, w_tiers nodes, confirmed references
   --                 ACCOUNT  compte_banque.code, w_compte_banque nodes
   --   category      ENTITY | PORTFOLIO | COUNTERPARTY | UNCLASSIFIED_PARTY
   --                 for a party; BANK_ACCOUNT for an account
   --   x_reason      why a party is UNCLASSIFIED_PARTY (X_); never NULL for one
   --   membership    MASTER_ONLY | BOTH | STRUCTURE_ONLY | REFERENCE_ONLY -
   --                 where the identity was found
   --   map_category  category of the code_map row that is the identity's ONE
   --                 translation. Normally equal to category; NULL until a run
   --                 needed a translation.
   --
   -- Holds original client identifiers. Same handling as code_map.
   create_table('identity_inventory', q'[
      CREATE TABLE anon_meta.identity_inventory (
         domain        VARCHAR2(10) NOT NULL,
         old_code      VARCHAR2(80) NOT NULL,
         category      VARCHAR2(20) NOT NULL,
         x_reason      VARCHAR2(30),
         membership    VARCHAR2(20) NOT NULL,
         map_category  VARCHAR2(20),
         first_run_id  NUMBER       NOT NULL,
         captured_at   DATE DEFAULT SYSDATE NOT NULL,
         CONSTRAINT pk_identity_inventory PRIMARY KEY (domain, old_code) USING INDEX TABLESPACE &tbs_index,
         CONSTRAINT ck_identity_domain CHECK (domain IN ('PARTY', 'ACCOUNT')),
         CONSTRAINT ck_identity_category CHECK (
               (domain = 'PARTY'   AND category IN ('ENTITY', 'PORTFOLIO', 'COUNTERPARTY',
                                                    'UNCLASSIFIED_PARTY'))
            OR (domain = 'ACCOUNT' AND category = 'BANK_ACCOUNT')),
         CONSTRAINT ck_identity_x_reason CHECK (
               (category = 'UNCLASSIFIED_PARTY'
                AND x_reason IN ('MISSING_MASTER', 'NO_STRUCTURE', 'UNKNOWN_FLAG',
                                 'NO_PARTY_SCREEN', 'UNKNOWN_CLASSIFICATION'))
            OR (category <> 'UNCLASSIFIED_PARTY' AND x_reason IS NULL)),
         CONSTRAINT ck_identity_membership CHECK (
               membership IN ('MASTER_ONLY', 'BOTH', 'STRUCTURE_ONLY', 'REFERENCE_ONLY'))
      )]');

   -- confirmed_identity - sensitive identities that exist only as references.
   --
   -- A code found in a CODE,PARTY or CODE,BANK_ACCOUNT column with no master
   -- row and no structure node is now picked up by itself (reference_harvest
   -- below): its master was deleted. This table is for the rest - a code in a
   -- column marked [no-harvest], or in a MIXED column - once reviewed:
   --
   --   INSERT INTO anon_meta.confirmed_identity (domain, old_code, note)
   --   VALUES ('PARTY', '<code>', 'reviewed <date>');
   --
   -- It is then classified like any other identity - a party with no master is
   -- UNCLASSIFIED_PARTY (X_), reason MISSING_MASTER.
   --
   -- Holds original client identifiers. Never put them in a file.
   create_table('confirmed_identity', q'[
      CREATE TABLE anon_meta.confirmed_identity (
         domain    VARCHAR2(10)  NOT NULL,
         old_code  VARCHAR2(80)  NOT NULL,
         note      VARCHAR2(200),
         added_at  DATE DEFAULT SYSDATE NOT NULL,
         CONSTRAINT pk_confirmed_identity PRIMARY KEY (domain, old_code) USING INDEX TABLESPACE &tbs_index,
         CONSTRAINT ck_confirmed_domain CHECK (domain IN ('PARTY', 'ACCOUNT'))
      )]');

   -- identity_plan - what one run intends to do with every identity.
   --
   -- Built by preflight from identity_inventory plus whatever new identities
   -- the run found. A dry run estimates against this plan and an EXECUTE run
   -- applies it, so the two cannot disagree - and a dry run's figures do not
   -- depend on whatever an earlier run left in code_map.
   --
   -- The plan of the latest completed EXECUTE run is kept: the verifier checks
   -- the result against it, because after the run the original values are
   -- gone from the data and only the plan still knows what each one was.
   --
   --   identity_status  KNOWN (already in identity_inventory) | NEW (found now)
   --   class_now        the category today's facts would give. Differs from
   --                    category only when master data changed since capture.
   --   map_status       EXISTING | NEW | NONE (no translation needed) |
   --                    CONFLICT | MISSING - the last two block the run
   --   seen_renamed     Y when a master or node row of this identity already
   --                    holds its replacement - renamed by an earlier run on
   --                    this same data
   --   id_on, desc_on, attr_on   this identity's three switches for the run
   create_table('identity_plan', q'[
      CREATE TABLE anon_meta.identity_plan (
         run_id                 NUMBER       NOT NULL,
         domain                 VARCHAR2(10) NOT NULL,
         old_code               VARCHAR2(80) NOT NULL,
         identity_status        VARCHAR2(10) NOT NULL,
         category               VARCHAR2(20) NOT NULL,
         x_reason               VARCHAR2(30),
         membership             VARCHAR2(20) NOT NULL,
         has_master             VARCHAR2(1),
         flag_state             VARCHAR2(10),
         has_party_node         VARCHAR2(1),
         has_entity_node        VARCHAR2(1),
         has_other_class_node   VARCHAR2(1),
         has_other_screen_node  VARCHAR2(1),
         has_account_node       VARCHAR2(1),
         entity_overlap         VARCHAR2(1),
         class_now              VARCHAR2(20),
         seen_renamed           VARCHAR2(1),
         map_category           VARCHAR2(20),
         new_code               VARCHAR2(80),
         map_status             VARCHAR2(10),
         superseded_maps        NUMBER,
         id_on                  VARCHAR2(1),
         desc_on                VARCHAR2(1),
         attr_on                VARCHAR2(1),
         CONSTRAINT pk_identity_plan PRIMARY KEY (run_id, domain, old_code) USING INDEX TABLESPACE &tbs_index
      )]');
   -- Replacements are unique within a plan. Only rows that HAVE one are
   -- indexed: a composite index would treat (run, NULL) twice as a duplicate.
   create_index('ux_identity_plan_new',
      'CREATE UNIQUE INDEX anon_meta.ux_identity_plan_new ON anon_meta.identity_plan('
   || 'CASE WHEN new_code IS NOT NULL THEN run_id END, new_code)');

   -- code_lookup - the typed lookups one run applies. Rebuilt every run from
   -- the plan; never edited by hand.
   --
   --   PARTY        party identities whose ID switch is on
   --   ACCOUNT      bank-account identities whose ID switch is on
   --   MIXED        identities known in exactly ONE domain, for columns
   --                reviewed as holding both
   --   AMBIGUOUS    texts that are a party AND an account (new_code NULL) -
   --                left alone in MIXED columns and reported for review,
   --                unless the column's [group:] settles them
   --   VALUE_P      every party original and party replacement of the plan
   --   VALUE_A      every account original and account replacement - with
   --                VALUE_P, how a MIXED group's other values are told apart
   --                (new_code NULL; texts that are both are in neither)
   create_table('code_lookup', q'[
      CREATE TABLE anon_meta.code_lookup (
         domain    VARCHAR2(12) NOT NULL,
         old_code  VARCHAR2(80) NOT NULL,
         new_code  VARCHAR2(80),
         CONSTRAINT pk_code_lookup PRIMARY KEY (domain, old_code) USING INDEX TABLESPACE &tbs_index
      )]');

   -- owner_key - how DESCRIPTION and SELF_CODE find the identity owning a row.
   --
   -- Two keys per translated identity: its original code and its replacement.
   -- A master row is matched whichever one its code column holds, so labels
   -- and attributes are masked correctly whether or not its identifier was
   -- renamed - and always with the identity's mapped value, never with the
   -- row's own code. Rebuilt every run from the plan.
   create_table('owner_key', q'[
      CREATE TABLE anon_meta.owner_key (
         domain    VARCHAR2(10) NOT NULL,
         key_code  VARCHAR2(80) NOT NULL,
         new_code  VARCHAR2(80) NOT NULL,
         category  VARCHAR2(20) NOT NULL,
         desc_on   VARCHAR2(1)  NOT NULL,
         attr_on   VARCHAR2(1)  NOT NULL,
         CONSTRAINT pk_owner_key PRIMARY KEY (domain, key_code) USING INDEX TABLESPACE &tbs_index
      )]');

   -- anon_run_setting - the three switches of each category, per run.
   --
   -- Recorded so that the plan, the verifier and the report all read the
   -- switches a run actually used, rather than a configuration file that may
   -- have changed since.
   create_table('anon_run_setting', q'[
      CREATE TABLE anon_meta.anon_run_setting (
         run_id    NUMBER       NOT NULL,
         category  VARCHAR2(20) NOT NULL,
         id_on     VARCHAR2(1)  NOT NULL,
         desc_on   VARCHAR2(1)  NOT NULL,
         attr_on   VARCHAR2(1)  NOT NULL,
         CONSTRAINT pk_anon_run_setting PRIMARY KEY (run_id, category) USING INDEX TABLESPACE &tbs_index
      )]');

   -- field_baseline - NULL counts of SELF_CODE columns before a run masks them.
   --
   -- SELF_CODE never fills an empty field. The verifier proves it by checking
   -- that no column has fewer NULLs afterwards than this records.
   create_table('field_baseline', q'[
      CREATE TABLE anon_meta.field_baseline (
         run_id       NUMBER        NOT NULL,
         table_name   VARCHAR2(128) NOT NULL,
         column_name  VARCHAR2(128) NOT NULL,
         total_rows   NUMBER,
         null_rows    NUMBER,
         CONSTRAINT pk_field_baseline PRIMARY KEY (run_id, table_name, column_name) USING INDEX TABLESPACE &tbs_index
      )]');

   -- verify_key - scratch for the verifier: one row per original or
   -- replacement code, saying what it is. Lets each column be classified in a
   -- single join instead of one subquery per question. Rebuilt by every
   -- verification.
   --   p_old/a_old    an original party / account identifier (_on: renaming on)
   --   p_new/a_new    a party / account replacement
   --   stray_new      a replacement in code_map that is no identity's own
   --   pere_role/on   where a structure.pere holding this original points
   --   pere_bad       a replacement that no structure.pere should hold
   create_table('verify_key', q'[
      CREATE TABLE anon_meta.verify_key (
         key_code   VARCHAR2(80) NOT NULL,
         p_old      VARCHAR2(1),
         p_old_on   VARCHAR2(1),
         a_old      VARCHAR2(1),
         a_old_on   VARCHAR2(1),
         p_new      VARCHAR2(1),
         a_new      VARCHAR2(1),
         stray_new  VARCHAR2(1),
         pere_role  VARCHAR2(10),
         pere_on    VARCHAR2(1),
         pere_bad   VARCHAR2(1),
         CONSTRAINT pk_verify_key PRIMARY KEY (key_code) USING INDEX TABLESPACE &tbs_index
      )]');

   -- unclassified_reason - why a party is UNCLASSIFIED_PARTY (X_), in words.
   --
   -- One row per x_reason: the reason in one line (brief) and in full (why),
   -- what would let the data classify the party, and a query that lists the
   -- parties of one run with that reason (:run_id). The run output, the
   -- report and anyone querying the metadata read the same text. Refreshed
   -- below on every run.
   create_table('unclassified_reason', q'[
      CREATE TABLE anon_meta.unclassified_reason (
         x_reason    VARCHAR2(30)   NOT NULL,
         sort_order  NUMBER         NOT NULL,
         label       VARCHAR2(40)   NOT NULL,
         brief       VARCHAR2(200),
         why         VARCHAR2(1000) NOT NULL,
         fix         VARCHAR2(1000) NOT NULL,
         list_sql    VARCHAR2(4000) NOT NULL,
         CONSTRAINT pk_unclassified_reason PRIMARY KEY (x_reason) USING INDEX TABLESPACE &tbs_index
      )]');
   add_column('unclassified_reason', 'brief', 'VARCHAR2(200)');

   -- reference_harvest - codes found only in references, per run.
   --
   -- A value of a CODE,PARTY or CODE,BANK_ACCOUNT column that is no identity
   -- of that domain is the code of a master row deleted in the past: it is
   -- captured as an identity found only in references (REFERENCE_ONLY) - a
   -- party as UNCLASSIFIED_PARTY, reason MISSING_MASTER, an account as
   -- BANK_ACCOUNT - and gets its own replacement like any other. One row per
   -- code and column where it was found, with the rows holding it, so a run
   -- can say where they came from. Columns marked [no-harvest] are not read.
   --
   -- Holds original client identifiers. Same handling as code_map.
   create_table('reference_harvest', q'[
      CREATE TABLE anon_meta.reference_harvest (
         run_id       NUMBER        NOT NULL,
         domain       VARCHAR2(10)  NOT NULL,
         old_code     VARCHAR2(80)  NOT NULL,
         table_name   VARCHAR2(128) NOT NULL,
         column_name  VARCHAR2(128) NOT NULL,
         n_rows       NUMBER        NOT NULL,
         CONSTRAINT pk_reference_harvest PRIMARY KEY (run_id, domain, old_code, table_name, column_name)
            USING INDEX TABLESPACE &tbs_index
      )]');

   -- node_lookup - what each structure node becomes, tree by tree.
   --
   -- (tree, old_code) is a node of one structure tree by its ORIGINAL code;
   -- new_code is the code it ends with: its role's translation (an account
   -- node, a party node, or a folder row named after a client), or its own
   -- code when it is not renamed. structure.code is renamed from it, and so
   -- is structure.pere - a child takes exactly what its parent node in the
   -- SAME tree became. Rebuilt every run from the plan; tree is NVL(structure,
   -- CHR(1)) so that nodes with no tree are a tree of their own.
   create_table('node_lookup', q'[
      CREATE TABLE anon_meta.node_lookup (
         tree      VARCHAR2(128) NOT NULL,
         old_code  VARCHAR2(80)  NOT NULL,
         new_code  VARCHAR2(80)  NOT NULL,
         kind      VARCHAR2(10)  NOT NULL,
         CONSTRAINT pk_node_lookup PRIMARY KEY (tree, old_code) USING INDEX TABLESPACE &tbs_index
      )]');
   -- A child already renamed by an earlier run points at what its parent
   -- became: found by the new code.
   create_index('ix_node_lookup_new',
      'CREATE INDEX anon_meta.ix_node_lookup_new ON anon_meta.node_lookup(tree, new_code)');
END;
/

-- The reasons, in the order the classification tests them. The queries list
-- original client identifiers: they are printed for the operator to run, never
-- run by the engine into a log.
MERGE INTO anon_meta.unclassified_reason d
USING (
   SELECT 'MISSING_MASTER' AS x_reason, 1 AS sort_order, 'missing master' AS label,
          'the code is a party, but tiers has no row for it' AS brief,
          'The code is a party - a w_tiers node in the structure tree, a value in a party '
       || 'column, or a confirmed reference - but tiers has no row for it, so there is no '
       || 'flag_portefeuille to tell a portfolio from an entity or a counterparty. A code '
       || 'found only in party columns is a party whose tiers row was deleted.' AS why,
          'Add the missing tiers row with its flag_portefeuille, or correct the code if it is '
       || 'a typo. A code left over from a deleted party can stay X_: it is renamed '
       || 'wherever it appears.' AS fix,
          q'{SELECT p.old_code AS code, p.membership, s.ecran, s.structure, s.pere,
       (SELECT LISTAGG(LOWER(h.table_name || '.' || h.column_name) || ' (' || h.n_rows || ')', ', '
                  ON OVERFLOW TRUNCATE) WITHIN GROUP (ORDER BY h.table_name, h.column_name)
          FROM anon_meta.reference_harvest h
         WHERE h.run_id = p.run_id AND h.domain = 'PARTY' AND h.old_code = p.old_code) AS found_in
  FROM anon_meta.identity_plan p
  LEFT JOIN op.structure s
         ON s.code = p.old_code AND NVL(s.ecran, '~') <> 'w_compte_banque'
 WHERE p.run_id = :run_id AND p.domain = 'PARTY'
   AND p.category = 'UNCLASSIFIED_PARTY' AND p.x_reason = 'MISSING_MASTER'
 ORDER BY p.old_code, s.ecran, s.structure;}' AS list_sql
     FROM dual
   UNION ALL
   SELECT 'NO_STRUCTURE', 2, 'no structure',
          'the tiers row has no structure node, and its flag is not N',
          'The tiers row has no node in the structure tree, and its flag_portefeuille is not N. '
       || 'Flagged N it would be an archived party, a counterparty (T_); but a portfolio (flag O) '
       || 'is told by its w_tiers node, and an empty or unknown flag says nothing. A '
       || 'w_compte_banque node with the same text is a bank account, not this party.',
          'Add its w_tiers node if it is a live portfolio, or set flag_portefeuille to N if it is '
       || 'an archived counterparty; otherwise leave it X_.',
          q'{SELECT t.*
  FROM op.tiers t
 WHERE t.code IN (SELECT p.old_code FROM anon_meta.identity_plan p
                   WHERE p.run_id = :run_id AND p.domain = 'PARTY'
                     AND p.category = 'UNCLASSIFIED_PARTY' AND p.x_reason = 'NO_STRUCTURE')
 ORDER BY t.code;}'
     FROM dual
   UNION ALL
   SELECT 'NO_PARTY_SCREEN', 3, 'no party screen',
          'the party has structure nodes, but none on the w_tiers screen',
          'The tiers row has structure nodes, but none on the w_tiers screen. A node on '
       || 'another screen, or a folder row with no screen, does not classify a party.',
          'Add a w_tiers node if it belongs in the party tree; otherwise leave it X_.',
          q'{SELECT s.code, s.ecran, s.structure, s.pere, t.flag_portefeuille
  FROM op.structure s
  JOIN op.tiers t ON t.code = s.code
 WHERE s.code IN (SELECT p.old_code FROM anon_meta.identity_plan p
                   WHERE p.run_id = :run_id AND p.domain = 'PARTY'
                     AND p.category = 'UNCLASSIFIED_PARTY' AND p.x_reason = 'NO_PARTY_SCREEN')
   AND NVL(s.ecran, '~') <> 'w_compte_banque'
 ORDER BY s.code, s.ecran, s.structure;}'
     FROM dual
   UNION ALL
   SELECT 'UNKNOWN_FLAG', 4, 'unknown flag',
          'flag_portefeuille is neither O nor N',
          'flag_portefeuille is neither O nor N - empty, another value, or different on two '
       || 'tiers rows with the same code - so it is not known whether the party is a portfolio.',
          'Set flag_portefeuille to O (portfolio) or N (entity or counterparty); remove a '
       || 'duplicate tiers row.',
          q'{SELECT t.*
  FROM op.tiers t
 WHERE t.code IN (SELECT p.old_code FROM anon_meta.identity_plan p
                   WHERE p.run_id = :run_id AND p.domain = 'PARTY'
                     AND p.category = 'UNCLASSIFIED_PARTY' AND p.x_reason = 'UNKNOWN_FLAG')
 ORDER BY t.code;}'
     FROM dual
   UNION ALL
   SELECT 'UNKNOWN_CLASSIFICATION', 5, 'unknown classification',
          'flag N, but its w_tiers nodes have no classification',
          'flag_portefeuille is N, but every w_tiers node of the party has an empty structure '
       || 'classification - so it is neither an entity (Entite) nor a counterparty (another '
       || 'classification).',
          'Set structure on its w_tiers node: Entite for an entity, the counterparty '
       || 'classification otherwise.',
          q'{SELECT s.code, s.ecran, s.structure, s.pere, t.flag_portefeuille
  FROM op.structure s
  JOIN op.tiers t ON t.code = s.code
 WHERE s.code IN (SELECT p.old_code FROM anon_meta.identity_plan p
                   WHERE p.run_id = :run_id AND p.domain = 'PARTY'
                     AND p.category = 'UNCLASSIFIED_PARTY'
                     AND p.x_reason = 'UNKNOWN_CLASSIFICATION')
   AND s.ecran = 'w_tiers'
 ORDER BY s.code;}'
     FROM dual
) s
ON (d.x_reason = s.x_reason)
WHEN MATCHED THEN UPDATE SET d.sort_order = s.sort_order, d.label = s.label, d.brief = s.brief,
                             d.why = s.why, d.fix = s.fix, d.list_sql = REPLACE(s.list_sql, CHR(13))
WHEN NOT MATCHED THEN INSERT (x_reason, sort_order, label, brief, why, fix, list_sql)
                      VALUES (s.x_reason, s.sort_order, s.label, s.brief, s.why, s.fix,
                              REPLACE(s.list_sql, CHR(13)));
COMMIT;

-- ----------------------------------------------------------------------------
-- Clear the inventory, ready for the generated INSERT file to repopulate it.
--
-- TRUNCATE, as SYS, here - deliberately, rather than DELETE as OP later.
--
-- DELETE takes a row lock per row, generates undo, and has no timeout: if
-- anything holds the table the statement waits forever, the run looks hung, and
-- if that session is then killed the client reports ORA-03114, which reads as a
-- network fault.
--
-- TRUNCATE is DDL: instant, no undo, no row locks, and it resets the table and
-- its index. If the table is already held it fails immediately with ORA-00054
-- naming the problem rather than hanging.
--
-- Nothing is lost. The inventory is rebuilt from the CSVs on every run; it is
-- a cache of the CSVs, not a record of anything.
-- ----------------------------------------------------------------------------
DECLARE
   v_rows NUMBER;
BEGIN
   EXECUTE IMMEDIATE 'SELECT COUNT(*) FROM anon_meta.anon_inventory' INTO v_rows;

   IF v_rows > 0 THEN
      EXECUTE IMMEDIATE 'TRUNCATE TABLE anon_meta.anon_inventory';
      DBMS_OUTPUT.PUT_LINE('  cleared anon_meta.anon_inventory (' || v_rows || ' rows)');
   ELSE
      DBMS_OUTPUT.PUT_LINE('  anon_meta.anon_inventory already empty');
   END IF;

EXCEPTION
   WHEN OTHERS THEN
      IF SQLCODE = -54 THEN         -- ORA-00054: resource busy
         RAISE_APPLICATION_ERROR(-20023,
            'anon_meta.anon_inventory is held by another session and cannot be cleared. '
         || 'Nothing has been changed. Find the holder with '
         || 'tests/manual/check_locks.sql as SYS, then re-run.');
      ELSE
         RAISE;
      END IF;
END;
/

-- The category constraint is (re)created after the TRUNCATE, so that it also
-- applies to an inventory created by an earlier version - that one carries the
-- old list, which has no PARTY, MIXED, NODE_ROLE or UNCLASSIFIED_PARTY.
--
-- ANY is still accepted here, so that an old custom CSV loads and
-- 21_validate_inventory.sql can name the rows to change, rather than the load
-- failing on a bare ORA-02290.
DECLARE
   v_n NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_n FROM dba_constraints
    WHERE owner = 'ANON_META' AND table_name = 'ANON_INVENTORY' AND constraint_name = 'CK_ANON_INV_CAT';
   IF v_n > 0 THEN
      EXECUTE IMMEDIATE 'ALTER TABLE anon_meta.anon_inventory DROP CONSTRAINT ck_anon_inv_cat';
   END IF;
   EXECUTE IMMEDIATE q'[ALTER TABLE anon_meta.anon_inventory ADD CONSTRAINT ck_anon_inv_cat CHECK
      (category IN ('PARTY', 'BANK_ACCOUNT', 'MIXED', 'NODE_ROLE', 'ENTITY', 'PORTFOLIO',
                    'COUNTERPARTY', 'UNCLASSIFIED_PARTY', 'NONE', 'ANY'))]';
END;
/

-- ----------------------------------------------------------------------------
-- ref_tables_modif - compatibility view for the EPF pipeline.
--
-- The EPF anonymization reads atrace.ref_tables_modif to carry the OP renames
-- into OPPAYMENTS. It expects that schema and shape, so the mapping is exposed
-- in that form rather than making the EPF scripts a special case here.
--
-- Exactly ONE row per identity - its own translation, typed by domain. EPF looks
-- values up with scalar subqueries per (table_name, old_value), which raise
-- ORA-01427 on a second row. And only translations a completed run actually
-- applied to identifiers: one allocated only to mask a label must not make EPF
-- rename an identifier that OP kept.
-- ----------------------------------------------------------------------------
DECLARE
   v_exists NUMBER;
BEGIN
   SELECT COUNT(*) INTO v_exists FROM dba_users WHERE username = 'ATRACE';
   IF v_exists = 0 THEN
      EXECUTE IMMEDIATE 'CREATE USER atrace IDENTIFIED BY atrace '
                     || 'DEFAULT TABLESPACE &tbs_data QUOTA UNLIMITED ON &tbs_data';
      EXECUTE IMMEDIATE 'GRANT CREATE SESSION TO atrace';
      DBMS_OUTPUT.PUT_LINE('  created user atrace (EPF compatibility)');
   END IF;
END;
/

-- The view belongs to atrace but reads anon_meta tables, so atrace needs its own
-- privilege on them - a view is compiled with the OWNER's rights, not the
-- creator's, so SYS creating it is not enough. WITH GRANT OPTION is needed too,
-- because atrace then has to pass SELECT on the view down to op.
--
-- Without this the CREATE VIEW fails with ORA-00942, which reads as "the table
-- does not exist" and is easy to misdiagnose as a missing object.
GRANT SELECT ON anon_meta.code_map           TO atrace WITH GRANT OPTION;
GRANT SELECT ON anon_meta.identity_inventory TO atrace WITH GRANT OPTION;

CREATE OR REPLACE VIEW atrace.ref_tables_modif AS
SELECT CASE i.domain WHEN 'ACCOUNT' THEN 'compte_banque' ELSE 'tiers' END AS table_name,
       'code'     AS field_name,
       c.old_code AS old_value,
       c.new_code AS new_value
  FROM anon_meta.identity_inventory i
  JOIN anon_meta.code_map c
    ON c.category = i.map_category
   AND c.old_code = i.old_code
 WHERE c.id_applied = 'Y';

-- ----------------------------------------------------------------------------
-- Grants
-- ----------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.code_map           TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.identity_inventory TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.confirmed_identity TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.identity_plan      TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.code_lookup        TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.owner_key          TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_inventory     TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_run           TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_run_setting   TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.field_baseline     TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_step_log      TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.verify_result      TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.verify_key         TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.reference_harvest  TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.node_lookup        TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_progress      TO op;
GRANT SELECT, INSERT, UPDATE, DELETE ON anon_meta.anon_check         TO op;
GRANT SELECT                          ON anon_meta.unclassified_reason TO op;
GRANT SELECT                          ON anon_meta.seq_anon_run      TO op;
GRANT SELECT                          ON anon_meta.seq_step_log      TO op;
GRANT SELECT                          ON atrace.ref_tables_modif     TO op;

PROMPT === Metadata schema ready ===
PROMPT
