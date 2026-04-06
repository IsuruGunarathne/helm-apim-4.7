# Peer-to-Peer Replication — SQL Server on Azure VMs

Set up peer-to-peer (P2P) transactional replication between two SQL Server instances on Azure VMs for WSO2 API Manager 4.7 multi-DC deployment.

**Why P2P over bidirectional?** Built-in conflict detection (Last Writer Wins), architectural loop prevention, and topology-aware replication. See [Key Differences from Bidirectional](#key-differences-from-bidirectional) for details.

## Architecture

```
        DC1 (East US 2)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  SQL Server 2022 Dev     │            │  SQL Server 2022 Dev     │
│  (Azure VM)              │            │  (Azure VM)              │
│                          │   P2P      │                          │
│  ┌─────────┐ ┌─────────┐│ Transact.  │┌─────────┐ ┌─────────┐  │
│  │ apim_db │ │shared_db ││◄──Repl.──►││ apim_db │ │shared_db │  │
│  └─────────┘ └─────────┘│            │└─────────┘ └─────────┘   │
│                          │            │                          │
│  User: apimadmineast     │            │  User: apimadminwest     │
│  Originator ID: 1        │            │  Originator ID: 2        │
│  IDENTITY: 1,3,5,7...   │            │  IDENTITY: 2,4,6,8...   │
│  Conflict: Last Writer   │            │  Conflict: Last Writer   │
└──────────────────────────┘            └──────────────────────────┘
```

## Connection Details

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

## Connecting from a Jump VM

If you have a VM in the same VNet (or a peered VNet), use it as a jump box.

### Test connectivity

```bash
telnet <sql-server-private-ip> 1433
```

### Install sqlcmd (Ubuntu/Debian)

```bash
curl -sSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg
wget -qO- https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/microsoft-prod.list
sudo apt-get update
sudo apt-get install -y mssql-tools18 unixodbc-dev
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc
```

### Connect to SQL Server

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C
```

The `-C` flag trusts the server certificate (needed for self-signed certs on VMs).

### Running SQL files

All P2P setup commands are in `dbscripts/p2p-mssql/`. Clone the repo or copy to the jump VM, then:

```bash
sqlcmd -S <host>,<port> -U <user> -P <pass> -d <database> -C \
  -i dbscripts/p2p-mssql/<file>.sql
```

---

## Step 1: Prerequisites

Ensure the following on **both** SQL Server VMs:

| Requirement | Details |
|-------------|---------|
| SQL Server Edition | **Enterprise or Developer** (P2P requires Enterprise features) |
| SQL Server Agent | Running and set to auto-start |
| Authentication | SQL Server authentication enabled (mixed mode) |
| Networking | VNet peering between East US 2 and West US 2, port 1433 open bidirectionally |

### Start SQL Server Agent (via RDP)

SQL Server Agent runs the Log Reader and Distribution Agent jobs that move transactions between nodes. It must be running on **both** VMs before configuring replication.

**RDP into each SQL Server VM** and run in PowerShell (as Administrator):

```powershell
# Start SQL Server Agent
net start SQLSERVERAGENT

# Set it to start automatically on boot
Set-Service -Name SQLSERVERAGENT -StartupType Automatic

# Verify it's running
Get-Service SQLSERVERAGENT
```

Alternatively, open `services.msc` and start **SQL Server Agent (MSSQLSERVER)**, then set Startup Type to **Automatic**.

> **Important:** If SQL Server Agent is not running, Steps 5-7 will appear to succeed but the replication agent jobs won't actually start. You'll only notice the problem at Step 8 when no agents show as running.

**Create SQL logins for replication:**

**DC1** — create the login that DC2's Distribution Agent will use:
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -i dbscripts/p2p-mssql/step1_dc1_login.sql
```

**DC2** — create the login that DC1's Distribution Agent will use:
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -i dbscripts/p2p-mssql/step1_dc2_login.sql
```

---

## Step 2: Configure Distribution

Each server acts as its own distributor. First, check the server hostname:

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C \
  -Q "SELECT @@SERVERNAME"

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -C \
  -Q "SELECT @@SERVERNAME"
```

> **Important:** Windows truncates hostnames longer than 15 characters. Use the value from `@@SERVERNAME` in the commands below.

**DC1:**
```bash
# Set SERVER_NAME to the value from @@SERVERNAME above
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -v SERVER_NAME="apim-4-7-eus2-s" \
  -i dbscripts/p2p-mssql/step2_dc1_distribution.sql
```

**DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -v SERVER_NAME="apim-4-7-wus2-s" \
  -i dbscripts/p2p-mssql/step2_dc2_distribution.sql
```

---

## Step 3: Create Databases

Run on **both** DCs:

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -i dbscripts/p2p-mssql/step3_create_dbs.sql

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -i dbscripts/p2p-mssql/step3_create_dbs.sql
```

---

## Step 4: Run DC-Specific Table Scripts

Use the pre-generated DC-specific scripts from `dbscripts/dc1/` and `dbscripts/dc2/`. These have IDENTITY seeds already configured per region.

**DC1:**
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/dc1/SQLServer/mssql/tables.sql

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/dc1/SQLServer/mssql/apimgt/tables.sql
```

**DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/dc2/SQLServer/mssql/tables.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/dc2/SQLServer/mssql/apimgt/tables.sql
```

| | DC1 | DC2 |
|--|-----|-----|
| IDENTITY columns | `IDENTITY(1,2)` | `IDENTITY(2,2)` |
| DCID default | `'DC1'` | `'DC2'` |
| NOT FOR REPLICATION | Set on all IDENTITY columns | Set on all IDENTITY columns |

> P2P replication still requires manual IDENTITY management. The odd/even offset ensures no PK collisions.

---

## Step 4a: Create Replication Database Users

**DC1:**
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C \
  -i dbscripts/p2p-mssql/step4a_dc1_dbusers.sql
```

**DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -C \
  -i dbscripts/p2p-mssql/step4a_dc2_dbusers.sql
```

---

## Step 5: Create P2P Publications

Each DC creates the **same publication name** but with a **different originator ID**. This is what makes it P2P rather than standard transactional replication.

**DC1** (originator_id = 1):
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step5_dc1_apim.sql

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/p2p-mssql/step5_dc1_shared.sql
```

**DC2** (originator_id = 2):
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step5_dc2_apim.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/p2p-mssql/step5_dc2_shared.sql
```

Key P2P publication parameters:
| Parameter | Value | Purpose |
|-----------|-------|---------|
| `@enabled_for_p2p` | `true` | Enables peer-to-peer mode |
| `@p2p_conflictdetection` | `true` | Enables conflict detection |
| `@p2p_conflictdetection_policy` | `lastwriter` | Most recent write wins |
| `@p2p_continue_onconflict` | `true` | Auto-resolve, don't stop agent |
| `@p2p_originator_id` | 1 (DC1) / 2 (DC2) | Unique node identifier |
| `@replicate_ddl` | 1 | Required for P2P |
| `@repl_freq` | `continuous` | Required for P2P |
| `@retention` | 0 | Subscriptions never expire |

---

## Step 6: Add Articles

Run on **both** DC1 and DC2 (same files, same databases):

**DC1:**
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step6_apim.sql

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/p2p-mssql/step6_shared.sql
```

**DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step6_apim.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/p2p-mssql/step6_shared.sql
```

> Note: `@identityrangemanagementoption = 'manual'` is required for P2P (was `'none'` in bidirectional).

---

## Step 7: Create Subscriptions

> **Important:** Use IP addresses (not hostnames) as the subscriber name to avoid Named Pipes connection issues.

**DC1 → DC2** (run on DC1):
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -v DC2_HOST="$DC2_HOST" \
  -i dbscripts/p2p-mssql/step7_dc1_apim.sql

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -v DC2_HOST="$DC2_HOST" \
  -i dbscripts/p2p-mssql/step7_dc1_shared.sql
```

**DC2 → DC1** (run on DC2):
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -v DC1_HOST="$DC1_HOST" \
  -i dbscripts/p2p-mssql/step7_dc2_apim.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -v DC1_HOST="$DC1_HOST" \
  -i dbscripts/p2p-mssql/step7_dc2_shared.sql
```

Distribution Agent jobs auto-start when subscriptions are created.

---

## Step 8: Verify Replication

### Check agent jobs and status

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_verify.sql

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_verify.sql
```

Expected: All agent jobs enabled, subscription status = 4 (idle) or 6 (succeeded).

### Check for errors

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_check_errors.sql

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_check_errors.sql
```

---

## Step 9: Test Replication

### DC1 → DC2

**Insert on DC1:**
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step9_dc1_insert.sql
```

**Check on DC2** (should appear within seconds):
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -Q "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999"
```

### DC2 → DC1

**Insert on DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step9_dc2_insert.sql
```

**Check on DC1** (should appear within seconds):
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -Q "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998"
```

### Clean up test data

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step9_cleanup.sql
```

---

## Step 10: Deploy APIM on Kubernetes

> **Critical: Start DC1 first, then DC2.** WSO2 APIM inserts seed data (default users, policies, claim dialects) on first startup. If both DCs start simultaneously, both insert the same seed data independently, causing conflicts. With Last Writer Wins, conflicts are auto-resolved, but starting sequentially avoids them entirely.

### Recommended startup sequence

1. Deploy APIM on DC1 only: `./scripts/deploy-azure-dc1-mssql.sh`
2. Wait for DC1 to fully initialize (all pods ready, access Publisher/DevPortal)
3. Verify DC1's seed data replicated to DC2:
   ```bash
   sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
     -Q "SELECT TOP 5 UM_USER_NAME FROM UM_USER"
   ```
   You should see the `admin` user on DC2.
4. Deploy APIM on DC2: `./scripts/deploy-azure-dc2-mssql.sh`
5. Run cross-DC event publisher setup: `./scripts/setup-cross-dc-mssql.sh`

### Helm values files

| Component | DC1 | DC2 |
|-----------|-----|-----|
| Control Plane | `azure-values-dc1-mssql.yaml` | `azure-values-dc2-mssql.yaml` |
| Gateway | `azure-values-dc1-mssql.yaml` | `azure-values-dc2-mssql.yaml` |
| Traffic Manager | `azure-values-dc1-mssql.yaml` | `azure-values-dc2-mssql.yaml` |

---

## Checking P2P Conflicts

P2P replication with Last Writer Wins auto-resolves conflicts. The losing row is saved to a `conflict_<schema>_<table>` table.

### View conflict tables

```bash
# Check apim_db conflicts
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/p2p-mssql/step8_check_conflicts.sql

# Check shared_db conflicts
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/p2p-mssql/step8_check_conflicts.sql
```

### How Last Writer Wins works

| Conflict Type | Resolution |
|--------------|------------|
| Insert-Insert (same PK) | Most recent insert wins |
| Update-Update (same row) | Most recent update wins |
| Update-Delete | **Delete always wins** |
| Delete-Delete | No conflict (both agree) |

> **Important:** Last Writer Wins depends on synchronized clocks across nodes. Azure VMs sync time via Azure Fabric, which is typically accurate within milliseconds.

---

## Troubleshooting

### Check replication agent errors

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/p2p-mssql/step8_check_errors.sql
```

### Named Pipes connection errors

If you see `Named Pipes Provider: Could not open a connection`, the subscriber was registered using a hostname. Fix: drop and recreate the subscription using the IP address. See Step 7.

### Replication login permission errors

If you see `Login failed for user 'repl_dcX'` or `Cannot open database`, the login doesn't have a database user. Re-run Step 4a.

### Log Reader Agent blocks operations

If `sp_droppublication` fails with "Only one Log Reader Agent can connect", flush the connection first:

```bash
sqlcmd -S $HOST,$PORT -U $USER -P $PASS -d <database> -C \
  -Q "EXEC sp_replflush"
```

Then use `sp_removedbreplication` for force removal:

```bash
sqlcmd -S $HOST,$PORT -U $USER -P $PASS -d master -C \
  -Q "EXEC sp_removedbreplication @dbname = '<database>'"
```

### Subscription not replicating

```bash
# Check Distribution Agent status
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -Q "EXEC sp_replmonitorhelpsubscription @publisher = @@SERVERNAME, @publication_type = 0"

# Restart a stopped agent job
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "EXEC sp_start_job @job_name = '<job-name>'"
```

### IDENTITY conflicts

Verify IDENTITY seeds: DC1 should have `IDENTITY(1,2)` and DC2 should have `IDENTITY(2,2)`:

```sql
SELECT TABLE_NAME, IDENT_SEED(TABLE_NAME) AS seed, IDENT_INCR(TABLE_NAME) AS incr
FROM INFORMATION_SCHEMA.TABLES
WHERE OBJECTPROPERTY(OBJECT_ID(TABLE_NAME), 'TableHasIdentity') = 1;
```

Verify `NOT FOR REPLICATION` is set:
```sql
SELECT OBJECT_NAME(object_id) AS table_name, name AS column_name, is_not_for_replication
FROM sys.identity_columns
WHERE is_not_for_replication = 0;
-- Should return no rows
```

### Distribution database cleanup

```sql
EXEC distribution.dbo.sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 72;
GO
```

---

## Key Differences from Bidirectional

| Feature | Bidirectional | Peer-to-Peer |
|---------|--------------|-------------|
| Edition required | Standard+ | **Enterprise/Developer only** |
| Loop prevention | `@loopback_detection = 'true'` | Built-in originator tracking |
| Conflict detection | None | Built-in (originator ID or Last Writer Wins) |
| Conflict resolution | Manual | Automatic (configurable) |
| Max nodes | 2 | Unlimited |
| `sp_addpublication` | Basic | `@enabled_for_p2p`, `@p2p_originator_id`, `@p2p_conflictdetection_policy` |
| `sp_addarticle` | `identityrangemanagementoption = 'none'` | `identityrangemanagementoption = 'manual'` |
| `sp_addsubscription` | `@sync_type = 'none'` | `@sync_type = 'replication support only'` |
| Snapshot initialization | Supported | **Not supported** |
| DDL replication | Optional | Required (`@replicate_ddl = 1`) |
| Row/column filters | Supported | **Not supported** |

---

## Networking Checklist

- [ ] VNet peering configured between East US 2 and West US 2 VNets
- [ ] SQL Server port 1433 open in NSG/firewall rules bidirectionally
- [ ] SQL Server Agent can reach the remote server (push subscriptions)
- [ ] Use private IP addresses for subscriber names (avoid Named Pipes)
- [ ] Azure VM clocks synchronized (required for Last Writer Wins accuracy)

---

## Summary of Operations

| Step | DC1 (East US 2) | DC2 (West US 2) |
|------|-----------------|-----------------|
| 1. Prerequisites | SQL Agent running, create `repl_dc2` login | SQL Agent running, create `repl_dc1` login |
| 2. Configure distribution | Self as distributor | Self as distributor |
| 3. Create databases | `apim_db`, `shared_db` | `apim_db`, `shared_db` |
| 4. Run table scripts | `dc1/SQLServer/mssql/` (IDENTITY 1,2) | `dc2/SQLServer/mssql/` (IDENTITY 2,2) |
| 4a. Create replication DB users | `repl_dc2` user in both DBs | `repl_dc1` user in both DBs |
| 5. Create P2P publications | originator_id=1, lastwriter | originator_id=2, lastwriter |
| 6. Add articles | All tables (manual identity) | All tables (manual identity) |
| 7. Create subscriptions | Push to DC2 (using DC2 IP) | Push to DC1 (using DC1 IP) |
| 8. Verify replication | Agents running, status=4/6 | Agents running, status=4/6 |
| 9. Test | Insert test rows, verify bidirectional | Insert test rows, verify bidirectional |
| 10. Deploy APIM | **Start first**, wait for seed data replication | Start **after** DC1 seed data replicates |
