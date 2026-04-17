# Bi-Directional Replication with pglogical — PostgreSQL Natively on Azure Ubuntu VMs

Set up active-active PostgreSQL replication between two Azure data centers for the WSO2 API Manager 4.7 multi-DC deployment, using a **native apt-installed PostgreSQL 17 + pglogical** on each of the two Ubuntu VMs that were originally provisioned for the Oracle + GoldenGate stack.

This is the VM-hosted counterpart of [`POSTGRES_PGLOGICAL_GUIDE.md`](POSTGRES_PGLOGICAL_GUIDE.md), which targets Azure Database for PostgreSQL Flexible Server. Nothing else differs at the pglogical layer — the node / replication-set / subscription topology is identical. Only the hosting and connection details change: private VM IPs instead of managed-service hostnames, `postgres` superuser instead of Azure-managed admin roles, and `apt install` replacing the Flexible Server provisioning.

Unlike the Oracle + GG setup in [`ORACLE_OGG_REPLICATION_GUIDE.md`](ORACLE_OGG_REPLICATION_GUIDE.md) there is **no separate replication-hub VM and no Docker** — pglogical runs inside each PostgreSQL instance, so the two VMs are fully symmetric and each just needs its local postgres service running.

## Prerequisites

1. Both OGG VMs from `ORACLE_OGG_REPLICATION_GUIDE.md` §Part 1 still exist, with the VNet peering from §1.3 in place. Docker is **not** required for this guide — if it's installed from the OGG setup it can stay, but nothing here uses it.
2. The Oracle stack on both VMs has been torn down via [`ORACLE_RESET_GUIDE.md`](ORACLE_RESET_GUIDE.md) — `docker ps` on each VM should return an empty list. Otherwise the Oracle container will compete for VM memory with the native postgres service on DC2's 2 vCPU / 8 GB shape.
3. The repo is cloned on each VM at `~/helm-apim-4.7` (same location the OGG guide used in §4.3). The DC-specific schema packs under `dbscripts/dc1/Postgresql/` and `dbscripts/dc2/Postgresql/` are needed at §Part 5.

## Architecture

```
        DC1 (East US 1)                            DC2 (West US 2)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│  Oracle subnet (10.2.4.0/24) │          │  Oracle subnet (10.1.4.0/24) │
│                              │          │                              │
│  ┌────────────────────────┐  │          │  ┌────────────────────────┐  │
│  │ apim-4-7-eus1-oracle   │  │          │  │ apim-4-7-wus2-oracle   │  │
│  │ (Ubuntu 22.04 LTS)     │  │          │  │ (Ubuntu 22.04 LTS)     │  │
│  │                        │  │          │  │                        │  │
│  │  postgres@17 systemd   │  │  VNet    │  │  postgres@17 systemd   │  │
│  │   apim_db + shared_db  │◄─┼──peering─┼─►│   apim_db + shared_db  │  │
│  │   pglogical extension  │  │  :5432   │  │   pglogical extension  │  │
│  │   Sequences 1,3,5,7... │  │          │  │   Sequences 2,4,6,8... │  │
│  │   DCID: DC1            │  │          │  │   DCID: DC2            │  │
│  │                        │  │          │  │                        │  │
│  │  IP: 10.2.4.4          │  │          │  │  IP: 10.1.4.4          │  │
│  └────────────────────────┘  │          │  └────────────────────────┘  │
│                              │          │                              │
│  Jump-box VM (x.x.1.0/24)    │          │  Jump-box VM (x.x.1.0/24)    │
└──────────────────────────────┘          └──────────────────────────────┘
```

**Replication topology** (identical to `POSTGRES_PGLOGICAL_GUIDE.md` §Step 8, two directions × two databases):

- **DC1 → DC2**: DC2's `apim_db` subscribes to DC1's `apim_db`; DC2's `shared_db` subscribes to DC1's `shared_db`.
- **DC2 → DC1**: DC1's `apim_db` subscribes to DC2's `apim_db`; DC1's `shared_db` subscribes to DC2's `shared_db`.
- Each subscription is created with `forward_origins := '{}'` so locally-applied replicated rows aren't re-shipped — the same loopback-prevention trick as the Flexible Server recipe.

## Connection details

```bash
# DC1 — East US 1
export DC1_HOST=10.2.4.4
export DC1_PORT=5432
export DC1_USER=postgres
export DC1_PASS="Apim@123"

# DC2 — West US 2
export DC2_HOST=10.1.4.4
export DC2_PORT=5432
export DC2_USER=postgres
export DC2_PASS="Apim@123"
```

> **Password placeholder**: `Apim@123` matches the OGG guide's default for copy-paste convenience. Replace it with a strong password for any non-lab deployment; every spot this guide writes `Apim@123` has to change consistently (`ALTER USER postgres`, pglogical DSNs, pg_hba entries, and later the Helm values that will be generated as a follow-up).

> **Why `postgres` and not the Azure-managed `apimadmineast`/`apimadminwest`?** Those are Azure Flexible Server's provisioning roles — they don't exist on a self-hosted PostgreSQL. On a freshly installed PG cluster, the bootstrap superuser is `postgres`, and it already has `SUPERUSER` + `REPLICATION`. Using it directly keeps the guide short; if you want a dedicated replication user for production, create one after §Part 2 with `CREATE ROLE repl WITH LOGIN REPLICATION PASSWORD '...';` and substitute it in every DSN below.

> **PostgreSQL 17 on pglogical 2.4.6** — pglogical 2.4.5 (Nov 2024) added PG 17 support and 2.4.6 (Aug 2025) is the current release. The PGDG apt repo ships `postgresql-17-pglogical_2.4.6-2.pgdg22.04+1_amd64.deb`, which installs cleanly on the Ubuntu 22.04 amd64 VMs. The `postgresql-42.7.4.jar` JDBC driver used by the existing Helm values targets PG 9.4+ and is fully compatible with PG 17.

---

## Part 1: NSG Rule for Port 5432

The OGG guide opened only port 1521 on each VM's NSG (§1.2). For pglogical we need 5432 in both directions over the peered VNets.

```bash
RG="rg-WSO2-APIM-4.7.0-release-isuruguna"

get_nsg() {
  az vm show -g "$RG" -n "$1" --query "networkProfile.networkInterfaces[0].id" -o tsv \
    | xargs az network nic show --ids \
    | jq -r '.networkSecurityGroup.id' \
    | xargs az network nsg show --ids \
    | jq -r '.name'
}

DC1_NSG=$(get_nsg apim-4-7-eus1-oracle)
DC2_NSG=$(get_nsg apim-4-7-wus2-oracle)

# DC1 VM — inbound 5432 from the VNet
az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC1_NSG \
  --name AllowPostgres5432 \
  --priority 1020 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 5432 \
  --source-address-prefixes VirtualNetwork

# DC2 VM — same rule
az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC2_NSG \
  --name AllowPostgres5432 \
  --priority 1020 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 5432 \
  --source-address-prefixes VirtualNetwork
```

Confirm the existing VNet peering from the OGG guide's §1.3 is still up (no changes needed):

```bash
az network vnet peering list --resource-group $RG \
  --vnet-name $(az network vnet list -g $RG --query "[?location=='eastus'].name" -o tsv | head -1) \
  -o table
```

Expected: bidirectional `Connected` entries between the two VNets. Port-level reachability is verified at the end of §Part 2, once postgres is running on both sides.

---

## Part 2: Install PostgreSQL 17 + pglogical

Run this **on both VMs** (DC1 and DC2) — they are symmetric.

### 2.1 Enable the PGDG apt repo and install the packages

Ubuntu 22.04's default `postgresql` package is PG 14, and pglogical isn't packaged in the Ubuntu repos at all. The PostgreSQL Global Development Group (PGDG) apt repo ships both `postgresql-17` and `postgresql-17-pglogical` (`2.4.6-2.pgdg22.04+1` at the time of writing).

```bash
sudo apt-get update
sudo apt-get install -y curl ca-certificates gnupg lsb-release

sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc

sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'

sudo apt-get update
sudo apt-get install -y postgresql-17 postgresql-17-pglogical
```

The `postgresql-17` package:
- Creates `/etc/postgresql/17/main/` with `postgresql.conf` and `pg_hba.conf`.
- Creates `/var/lib/postgresql/17/main/` as the data directory.
- Registers `postgresql@17-main` under systemd and starts it immediately.
- Creates the `postgres` Unix user with peer-auth access to the cluster (`sudo -u postgres psql` works without a password).

Verify the extension binaries landed:

```bash
sudo -u postgres psql -c "SELECT name, default_version FROM pg_available_extensions WHERE name='pglogical';"
```

Expect one row with `default_version = 2.4.6`.

### 2.2 Set the `postgres` password and tune server parameters

`pglogical` replication uses TCP + password auth for the cross-DC links, so the `postgres` role needs an actual password (bootstrap peer auth only works from the local Unix socket). While we're in `psql`, also set the eight server parameters pglogical needs — identical list to `POSTGRES_PGLOGICAL_GUIDE.md` §Step 1 plus `listen_addresses` (so the service binds on the VM's private IP, not just loopback) and `max_connections` (raised to 300 for APIM load, see below). The PG 16 → PG 17 jump didn't change the defaults or units for any of these eight GUCs, so this block is copy-paste identical to a PG 16 setup:

```bash
sudo -u postgres psql <<'SQL'
ALTER USER postgres WITH PASSWORD 'Apim@123';

ALTER SYSTEM SET listen_addresses         = '*';
ALTER SYSTEM SET shared_preload_libraries = 'pglogical';
ALTER SYSTEM SET wal_level                = 'logical';
ALTER SYSTEM SET track_commit_timestamp   = on;
ALTER SYSTEM SET max_worker_processes     = 16;
ALTER SYSTEM SET max_replication_slots    = 10;
ALTER SYSTEM SET max_wal_senders          = 10;
ALTER SYSTEM SET max_connections          = 300;
SQL
```

`ALTER SYSTEM` writes to `postgresql.auto.conf`, which `postgresql.conf` always includes — no manual file editing needed.

Rationale for each parameter (same as the Flexible Server guide unless noted):
- `listen_addresses = '*'` — bind on all interfaces, including the VM's private IP. The PGDG Ubuntu default is `localhost`, which would leave the peer DC unreachable.
- `shared_preload_libraries = 'pglogical'` — loads the extension at startup (required).
- `wal_level = logical` — required for logical replication.
- `track_commit_timestamp = on` — needed for pglogical conflict resolution.
- `max_worker_processes = 16`, `max_replication_slots = 10`, `max_wal_senders = 10` — headroom for pglogical's background workers and slots (at least 2 of each per replicated DB).
- `max_connections = 300` — raised from the PGDG default of 100. Under full APIM 4.7 multi-DC load each APIM pod opens JDBC pools against *both* `apim_db` and `shared_db`; with 6 pods per DC plus pglogical apply/sender workers plus incoming replication connections from the peer, 100 saturates and pod logs fill with `FATAL: sorry, too many clients already`. 300 is the ceiling the earlier pgsql multi-DC run settled on. Mirrors the OGG guide's `PROCESSES=1000` bump in §4.2.

### 2.3 Restart to pick up the static parameters

`shared_preload_libraries`, `max_connections`, and `listen_addresses` are all *restart-required* parameters — `SELECT pg_reload_conf();` will not pick them up. Do a full service restart:

```bash
sudo systemctl restart postgresql@17-main

# Confirm it came back up
sudo systemctl status postgresql@17-main --no-pager
sudo -u postgres psql -c "SHOW shared_preload_libraries;"
sudo -u postgres psql -c "SHOW max_connections;"
sudo -u postgres psql -c "SHOW listen_addresses;"
```

Expect `pglogical`, `300`, `*` respectively.

### 2.4 Verify cross-DC reachability

From the **DC1** VM:

```bash
nc -zv 10.1.4.4 5432
# expect: Connection to 10.1.4.4 5432 port [tcp/*] succeeded!
```

From the **DC2** VM:

```bash
nc -zv 10.2.4.4 5432
# expect: Connection to 10.2.4.4 5432 port [tcp/*] succeeded!
```

If either `nc` fails: re-check the NSG rule from §Part 1 and the VNet peering from the OGG guide's §1.3 before continuing.

---

## Part 3: Allow Replication Connections in `pg_hba.conf`

The PGDG default `pg_hba.conf` only allows local peer auth + loopback `scram-sha-256`. pglogical additionally opens a `replication` channel that needs a matching `host replication …` line for the peer's IP — **and** for this VM's *own* private IP, because `pglogical.create_subscription` validates the local node by opening a fresh TCP connection to the local node's DSN (which points at the VM's private NIC address, not loopback). A pg_hba that only whitelists the peer DC leaves the subscribe step failing with `FATAL: no pg_hba.conf entry for host "<self-IP>"`.

Run the block below **on both VMs**, swapping the IPs:
- On **DC1**, `SELF_IP=10.2.4.4`, `PEER_IP=10.1.4.4`.
- On **DC2**, `SELF_IP=10.1.4.4`, `PEER_IP=10.2.4.4`.

```bash
SELF_IP=10.2.4.4    # on DC1; use 10.1.4.4 on DC2
PEER_IP=10.1.4.4    # on DC1; use 10.2.4.4 on DC2

sudo tee -a /etc/postgresql/17/main/pg_hba.conf <<EOF

# pglogical cross-DC replication (added by POSTGRES_VM_GUIDE.md §Part 3)
host    all         postgres  ${SELF_IP}/32  scram-sha-256
host    replication postgres  ${SELF_IP}/32  scram-sha-256
host    all         postgres  ${PEER_IP}/32  scram-sha-256
host    replication postgres  ${PEER_IP}/32  scram-sha-256
EOF

sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

The `pg_reload_conf()` call is a hot reload — no service restart needed for pg_hba changes.

Verify:

```bash
sudo -u postgres psql -c "
  SELECT type, database, user_name, address, auth_method
    FROM pg_hba_file_rules
   WHERE address IS NOT NULL
   ORDER BY line_number;
"
```

Expect at least four `scram-sha-256` rows (two for `SELF_IP`, two for `PEER_IP`) on top of the image's default `host all all 127.0.0.1/32 scram-sha-256` / `::1/128` entries.

---

## Part 4: Create Databases and the pglogical Extension

Run this block **on both VMs** (identical commands).

```bash
sudo -u postgres psql <<'SQL'
CREATE DATABASE apim_db;
CREATE DATABASE shared_db;
SQL

sudo -u postgres psql -d apim_db   -c "CREATE EXTENSION IF NOT EXISTS pglogical;"
sudo -u postgres psql -d shared_db -c "CREATE EXTENSION IF NOT EXISTS pglogical;"
```

Verify the extension is present in each database:

```bash
for db in apim_db shared_db; do
  sudo -u postgres psql -d $db \
    -c "SELECT extname, extversion FROM pg_extension WHERE extname='pglogical';"
done
```

Expect one row per database per VM (4 total across both DCs) with `extname = pglogical`.

---

## Part 5: Load DC-Specific Schema Packs

Use the pre-generated scripts under `dbscripts/dc1/Postgresql/` (on DC1) and `dbscripts/dc2/Postgresql/` (on DC2). These are the same packs referenced by `POSTGRES_PGLOGICAL_GUIDE.md` §Step 5 — sequences and `DCID` defaults are already DC-customized, do not edit them.

| | DC1 | DC2 |
|--|-----|-----|
| Sequences | `START 1 INCREMENT 2` | `START 2 INCREMENT 2` |
| DCID default (`IDN_OAUTH2_ACCESS_TOKEN`) | `'DC1'` | `'DC2'` |

DC1 therefore generates IDs 1,3,5,7… and DC2 generates 2,4,6,8…, avoiding PK collisions on independently-issued inserts — the same fix the earlier pgsql multi-DC run landed on after hitting `duplicate key value violates unique constraint "pk_reg_resource"`.

The repo files live under `azureuser`'s home (`~/helm-apim-4.7`), which the `postgres` OS user can't read directly. Streaming the scripts through stdin sidesteps the permission issue without having to copy or chmod anything:

**DC1 VM** (inside `~/helm-apim-4.7`):

```bash
cd ~/helm-apim-4.7

cat dbscripts/dc1/Postgresql/tables.sql        | sudo -u postgres psql -d shared_db
cat dbscripts/dc1/Postgresql/apimgt/tables.sql | sudo -u postgres psql -d apim_db
```

**DC2 VM** — same commands with `dc1/` replaced by `dc2/`:

```bash
cd ~/helm-apim-4.7

cat dbscripts/dc2/Postgresql/tables.sql        | sudo -u postgres psql -d shared_db
cat dbscripts/dc2/Postgresql/apimgt/tables.sql | sudo -u postgres psql -d apim_db
```

Verify the `DCID` default landed on the right DC:

```bash
sudo -u postgres psql -d apim_db -c "
  SELECT column_default
    FROM information_schema.columns
   WHERE table_name='idn_oauth2_access_token' AND column_name='dcid';
"
# expect 'DC1' on DC1 VM, 'DC2' on DC2 VM
```

---

## Part 6: Create pglogical Nodes

Each database on each VM needs a pglogical node. A node represents this database instance in the replication topology. Four nodes in total (two per VM).

> **pglogical objects are database-scoped.** Nodes (§Part 6), replication set memberships (§Part 7), and subscriptions (§Part 8) all live inside a single database — they don't span the PG cluster. Every block below uses `psql -d <db>` to pin the target database explicitly. If you accidentally run a `create_node` or `create_subscription` without the right `-d`, it lands in the `postgres` maintenance DB and the real `apim_db` / `shared_db` wiring silently stays empty. The same pitfall bit the earlier pgsql run.

### DC1 — apim_db

```bash
sudo -u postgres psql -d apim_db <<'SQL'
SELECT pglogical.create_node(
    node_name := 'dc1-apim',
    dsn := 'host=10.2.4.4 port=5432 dbname=apim_db user=postgres password=Apim@123'
);
SQL
```

### DC1 — shared_db

```bash
sudo -u postgres psql -d shared_db <<'SQL'
SELECT pglogical.create_node(
    node_name := 'dc1-shared',
    dsn := 'host=10.2.4.4 port=5432 dbname=shared_db user=postgres password=Apim@123'
);
SQL
```

### DC2 — apim_db

```bash
sudo -u postgres psql -d apim_db <<'SQL'
SELECT pglogical.create_node(
    node_name := 'dc2-apim',
    dsn := 'host=10.1.4.4 port=5432 dbname=apim_db user=postgres password=Apim@123'
);
SQL
```

### DC2 — shared_db

```bash
sudo -u postgres psql -d shared_db <<'SQL'
SELECT pglogical.create_node(
    node_name := 'dc2-shared',
    dsn := 'host=10.1.4.4 port=5432 dbname=shared_db user=postgres password=Apim@123'
);
SQL
```

> **DSN is the node's self-description.** Each node's DSN points at itself (`host` = the VM the command is run on). Subscribers in §Part 8 will use a copy of this DSN to reach the node.

---

## Part 7: Add Tables to the Default Replication Set

On **all four databases** (both DBs on both VMs):

```bash
sudo -u postgres psql -d apim_db \
  -c "SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);"

sudo -u postgres psql -d shared_db \
  -c "SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);"
```

This adds every table in the `public` schema to the default replication set. All WSO2 APIM tables have primary keys, which is the only requirement pglogical enforces at add time.

---

## Part 8: Create Bi-Directional Subscriptions

Each subscription pulls from the opposite DC for the same database. `synchronize_data := false` because both databases were freshly created with identical schemas and no data in §Part 5; `forward_origins := '{}'` prevents the replication loop that would otherwise ship rows back to their origin.

### 8a. DC2 subscribes to DC1

**On the DC2 VM**, `apim_db` subscribes to DC1's `apim_db`:

```bash
sudo -u postgres psql -d apim_db <<'SQL'
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=10.2.4.4 port=5432 dbname=apim_db user=postgres password=Apim@123',
    synchronize_data := false,
    forward_origins := '{}'
);
SQL
```

**On the DC2 VM**, `shared_db` subscribes to DC1's `shared_db`:

```bash
sudo -u postgres psql -d shared_db <<'SQL'
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=10.2.4.4 port=5432 dbname=shared_db user=postgres password=Apim@123',
    synchronize_data := false,
    forward_origins := '{}'
);
SQL
```

### 8b. DC1 subscribes to DC2 (reverse direction)

**On the DC1 VM**, `apim_db` subscribes to DC2's `apim_db`:

```bash
sudo -u postgres psql -d apim_db <<'SQL'
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=10.1.4.4 port=5432 dbname=apim_db user=postgres password=Apim@123',
    synchronize_data := false,
    forward_origins := '{}'
);
SQL
```

**On the DC1 VM**, `shared_db` subscribes to DC2's `shared_db`:

```bash
sudo -u postgres psql -d shared_db <<'SQL'
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=10.1.4.4 port=5432 dbname=shared_db user=postgres password=Apim@123',
    synchronize_data := false,
    forward_origins := '{}'
);
SQL
```

> `synchronize_data := false` is safe here because §Part 5 loaded identical schemas on both sides with no data. If you ever need to bootstrap a non-empty DC from scratch, use `pg_dump` + `pg_restore` first, then create the subscription with `synchronize_data := false` on top. Setting `synchronize_data := true` against an already-populated target can wedge pglogical in an unrecoverable state — the same failure mode called out in the Flexible Server guide applies to self-hosted PG.

---

## Part 9: Verify Replication Status

**On each VM**, in each database:

```bash
sudo -u postgres psql -d apim_db \
  -c "SELECT subscription_name, status FROM pglogical.show_subscription_status();"

sudo -u postgres psql -d shared_db \
  -c "SELECT subscription_name, status FROM pglogical.show_subscription_status();"
```

Expected — each VM should show one subscription per database in `replicating` state:

```
 subscription_name |   status
-------------------+-------------
 dc1_sub_apim      | replicating   <- on DC1 VM, apim_db
 dc1_sub_shared    | replicating   <- on DC1 VM, shared_db
 dc2_sub_apim      | replicating   <- on DC2 VM, apim_db
 dc2_sub_shared    | replicating   <- on DC2 VM, shared_db
```

Check the replication slots backing these subscriptions (on both VMs):

```bash
sudo -u postgres psql \
  -c "SELECT slot_name, database, active FROM pg_replication_slots;"
```

Expect two `active = t` rows per VM (one per subscription).

---

## Part 10: Round-Trip Replication Test

Insert a row on one DC and confirm it appears on the other within seconds. Then do the same in the reverse direction.

### DC1 → DC2 on apim_db

On **DC1 VM**:

```bash
sudo -u postgres psql -d apim_db <<'SQL'
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (999, 'test-dc1-replication', 'admin-dashboard');
SQL
```

Wait ~3 seconds, then on **DC2 VM**:

```bash
sudo -u postgres psql -d apim_db \
  -c "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;"
```

Expect the inserted row to show up with `ALERT_TYPE_ID = 999`.

### DC2 → DC1 on apim_db

On **DC2 VM**:

```bash
sudo -u postgres psql -d apim_db <<'SQL'
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (998, 'test-dc2-replication', 'admin-dashboard');
SQL
```

On **DC1 VM**:

```bash
sudo -u postgres psql -d apim_db \
  -c "SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998;"
```

### Cleanup

On either DC — the DELETE itself replicates:

```bash
sudo -u postgres psql -d apim_db \
  -c "DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999);"
```

Then re-run the two `SELECT`s above on the other VM — both should return zero rows.

If any of the selects comes back empty within ~10 seconds of the insert, investigate in this order:
1. `pglogical.show_subscription_status()` on the *target* DB — status should still be `replicating`.
2. `pg_replication_slots.active` on the *source* DB — should be `t`. If `f`, the subscription has disconnected (usually a networking or auth issue).
3. `sudo journalctl -u postgresql@17-main -n 200 --no-pager` on both VMs for pglogical worker errors (look for `background worker "pglogical apply"` log lines).

---

## Part 11: Troubleshooting & Operations

### Service-level

```bash
# Live log tail (pglogical workers + PG server logs land in journald)
sudo journalctl -u postgresql@17-main -f

# Restart after a transient issue — subscriptions resume automatically
sudo systemctl restart postgresql@17-main

# Status
sudo systemctl status postgresql@17-main --no-pager

# Reload config only (no restart — picks up pg_hba and most postgresql.conf edits)
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

### pglogical state introspection

```bash
sudo -u postgres psql -d apim_db <<'SQL'
SELECT * FROM pglogical.local_node;
SELECT * FROM pglogical.subscription;
SELECT subscription_name, status FROM pglogical.show_subscription_status();
SQL
```

### Replication lag

```bash
sudo -u postgres psql -c "
  SELECT slot_name,
         confirmed_flush_lsn,
         pg_current_wal_lsn(),
         pg_current_wal_lsn() - confirmed_flush_lsn AS lag_bytes
    FROM pg_replication_slots;
"
```

Healthy steady state is `lag_bytes` in single-digit KB or zero. Multi-MB growth that doesn't drain back to zero means the subscriber has disconnected.

### Stuck subscription — drop and recreate

If a subscription gets into a wedged state and re-running it cleanly is faster than diagnosing it:

```bash
# On the subscriber DC, in the affected database:
sudo -u postgres psql -d apim_db \
  -c "SELECT pglogical.drop_subscription('dc2_sub_apim');"

# Then re-run the matching CREATE SUBSCRIPTION from §Part 8.
```

### Hard reset (data loss)

If you want to start over from an empty cluster (e.g. to rerun the guide end-to-end cleanly):

```bash
sudo systemctl stop postgresql@17-main
sudo apt-get purge -y postgresql-17 postgresql-17-pglogical
sudo rm -rf /etc/postgresql/17 /var/lib/postgresql/17
# Then re-run §Part 2 → §Part 8 on this VM.
```

If you hard-reset only one of the two VMs, the surviving VM's subscription will abend because its provider DSN now points at a node that doesn't exist. Drop and recreate that subscription too after the rebuild.

### Pointing APIM pods at this stack

The matching Helm values files (new `azure-values-dc{1,2}-pg.yaml` that point JDBC URLs at `10.2.4.4` and `10.1.4.4` instead of the Flexible Server hostnames and drop `?sslmode=require`) are out of scope for this guide — the user will request those as a follow-up task once the VMs' IPs are fixed.

---

## Summary of Operations

| Step | DC1 VM (East US 1) | DC2 VM (West US 2) |
|------|-------------------|-------------------|
| Part 1 — NSG rule | `AllowPostgres5432` inbound | `AllowPostgres5432` inbound |
| Part 2 — Install + tune | `apt install postgresql-17 postgresql-17-pglogical`, `ALTER SYSTEM SET ...`, restart | Same |
| Part 3 — pg_hba | Allow `10.2.4.4` (self) + `10.1.4.4` (peer) for `all` + `replication` | Allow `10.1.4.4` (self) + `10.2.4.4` (peer) for `all` + `replication` |
| Part 4 — DBs + extension | `apim_db`, `shared_db` + `pglogical` | Same |
| Part 5 — Schema pack | `dbscripts/dc1/Postgresql/` | `dbscripts/dc2/Postgresql/` |
| Part 6 — Nodes | `dc1-apim`, `dc1-shared` | `dc2-apim`, `dc2-shared` |
| Part 7 — Replication set | `replication_set_add_all_tables` on both DBs | Same |
| Part 8 — Subscriptions | `dc1_sub_apim`, `dc1_sub_shared` (to DC2) | `dc2_sub_apim`, `dc2_sub_shared` (to DC1) |
| Part 9 — Verify | All four subs `replicating` | All four subs `replicating` |
| Part 10 — Round-trip | Insert on DC1, see it on DC2 | Insert on DC2, see it on DC1 |
