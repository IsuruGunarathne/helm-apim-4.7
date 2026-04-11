SET SERVEROUTPUT ON SIZE UNLIMITED
SET FEEDBACK ON
SET LINESIZE 200
SET PAGESIZE 0
WHENEVER SQLERROR CONTINUE

PROMPT ============================================================
PROMPT === apim_db: listing tables missing CDRTS$ROW
PROMPT ============================================================
ALTER SESSION SET CONTAINER = apim_db;

SELECT t.owner||'.'||t.table_name AS missing_table
FROM   dba_tables t
WHERE  t.owner = 'APIMADMIN'
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
PROMPT === apim_db: running ADD_AUTO_CDR on the missing ones
PROMPT ============================================================
DECLARE
  v_ok  PLS_INTEGER := 0;
  v_err PLS_INTEGER := 0;
  v_msg VARCHAR2(500);
BEGIN
  FOR r IN (
    SELECT t.owner, t.table_name
    FROM   dba_tables t
    WHERE  t.owner = 'APIMADMIN'
      AND  EXISTS (SELECT 1 FROM dba_constraints c
                   WHERE c.owner = t.owner
                     AND c.table_name = t.table_name
                     AND c.constraint_type = 'P')
      AND  NOT EXISTS (SELECT 1 FROM dba_tab_cols tc
                       WHERE tc.owner = t.owner
                         AND tc.table_name = t.table_name
                         AND tc.column_name = 'CDRTS$ROW')
  ) LOOP
    BEGIN
      DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
        schema_name => r.owner,
        table_name  => r.table_name);
      v_ok := v_ok + 1;
      DBMS_OUTPUT.PUT_LINE('OK  : '||r.owner||'.'||r.table_name);
    EXCEPTION
      WHEN OTHERS THEN
        v_err := v_err + 1;
        v_msg := SUBSTR(SQLERRM, 1, 400);
        DBMS_OUTPUT.PUT_LINE('ERR : '||r.owner||'.'||r.table_name||' -> '||v_msg);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('apim_db SUMMARY ok='||v_ok||' errors='||v_err);
END;
/

PROMPT ============================================================
PROMPT === apim_db: coverage after fix
PROMPT ============================================================
SELECT 'apim_db pk_tables='   ||
       (SELECT COUNT(DISTINCT t.table_name)
          FROM dba_tables t
          JOIN dba_constraints c
            ON c.owner = t.owner
           AND c.table_name = t.table_name
           AND c.constraint_type = 'P'
         WHERE t.owner='APIMADMIN')
    || '  acdr_tables='||
       (SELECT COUNT(*)
          FROM dba_tab_cols
         WHERE owner='APIMADMIN'
           AND column_name='CDRTS$ROW')
FROM dual;

PROMPT ============================================================
PROMPT === shared_db: listing tables missing CDRTS$ROW
PROMPT ============================================================
ALTER SESSION SET CONTAINER = shared_db;

SELECT t.owner||'.'||t.table_name AS missing_table
FROM   dba_tables t
WHERE  t.owner = 'APIMADMIN'
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
PROMPT === shared_db: running ADD_AUTO_CDR on the missing ones
PROMPT ============================================================
DECLARE
  v_ok  PLS_INTEGER := 0;
  v_err PLS_INTEGER := 0;
  v_msg VARCHAR2(500);
BEGIN
  FOR r IN (
    SELECT t.owner, t.table_name
    FROM   dba_tables t
    WHERE  t.owner = 'APIMADMIN'
      AND  EXISTS (SELECT 1 FROM dba_constraints c
                   WHERE c.owner = t.owner
                     AND c.table_name = t.table_name
                     AND c.constraint_type = 'P')
      AND  NOT EXISTS (SELECT 1 FROM dba_tab_cols tc
                       WHERE tc.owner = t.owner
                         AND tc.table_name = t.table_name
                         AND tc.column_name = 'CDRTS$ROW')
  ) LOOP
    BEGIN
      DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
        schema_name => r.owner,
        table_name  => r.table_name);
      v_ok := v_ok + 1;
      DBMS_OUTPUT.PUT_LINE('OK  : '||r.owner||'.'||r.table_name);
    EXCEPTION
      WHEN OTHERS THEN
        v_err := v_err + 1;
        v_msg := SUBSTR(SQLERRM, 1, 400);
        DBMS_OUTPUT.PUT_LINE('ERR : '||r.owner||'.'||r.table_name||' -> '||v_msg);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('---');
  DBMS_OUTPUT.PUT_LINE('shared_db SUMMARY ok='||v_ok||' errors='||v_err);
END;
/

PROMPT ============================================================
PROMPT === shared_db: coverage after fix
PROMPT ============================================================
SELECT 'shared_db pk_tables=' ||
       (SELECT COUNT(DISTINCT t.table_name)
          FROM dba_tables t
          JOIN dba_constraints c
            ON c.owner = t.owner
           AND c.table_name = t.table_name
           AND c.constraint_type = 'P'
         WHERE t.owner='APIMADMIN')
    || '  acdr_tables='||
       (SELECT COUNT(*)
          FROM dba_tab_cols
         WHERE owner='APIMADMIN'
           AND column_name='CDRTS$ROW')
FROM dual;

EXIT;
