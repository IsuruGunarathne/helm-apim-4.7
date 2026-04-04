# Database Teardown & Recreation Guide — SQL Server

Reset the `apim_db` and `shared_db` databases on both DCs to a clean state with bidirectional transactional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `sqlcmd` client available (or SSMS connected to both servers)
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

> **Important:** Subscriptions were created using IP addresses (not hostnames) in Step 7 of the replication guide. The drop commands below use `${DC2_HOST}` and `${DC1_HOST}` to match. Make sure the environment variables above are set before running.

### 1.1 Drop subscriptions on DC1

```bash
# DC1 — drop apim_db subscription to DC2
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -Q "EXEC sp_dropsubscription @publication = 'apim_db_pub', @subscriber = '${DC2_HOST}', @destination_db = 'apim_db', @article = 'all'; GO"

# DC1 — drop shared_db subscription to DC2
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -Q "EXEC sp_dropsubscription @publication = 'shared_db_pub', @subscriber = '${DC2_HOST}', @destination_db = 'shared_db', @article = 'all'; GO"
```

### 1.2 Drop subscriptions on DC2

```bash
# DC2 — drop apim_db subscription to DC1
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -Q "EXEC sp_dropsubscription @publication = 'apim_db_pub', @subscriber = '${DC1_HOST}', @destination_db = 'apim_db', @article = 'all'; GO"

# DC2 — drop shared_db subscription to DC1
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -Q "EXEC sp_dropsubscription @publication = 'shared_db_pub', @subscriber = '${DC1_HOST}', @destination_db = 'shared_db', @article = 'all'; GO"
```

### 1.3 Drop publications on both DCs

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -Q "EXEC sp_droppublication @publication = 'apim_db_pub'; GO"

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -Q "EXEC sp_droppublication @publication = 'shared_db_pub'; GO"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -Q "EXEC sp_droppublication @publication = 'apim_db_pub'; GO"

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -Q "EXEC sp_droppublication @publication = 'shared_db_pub'; GO"
```

### 1.4 Disable publishing on databases

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C \
  -Q "EXEC sp_replicationdboption @dbname = 'apim_db', @optname = 'publish', @value = 'false'; GO EXEC sp_replicationdboption @dbname = 'shared_db', @optname = 'publish', @value = 'false'; GO"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -C \
  -Q "EXEC sp_replicationdboption @dbname = 'apim_db', @optname = 'publish', @value = 'false'; GO EXEC sp_replicationdboption @dbname = 'shared_db', @optname = 'publish', @value = 'false'; GO"
```

### 1.5 Drop databases on both DCs

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -Q "ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE apim_db; ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shared_db;"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -Q "ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE apim_db; ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE shared_db;"
```

### 1.6 Clean up distribution database (if needed)

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "SELECT * FROM dbo.MSsubscriptions; GO EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0; GO"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -Q "SELECT * FROM dbo.MSsubscriptions; GO EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0; GO"
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

### "database is in use" when dropping

Use `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` as shown in Step 1.5. If that still fails:

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
  -Q "EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0; GO"
```
