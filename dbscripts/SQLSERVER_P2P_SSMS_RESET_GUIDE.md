# Database Reset Guide — P2P Replication via SSMS

Reset `apim_db` and `shared_db` on both DCs to a clean state using **SQL Server Management Studio (SSMS)**.

> For the sqlcmd-based alternative, see [SQLSERVER_P2P_RESET_GUIDE.md](SQLSERVER_P2P_RESET_GUIDE.md).

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  SQL Server 2022 Dev     │            │  SQL Server 2022 Dev     │
│  IP: 10.2.3.4            │            │  IP: 10.1.3.4            │
│  User: apimadmineast     │   P2P      │  User: apimadminwest     │
│  Originator ID: 100      │◄──Repl.──►│  Originator ID: 200      │
│  apim_db + shared_db     │            │  apim_db + shared_db     │
└──────────────────────────┘            └──────────────────────────┘

        Windows Jump VM (SSMS installed)
```

## Prerequisites

- APIM pods **scaled down** on both DCs before starting
- SSMS connected to both DC1 and DC2 (see [SQLSERVER_P2P_SSMS_GUIDE.md](SQLSERVER_P2P_SSMS_GUIDE.md) for connection setup)

---

## Phase 1: Teardown

### 1.1 Connect to both servers

1. Open SSMS
2. **Object Explorer** > **Connect** > **Database Engine**
   - Server: `10.2.3.4,1433` | Login: `apimadmineast` (DC1)
   - Server: `10.1.3.4,1433` | Login: `apimadminwest` (DC2)
3. You should see both servers in the Object Explorer sidebar

### 1.2 Remove replication from databases

Run these on **DC1** first, then **DC2**.

1. Right-click the DC1 server > **New Query**
2. Make sure the database dropdown (top-left) is set to **apim_db**, then run:

```sql
EXEC sp_replflush;
```

3. Switch the database dropdown to **master**, then run:

```sql
EXEC sp_removedbreplication @dbname = 'apim_db';
```

4. Switch to **shared_db** and run:

```sql
EXEC sp_replflush;
```

5. Switch back to **master** and run:

```sql
EXEC sp_removedbreplication @dbname = 'shared_db';
```

6. **Repeat steps 1-5 on DC2** (right-click the DC2 server > New Query).

> **Tip:** After running these, expand **Replication** > **Local Publications** in Object Explorer for each server and verify the publications are gone. You may need to right-click **Replication** > **Refresh**.

### 1.3 Drop databases

You can use the GUI or a query. **Do this on DC1 first, then DC2.**

**Option A — GUI:**

1. In Object Explorer, expand **Databases** under the DC1 server
2. Right-click **apim_db** > **Delete**
3. In the Delete dialog, check **Close existing connections** > **OK**
4. Repeat for **shared_db**
5. Repeat on DC2

**Option B — Query:**

Right-click the server > **New Query** (connected to **master**):

```sql
ALTER DATABASE apim_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE apim_db;

ALTER DATABASE shared_db SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE shared_db;
```

Run on DC2 as well.

> After dropping, right-click **Databases** in Object Explorer > **Refresh** to confirm both databases are gone.

### 1.4 Disable distribution and drop distribution database

After removing replication and dropping the user databases, disable the distributor on **each DC**. This drops the `distribution` database cleanly.

1. Right-click the server > **New Query** (connected to **master**)
2. Run:

```sql
EXEC sp_dropdistributor @no_checks = 1;
```

3. Repeat on the other DC.

> **Verify:** In Object Explorer, the **Replication** folder should no longer show **Local Publications** / **Local Subscriptions**. Right-click **Replication** > **Refresh** to confirm.
---

## Phase 2: Recreate Databases & Replication

Follow [SQLSERVER_P2P_SSMS_GUIDE.md](SQLSERVER_P2P_SSMS_GUIDE.md) from **Step 2** onwards:

| Step | Action |
|------|--------|
| **Step 2** | Create replication logins (`repl_dc2` on DC1, `repl_dc1` on DC2) — if they were lost with the drop |
| **Step 3** | Configure Distribution (recreates the `distribution` database) + set `max text repl size` to `-1` |
| **Step 4** | Create `apim_db` and `shared_db` on both DCs |
| **Step 5** | Run DC-specific table scripts (`dc1/SQLServer/mssql/` and `dc2/SQLServer/mssql/`) |
| **Step 5a** | Create replication database users (`repl_dc2` on DC1, `repl_dc1` on DC2) |
| **Step 6** | Create P2P publications (DC1: originator=100, DC2: originator=200) |
| **Step 7** | Add articles on both DCs |
| **Step 8** | Create bidirectional subscriptions |
| **Step 9** | Verify agents are running and status is healthy |
| **Step 10** | Test bidirectional replication |

> **Note:** Step 1 (connecting to servers) can be skipped — you're already connected. Step 2 (logins) may also be skipped if the replication logins still exist (they're server-level and may survive the distributor drop). Check **Security > Logins** in Object Explorer.

---

## Phase 3: Restart APIM

> **Critical: Start DC1 first, then DC2.**

1. Scale up APIM pods on **DC1 only**:
   ```bash
   kubectl scale deployment --all --replicas=1 -n apim --context=dc1
   ```

2. Wait for DC1 to fully initialize (all pods ready):
   ```bash
   kubectl get pods -n apim --context=dc1 -w
   ```

3. Verify DC1's seed data replicated to DC2 — in SSMS, open a **New Query** on DC2, set database to **shared_db**:

   ```sql
   SELECT TOP 5 UM_USER_NAME FROM UM_USER;
   ```

   You should see the `admin` user (and others) created by DC1.

4. Scale up APIM pods on **DC2**:
   ```bash
   kubectl scale deployment --all --replicas=1 -n apim --context=dc2
   ```

---

## Troubleshooting

### sp_removedbreplication fails — "Only one Log Reader Agent can connect"

The Log Reader Agent still holds a connection.

1. Run `EXEC sp_replflush;` on the affected database first (Step 1.2)
2. If that doesn't work, stop the agent via SSMS:
   - Expand **SQL Server Agent** > **Jobs** in Object Explorer
   - Find the Log Reader job (name contains the database name)
   - Right-click > **Stop Job**
3. Retry `sp_removedbreplication`

### "Database is in use" when dropping

1. **GUI:** Make sure you checked **Close existing connections** in the Delete dialog
2. **Query:** Use `SET SINGLE_USER WITH ROLLBACK IMMEDIATE` (shown in Step 1.3 Option B)
3. If still blocked, kill active sessions — New Query on **master**:

```sql
DECLARE @kill VARCHAR(8000) = '';
SELECT @kill = @kill + 'KILL ' + CONVERT(VARCHAR(5), session_id) + ';'
FROM sys.dm_exec_sessions
WHERE database_id = DB_ID('apim_db')
  AND session_id <> @@SPID;
EXEC(@kill);
```

Then retry the drop.

### Orphaned replication agent jobs

After dropping publications, SQL Server Agent jobs may remain:

1. In Object Explorer, expand **SQL Server Agent** > **Jobs**
2. Look for jobs with names starting with the server hostname and containing `apim_db` or `shared_db`
3. Right-click orphaned jobs > **Delete**

Or via query — New Query on **msdb**:

```sql
-- List replication jobs
SELECT name, enabled
FROM sysjobs
WHERE category_id IN (
    SELECT category_id FROM syscategories WHERE name LIKE 'REPL%'
);

-- Delete a specific orphaned job
EXEC msdb.dbo.sp_delete_job @job_name = '<job_name_here>';
```

### Check replication errors after recreation

Use **Replication Monitor** in SSMS:

1. In Object Explorer, right-click **Replication** > **Launch Replication Monitor**
2. Expand the publisher > select the publication
3. Check the **Warnings and Agents** tab for errors
4. Check the **Tracer Tokens** tab to measure latency

Or via query — New Query on **distribution**:

```sql
-- Check for distribution errors
SELECT * FROM dbo.MSrepl_errors ORDER BY time DESC;

-- Check agent history
SELECT * FROM dbo.MSdistribution_history ORDER BY time DESC;
```

### sp_dropdistributor fails — "cannot drop distributor, distribution databases exist"

If dropping the distributor fails, force-drop the distribution database first:

```sql
EXEC sp_dropdistpublisher @publisher = @@SERVERNAME, @no_checks = 1;
EXEC sp_dropdistributiondb @database = 'distribution';
EXEC sp_dropdistributor @no_checks = 1;
```
