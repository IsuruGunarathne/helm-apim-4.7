# Peer-to-Peer Replication Setup via SSMS

Set up P2P transactional replication between two SQL Server 2022 instances using **SQL Server Management Studio (SSMS)** on a Windows jump VM.

> For a sqlcmd-based alternative, see [SQLSERVER_P2P_REPLICATION_GUIDE.md](SQLSERVER_P2P_REPLICATION_GUIDE.md).

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  SQL Server 2022 Dev     │            │  SQL Server 2022 Dev     │
│  IP: 10.2.3.4            │            │  IP: 10.1.3.4            │
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

### 2. NSG Security

Ensure the Azure NSG rules for port **1433** on both SQL Server VMs restrict the source to your VNet CIDRs (e.g. `10.0.0.0/8`), **not** `Any`. Leaving 1433 open to the internet exposes the server to brute-force attacks.

### 3. Cross-VNet Hostname Resolution

SSMS replication wizards require **hostnames** (from `@@SERVERNAME`), not IPs. VNet peering doesn't share DNS, so add hosts file entries on **all three machines**.

Open **Notepad as Administrator** > File > Open > `C:\Windows\System32\drivers\etc\hosts` (set filter to "All Files"):

**Jump VM** (if in West US 2, add the East US 1 server):
```
10.2.3.4 apim-4-7-eus1-s
```

**DC1 VM** — add DC2:
```
10.1.3.4 apim-4-7-wus2-s
```

**DC2 VM** — add DC1:
```
10.2.3.4 apim-4-7-eus1-s
```

Verify on each SQL Server VM:
```powershell
Test-NetConnection <other-server-hostname> -Port 1433
# TcpTestSucceeded : True
```

> `ping` may time out (Azure blocks ICMP) — that's fine, only TCP 1433 matters.

### 4. SQL Server Agent

RDP into **each** SQL Server VM:

1. Open `services.msc`
2. Find **SQL Server Agent (MSSQLSERVER)** > set Startup Type to **Automatic** > **Start**

> If Agent isn't running, replication setup will appear to succeed but nothing will replicate.

---

## Step 1: Connect to Both Servers

> **Use hostnames (from `@@SERVERNAME`), not IPs.** Connecting via IP (with or without port) causes "must be enabled as a Publisher" errors because the distributor registers the server by its `@@SERVERNAME` hostname. The hosts file entries in the Prerequisites ensure these hostnames resolve from the jump VM and across VNets.

1. SSMS > **Connect > Database Engine**
   - Server: `apim-4-7-eus1-s`, Auth: SQL Server, Login: `apimadmineast` / `distributed@2`
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

### Create distribution database master key

On **each** DC, open a **New Query** on the **distribution** database and run:

```sql
USE distribution;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'Repl@MasterKey2025!';
GO
```

> The distribution database needs a master key to store encrypted subscriber credentials. Without it, push subscription agent jobs will fail.

### Set max text repl size

On **each** DC, open a **New Query** on **master** and run:

```sql
EXEC sp_configure 'max text repl size', -1;
RECONFIGURE;
```

> This removes the 64KB default limit on LOB data replicated via P2P. Without this, APIM's LLM Provider registration (which inserts ~145KB of data) will fail at startup.

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
sqlcmd -S apim-4-7-eus1-s -U apimadmineast -P "distributed@2" -d shared_db -C -i dbscripts/dc1/SQLServer/mssql/tables.sql
sqlcmd -S apim-4-7-eus1-s -U apimadmineast -P "distributed@2" -d apim_db -C -i dbscripts/dc1/SQLServer/mssql/apimgt/tables.sql
```

**On DC2** (from jump VM):
```powershell
sqlcmd -S apim-4-7-wus2-s -U apimadminwest -P "distributed@2" -d shared_db -C -i dbscripts/dc2/SQLServer/mssql/tables.sql
sqlcmd -S apim-4-7-wus2-s -U apimadminwest -P "distributed@2" -d apim_db -C -i dbscripts/dc2/SQLServer/mssql/apimgt/tables.sql
```

> DC1 uses `IDENTITY(1,2)` (odd), DC2 uses `IDENTITY(2,2)` (even). Don't mix them up.

---

## Step 5a: Create Replication Database Users

**On DC1** — switch the database dropdown to `apim_db`, run the command, then switch to `shared_db` and run the same command:
```sql
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO
```

**On DC2** — same process (run against both `apim_db` and `shared_db`):
```sql
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO
```

---

## Step 6: Create Publications (on DC1 only)

> **Reference video:** https://www.youtube.com/watch?v=lqYyYaJp9Wk
> The wizard creates the publication AND adds articles (tables) in one flow. DC2's publication is created later by the P2P Topology Wizard (Step 7).

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
   > Do NOT enter a replication login (e.g. `repl_dc2`) here — those are SQL logins, not Windows accounts. Replication logins are used later for subscriber connections in Step 7.
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

## Step 6a: Create Publications on DC2 via T-SQL Script

> We cannot use the SSMS UI Wizard on DC2 — it hardcodes the **Peer Originator ID** to `100` (the value DC1 already uses) and locks the field. Letting the P2P Topology Wizard (Step 7) build DC2's schema also fails: the scripted procedures it generates reference the hidden `$sys_p2p_cd_id` column, and the Dedicated Administrator Connection (DAC) security restrictions block that approach.
>
> Instead, generate a native T-SQL script from DC1's publication, modify it for DC2, and run it directly. This creates DC2's publication, articles, `$sys_p2p_cd_id` columns, and per-article `sp_MSins_*` / `sp_MSupd_*` / `sp_MSdel_*` procedures natively — no DAC bypass required.

### For apim_db

1. On **DC1**, expand **Replication** > **Local Publications**
2. Right-click `apim_db_pub` > **Generate Scripts...**
3. Select **Script the following: Create** and **Script to: New Query Window**, then **Generate Script**

### Find and Replace (mandatory)

Use **Ctrl+H** on the generated script:

| Find | Replace with |
|------|--------------|
| `apim-4-7-eus1-s` | `apim-4-7-wus2-s` |
| `apimadmineast` | `apimadminwest` |
| `repl_dc2` | `repl_dc1` |

### Manual script tweaks

1. **`sp_addlogreader_agent`** — add the missing password parameter:
   ```sql
   @publisher_password = N'distributed@2'
   ```
   > If DC2 already has a log reader agent from previous attempts, delete the entire `sp_addlogreader_agent` block instead.

2. **`sp_addpublication`** — scroll to the end of this call and change `@p2p_originator_id = 100` to `@p2p_originator_id = 200`.

3. **`sp_grant_publication_access`** — delete any lines referencing local `NT SERVICE\...` accounts (they don't exist on DC2 and will fail).

### Execute on DC2

Connect to **DC2**, switch the query context to `apim_db`, and execute the modified script. This natively creates the publication, the `$sys_p2p_cd_id` conflict-detection column on every article, and the per-article replication stored procedures — without DAC errors.

### Repeat for shared_db

Generate a script from `shared_db_pub` on DC1, apply the same Find/Replace and manual tweaks (including `@p2p_originator_id = 200`), and execute against `shared_db` on DC2.

---

## Step 7: P2P Topology Wizard

Since Step 6a already created DC2's publication and articles, the Topology Wizard will **detect the existing publication** and skip schema creation — it only wires the push subscriptions between the two peers:
1. Creates the DC1 → DC2 push subscription
2. Creates the DC2 → DC1 push subscription

### For apim_db_pub

1. On DC1, right-click `apim_db_pub` > **Configure Peer-to-Peer Topology...**
2. DC1 appears as the first node with its Originator ID (e.g. `100`)
3. **Add DC2:** Right-click empty area > **Add a New Peer Node**
   - Connect: `apim-4-7-wus2-s`, SQL Server Auth, `apimadminwest` / `distributed@2`
4. When prompted for DC2's Originator ID, enter `200` to match the value set in the Step 6a script. Verify the IDs are unique (DC1 = `100`, DC2 = `200`).
5. Select `apim_db` as the database
6. **Connect nodes:** Right-click each node > **Connect to All Displayed Nodes** (bidirectional arrows appear)
7. **Log Reader Agent Security** (one row for DC2):
   - Click `(...)` on the `apim-4-7-wus2-s` row
   - Connection to Distributor: **Run under the SQL Server Agent service account** / **By impersonating the process account**
   - Connection to Publisher: same — **Agent service account** / **impersonate**
8. **Distribution Agent Security** (two rows, one per peer):
   > **Key:** "Agent for Subscriber" = the agent that **runs on** that server's distributor, pushing its data to the other peer. The login must exist on the **remote** (target) server.
   - `apim-4-7-eus1-s` (DC1 agent pushes TO DC2):
     - Connection to Distributor: **Agent service account** / **impersonate**
     - Connection to Subscriber: **Using the following SQL Server login** → `repl_dc1` / `Repl@2025` *(exists on DC2)*
   - `apim-4-7-wus2-s` (DC2 agent pushes TO DC1):
     - Connection to Distributor: **Agent service account** / **impersonate**
     - Connection to Subscriber: **Using the following SQL Server login** → `repl_dc2` / `Repl@2025` *(exists on DC1)*
9. **New Peer Initialization**: Select **"I created the peer database manually"** (first option)
10. **Finish** — expect green checkmarks for the subscription steps:
   - Creating subscription for DC2 — Success
   - Creating subscription for DC1 — Success

   > The wizard skips "Creating publication on DC2" because Step 6a already created it.

### Repeat for shared_db_pub

### Set conflict resolution on DC2

The P2P Topology Wizard doesn't set `p2p_continue_onconflict` on DC2's publications. Run on DC2 against each database:

```sql
-- apim_db
EXEC sp_changepublication @publication = 'apim_db_pub', @property = 'p2p_continue_onconflict', @value = 'true';
GO

-- shared_db
EXEC sp_changepublication @publication = 'shared_db_pub', @property = 'p2p_continue_onconflict', @value = 'true';
GO
```

---

## Step 8: Verify Replication

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

## Step 9: Test Replication

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

### Test shared_db (UM_USER)

**DC1 → DC2:** Run on DC1 against `shared_db`:
```sql
SET IDENTITY_INSERT UM_USER ON;
INSERT INTO shared_db.dbo.UM_USER (UM_ID, UM_USER_ID, UM_USER_NAME, UM_USER_PASSWORD, UM_SALT_VALUE, UM_REQUIRE_CHANGE, UM_CHANGED_TIME, UM_TENANT_ID)
VALUES (999, 'test-uuid-dc1', 'test-user-dc1', 'dummy-pass', 'dummy-salt', 0, CURRENT_TIMESTAMP, -1234);
SET IDENTITY_INSERT UM_USER OFF;
GO
```
Check on DC2: `SELECT * FROM shared_db.dbo.UM_USER WHERE UM_ID = 999;`

**DC2 → DC1:** Run on DC2 against `shared_db`:
```sql
SET IDENTITY_INSERT UM_USER ON;
INSERT INTO shared_db.dbo.UM_USER (UM_ID, UM_USER_ID, UM_USER_NAME, UM_USER_PASSWORD, UM_SALT_VALUE, UM_REQUIRE_CHANGE, UM_CHANGED_TIME, UM_TENANT_ID)
VALUES (998, 'test-uuid-dc2', 'test-user-dc2', 'dummy-pass', 'dummy-salt', 0, CURRENT_TIMESTAMP, -1234);
SET IDENTITY_INSERT UM_USER OFF;
GO
```
Check on DC1: `SELECT * FROM shared_db.dbo.UM_USER WHERE UM_ID = 998;`

**Cleanup:**
```sql
DELETE FROM apim_db.dbo.AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999);
DELETE FROM shared_db.dbo.UM_USER WHERE UM_ID IN (998, 999);
GO
```

---

## Step 10: Deploy APIM

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
| `Could not find stored procedure 'dbo.sp_MSins_...'` (or `dbo.i_<Table><hash>`) | DC2 is missing the per-article custom replication procs that DC1 auto-generated in Step 6 | Use the Step 6a native T-SQL scripting method to create the publication on DC2 — the generated script creates these procs natively. **Do not** "fix" this by dropping `@status = 16` from the articles — that silently switches replication to raw DML and disables P2P conflict detection, which runs inside those custom procs |
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
| Pre | Hosts file + SQL Agent + NSG | Add DC2 hostname, start Agent | Add DC1 hostname, start Agent |
| 1 | Connect in SSMS | `apim-4-7-eus1-s` | `apim-4-7-wus2-s` |
| 2 | Replication logins | `repl_dc2` | `repl_dc1` |
| 3 | Configure distribution | Self as distributor | Self as distributor |
| 3+ | Set `max text repl size` | `sp_configure` → `-1` | `sp_configure` → `-1` |
| 4 | Create databases | `apim_db`, `shared_db` + snapshot isolation | Same |
| 5 | Table scripts | `dc1/` scripts (odd IDs) | `dc2/` scripts (even IDs) |
| 5a | Replication DB users | `repl_dc2` in both DBs | `repl_dc1` in both DBs |
| 6 | Create publications (SSMS wizard) | `apim_db_pub` + `shared_db_pub`, P2P enabled | — (created in Step 6a) |
| 6a | Create publications on DC2 via T-SQL | Generate `CREATE` script from each publication | Apply Find/Replace + set `@p2p_originator_id = 200`, run against `apim_db` and `shared_db` |
| 7 | P2P Topology Wizard | Adds DC2 peer (Originator ID `200`), creates both subscriptions | Wizard detects existing publication, wires subscriptions |
| 7+ | Conflict resolution on DC2 | — | `sp_changepublication` (`p2p_continue_onconflict`) |
| 8 | Verify | Replication Monitor | Replication Monitor |
| 9 | Test | Row 999 → appears on DC2 | Row 998 → appears on DC1 |
| 10 | Deploy APIM | **Start first** | Start after DC1 seed replicates |
