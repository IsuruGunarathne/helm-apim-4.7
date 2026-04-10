# Oracle Database Teardown & Recreation Guide

Reset the `apim_db` and `shared_db` pluggable databases on both DCs to a clean state with GoldenGate bi-directional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `sqlplus` client available (from jump-box or GoldenGate hub VM)
- Database passwords available
- Access to the GoldenGate hub VM

## Connection Setup

```bash
# DC1 — East US 1 (Oracle DB VM)
export DC1_HOST=10.2.4.4
export DC1_PORT=1521
export DC1_USER=apimadmineast
export DC1_PASS="{your-password}"

# DC2 — West US 2 (Oracle DB VM)
export DC2_HOST=10.1.4.4
export DC2_PORT=1521
export DC2_USER=apimadminwest
export DC2_PASS="{your-password}"
```

---

## Phase 1: Stop GoldenGate Processes

SSH into the **GoldenGate hub VM** and stop all processes:

```bash
cd $OGG_HOME
./ggsci

GGSCI> STOP REPLICAT REP1A
GGSCI> STOP REPLICAT REP1S
GGSCI> STOP REPLICAT REP2A
GGSCI> STOP REPLICAT REP2S

GGSCI> STOP EXTRACT EXT1A
GGSCI> STOP EXTRACT EXT1S
GGSCI> STOP EXTRACT EXT2A
GGSCI> STOP EXTRACT EXT2S

-- Verify all stopped
GGSCI> INFO ALL
```

### 1.1 Delete GoldenGate Processes

```bash
-- Unregister Extracts from the databases
GGSCI> DBLOGIN USERIDALIAS dc1_apim
GGSCI> UNREGISTER EXTRACT EXT1A DATABASE CONTAINER (apim_db)
GGSCI> DELETE EXTRACT EXT1A
GGSCI> DELETE EXTTRAIL ./dirdat/a1

GGSCI> DBLOGIN USERIDALIAS dc1_shared
GGSCI> UNREGISTER EXTRACT EXT1S DATABASE CONTAINER (shared_db)
GGSCI> DELETE EXTRACT EXT1S
GGSCI> DELETE EXTTRAIL ./dirdat/s1

GGSCI> DBLOGIN USERIDALIAS dc2_apim
GGSCI> UNREGISTER EXTRACT EXT2A DATABASE CONTAINER (apim_db)
GGSCI> DELETE EXTRACT EXT2A
GGSCI> DELETE EXTTRAIL ./dirdat/a2

GGSCI> DBLOGIN USERIDALIAS dc2_shared
GGSCI> UNREGISTER EXTRACT EXT2S DATABASE CONTAINER (shared_db)
GGSCI> DELETE EXTRACT EXT2S
GGSCI> DELETE EXTTRAIL ./dirdat/s2

-- Delete Replicats
GGSCI> DELETE REPLICAT REP1A
GGSCI> DELETE REPLICAT REP1S
GGSCI> DELETE REPLICAT REP2A
GGSCI> DELETE REPLICAT REP2S

-- Verify clean state
GGSCI> INFO ALL
-- Should only show MANAGER RUNNING
```

### 1.2 Clean Up Trail Files

```bash
# Remove old trail files
rm -f $OGG_HOME/dirdat/a1*
rm -f $OGG_HOME/dirdat/a2*
rm -f $OGG_HOME/dirdat/s1*
rm -f $OGG_HOME/dirdat/s2*
```

---

## Phase 2: Drop and Recreate PDBs

### 2.1 Drop PDBs on DC1

SSH into the **DC1 Oracle DB VM**:

```sql
sqlplus / as sysdba

-- Close PDBs first
ALTER PLUGGABLE DATABASE apim_db CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE shared_db CLOSE IMMEDIATE;

-- Drop PDBs (including datafiles)
DROP PLUGGABLE DATABASE apim_db INCLUDING DATAFILES;
DROP PLUGGABLE DATABASE shared_db INCLUDING DATAFILES;

-- Verify
SELECT name, open_mode FROM v$pdbs;
```

### 2.2 Drop PDBs on DC2

SSH into the **DC2 Oracle DB VM**:

```sql
sqlplus / as sysdba

ALTER PLUGGABLE DATABASE apim_db CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE shared_db CLOSE IMMEDIATE;

DROP PLUGGABLE DATABASE apim_db INCLUDING DATAFILES;
DROP PLUGGABLE DATABASE shared_db INCLUDING DATAFILES;
```

---

## Phase 3: Recreate Databases & Replication

Follow [ORACLE_OGG_REPLICATION_GUIDE.md](ORACLE_OGG_REPLICATION_GUIDE.md) from **Part 3: Step 1** onwards:

- **Step 1** — Create PDBs (`apim_db`, `shared_db`) on both DCs
- **Step 2** — Grant user privileges
- **Steps 3-5** — Already done (archive log, supplemental logging, GoldenGate replication are CDB-level settings that survive PDB drops)
- **Step 6** — GoldenGate admin user (C##GGADMIN) is a CDB common user — no need to recreate
- **Step 7** — Run DC-specific table and sequence scripts
- **Steps 8-9** — tnsnames.ora and Manager are still configured on the hub VM
- **Step 10-12** — Hub subdirectories and credentials still exist
- **Steps 13-14** — Recreate Extract and Replicat processes
- **Step 15** — Start all processes
- **Steps 16-17** — Verify replication

> **Shortcut:** Since the GoldenGate hub VM's Manager, credentials, and tnsnames are still in place, you only need to recreate the PDBs, run the table/sequence scripts, and re-add the Extract/Replicat processes.

---

## Phase 4: Restart APIM

Scale APIM pods back up on both DCs. The first startup on fresh databases will initialize the default data (admin user, default policies, etc.).

### Quick replication test

After APIM starts on DC1, verify the admin user replicated to DC2:

```sql
sqlplus apimadminwest/{password}@DC2_SHARED

SELECT UM_USER_NAME FROM UM_USER WHERE ROWNUM <= 5;
```

You should see the `admin` user (created by DC1's first startup) appear on DC2.

---

## Troubleshooting

### "pluggable database is in use"

If `ALTER PLUGGABLE DATABASE ... CLOSE IMMEDIATE` fails:

```sql
-- Check active sessions
SELECT sid, serial#, username, program FROM v$session WHERE con_id = (SELECT con_id FROM v$pdbs WHERE name = 'APIM_DB');

-- Kill sessions
ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE;

-- Then retry close
ALTER PLUGGABLE DATABASE apim_db CLOSE IMMEDIATE;
```

### GoldenGate Extract won't start after recreation

```bash
# Check the report
GGSCI> VIEW REPORT EXT1A

# Common cause: Extract was registered to the old PDB incarnation
# Re-register:
GGSCI> DBLOGIN USERIDALIAS dc1_apim
GGSCI> UNREGISTER EXTRACT EXT1A DATABASE
GGSCI> REGISTER EXTRACT EXT1A DATABASE CONTAINER (apim_db)
GGSCI> START EXTRACT EXT1A
```

### Stale checkpoint files

If processes fail with checkpoint errors after recreation:

```bash
# Delete checkpoint files
rm -f $OGG_HOME/dirchk/EXT1A.*
rm -f $OGG_HOME/dirchk/REP2A.*
# etc.

# Re-add processes with BEGIN NOW
GGSCI> ADD EXTRACT EXT1A, INTEGRATED TRANLOG, BEGIN NOW
```
