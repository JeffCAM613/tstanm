-- ============================================================================
-- run/inventory - The loaded inventory, against this database
-- ============================================================================
-- Sent to the worker session (as OP) after the inventory was loaded and
-- 21_validate_inventory.sql accepted it: how many items it holds, where they
-- come from, and how many are in this database.
--
-- Prints
--   ANON_INVENTORY|<items>|<shipped>|<site>|<here>|<not here>|<tables not here>|<columns not here>
-- ============================================================================

SET ECHO OFF TAB OFF FEEDBACK OFF VERIFY OFF HEADING OFF PAGESIZE 0 LINESIZE 32767 TRIMOUT ON
WHENEVER SQLERROR CONTINUE

SELECT 'ANON_INVENTORY|' || COUNT(*)
       || '|' || COUNT(CASE WHEN i.source = 'BASE' THEN 1 END)
       || '|' || COUNT(CASE WHEN i.source = 'CUSTOM' THEN 1 END)
       || '|' || COUNT(CASE WHEN c.column_name IS NOT NULL THEN 1 END)
       || '|' || COUNT(CASE WHEN c.column_name IS NULL THEN 1 END)
       || '|' || COUNT(DISTINCT CASE WHEN t.table_name IS NULL THEN i.table_name END)
       || '|' || COUNT(CASE WHEN c.column_name IS NULL AND t.table_name IS NOT NULL THEN 1 END)
  FROM anon_meta.anon_inventory i
  LEFT JOIN all_tab_columns c
         ON c.owner = 'OP' AND c.table_name = i.table_name AND c.column_name = i.column_name
  LEFT JOIN (SELECT DISTINCT table_name FROM all_tab_columns WHERE owner = 'OP') t
         ON t.table_name = i.table_name;
