SET LINESIZE 200
SET PAGESIZE 100
SET FEEDBACK OFF
WHENEVER SQLERROR CONTINUE

-- ============================================================
-- Real ACDR coverage check for APIMADMIN application tables.
--
-- We exclude two classes of PK-bearing tables that should NOT
-- have ACDR applied, because they are GoldenGate internal
-- infrastructure that just happens to live in the APIMADMIN
-- schema (Extract and Replicat run as apimadmin):
--
--   * OGG$Q_TAB_%       - Integrated Extract's AQ queue table
--   * AQ$_OGG$Q_TAB_%   - Oracle AQ system auxiliary tables
--                         (_C/_D/_G/_H/_I/_P/_S/_T)
--   * GG_HEARTBEAT%     - GG heartbeat tables (installed per
--                         connection in Part 6.2)
-- ============================================================

COLUMN pdb         FORMAT A12
COLUMN app_pk      FORMAT 9999
COLUMN acdr        FORMAT 9999
COLUMN gap         FORMAT 9999
COLUMN status      FORMAT A10

PROMPT ============================================================
PROMPT === apim_db coverage
PROMPT ============================================================
ALTER SESSION SET CONTAINER = apim_db;

SELECT 'apim_db' AS pdb,
       (SELECT COUNT(DISTINCT t.table_name)
          FROM dba_tables t
          JOIN dba_constraints c
            ON c.owner = t.owner
           AND c.table_name = t.table_name
           AND c.constraint_type = 'P'
         WHERE t.owner = 'APIMADMIN'
           AND t.table_name NOT LIKE 'OGG$Q_TAB%'
           AND t.table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
           AND t.table_name NOT LIKE 'GG_HEARTBEAT%') AS app_pk,
       (SELECT COUNT(*)
          FROM dba_tab_cols
         WHERE owner = 'APIMADMIN'
           AND column_name = 'CDRTS$ROW'
           AND table_name NOT LIKE 'OGG$Q_TAB%'
           AND table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
           AND table_name NOT LIKE 'GG_HEARTBEAT%') AS acdr
FROM dual;

PROMPT
PROMPT -- any application table missing ACDR (should return 0 rows):
SELECT t.owner||'.'||t.table_name AS missing_acdr
FROM   dba_tables t
WHERE  t.owner = 'APIMADMIN'
  AND  t.table_name NOT LIKE 'OGG$Q_TAB%'
  AND  t.table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
  AND  t.table_name NOT LIKE 'GG_HEARTBEAT%'
  AND  EXISTS (SELECT 1 FROM dba_constraints c
               WHERE c.owner = t.owner
                 AND c.table_name = t.table_name
                 AND c.constraint_type = 'P')
  AND  NOT EXISTS (SELECT 1 FROM dba_tab_cols tc
                   WHERE tc.owner = t.owner
                     AND tc.table_name = t.table_name
                     AND tc.column_name = 'CDRTS$ROW')
ORDER  BY t.table_name;

PROMPT ============================================================
PROMPT === shared_db coverage
PROMPT ============================================================
ALTER SESSION SET CONTAINER = shared_db;

SELECT 'shared_db' AS pdb,
       (SELECT COUNT(DISTINCT t.table_name)
          FROM dba_tables t
          JOIN dba_constraints c
            ON c.owner = t.owner
           AND c.table_name = t.table_name
           AND c.constraint_type = 'P'
         WHERE t.owner = 'APIMADMIN'
           AND t.table_name NOT LIKE 'OGG$Q_TAB%'
           AND t.table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
           AND t.table_name NOT LIKE 'GG_HEARTBEAT%') AS app_pk,
       (SELECT COUNT(*)
          FROM dba_tab_cols
         WHERE owner = 'APIMADMIN'
           AND column_name = 'CDRTS$ROW'
           AND table_name NOT LIKE 'OGG$Q_TAB%'
           AND table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
           AND table_name NOT LIKE 'GG_HEARTBEAT%') AS acdr
FROM dual;

PROMPT
PROMPT -- any application table missing ACDR (should return 0 rows):
SELECT t.owner||'.'||t.table_name AS missing_acdr
FROM   dba_tables t
WHERE  t.owner = 'APIMADMIN'
  AND  t.table_name NOT LIKE 'OGG$Q_TAB%'
  AND  t.table_name NOT LIKE 'AQ$_OGG$Q_TAB%'
  AND  t.table_name NOT LIKE 'GG_HEARTBEAT%'
  AND  EXISTS (SELECT 1 FROM dba_constraints c
               WHERE c.owner = t.owner
                 AND c.table_name = t.table_name
                 AND c.constraint_type = 'P')
  AND  NOT EXISTS (SELECT 1 FROM dba_tab_cols tc
                   WHERE tc.owner = t.owner
                     AND tc.table_name = t.table_name
                     AND tc.column_name = 'CDRTS$ROW')
ORDER  BY t.table_name;

EXIT;
