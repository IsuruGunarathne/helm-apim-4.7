# Bi-Directional Replication with Transactional Replication — SQL Server on Azure VMs

Set up bidirectional transactional replication between two SQL Server instances on Azure VMs for WSO2 API Manager 4.7 multi-DC deployment.

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  apim-4-7-eus1-s         │            │  apim-4-7-wus2-s         │
│  (SQL Server on Azure VM)│            │  (SQL Server on Azure VM)│
│                          │            │                          │
│  ┌─────────┐ ┌─────────┐│ Transact.  │┌─────────┐ ┌─────────┐  │
│  │ apim_db │ │shared_db ││◄──Repl.──►││ apim_db │ │shared_db │  │
│  └─────────┘ └─────────┘│            │└─────────┘ └─────────┘   │
│                          │            │                          │
│  User: apimadmineast     │            │  User: apimadminwest     │
│  DCID: DC1               │            │  DCID: DC2               │
│  IDENTITY: 1,3,5,7...   │            │  IDENTITY: 2,4,6,8...   │
└──────────────────────────┘            └──────────────────────────┘
```

## Connection Details

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

## Connecting from a Jump VM

If you have a VM in the same VNet (or a peered VNet), you can use it as a jump box to connect to the SQL Server VMs and run the setup scripts.

### Test connectivity

```bash
telnet <sql-server-private-ip> 1433
# Expected output:
# Trying <ip>...
# Connected to <ip>.
# Escape character is '^]'.
```

If this succeeds, port 1433 is reachable.

### Install sqlcmd (Ubuntu/Debian)

```bash
# Download and install Microsoft signing key
curl -sSL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg

# Add the Microsoft SQL Server repository
wget -qO- https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/prod.list | sudo tee /etc/apt/sources.list.d/microsoft-prod.list

# Install sqlcmd and ODBC driver
sudo apt-get update
sudo apt-get install -y mssql-tools18 unixodbc-dev

# Add sqlcmd to PATH
echo 'export PATH="$PATH:/opt/mssql-tools18/bin"' >> ~/.bashrc
source ~/.bashrc
```

### Connect to SQL Server

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C
```

The `-C` flag trusts the server certificate (needed for self-signed certs on VMs).

### Running SQL files

All replication setup commands are available as `.sql` files in `dbscripts/mssqlcommands/`. Clone the repo or copy the directory to the jump VM, then run each step with:

```bash
sqlcmd -S <host>,<port> -U <user> -P <pass> -d <database> -C \
  -i dbscripts/mssqlcommands/<file>.sql
```

---

## Step 1: Prerequisites

Ensure the following on **both** SQL Server VMs:

| Requirement | Details |
|-------------|---------|
| SQL Server Edition | Enterprise or Standard (Enterprise recommended for advanced replication features) |
| SQL Server Agent | Running and set to auto-start |
| Authentication | SQL Server authentication enabled (mixed mode) |
| Networking | VNet peering between East US 1 and West US 2, port 1433 open bidirectionally |
| Linked Server (optional) | Each server can connect to the other via linked server for easier management |

**Create SQL logins for replication:**

**DC1** — create the login that DC2's Distribution Agent will use to push data here:
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -i dbscripts/mssqlcommands/step1_dc1_login.sql
```

<details><summary>step1_dc1_login.sql</summary>

```sql
-- Create replication login on DC1
-- DC2's Distribution Agent will use this login to push replicated data here
CREATE LOGIN repl_dc2 WITH PASSWORD = 'Repl@2025';
GO
```
</details>

**DC2** — create the login that DC1's Distribution Agent will use to push data here:
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -i dbscripts/mssqlcommands/step1_dc2_login.sql
```

<details><summary>step1_dc2_login.sql</summary>

```sql
-- Create replication login on DC2
-- DC1's Distribution Agent will use this login to push replicated data here
CREATE LOGIN repl_dc1 WITH PASSWORD = 'Repl@2025';
GO
```
</details>

---

## Step 2: Configure Distribution

Each server acts as its own distributor.

### DC1

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d master -C \
  -i dbscripts/mssqlcommands/step2_dc1_distribution.sql
```

<details><summary>step2_dc1_distribution.sql</summary>

```sql
USE master;
GO

-- Configure DC1 as its own distributor
EXEC sp_adddistributor
    @distributor = 'apim-4-7-eus1-s',
    @password = 'Dist@2025';
GO

-- Create the distribution database
EXEC sp_adddistributiondb
    @database = 'distribution',
    @security_mode = 1;
GO

-- Register this server as a publisher using the distribution database
EXEC sp_adddistpublisher
    @publisher = 'apim-4-7-eus1-s',
    @distribution_db = 'distribution',
    @security_mode = 1;
GO
```
</details>

### DC2

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d master -C \
  -i dbscripts/mssqlcommands/step2_dc2_distribution.sql
```

<details><summary>step2_dc2_distribution.sql</summary>

```sql
USE master;
GO

EXEC sp_adddistributor
    @distributor = 'apim-4-7-wus2-s',
    @password = 'Dist@2025';
GO

EXEC sp_adddistributiondb
    @database = 'distribution',
    @security_mode = 1;
GO

-- Register this server as a publisher using the distribution database
EXEC sp_adddistpublisher
    @publisher = 'apim-4-7-wus2-s',
    @distribution_db = 'distribution',
    @security_mode = 1;
GO
```
</details>

If you get errors about the SQL Server Agent not running, make sure to start it and set it to automatic

```powershell
# RDP into the VM and start it:
net start SQLSERVERAGENT  

#To make it start automatically on boot:       
Set-Service -Name SQLSERVERAGENT -StartupType Automatic
```

---

## Step 3: Create Databases

### DC1

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C \
  -i dbscripts/mssqlcommands/step3_create_dbs.sql
```

### DC2

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -C \
  -i dbscripts/mssqlcommands/step3_create_dbs.sql
```

<details><summary>step3_create_dbs.sql</summary>

```sql
CREATE DATABASE apim_db;
GO
CREATE DATABASE shared_db;
GO

-- Enable snapshot isolation (recommended by WSO2 APIM to avoid deadlocks)
ALTER DATABASE apim_db SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE apim_db SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
ALTER DATABASE shared_db SET ALLOW_SNAPSHOT_ISOLATION ON;
ALTER DATABASE shared_db SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;
GO
```
</details>

---

## Step 4: Run DC-Specific Table Scripts

Use the pre-generated DC-specific scripts from the `dbscripts/dc1/` and `dbscripts/dc2/` directories. These have IDENTITY seeds and DCID values already configured per region.

Copy the `dbscripts/` directory to the jump VM (e.g., via `scp` or `git clone`), then run:

**DC1:**
```bash
# shared_db tables
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/dc1/SQLServer/mssql/tables.sql

# apim_db tables
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/dc1/SQLServer/mssql/apimgt/tables.sql
```

**DC2:**
```bash
# shared_db tables
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/dc2/SQLServer/mssql/tables.sql

# apim_db tables
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/dc2/SQLServer/mssql/apimgt/tables.sql
```

**What the DC-specific scripts change:**

| | DC1 | DC2 |
|--|-----|-----|
| IDENTITY columns | `IDENTITY(1,2)` | `IDENTITY(2,2)` |
| DCID default (IDN_OAUTH2_ACCESS_TOKEN) | `'DC1'` | `'DC2'` |
| NOT FOR REPLICATION | Set on all IDENTITY columns | Set on all IDENTITY columns |

This ensures DC1 generates IDs 1,3,5,7... and DC2 generates 2,4,6,8... — no collisions during replication.

> **Note:** The `NOT FOR REPLICATION` flag is already set by the `sp_msforeachtable` block at the end of each script. This tells SQL Server to preserve the original IDENTITY values when rows arrive via replication, rather than generating new ones.

---

## Step 4a: Create Replication Database Users

Now that the databases exist, create database users for the replication logins. These are needed so the Distribution Agent can write replicated data into the target databases.

**DC1** — create user for `repl_dc2` (DC2's agent writes here):
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -C \
  -i dbscripts/mssqlcommands/step4a_dc1_dbusers.sql
```

**DC2** — create user for `repl_dc1` (DC1's agent writes here):
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -C \
  -i dbscripts/mssqlcommands/step4a_dc2_dbusers.sql
```

<details><summary>step4a_dc1_dbusers.sql</summary>

```sql
-- Create database users for replication login (repl_dc2) on DC1
-- DC2's Distribution Agent uses repl_dc2 to push replicated data to DC1
-- Run this AFTER databases and tables are created (Step 3-4)

USE apim_db;
GO
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO

USE shared_db;
GO
CREATE USER repl_dc2 FOR LOGIN repl_dc2;
EXEC sp_addrolemember 'db_owner', 'repl_dc2';
GO
```
</details>

<details><summary>step4a_dc2_dbusers.sql</summary>

```sql
-- Create database users for replication login (repl_dc1) on DC2
-- DC1's Distribution Agent uses repl_dc1 to push replicated data to DC2
-- Run this AFTER databases and tables are created (Step 3-4)

USE apim_db;
GO
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO

USE shared_db;
GO
CREATE USER repl_dc1 FOR LOGIN repl_dc1;
EXEC sp_addrolemember 'db_owner', 'repl_dc1';
GO
```
</details>

> **Why `db_owner`?** The Distribution Agent needs to INSERT, UPDATE, and DELETE replicated rows and manage schema artifacts. `db_owner` is the simplest role that covers all replication operations.

---

## Step 5: Configure Publishing

Enable transactional publishing on all 4 databases (apim_db and shared_db on both DCs).

### DC1 — apim_db

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step5_apim.sql
```

### DC1 — shared_db

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step5_shared.sql
```

### DC2 — apim_db

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step5_apim.sql
```

### DC2 — shared_db

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step5_shared.sql
```

<details><summary>step5_apim.sql</summary>

```sql
EXEC sp_replicationdboption
    @dbname = 'apim_db',
    @optname = 'publish',
    @value = 'true';
GO

EXEC sp_addpublication
    @publication = 'apim_db_pub',
    @status = 'active',
    @allow_push = 'true',
    @allow_pull = 'true',
    @independent_agent = 'true',
    @immediate_sync = 'false',
    @replicate_ddl = 0,
    @allow_initialize_from_backup = 'true';
GO
```
</details>

<details><summary>step5_shared.sql</summary>

```sql
EXEC sp_replicationdboption
    @dbname = 'shared_db',
    @optname = 'publish',
    @value = 'true';
GO

EXEC sp_addpublication
    @publication = 'shared_db_pub',
    @status = 'active',
    @allow_push = 'true',
    @allow_pull = 'true',
    @independent_agent = 'true',
    @immediate_sync = 'false',
    @replicate_ddl = 0,
    @allow_initialize_from_backup = 'true';
GO
```
</details>

---

## Step 6: Add Articles (Tables) to Publications

Add all user tables to each publication. The script dynamically adds every user table with `@identityrangemanagementoption = 'none'` (we manage IDENTITY ranges ourselves via DC-specific scripts).

### DC1 — apim_db

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step6_apim.sql
```

### DC1 — shared_db

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step6_shared.sql
```

### DC2 — apim_db

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step6_apim.sql
```

### DC2 — shared_db

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step6_shared.sql
```

<details><summary>step6_apim.sql</summary>

```sql
DECLARE @table_name NVARCHAR(256);
DECLARE table_cursor CURSOR FOR
    SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo';

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sp_addarticle
        @publication = 'apim_db_pub',
        @article = @table_name,
        @source_object = @table_name,
        @type = 'logbased',
        @schema_option = 0x0000000008000001,
        @identityrangemanagementoption = 'none',
        @status = 16;
    FETCH NEXT FROM table_cursor INTO @table_name;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;
GO
```
</details>

<details><summary>step6_shared.sql</summary>

```sql
DECLARE @table_name NVARCHAR(256);
DECLARE table_cursor CURSOR FOR
    SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES
    WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA = 'dbo';

OPEN table_cursor;
FETCH NEXT FROM table_cursor INTO @table_name;

WHILE @@FETCH_STATUS = 0
BEGIN
    EXEC sp_addarticle
        @publication = 'shared_db_pub',
        @article = @table_name,
        @source_object = @table_name,
        @type = 'logbased',
        @schema_option = 0x0000000008000001,
        @identityrangemanagementoption = 'none',
        @status = 16;
    FETCH NEXT FROM table_cursor INTO @table_name;
END

CLOSE table_cursor;
DEALLOCATE table_cursor;
GO
```
</details>

> **Key:** `@identityrangemanagementoption = 'none'` disables SQL Server's automatic IDENTITY range management, since we handle it ourselves with DC-specific IDENTITY seeds and increments.

---

## Step 7: Create Subscriptions (Bidirectional)

> **Important: Use IP addresses, not hostnames.** The `@subscriber` parameter must use the remote server's IP address (not the Windows hostname). Using hostnames causes the Distribution Agent to attempt Named Pipes connections, which fail across Azure VMs. The SQL files use `$(DC2_HOST)` / `$(DC1_HOST)` as sqlcmd variables — pass the IP via `-v` on the command line.

### 7a. DC1 pushes to DC2

On **DC1**, create push subscriptions to DC2.

**DC1 — apim_db → DC2:**

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -v DC2_HOST="$DC2_HOST" \
  -i dbscripts/mssqlcommands/step7a_dc1_apim.sql
```

**DC1 — shared_db → DC2:**

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -v DC2_HOST="$DC2_HOST" \
  -i dbscripts/mssqlcommands/step7a_dc1_shared.sql
```

<details><summary>step7a_dc1_apim.sql</summary>

```sql
-- DC1 pushes apim_db to DC2
-- NOTE: subscriber uses IP address (from $DC2_HOST) to avoid Named Pipes issues
-- Replace <DC2_IP> with the actual DC2 IP if not using the sqlcmd variable substitution
EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = '$(DC2_HOST)',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025';
GO
```
</details>

<details><summary>step7a_dc1_shared.sql</summary>

```sql
-- DC1 pushes shared_db to DC2
-- NOTE: subscriber uses IP address (from $DC2_HOST) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'shared_db_pub',
    @subscriber = '$(DC2_HOST)',
    @destination_db = 'shared_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'shared_db_pub',
    @subscriber = '$(DC2_HOST)',
    @subscriber_db = 'shared_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc1',
    @subscriber_password = 'Repl@2025';
GO
```
</details>

### 7b. DC2 pushes to DC1

On **DC2**, create push subscriptions to DC1.

**DC2 — apim_db → DC1:**

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -v DC1_HOST="$DC1_HOST" \
  -i dbscripts/mssqlcommands/step7b_dc2_apim.sql
```

**DC2 — shared_db → DC1:**

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -v DC1_HOST="$DC1_HOST" \
  -i dbscripts/mssqlcommands/step7b_dc2_shared.sql
```

<details><summary>step7b_dc2_apim.sql</summary>

```sql
-- DC2 pushes apim_db to DC1
-- NOTE: subscriber uses IP address (from $DC1_HOST) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'apim_db_pub',
    @subscriber = '$(DC1_HOST)',
    @destination_db = 'apim_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'apim_db_pub',
    @subscriber = '$(DC1_HOST)',
    @subscriber_db = 'apim_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc2',
    @subscriber_password = 'Repl@2025';
GO
```
</details>

<details><summary>step7b_dc2_shared.sql</summary>

```sql
-- DC2 pushes shared_db to DC1
-- NOTE: subscriber uses IP address (from $DC1_HOST) to avoid Named Pipes issues
EXEC sp_addsubscription
    @publication = 'shared_db_pub',
    @subscriber = '$(DC1_HOST)',
    @destination_db = 'shared_db',
    @subscription_type = 'push',
    @sync_type = 'none',
    @loopback_detection = 'true';
GO

EXEC sp_addpushsubscription_agent
    @publication = 'shared_db_pub',
    @subscriber = '$(DC1_HOST)',
    @subscriber_db = 'shared_db',
    @subscriber_security_mode = 0,
    @subscriber_login = 'repl_dc2',
    @subscriber_password = 'Repl@2025';
GO
```
</details>

> **`@sync_type = 'none'`:** Both databases are freshly created with identical schemas and no data. No snapshot synchronization is needed. This is the SQL Server equivalent of pglogical's `synchronize_data := false`.

> **`@loopback_detection = 'true'`:** Prevents replication loops. Changes replicated from DC1→DC2 will not be replicated back DC2→DC1. This is the SQL Server equivalent of pglogical's `forward_origins := '{}'`.

---

## Step 8: Verify Agents Are Running

The Log Reader and Distribution Agent jobs are created and started automatically in Step 7 when subscriptions are added. Verify they exist and are enabled:

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql
```

You should see replication jobs with `enabled = 1`. If any agents are not running, start them from **SQL Server Agent → Jobs** in SSMS.

---

## Step 9: Verify Replication Status

### Check publications on DC1

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step9_verify_apim.sql

sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step9_verify_shared.sql
```

### Check publications on DC2

```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step9_verify_apim.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d shared_db -C \
  -i dbscripts/mssqlcommands/step9_verify_shared.sql
```

<details><summary>step9_verify_apim.sql</summary>

```sql
-- List publications
EXEC sp_helppublication;
GO

-- List articles in the publication
EXEC sp_helparticle @publication = 'apim_db_pub';
GO

-- List subscriptions
EXEC sp_helpsubscription @publication = 'apim_db_pub';
GO
```
</details>

<details><summary>step9_verify_shared.sql</summary>

```sql
EXEC sp_helppublication;
GO

EXEC sp_helparticle @publication = 'shared_db_pub';
GO

EXEC sp_helpsubscription @publication = 'shared_db_pub';
GO
```
</details>

### Check replication monitor

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_dc1_monitor.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_dc2_monitor.sql
```

### Check agent job status (on both DCs)

```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql

sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql
```

### Check replication error logs

If replication isn't working, check the error logs on **both** DCs:

```bash
# DC1 errors
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql

# DC2 errors
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql
```

<details><summary>step9_check_errors.sql</summary>

```sql
-- Check recent replication errors
SELECT TOP 10 id, error_text, time
FROM dbo.MSrepl_errors
ORDER BY time DESC;
GO
```
</details>

Common errors and fixes:

| Error | Cause | Fix |
|-------|-------|-----|
| `Named Pipes Provider: Could not open a connection` | Subscriber uses hostname instead of IP | Recreate subscription with IP address (Step 7) |
| `Login failed for user 'repl_dcX'` | Replication login has no database user | Run `CREATE USER` + `sp_addrolemember` on target DB |
| `Cannot open database "X" requested by the login` | Same as above — login exists but has no DB user | Run `CREATE USER` + `sp_addrolemember` on target DB |
| `Violation of PRIMARY KEY constraint` | Duplicate row (loopback or stale data) | Check loopback_detection is enabled; clean up duplicate rows |

If a Distribution Agent has stopped due to errors, restart it after fixing the issue:

```bash
# List agent job names
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -i dbscripts/mssqlcommands/step9_agent_jobs.sql

# Restart a specific agent job
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "EXEC sp_start_job @job_name = '<job-name-from-above>';"
```

---

## Step 10: Test Replication

Insert a test row on DC1 and verify it appears on DC2 (and vice versa).

### DC1 → DC2

**Insert on DC1:**
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step10_dc1_insert.sql
```

**Check on DC2** (should appear within seconds):
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -Q "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;"
```

### DC2 → DC1

**Insert on DC2:**
```bash
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step10_dc2_insert.sql
```

**Check on DC1** (should appear within seconds):
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -Q "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998;"
```

### Clean up test data

Run on either DC — will replicate to the other:
```bash
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d apim_db -C \
  -i dbscripts/mssqlcommands/step10_cleanup.sql
```

---

## Connecting APIM (Kubernetes) to SQL Server

WSO2 API Manager running in AKS needs to reach the SQL Server VMs over JDBC.

### Networking

AKS pods can reach the SQL Server VM's private IP directly if:
- AKS uses **Azure CNI** networking (pods get IPs from the VNet subnet)
- The AKS VNet and SQL Server VNet are the **same VNet** or **peered**
- The **NSG on the SQL Server VM** allows inbound port 1433 from the AKS subnet CIDR
- **Windows Firewall** on the SQL VM allows inbound 1433

Quick connectivity test from a pod:
```bash
kubectl run debug --rm -it --image=mcr.microsoft.com/mssql-tools -n apim -- /bin/bash

# Inside the pod:
/opt/mssql-tools/bin/sqlcmd -S <sql-vm-private-ip>,1433 -U apimadmineast -P '{password}' -C -Q "SELECT 1"
```

### Helm Values Configuration

Configure the JDBC connection in your Helm values files (e.g., `azure-values-dc1.yaml`). This follows the same pattern as the existing PostgreSQL configuration.

**DC1 example:**
```yaml
wso2:
  apim:
    configurations:
      databases:
        type: "mssql"
        jdbc:
          driver: "com.microsoft.sqlserver.jdbc.SQLServerDriver"
        apim_db:
          url: "jdbc:sqlserver://<dc1-sql-private-ip>:1433;databaseName=apim_db;encrypt=true;trustServerCertificate=true"
          username: "apimadmineast"
          password: "distributed@2"
        shared_db:
          url: "jdbc:sqlserver://<dc1-sql-private-ip>:1433;databaseName=shared_db;encrypt=true;trustServerCertificate=true"
          username: "apimadmineast"
          password: "distributed@2"
```

**DC2** — same structure, pointing to DC2's SQL Server private IP with `apimadminwest`.

> **Note:** In `deployment.toml`, JDBC URLs must use `&amp;` instead of bare `&` for any URL parameters (XML entity encoding).

### JDBC Driver Init Container

The APIM container image does not bundle the SQL Server JDBC driver. Use an init container to download it at pod startup, following the same pattern used for PostgreSQL.

**Control Plane (`azure-values-dc1.yaml`):**
```yaml
kubernetes:
  initContainers:
    - name: mssql-driver-init
      image: busybox:1.36
      command:
        - /bin/sh
        - -c
        - |
          wget -O /jdbc-driver/mssql-jdbc-12.8.1.jre11.jar \
            "https://repo1.maven.org/maven2/com/microsoft/sqlserver/mssql-jdbc/12.8.1.jre11/mssql-jdbc-12.8.1.jre11.jar" && \
          echo "MSSQL JDBC driver downloaded successfully"
      volumeMounts:
        - name: mssql-driver-vol
          mountPath: /jdbc-driver
  extraVolumes:
    - name: mssql-driver-vol
      emptyDir: {}
  extraVolumeMounts:
    - name: mssql-driver-vol
      mountPath: /home/wso2carbon/wso2am-acp-4.7.0-alpha/repository/components/lib/mssql-jdbc-12.8.1.jre11.jar
      subPath: mssql-jdbc-12.8.1.jre11.jar
      readOnly: true
```

**Gateway** — same init container, but change the mount path to match the gateway profile:
```yaml
  extraVolumeMounts:
    - name: mssql-driver-vol
      mountPath: /home/wso2carbon/wso2am-universal-gw-4.7.0-alpha/repository/components/lib/mssql-jdbc-12.8.1.jre11.jar
      subPath: mssql-jdbc-12.8.1.jre11.jar
      readOnly: true
```

> **Tip:** Check the actual APIM version path inside the container (`ls /home/wso2carbon/`) in case the version suffix differs from `4.7.0-alpha`.

---

## Networking Checklist

- [ ] VNet peering configured between East US 1 and West US 2 VNets
- [ ] SQL Server port 1433 open in NSG/firewall rules for both directions
- [ ] SQL Server Agent can reach the remote server (required for push subscriptions)
- [ ] Both servers registered as linked servers (optional, for management convenience)
- [ ] Use private IP addresses if VNet peering is active (better security and latency)

---

## Troubleshooting

### Check replication agent errors

```bash
# DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql

# DC2
sqlcmd -S $DC2_HOST,$DC2_PORT -U $DC2_USER -P $DC2_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_check_errors.sql
```

### Named Pipes connection errors

If you see `Named Pipes Provider: Could not open a connection to SQL Server`, the subscriber was registered using a hostname that the local machine can't resolve. Fix: drop and recreate the subscription using the subscriber's IP address instead of hostname. See Step 7 for the correct commands.

### Replication login permission errors

If you see `Login failed for user 'repl_dcX'` or `Cannot open database "X"`, the replication login exists but doesn't have a database user on the target databases. Fix:

```bash
# On the target server (where the login is failing), create users in each database:
sqlcmd -S <TARGET_HOST>,<PORT> -U <ADMIN_USER> -P <ADMIN_PASS> -C -Q "
USE apim_db;
CREATE USER repl_dcX FOR LOGIN repl_dcX;
EXEC sp_addrolemember 'db_owner', 'repl_dcX';
GO
USE shared_db;
CREATE USER repl_dcX FOR LOGIN repl_dcX;
EXEC sp_addrolemember 'db_owner', 'repl_dcX';
GO
"
```

### Subscription not replicating

```bash
# Check Distribution Agent status on DC1
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d distribution -C \
  -i dbscripts/mssqlcommands/step9_dc1_monitor.sql

# Restart a stopped agent job
sqlcmd -S $DC1_HOST,$DC1_PORT -U $DC1_USER -P $DC1_PASS -d msdb -C \
  -Q "EXEC sp_start_job @job_name = '<job-name>';"
```

### IDENTITY conflicts

If you see unique constraint violations on IDENTITY columns:
1. Verify IDENTITY seeds: DC1 should have `IDENTITY(1,2)` and DC2 should have `IDENTITY(2,2)`
2. Verify `NOT FOR REPLICATION` is set:
```sql
SELECT OBJECT_NAME(object_id) AS table_name, name AS column_name, is_not_for_replication
FROM sys.identity_columns
WHERE is_not_for_replication = 0;
-- Should return no rows (all should be 1 = NOT FOR REPLICATION)
```

### Check current IDENTITY values

```sql
-- Check the current IDENTITY value for a specific table
DBCC CHECKIDENT ('table_name', NORESEED);
GO
```

### Distribution database cleanup

If the distribution database grows too large:
```sql
-- Check distribution history retention
EXEC sp_helpdistributiondb;
GO

-- Clean up old distribution history (default retention is 72 hours)
EXEC distribution.dbo.sp_MSdistribution_cleanup @min_distretention = 0, @max_distretention = 72;
GO
```

### Log Reader Agent not starting

```sql
-- Ensure the database has the right recovery model
ALTER DATABASE apim_db SET RECOVERY FULL;
GO
ALTER DATABASE shared_db SET RECOVERY FULL;
GO
```

---

## Key Differences from PostgreSQL pglogical

| Aspect | PostgreSQL (pglogical) | SQL Server (Transactional Replication) |
|--------|----------------------|---------------------------------------|
| Replication engine | pglogical extension (must be installed) | Built-in feature (no extension needed) |
| Loop prevention | `forward_origins := '{}'` | `@loopback_detection = 'true'` |
| Auto-increment | Sequences with START/INCREMENT | IDENTITY(seed, increment) |
| Identity preservation | N/A (sequences are local) | `NOT FOR REPLICATION` flag on IDENTITY columns |
| Initial sync | `synchronize_data := false` | `@sync_type = 'none'` |
| Agent/Worker | pglogical background workers | SQL Server Agent jobs (Log Reader + Distribution Agent) |
| Monitoring | `pglogical.show_subscription_status()` | Replication Monitor / `sp_replmonitorhelpsubscription` |
| Azure product | Azure PostgreSQL Flexible Server | SQL Server on Azure VMs |
| Configuration | Server parameters (wal_level, etc.) | Distributor configuration (sp_adddistributor) |
| Conflict resolution | `track_commit_timestamp` | Loopback detection + IDENTITY offset strategy |

---

## Summary of Operations

| Step | DC1 (East US 1) | DC2 (West US 2) |
|------|-----------------|-----------------|
| 1. Prerequisites | SQL Server Agent running, create `repl_dc2` login | SQL Server Agent running, create `repl_dc1` login |
| 2. Configure distribution | Self as distributor | Self as distributor |
| 3. Create databases | `apim_db`, `shared_db` | `apim_db`, `shared_db` |
| 4. Run table scripts | `dc1/SQLServer/mssql/` scripts | `dc2/SQLServer/mssql/` scripts |
| 4a. Create replication DB users | `repl_dc2` user in both databases | `repl_dc1` user in both databases |
| 5. Enable publishing | Both databases | Both databases |
| 6. Add articles | All tables in both databases | All tables in both databases |
| 7. Create subscriptions | Push to DC2 (using DC2 IP) | Push to DC1 (using DC1 IP) |
| 8. Verify agents | Agents auto-start with Step 7 | Agents auto-start with Step 7 |
| 9. Verify replication | Check status + error logs on both | Check status + error logs on both |
| 10. Test | Insert test rows, verify bidirectional | Insert test rows, verify bidirectional |
