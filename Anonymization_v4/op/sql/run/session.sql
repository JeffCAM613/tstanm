-- ============================================================================
-- run/session - What a session is connected to
-- ============================================================================
-- Sent by run_op_anonymization.bat right after each CONNECT, as SYS and as
-- OP, before anything else: the connection is tested before it is used.
--
-- Prints
--   ANON_SESSION|<user>|<database>|<container>|<Oracle version>|<database clock>
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
SET SERVEROUTPUT ON SIZE UNLIMITED FORMAT WRAPPED
WHENEVER SQLERROR CONTINUE

DECLARE
   v_version VARCHAR2(40);
BEGIN
   -- VERSION_FULL (18c and later) says 19.21; VERSION says only 19.0.
   BEGIN
      EXECUTE IMMEDIATE q'[SELECT MAX(version_full) FROM product_component_version
                            WHERE product LIKE 'Oracle Database%']' INTO v_version;
   EXCEPTION
      WHEN OTHERS THEN
         SELECT MAX(version) INTO v_version FROM product_component_version WHERE product LIKE 'Oracle%';
   END;
   DBMS_OUTPUT.PUT_LINE('ANON_SESSION|' || USER || '|' || SYS_CONTEXT('USERENV', 'DB_NAME')
                     || '|' || SYS_CONTEXT('USERENV', 'CON_NAME') || '|' || v_version
                     || '|' || TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS'));
END;
/
