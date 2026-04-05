# Database Teardown & Recreation Guide — P2P Replication

Reset the `apim_db` and `shared_db` databases on both DCs to a clean state with peer-to-peer transactional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `sqlcmd` client available
- Database passwords available

## Connection Setup

```bash
# DC1 — East US 2
export DC1_HOST=10.0.3.4
export DC1_USER=apimadmineast
export DC1_PORT=1433
export DC1_PASS="distributed@2"

# DC2 — West US 2
export DC2_HOST=10.1.3.4
export DC2_USER=apimadminwest
export DC2_PORT=1433
export DC2_PASS="distributed@2"
```

---

## Phase 1: Teardown

### 1.1 Remove all replication from databases

> `sp_removedbreplication` forcefully removes all replication objects (subscriptions, publications, articles, and the publish flag) from a database in one shot. Run `sp_replflush` first to release any Log Reader Agent connections.

```bash
# DC1 — flush replication connections, then remove
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -Q "EXEC sp_replflush"
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "EXEC sp_removedbreplication @dbname = 'apim_db'"

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -Q "EXEC sp_replflush"
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "EXEC sp_removedbreplication @dbname = 'shared_db'"

# DC2 — flush replication connections, then remove
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -Q "EXEC sp_replflush"
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -Q "EXEC sp_removedbreplication @dbname = 'apim_db'"

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -Q "EXEC sp_replflush"
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -Q "EXEC sp_removedbreplication @dbname = 'shared_db'"
```

### 1.2 Drop databases on both DCs

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE apim_db; ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shared_db;"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -Q "ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE apim_db; ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shared_db;"
```

### 1.3 Clean up distribution database (if needed)

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "SELECT * FROM dbo.MSsubscriptions;"

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -Q "SELECT * FROM dbo.MSsubscriptions;"

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -Q "EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;"
```

---

## Phase 2: Recreate Databases & Replication

Follow [SQLSERVER_P2P_REPLICATION_GUIDE.md](SQLSERVER_P2P_REPLICATION_GUIDE.md) from **Step 3** onwards:

- **Step 3** — Create `apim_db` and `shared_db` on both DCs
- **Step 4** — Run DC-specific table scripts (`dc1/SQLServer/mssql/` and `dc2/SQLServer/mssql/`)
- **Step 4a** — Create replication database users (`repl_dc2` on DC1, `repl_dc1` on DC2)
- **Step 5** — Create P2P publications (DC1: originator=1, DC2: originator=2)
- **Step 6** — Add articles on both DCs
- **Step 7** — Create bidirectional subscriptions
- **Step 8** — Verify agents are running and status is healthy
- **Step 9** — Test bidirectional replication

> Steps 1-2 (logins and distribution) don't need to be repeated — they're server-level settings that survive database drops. However, Step 4a (database users) **must** be re-run since the databases are new.

---

## Phase 3: Restart APIM

> **Critical: Start DC1 first, then DC2.** See Step 10 in the main guide for the full sequence.

1. Scale up APIM pods on **DC1 only**
2. Wait for DC1 to fully initialize (all pods ready)
3. Verify DC1's seed data replicated to DC2:
   ```bash
   sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
     -Q "SELECT TOP 5 UM_USER_NAME FROM UM_USER"
   ```
4. Scale up APIM pods on DC2

---

## Troubleshooting

### Log Reader Agent blocks sp_removedbreplication

If `sp_removedbreplication` fails with "Only one Log Reader Agent can connect", run `sp_replflush` on the affected database first (shown in Step 1.1). If that still fails, RDP into the Windows VM and stop the SQL Server Agent service from `services.msc`.

### "database is in use" when dropping

Use `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` as shown in Step 1.2. If that still fails, kill active sessions:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "DECLARE @kill VARCHAR(8000) = ''; SELECT @kill = @kill + 'KILL ' + CONVERT(VARCHAR(5), session_id) + ';' FROM sys.dm_exec_sessions WHERE database_id = DB_ID('apim_db') AND session_id <> @@SPID; EXEC(@kill);"
```

### Orphaned replication agent jobs

After dropping publications, check if SQL Server Agent jobs were cleaned up:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "SELECT name, enabled FROM sysjobs WHERE category_id IN (SELECT category_id FROM syscategories WHERE name LIKE 'REPL%')"

# Delete orphaned jobs manually if needed
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "EXEC msdb.dbo.sp_delete_job @job_name = '<job_name_here>'"
```

### Subscription errors after recreation

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_check_errors.sql
```

### Distribution database issues

If the distribution database has stale entries:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;"
```
