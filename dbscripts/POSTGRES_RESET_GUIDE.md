# Database Teardown & Recreation Guide

Reset the `apim_db` and `shared_db` databases on both DCs to a clean state with pglogical bi-directional replication.

**Prerequisites:**
- APIM pods scaled down on both DCs before starting
- `psql` client available
- Database passwords available

## Connection Setup

```bash
# DC1 — East US 1
export DC1_HOST=apim-4-7-eus1.postgres.database.azure.com
export DC1_USER=apimadmineast
export DC1_PORT=5432
export DC1_PASS="{your-password}"

# DC2 — West US 2
export DC2_HOST=apim-4-7-wus2.postgres.database.azure.com
export DC2_USER=apimadminwest
export DC2_PORT=5432
export DC2_PASS="{your-password}"
```

---

## Phase 1: Teardown

### 1.1 Drop subscriptions on DC2

```bash
psql "host=$DC2_HOST port=$DC2_PORT user=$DC2_USER dbname=apim_db password=$DC2_PASS sslmode=require"
```

```sql
-- Check existing subscriptions
SELECT subscription_name, status FROM pglogical.show_subscription_status();

-- Drop them
SELECT pglogical.drop_subscription('dc2_sub_apim');
\q
```

```bash
psql "host=$DC2_HOST port=$DC2_PORT user=$DC2_USER dbname=shared_db password=$DC2_PASS sslmode=require"
```

```sql
SELECT pglogical.drop_subscription('dc2_sub_shared');
\q
```

### 1.2 Drop subscriptions on DC1

```bash
psql "host=$DC1_HOST port=$DC1_PORT user=$DC1_USER dbname=apim_db password=$DC1_PASS sslmode=require"
```

```sql
SELECT subscription_name, status FROM pglogical.show_subscription_status();

SELECT pglogical.drop_subscription('dc1_sub_apim');
\q
```

```bash
psql "host=$DC1_HOST port=$DC1_PORT user=$DC1_USER dbname=shared_db password=$DC1_PASS sslmode=require"
```

```sql
SELECT pglogical.drop_subscription('dc1_sub_shared');
\q
```

> **Note:** If subscription names differ (hyphens vs underscores), use the names shown by `show_subscription_status()`.

### 1.3 Drop databases on both DCs

Connect to the default `postgres` database to drop the others. Use `WITH (FORCE)` to automatically terminate any remaining connections (including Azure internal processes that can't be terminated manually).

**DC1:**
```bash
psql "host=$DC1_HOST port=$DC1_PORT user=$DC1_USER dbname=postgres password=$DC1_PASS sslmode=require"
```

```sql
DROP DATABASE IF EXISTS apim_db WITH (FORCE);
DROP DATABASE IF EXISTS shared_db WITH (FORCE);
\q
```

**DC2:**
```bash
psql "host=$DC2_HOST port=$DC2_PORT user=$DC2_USER dbname=postgres password=$DC2_PASS sslmode=require"
```

```sql
DROP DATABASE IF EXISTS apim_db WITH (FORCE);
DROP DATABASE IF EXISTS shared_db WITH (FORCE);
\q
```

### 1.4 Clean up stale replication slots (if any)

On **both** DCs, connected to `postgres`:

```sql
-- Check for leftover slots
SELECT slot_name, active FROM pg_replication_slots;

-- Drop any stale ones
SELECT pg_drop_replication_slot('slot_name_here');
```

---

## Phase 2: Recreate Databases & Replication

Follow [POSTGRES_PGLOGICAL_GUIDE.md](POSTGRES_PGLOGICAL_GUIDE.md) from **Step 3** onwards:

- **Step 3** — Create `apim_db` and `shared_db` on both DCs
- **Step 4** — Create pglogical extension in all 4 databases
- **Step 5** — Run DC-specific table scripts (`dc1/` and `dc2/`)
- **Step 6** — Create pglogical nodes
- **Step 7** — Add tables to replication sets
- **Step 8** — Create bi-directional subscriptions
- **Step 9** — Verify all subscriptions show `replicating`

> Steps 1-2 (server parameters and replication privileges) don't need to be repeated — they're server-level settings that survive database drops.

---

## Phase 3: Restart APIM

Scale APIM pods back up on both DCs. The first startup on fresh databases will initialize the default data (admin user, default policies, etc.).

### Quick replication test

After APIM starts on DC1, verify the admin user replicated to DC2:

```bash
psql "host=$DC2_HOST port=$DC2_PORT user=$DC2_USER dbname=shared_db password=$DC2_PASS sslmode=require" \
  -c "SELECT UM_USER_NAME FROM UM_USER LIMIT 5;"
```

You should see the `admin` user (created by DC1's first startup) appear on DC2.

---

## Troubleshooting

### "database is being accessed by other users"

Use `DROP DATABASE ... WITH (FORCE)` as shown in Step 1.3 above. If that still fails, try terminating non-Azure connections first:
```sql
SELECT pg_terminate_backend(pid) FROM pg_stat_activity
WHERE datname IN ('apim_db', 'shared_db') AND pid <> pg_backend_pid() AND usename NOT LIKE 'azure%';
```

### Subscription stuck / not replicating

```sql
-- Check status
SELECT * FROM pglogical.show_subscription_status();

-- Check replication slots on the provider
SELECT slot_name, active FROM pg_replication_slots;

-- Drop and recreate the subscription
SELECT pglogical.drop_subscription('subscription_name_here');
-- Then re-run the CREATE SUBSCRIPTION command
```

### Stale replication slots after dropping databases

If `DROP DATABASE` fails because of active replication slots:
```sql
-- Connected to postgres
SELECT slot_name, active, database FROM pg_replication_slots;
SELECT pg_drop_replication_slot('slot_name_here');
```
