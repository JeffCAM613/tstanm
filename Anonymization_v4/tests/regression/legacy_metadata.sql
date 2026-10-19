-- ============================================================================
-- Regression fixture - the metadata schema as the previous v4 created it
-- ============================================================================
-- Run as SYS, after fixture_schema.sql (which drops anon_meta). Recreates the
-- objects exactly as the version before the typed identity model left them -
-- code_map without run_id and id_applied, the untyped code_map_any lookup, the
-- old inventory category list, anon_run without dataset_json - so that the
-- current 10_create_metadata_schema.sql can be shown to migrate them in place.
-- ============================================================================

SET FEEDBACK OFF
WHENEVER SQLERROR EXIT FAILURE

CREATE USER anon_meta IDENTIFIED BY anon_meta DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;

CREATE TABLE anon_meta.code_map (
   category   VARCHAR2(20)  NOT NULL,
   old_code   VARCHAR2(80)  NOT NULL,
   new_code   VARCHAR2(80)  NOT NULL,
   created_at DATE DEFAULT SYSDATE NOT NULL,
   CONSTRAINT pk_code_map PRIMARY KEY (category, old_code));
CREATE INDEX anon_meta.ix_code_map_old ON anon_meta.code_map(old_code);
CREATE UNIQUE INDEX anon_meta.ux_code_map_new ON anon_meta.code_map(new_code);

CREATE TABLE anon_meta.code_map_any (
   old_code VARCHAR2(80) NOT NULL,
   new_code VARCHAR2(80) NOT NULL,
   CONSTRAINT pk_code_map_any PRIMARY KEY (old_code));

CREATE TABLE anon_meta.anon_inventory (
   table_name  VARCHAR2(128) NOT NULL,
   column_name VARCHAR2(128) NOT NULL,
   rule        VARCHAR2(20)  NOT NULL,
   category    VARCHAR2(20)  NOT NULL,
   source      VARCHAR2(10)  DEFAULT 'BASE' NOT NULL,
   notes       VARCHAR2(500),
   seq         NUMBER,
   CONSTRAINT pk_anon_inventory PRIMARY KEY (table_name, column_name),
   CONSTRAINT ck_anon_inv_rule CHECK (rule IN ('CODE','NULL_OUT','DESCRIPTION','SELF_CODE')),
   CONSTRAINT ck_anon_inv_cat CHECK
      (category IN ('ANY','ENTITY','PORTFOLIO','COUNTERPARTY','BANK_ACCOUNT','NONE')));
INSERT INTO anon_meta.anon_inventory (table_name, column_name, rule, category, seq)
VALUES ('TIERS', 'CODE', 'CODE', 'ANY', 1);

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
   CONSTRAINT pk_anon_run PRIMARY KEY (run_id),
   CONSTRAINT ck_anon_run_mode   CHECK (run_mode IN ('EXECUTE','DRYRUN')),
   CONSTRAINT ck_anon_run_status CHECK (status IN ('RUNNING','COMPLETED','FAILED')));
CREATE SEQUENCE anon_meta.seq_anon_run START WITH 1 INCREMENT BY 1 NOCACHE;
INSERT INTO anon_meta.anon_run (run_id, run_mode, status, config_json)
VALUES (anon_meta.seq_anon_run.NEXTVAL, 'EXECUTE', 'COMPLETED',
        '{"categories":"ENTITY","parallel":4,"min_code_length":2}');

CREATE TABLE anon_meta.anon_step_log (
   run_id        NUMBER        NOT NULL,
   logged_at     TIMESTAMP     DEFAULT SYSTIMESTAMP NOT NULL,
   phase         VARCHAR2(40)  NOT NULL,
   object_name   VARCHAR2(300),
   rule          VARCHAR2(20),
   status        VARCHAR2(20)  NOT NULL,
   rows_affected NUMBER,
   elapsed_ms    NUMBER,
   message       VARCHAR2(4000));

CREATE TABLE anon_meta.verify_result (
   checked_at   TIMESTAMP    DEFAULT SYSTIMESTAMP NOT NULL,
   part         VARCHAR2(60) NOT NULL,
   check_name   VARCHAR2(300),
   expectation  VARCHAR2(200),
   total_rows   NUMBER,
   bad_rows     NUMBER,
   status       VARCHAR2(10) NOT NULL,
   detail       VARCHAR2(4000));

COMMIT;

PROMPT legacy metadata schema created
EXIT SUCCESS
