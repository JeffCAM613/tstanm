-- ============================================================================
-- run/engine - Whether the engine is installed and valid
-- ============================================================================
-- Sent to the worker session (as OP) right after 30_install_engine.sql.
--
-- Prints ANON_ENGINE|<package status>|<body status>|<version>
-- (the version only when both are VALID).
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

DECLARE
   v_spec    VARCHAR2(10);
   v_body    VARCHAR2(10);
   v_version VARCHAR2(20);
BEGIN
   SELECT NVL(MAX(CASE WHEN object_type = 'PACKAGE' THEN status END), 'MISSING'),
          NVL(MAX(CASE WHEN object_type = 'PACKAGE BODY' THEN status END), 'MISSING')
     INTO v_spec, v_body
     FROM user_objects
    WHERE object_name = 'ANON_ENGINE';
   IF v_spec = 'VALID' AND v_body = 'VALID' THEN
      EXECUTE IMMEDIATE 'BEGIN :v := op.anon_engine.tool_version; END;' USING OUT v_version;
   END IF;
   DBMS_OUTPUT.PUT_LINE('ANON_ENGINE|' || v_spec || '|' || v_body || '|' || v_version);
END;
/
