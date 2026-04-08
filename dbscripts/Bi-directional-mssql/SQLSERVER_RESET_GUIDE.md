# Database Teardown & Recreation Guide — SQL Server

Reset the `apim_db` and `shared_db` databases on both DCs to a clean state with bidirectional transactional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `sqlcmd` client available (or SSMS connected to both servers)
- Database passwords available

## Connection Setup

```bash
# DC1 — East US 1
export DC1_HOST=10.2.3.4
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

> `sp_removedbreplication` forcefully removes all replication objects (subscriptions, publications, articles, and the publish flag) from a database in one shot. This avoids Log Reader Agent lock conflicts that block `sp_droppublication`.
>
> If `sp_removedbreplication` fails with a Log Reader lock error, run `sp_replflush` on the affected database first to release the connection.

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

Follow [SQLSERVER_REPLICATION_GUIDE.md](SQLSERVER_REPLICATION_GUIDE.md) from **Step 3** onwards:

- **Step 3** — Create `apim_db` and `shared_db` on both DCs
- **Step 4** — Run DC-specific table scripts (`dc1/SQLServer/mssql/` and `dc2/SQLServer/mssql/`)
- **Step 4a** — Create replication database users (`repl_dc2` on DC1, `repl_dc1` on DC2)
- **Step 5** — Configure publishing on all 4 databases
- **Step 6** — Add articles (tables) to publications
- **Step 7** — Create bidirectional subscriptions (agents auto-start)
- **Step 8** — Verify agents are running
- **Step 9** — Verify all subscriptions are active
- **Step 10** — Test bidirectional replication

> Steps 1-2 (prerequisites, logins, and distribution configuration) don't need to be repeated — they're server-level settings that survive database drops. However, Step 4a (database users) **must** be re-run since the databases are new.

---

## Phase 3: Restart APIM

Scale APIM pods back up on both DCs. The first startup on fresh databases will initialize the default data (admin user, default policies, etc.).

### Quick replication test

After APIM starts on DC1, verify the admin user replicated to DC2:

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -Q "SELECT TOP 5 UM_USER_NAME FROM UM_USER;"
```

You should see the `admin` user (created by DC1's first startup) appear on DC2.

---

## Troubleshooting

### Log Reader Agent blocks sp_droppublication

If you try `sp_droppublication` or `sp_dropsubscription` individually, you may get: *"Only one Log Reader Agent or log-related procedure can connect to a database at a time."* This happens because the Log Reader Agent holds an active connection. Stopping the agent via `xp_servicecontrol` requires sysadmin and is typically denied. Use `sp_removedbreplication` instead (see Step 1.1) — it bypasses the Log Reader lock.

### "database is in use" when dropping

Use `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` as shown in Step 1.2. If that still fails:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "DECLARE @kill VARCHAR(8000) = ''; SELECT @kill = @kill + 'KILL ' + CONVERT(VARCHAR(5), session_id) + ';' FROM sys.dm_exec_sessions WHERE database_id = DB_ID('apim_db') AND session_id <> @@SPID; EXEC(@kill);"
```

### Subscription errors after recreation

```bash
# Check error details on DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql

# Check error details on DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql
```

### Orphaned replication agent jobs

After dropping publications, check if SQL Server Agent jobs were cleaned up:

```bash
# List replication jobs on DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql

# Delete orphaned jobs manually if needed
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "EXEC msdb.dbo.sp_delete_job @job_name = '<job_name_here>';"
```

### Distribution database issues

If the distribution database has stale entries after recreation:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;"
```
