# Peer-to-Peer Replication Setup via SSMS

Set up P2P transactional replication between two SQL Server 2022 instances using **SQL Server Management Studio (SSMS)** on a Windows jump VM.

> For a sqlcmd-based alternative, see [SQLSERVER_P2P_REPLICATION_GUIDE.md](SQLSERVER_P2P_REPLICATION_GUIDE.md).

## Architecture

```
        DC1 (East US 2)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  SQL Server 2022 Dev     │            │  SQL Server 2022 Dev     │
│  IP: 10.0.3.4            │            │  IP: 10.1.3.4            │
│  User: apimadmineast     │   P2P      │  User: apimadminwest     │
│  Originator ID: 100      │◄──Repl.──►│  Originator ID: 200      │
│  IDENTITY: 1,3,5,7...   │            │  IDENTITY: 2,4,6,8...   │
│  apim_db + shared_db     │            │  apim_db + shared_db     │
└──────────────────────────┘            └──────────────────────────┘

        Windows Jump VM (SSMS installed, West US 2 VNet)
```

---

## Prerequisites

### 1. Windows Jump VM

1. Provision a **Windows Server 2022** VM in the same VNet or a peered VNet
2. Install **SSMS** from [https://aka.ms/ssmsfullsetup](https://aka.ms/ssmsfullsetup)
3. Ensure port **1433** is open to both SQL Server VMs

### 2. Cross-VNet Hostname Resolution

SSMS replication wizards require **hostnames** (from `@@SERVERNAME`), not IPs. VNet peering doesn't share DNS, so add hosts file entries on **all three machines**.

Open **Notepad as Administrator** > File > Open > `C:\Windows\System32\drivers\etc\hosts` (set filter to "All Files"):

**Jump VM** (if in West US 2, add the East US 2 server):
```
10.0.3.4 apim-4-7-eus2-s
```

**DC1 VM** — add DC2:
```
10.1.3.4 apim-4-7-wus2-s
```

**DC2 VM** — add DC1:
```
10.0.3.4 apim-4-7-eus2-s
```

Verify on each SQL Server VM:
```powershell
Test-NetConnection <other-server-hostname> -Port 1433
# TcpTestSucceeded : True
```

> `ping` may time out (Azure blocks ICMP) — that's fine, only TCP 1433 matters.

### 3. SQL Server Agent

RDP into **each** SQL Server VM:

1. Open `services.msc`
2. Find **SQL Server Agent (MSSQLSERVER)** > set Startup Type to **Automatic** > **Start**

> If Agent isn't running, replication setup will appear to succeed but nothing will replicate.

---

## Step 1: Connect to Both Servers

> **Use hostnames (from `@@SERVERNAME`), not IPs.** Connecting via IP (with or without port) causes "must be enabled as a Publisher" errors because the distributor registers the server by its `@@SERVERNAME` hostname. The hosts file entries in the Prerequisites ensure these hostnames resolve from the jump VM and across VNets.

1. SSMS > **Connect > Database Engine**
   - Server: `apim-4-7-eus2-s`, Auth: SQL Server, Login: `apimadmineast` / `distributed@2`
2. **Connect > Database Engine** again
   - Server: `apim-4-7-wus2-s`, Auth: SQL Server, Login: `apimadminwest` / `distributed@2`

---

## Step 2: Create Replication Logins

**On DC1:** Security > Logins > New Login:
- Login: `repl_dc2`, SQL Server auth, 
- Password: `Repl@2025`, 
- **Uncheck enforce policy (IMPORTANT)**, 
- Server Role: `sysadmin`

**On DC2:** Same but login name `repl_dc1`.

---

## Step 3: Configure Distribution

On **each** server: right-click **Replication** > **Configure Distribution...**

1. **Distributor**: "will act as its own Distributor"
2. **Snapshot Folder**: Leave default
3. **Distribution Database**: Leave as `distribution`
4. Click through to **Finish**

> After this, you'll see **Local Publications** and **Local Subscriptions** under each server's Replication folder.

---

## Step 4: Create Databases

On **each** DC: right-click **Databases** > New Database > create `apim_db` and `shared_db`.

Then run on each DC:

```sql
ALTER DATABASE apim_db SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE apim_db SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
ALTER DATABASE shared_db SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE shared_db SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
```

---

## Step 5: Run DC-Specific Table Scripts

**On DC1** (from jump VM):
```powershell
sqlcmd -S apim-4-7-eus2-s -U apimadmineast -P "distributed@2" -d shared_db -i "dbscripts\dc1\SQLServer\mssql\tables.sql"
sqlcmd -S apim-4-7-eus2-s -U apimadmineast -P "distributed@2" -d apim_db -i "dbscripts\dc1\SQLServer\mssql\apimgt\tables.sql"
```

**On DC2** (from jump VM):
```powershell
sqlcmd -S apim-4-7-wus2-s -U apimadminwest -P "distributed@2" -d shared_db -i "dbscripts\dc2\SQLServer\mssql\tables.sql"
sqlcmd -S apim-4-7-wus2-s -U apimadminwest -P "distributed@2" -d apim_db -i "dbscripts\dc2\SQLServer\mssql\apimgt\tables.sql"
```

> DC1 uses `IDENTITY(1,2)` (odd), DC2 uses `IDENTITY(2,2)` (even). Don't mix them up.

---

## Step 5a: Create Replication Database Users

**On DC1** — run against both `apim_db` and `shared_db`:
```sql
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO
```

**On DC2** — run against both `apim_db` and `shared_db`:
```sql
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO
```

---

## Step 6: Create P2P Publications (on DC1 only)

> **Reference video:** https://www.youtube.com/watch?v=lqYyYaJp9Wk
>
> The wizard creates the publication AND adds articles (tables) in one flow. DC2's publication is created later by the P2P Topology Wizard (Step 8).

### For apim_db

1. Expand **DC1** > **Replication** > right-click **Local Publications** > **New Publication...**
   > "Must be enabled as a Publisher" error? Run Step 3 first.
2. **Publication Database**: `apim_db`
3. **Publication Type**: **Peer-to-Peer publication** (or "Transactional publication" if P2P isn't listed)
4. **Articles**: Check all **Tables**
5. **Filter Table Rows**: Skip
6. **Snapshot Agent**: **Uncheck** "Create a snapshot immediately"
7. **Agent Security (Log Reader)**: Click Security Settings:
   - **Run under the SQL Server Agent service account**
   - **By impersonating the process account**
   > Do NOT enter `repl_dc1` here — that's a SQL login, not a Windows account. Replication logins are used later for subscriber connections.
8. **Publication Name**: `apim_db_pub` > **Finish**

### Enable P2P settings

Right-click `apim_db_pub` > **Properties** > **Subscription Options**:

- **Allow peer-to-peer subscriptions**: `True`
- **Allow peer-to-peer conflict detection**: `True`
- **Peer originator id**: Note the value (defaults to `100` — fine, DC2 will get a different one)
- **Continue replication after conflict detection**: **`True`**

Click **OK**.

### Repeat for shared_db

Create `shared_db_pub` on DC1 with the same wizard flow + P2P settings.

---

## Step 8: P2P Topology Wizard

The wizard handles **three things** in one workflow:
1. Creates the publication on DC2 (including articles)
2. Creates the DC1 → DC2 push subscription
3. Creates the DC2 → DC1 push subscription

### For apim_db_pub

1. On DC1, right-click `apim_db_pub` > **Configure Peer-to-Peer Topology...**
2. DC1 appears as the first node with its Originator ID (e.g. `100`)
3. **Add DC2:** Right-click empty area > **Add a New Peer Node**
   - Connect: `apim-4-7-wus2-s`, SQL Server Auth, `apimadminwest` / `distributed@2`
4. DC2 appears with a different Originator ID (e.g. `200`). Verify they're unique.
5. **Connect nodes:** Right-click each node > **Connect to All Displayed Nodes** (bidirectional arrows appear)
6. **Log Reader Agent Security** (one row for DC2):
   - Click `(...)` on the `apim-4-7-wus2-s` row
   - Connection to Distributor: **Run under the SQL Server Agent service account** / **By impersonating the process account**
   - Connection to Publisher: same — **Agent service account** / **impersonate**
7. **Distribution Agent Security** (two rows, one per subscriber):
   > **Key:** "Agent for Subscriber" = the agent pushes TO that server. The login must exist **on the subscriber server**.
   - `apim-4-7-eus2-s` (pushes TO DC1):
     - Connection to Distributor: **Agent service account** / **impersonate**
     - Connection to Subscriber: **Using the following SQL Server login** → `repl_dc2` / `Repl@2025` *(exists on DC1)*
   - `apim-4-7-wus2-s` (pushes TO DC2):
     - Connection to Distributor: **Agent service account** / **impersonate**
     - Connection to Subscriber: **Using the following SQL Server login** → `repl_dc1` / `Repl@2025` *(exists on DC2)*
8. **New Peer Initialization**: Select **"I created the peer database manually"** (first option)
9. **Finish** — expect three green checkmarks:
   - Creating publication on DC2 — Success
   - Creating subscription for DC2 — Success
   - Creating subscription for DC1 — Success

### Repeat for shared_db_pub

### Set conflict resolution on DC2

Run on DC2 against each database:
```sql
-- apim_db
EXEC sp_changepublication @publication = 'apim_db_pub', @property = 'p2p_continue_onconflict', @value = 'true';
GO

-- shared_db
EXEC sp_changepublication @publication = 'shared_db_pub', @property = 'p2p_continue_onconflict', @value = 'true';
GO
```

---

## Step 9: Verify Replication

### Replication Monitor

Right-click **Replication** > **Launch Replication Monitor**:
- **All Subscriptions** tab: status = **Running** or **Succeeded**
- **Agents** tab: Log Reader + Distribution agents running

### SQL Agent Jobs

Expand **SQL Server Agent** > **Jobs** — you should see `REPL%` category jobs. Right-click > **View History** to check for errors.

### SQL Query

```sql
SELECT name, enabled FROM msdb.dbo.sysjobs
WHERE category_id IN (SELECT category_id FROM msdb.dbo.syscategories WHERE name LIKE 'REPL%');
GO

EXEC distribution.dbo.sp_replmonitorhelpsubscription @publisher = @@SERVERNAME, @publication_type = 0;
GO

SELECT TOP 20 id, error_text, time FROM distribution.dbo.MSrepl_errors ORDER BY id DESC;
GO
```

Status values: **3** = Running, **4** = Idle, **6** = Succeeded.

---

## Step 10: Test Replication

**DC1 → DC2:** Run on DC1 against `apim_db`:
```sql
SET IDENTITY_INSERT AM_ALERT_TYPES ON;
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER) VALUES (999, 'test-dc1', 'publisher');
SET IDENTITY_INSERT AM_ALERT_TYPES OFF;
GO
```
Check on DC2: `SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;`

**DC2 → DC1:** Run on DC2 against `apim_db`:
```sql
SET IDENTITY_INSERT AM_ALERT_TYPES ON;
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER) VALUES (998, 'test-dc2', 'publisher');
SET IDENTITY_INSERT AM_ALERT_TYPES OFF;
GO
```
Check on DC1: `SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998;`

**Cleanup:** `DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999); GO`

---

## Step 11: Deploy APIM

> **Critical: Start DC1 first, then DC2.** APIM inserts seed data on first startup. Starting sequentially avoids conflicts.

1. Deploy APIM on **DC1 only**
2. Wait for all pods to be ready
3. Verify seed data on DC2: `SELECT TOP 5 UM_USER_NAME FROM shared_db.dbo.UM_USER;`
4. Deploy APIM on **DC2**

---

## Troubleshooting

| Error | Cause | Fix |
|-------|-------|-----|
| `Named Pipes Provider: Could not open a connection` | Hostname can't be resolved | Add hosts file entry on the SQL Server VM |
| `must be enabled as a Publisher` | Connected via IP instead of hostname | Reconnect using `@@SERVERNAME` hostname |
| `Login failed for user 'repl_dcX'` | DB user doesn't exist | Re-run Step 5a |
| `Could not find stored procedure 'dbo.i_<Table><hash>'` | Articles added with `@status = 16` | Remove replication, re-add articles without `@status = 16` |
| `LSN {00000000:00000000:0000} occurs before...` | Log Reader out of sync | Full reset: drop and recreate databases |
| `process account is not a valid account` | Used SQL login in Log Reader Agent security | Use "Run under SQL Server Agent service account" instead |
| `@@SERVERNAME` returns wrong name | Server was renamed after SQL install | Run `EXEC sp_dropserver 'OldName'; EXEC sp_addserver 'NewName', 'local';` then restart SQL Server service |

### Force remove all replication

```sql
USE apim_db; EXEC sp_replflush; GO
USE master; EXEC sp_removedbreplication @dbname = 'apim_db'; GO
```

---

## Summary — Step-by-Step Checklist

| Step | Action | DC1 | DC2 |
|------|--------|-----|-----|
| Pre | Hosts file + SQL Agent | Add DC2 hostname, start Agent | Add DC1 hostname, start Agent |
| 1 | Connect in SSMS | `apim-4-7-eus2-s` | `apim-4-7-wus2-s` |
| 2 | Replication logins | `repl_dc2` | `repl_dc1` |
| 3 | Configure distribution | Self as distributor | Self as distributor |
| 4 | Create databases | `apim_db`, `shared_db` + snapshot isolation | Same |
| 5 | Table scripts | `dc1/` scripts (odd IDs) | `dc2/` scripts (even IDs) |
| 5a | Replication DB users | `repl_dc2` in both DBs | `repl_dc1` in both DBs |
| 6 | New Publication Wizard | `apim_db_pub` + `shared_db_pub` | *(Step 8 handles this)* |
| 6+ | Enable P2P settings | Publication Properties + SQL | *(Step 8 handles this)* |
| 8 | P2P Topology Wizard | Creates DC2 pub + both subscriptions | *(automatic)* |
| 8+ | Conflict resolution on DC2 | — | `sp_changepublication` |
| 9 | Verify | Replication Monitor | Replication Monitor |
| 10 | Test | Row 999 → appears on DC2 | Row 998 → appears on DC1 |
| 11 | Deploy APIM | **Start first** | Start after DC1 seed replicates |
