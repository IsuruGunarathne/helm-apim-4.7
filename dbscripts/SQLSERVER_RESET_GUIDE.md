# Database Teardown & Recreation Guide — SQL Server

Reset the `apim_db` and `shared_db` databases on both DCs to a clean state with bidirectional transactional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `sqlcmd` client available (or SSMS connected to both servers)
- Database passwords available

## Connection Setup

```bash
# DC1 — East US 2
export DC1_HOST=apim-4-7-eus2-sql
export DC1_USER=apimadmineast
export DC1_PORT=1433
export DC1_PASS="{your-password}"

# DC2 — West US 2
export DC2_HOST=apim-4-7-wus2-sql
export DC2_USER=apimadminwest
export DC2_PORT=1433
export DC2_PASS="{your-password}"
```

---

## Phase 1: Teardown

### 1.1 Drop subscriptions on DC1

```sql
-- Connect to DC1 apim_db
USE apim_db;
GO

-- Check existing subscriptions
EXEC sp_helpsubscription @publication = 'apim_db_pub';
GO

-- Drop subscription to DC2
EXEC sp_dropsubscription
    @publication = 'apim_db_pub',
    @subscriber = 'apim-4-7-wus2-sql',
    @destination_db = 'apim_db',
    @article = 'all';
GO
```

```sql
-- Connect to DC1 shared_db
USE shared_db;
GO

EXEC sp_dropsubscription
    @publication = 'shared_db_pub',
    @subscriber = 'apim-4-7-wus2-sql',
    @destination_db = 'shared_db',
    @article = 'all';
GO
```

### 1.2 Drop subscriptions on DC2

```sql
-- Connect to DC2 apim_db
USE apim_db;
GO

EXEC sp_dropsubscription
    @publication = 'apim_db_pub',
    @subscriber = 'apim-4-7-eus2-sql',
    @destination_db = 'apim_db',
    @article = 'all';
GO
```

```sql
-- Connect to DC2 shared_db
USE shared_db;
GO

EXEC sp_dropsubscription
    @publication = 'shared_db_pub',
    @subscriber = 'apim-4-7-eus2-sql',
    @destination_db = 'shared_db',
    @article = 'all';
GO
```

### 1.3 Drop publications on both DCs

On **DC1**:
```sql
USE apim_db;
GO
EXEC sp_droppublication @publication = 'apim_db_pub';
GO

USE shared_db;
GO
EXEC sp_droppublication @publication = 'shared_db_pub';
GO
```

On **DC2**:
```sql
USE apim_db;
GO
EXEC sp_droppublication @publication = 'apim_db_pub';
GO

USE shared_db;
GO
EXEC sp_droppublication @publication = 'shared_db_pub';
GO
```

### 1.4 Disable publishing on databases

On **both** DCs:
```sql
EXEC sp_replicationdboption @dbname = 'apim_db', @optname = 'publish', @value = 'false';
GO
EXEC sp_replicationdboption @dbname = 'shared_db', @optname = 'publish', @value = 'false';
GO
```

### 1.5 Drop databases on both DCs

On **DC1**:
```sql
USE master;
GO

ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
DROP DATABASE apim_db;
GO

ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
DROP DATABASE shared_db;
GO
```

On **DC2**:
```sql
USE master;
GO

ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
DROP DATABASE apim_db;
GO

ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO
DROP DATABASE shared_db;
GO
```

### 1.6 Clean up distribution database (if needed)

On **both** DCs, check for orphaned entries:
```sql
-- Check for stale subscriptions in the distribution database
USE distribution;
GO
SELECT * FROM dbo.MSsubscriptions;
GO

-- Clean up distribution history
EXEC sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;
GO
```

---

## Phase 2: Recreate Databases & Replication

Follow [SQLSERVER_REPLICATION_GUIDE.md](SQLSERVER_REPLICATION_GUIDE.md) from **Step 3** onwards:

- **Step 3** — Create `apim_db` and `shared_db` on both DCs
- **Step 4** — Run DC-specific table scripts (`dc1/SQLServer/mssql/` and `dc2/SQLServer/mssql/`)
- **Step 5** — Configure publishing on all 4 databases
- **Step 6** — Add articles (tables) to publications
- **Step 7** — Create bidirectional subscriptions
- **Step 8** — Start replication agents
- **Step 9** — Verify all subscriptions are active

> Steps 1-2 (prerequisites and distribution configuration) don't need to be repeated — they're server-level settings that survive database drops.

---

## Phase 3: Restart APIM

Scale APIM pods back up on both DCs. The first startup on fresh databases will initialize the default data (admin user, default policies, etc.).

### Quick replication test

After APIM starts on DC1, verify the admin user replicated to DC2:

```bash
sqlcmd -S $DC2_HOST -U $DC2_USER -P $DC2_PASS -d shared_db \
  -Q "SELECT TOP 5 UM_USER_NAME FROM UM_USER;"
```

You should see the `admin` user (created by DC1's first startup) appear on DC2.

---

## Troubleshooting

### "database is in use" when dropping

Use `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` as shown in Step 1.5. If that still fails:
```sql
-- Kill all connections to the database
DECLARE @kill VARCHAR(8000) = '';
SELECT @kill = @kill + 'KILL ' + CONVERT(VARCHAR(5), session_id) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID('apim_db') AND session_id <> @@SPID;
EXEC(@kill);
GO
```

### Subscription errors after recreation

```sql
-- Check for error details
SELECT * FROM distribution.dbo.MSrepl_errors ORDER BY time DESC;
GO

-- If agents are stuck, stop and restart them from SQL Server Agent Jobs
```

### Orphaned replication agent jobs

After dropping publications, check if SQL Server Agent jobs were cleaned up:
```sql
-- List replication-related jobs
SELECT name, enabled FROM msdb.dbo.sysjobs
WHERE category_id IN (
    SELECT category_id FROM msdb.dbo.syscategories WHERE name LIKE 'REPL%'
);
GO

-- Delete orphaned jobs manually if needed
EXEC msdb.dbo.sp_delete_job @job_name = 'job_name_here';
GO
```

### Distribution database issues

If the distribution database has stale entries after recreation:
```sql
-- Reinitialize distribution cleanup
EXEC distribution.dbo.sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 0;
GO
```
