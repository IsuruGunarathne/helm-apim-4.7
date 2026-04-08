# Bi-Directional Replication with pglogical — Azure Database for PostgreSQL Flexible Server

Set up pglogical bi-directional replication between two Azure PostgreSQL Flexible Server instances for WSO2 API Manager 4.7 multi-DC deployment.

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────┐            ┌──────────────────────────┐
│  apim-4-7-eus1.postgres  │            │  apim-4-7-wus2.postgres  │
│  .database.azure.com     │            │  .database.azure.com     │
│                          │            │                          │
│  ┌─────────┐ ┌─────────┐│  pglogical ││┌─────────┐ ┌─────────┐ │
│  │ apim_db │ │shared_db ││◄──────────►││ apim_db │ │shared_db │ │
│  └─────────┘ └─────────┘│            │└─────────┘ └─────────┘  │
│                          │            │                          │
│  User: apimadmineast     │            │  User: apimadminwest     │
│  DCID: DC1               │            │  DCID: DC2               │
│  Sequences: 1,3,5,7...   │            │  Sequences: 2,4,6,8...   │
└──────────────────────────┘            └──────────────────────────┘
```

## Connection Details

```bash
# DC1 — East US 1
export DC1_HOST=apim-4-7-eus1.postgres.database.azure.com
export DC1_USER=apimadmineast
export DC1_PORT=5432
export DC1_PASS="{your-password}"

or

export PGHOST=apim-4-7-eus1.postgres.database.azure.com
export PGUSER=apimadmineast
export PGPORT=5432
export PGDATABASE=postgres
export PGPASSWORD="{your-password}" # for psql convenience

# DC2 — West US 2
export DC2_HOST=apim-4-7-wus2.postgres.database.azure.com
export DC2_USER=apimadminwest
export DC2_PORT=5432
export DC2_PASS="{your-password}"

or 

export PGHOST=apim-4-7-wus2.postgres.database.azure.com
export PGUSER=apimadminwest
export PGPORT=5432
export PGDATABASE=postgres
export PGPASSWORD="{your-password}" # for psql convenience
```

---

## Step 1: Configure Azure Server Parameters

Configure these on **both** Flexible Server instances via the Azure Portal (Server Parameters blade) or Azure CLI.

| Parameter | Value | Notes |
|-----------|-------|-------|
| `wal_level` | `logical` | Required for logical replication |
| `max_worker_processes` | `16` | Must be enough for pglogical workers |
| `max_replication_slots` | `10` | At least 2 per database being replicated |
| `max_wal_senders` | `10` | At least 2 per database being replicated |
| `track_commit_timestamp` | `on` | Required for conflict resolution |
| `shared_preload_libraries` | `pglogical` | Loads pglogical extension at startup |
| `azure.extensions` | `pglogical` | Allows pglogical extension on Azure |

Using Azure CLI:
```bash
# DC1
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name wal_level --value logical
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name max_worker_processes --value 16
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name max_replication_slots --value 10
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name max_wal_senders --value 10
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name track_commit_timestamp --value on
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name shared_preload_libraries --value pglogical
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-eus1 --name azure.extensions --value pglogical

# DC2
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name wal_level --value logical
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name max_worker_processes --value 16
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name max_replication_slots --value 10
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name max_wal_senders --value 10
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name track_commit_timestamp --value on
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name shared_preload_libraries --value pglogical
az postgres flexible-server parameter set --resource-group rg-WSO2-APIM-4.7.0-release-isuruguna --server-name apim-4-7-wus2 --name azure.extensions --value pglogical
```

**Restart both servers** after changing these parameters.

---

## Step 2: Grant Replication Privileges

On **DC1** (`psql` connected to DC1):
```sql
GRANT azure_pg_admin TO apimadmineast;
ALTER ROLE apimadmineast REPLICATION LOGIN;
```

On **DC2** (`psql` connected to DC2):
```sql
GRANT azure_pg_admin TO apimadminwest;
ALTER ROLE apimadminwest REPLICATION LOGIN;
```

---

## Step 3: Create Databases

On **both** servers:
```sql
CREATE DATABASE apim_db;
CREATE DATABASE shared_db;
```

---

## Step 4: Create pglogical Extension

Create the extension in **each database** on **both** servers (4 total):

```sql
-- Connect to apim_db
\c apim_db
CREATE EXTENSION IF NOT EXISTS pglogical;

-- Connect to shared_db
\c shared_db
CREATE EXTENSION IF NOT EXISTS pglogical;
```

---

## Step 5: Run DC-Specific Table Scripts

Use the pre-generated DC-specific scripts from the `dbscripts/dc1/` and `dbscripts/dc2/` directories. These have sequences and DCID values already configured per region.

**DC1** (`psql` connected to DC1):
```bash
# shared_db tables
psql -h $PGHOST -U $PGUSER -d shared_db -f dbscripts/dc1/Postgresql/tables.sql

# apim_db tables
psql -h $PGHOST -U $PGUSER -d apim_db -f dbscripts/dc1/Postgresql/apimgt/tables.sql
```

**DC2** (`psql` connected to DC2):
```bash
# shared_db tables
psql -h $PGHOST -U $PGUSER -d shared_db -f dbscripts/dc2/Postgresql/tables.sql

# apim_db tables
psql -h $PGHOST -U $PGUSER -d apim_db -f dbscripts/dc2/Postgresql/apimgt/tables.sql
```

**What the DC-specific scripts change:**

| | DC1 | DC2 |
|--|-----|-----|
| Sequences | `START 1 INCREMENT 2` | `START 2 INCREMENT 2` |
| DCID default (IDN_OAUTH2_ACCESS_TOKEN) | `'DC1'` | `'DC2'` |

This ensures DC1 generates IDs 1,3,5,7... and DC2 generates 2,4,6,8... — no collisions during replication.

---

## Step 6: Create pglogical Nodes

Each database on each server needs a pglogical node. A node represents this database instance in the replication topology.

### DC1 — apim_db
```sql
-- psql -h $DC1_HOST -U $DC1_USER -d apim_db
\c apim_db
SELECT pglogical.create_node(
    node_name := 'dc1-apim',
    dsn := 'host=apim-4-7-eus1.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmineast password={your-password}'
);
```

### DC1 — shared_db
```sql
-- psql -h $DC1_HOST -U $DC1_USER -d shared_db
\c shared_db
SELECT pglogical.create_node(
    node_name := 'dc1-shared',
    dsn := 'host=apim-4-7-eus1.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmineast password={your-password}'
);
```

### DC2 — apim_db
```sql
-- psql -h $DC2_HOST -U $DC2_USER -d apim_db
\c apim_db
SELECT pglogical.create_node(
    node_name := 'dc2-apim',
    dsn := 'host=apim-4-7-wus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadminwest password={your-password}'
);
```

### DC2 — shared_db
```sql
-- psql -h $DC2_HOST -U $DC2_USER -d shared_db
\c shared_db
SELECT pglogical.create_node(
    node_name := 'dc2-shared',
    dsn := 'host=apim-4-7-wus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadminwest password={your-password}'
);
```

---

## Step 7: Add Tables to Replication Sets

On **all 4 databases** (apim_db and shared_db on both DC1 and DC2):

```sql
SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
```

This adds all tables in the `public` schema to the default replication set. All tables must have primary keys (verified — all WSO2 APIM tables do).

---

## Step 8: Create Subscriptions (Bi-Directional)

### 8a. DC2 subscribes to DC1

**DC2 — apim_db** subscribes to DC1's apim_db:
```sql
-- psql -h $DC2_HOST -U $DC2_USER -d apim_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-4-7-eus1.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmineast password={your-password}',
    synchronize_data := false,
    forward_origins := '{}'
);
```

**DC2 — shared_db** subscribes to DC1's shared_db:
```sql
-- psql -h $DC2_HOST -U $DC2_USER -d shared_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-4-7-eus1.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmineast password={your-password}',
    synchronize_data := false,
    forward_origins := '{}'
);
```

**Verify** subscriptions are active:
```sql
SELECT subscription_name, status FROM pglogical.show_subscription_status();
-- Both should show status = 'replicating'
```

### 8b. DC1 subscribes to DC2 (reverse direction)

**DC1 — apim_db** subscribes to DC2's apim_db:
```sql
-- psql -h $DC1_HOST -U $DC1_USER -d apim_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-4-7-wus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadminwest password={your-password}',
    synchronize_data := false,
    forward_origins := '{}'
);
```

**DC1 — shared_db** subscribes to DC2's shared_db:
```sql
-- psql -h $DC1_HOST -U $DC1_USER -d shared_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-4-7-wus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadminwest password={your-password}',
    synchronize_data := false,
    forward_origins := '{}'
);
```

> **Note:** `synchronize_data` is set to `false` for all subscriptions because both databases are freshly created with identical schemas and no data. Setting it to `true` can cause pglogical to get stuck in a nonrecoverable state on Azure Flexible Server. If you need to sync existing data later, use `pg_dump`/`pg_restore` instead.

### Why `forward_origins := '{}'`?

This prevents **replication loops**. Without it, data replicated from DC1→DC2 would be replicated back DC2→DC1 endlessly. Setting `forward_origins` to an empty array means "only replicate changes that originated locally on this node."

---

## Step 9: Verify Replication Status

On **both** servers, in each database:
```sql
SELECT subscription_name, status FROM pglogical.show_subscription_status();
```

Expected output — all subscriptions should show `replicating`:
```
 subscription_name |   status
-------------------+-------------
 dc1-sub-apim      | replicating
 dc1-sub-shared    | replicating
```

Check replication slots:
```sql
SELECT slot_name, active FROM pg_replication_slots;
```

---

## Step 10: Test Replication

Insert a test row on DC1 and verify it appears on DC2 (and vice versa).

**DC1 — apim_db:**
```sql
-- Insert on DC1
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (999, 'test-dc1-replication', 'admin-dashboard');

-- Check on DC2 (should appear within seconds)
-- psql -h $DC2_HOST -U $DC2_USER -d apim_db
SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;
```

**DC2 — apim_db:**
```sql
-- Insert on DC2
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (998, 'test-dc2-replication', 'admin-dashboard');

-- Check on DC1 (should appear within seconds)
-- psql -h $DC1_HOST -U $DC1_USER -d apim_db
SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998;
```

**Clean up test data** (run on either DC — will replicate to the other):
```sql
DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999);
```

---

## Networking Checklist

- [ ] VNet peering configured between East US 1 and West US 2 VNets
- [ ] PostgreSQL port 5432 open in NSG/firewall rules for both directions
- [ ] Use private IP addresses in DSN strings if VNet peering is active (better security and latency)
- [ ] Both servers can reach each other (test with `psql` from one region to the other)

---

## Troubleshooting

### Check subscription status
```sql
SELECT * FROM pglogical.show_subscription_status();
```

### Check replication lag
```sql
SELECT slot_name, confirmed_flush_lsn, pg_current_wal_lsn(),
       (pg_current_wal_lsn() - confirmed_flush_lsn) AS lag_bytes
FROM pg_replication_slots;
```

### View pglogical worker status
```sql
SELECT * FROM pglogical.local_node;
SELECT * FROM pglogical.subscription;
```

### If a subscription is stuck
```sql
-- Drop and recreate
SELECT pglogical.drop_subscription('dc2-sub-apim');
-- Then re-run the CREATE SUBSCRIPTION command
```

### Check PostgreSQL logs
Azure Portal → Your server → Monitoring → Logs, or:
```bash
az postgres flexible-server log list --resource-group <rg> --server-name apim-4-7-eus1
```

---

## Summary of Operations

| Step | DC1 (East US 1) | DC2 (West US 2) |
|------|-----------------|-----------------|
| Server params | Configure & restart | Configure & restart |
| Grant privileges | `apimadmineast` | `apimadminwest` |
| Create databases | `apim_db`, `shared_db` | `apim_db`, `shared_db` |
| pglogical extension | Both databases | Both databases |
| Run table scripts | `dc1/Postgresql/` scripts | `dc2/Postgresql/` scripts |
| Create nodes | `dc1-apim`, `dc1-shared` | `dc2-apim`, `dc2-shared` |
| Add to replication set | Both databases | Both databases |
| Subscribe (forward) | — | Subscribe to DC1 (`synchronize_data=true`) |
| Subscribe (reverse) | Subscribe to DC2 (`synchronize_data=false`) | — |
| Verify | Check status on both | Check status on both |
