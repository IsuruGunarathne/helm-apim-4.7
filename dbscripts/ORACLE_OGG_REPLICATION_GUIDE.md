# Bi-Directional Replication with Oracle GoldenGate Free — Oracle 23ai on Azure Ubuntu VMs

Set up Oracle 23ai Free bi-directional replication between two Azure data centers for WSO2 API Manager 4.7 multi-DC deployment, using **Oracle Container Registry images** (Database 23ai Free + GoldenGate Free 23ai) on **Ubuntu VMs**.

The GoldenGate Free container is colocated on the DC1 VM and runs both Extract and Replicat pipelines from there against both DB containers over the peered VNet. Splitting it onto a dedicated third VM is possible but optional.

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│  Oracle subnet (x.x.4.0/24)  │          │  Oracle subnet (x.x.4.0/24)  │
│                               │          │                               │
│  ┌─────────────────────────┐  │          │  ┌─────────────────────────┐  │
│  │ apim-4-7-eus1-oracle    │  │          │  │ apim-4-7-wus2-oracle    │  │
│  │ (Ubuntu 22.04 LTS)      │  │          │  │ (Ubuntu 22.04 LTS)      │  │
│  │                          │  │          │  │                          │  │
│  │  oracle-db container:    │  │          │  │  oracle-db container:    │  │
│  │   apim_db + shared_db    │  │  VNet    │  │   apim_db + shared_db    │  │
│  │   Sequences 1,3,5,7...   │◄─┼──Peering─┼──►  Sequences 2,4,6,8...   │  │
│  │   DCID: DC1              │  │          │  │   DCID: DC2              │  │
│  │                          │  │          │  │                          │  │
│  │  ogg-hub container:      │  │          │  │  IP: 10.1.4.4            │  │
│  │   Active-Active pipelines│  │          │  └─────────────────────────┘  │
│  │   (apim-db, shared-db)   │  │          │                               │
│  │                          │  │          │                               │
│  │ IP: 10.2.4.4             │  │          │                               │
│  └─────────────────────────┘  │          │                               │
│                               │          │                               │
│  Jump-box VM (x.x.1.0/24)     │          │  Jump-box VM (x.x.1.0/24)     │
└──────────────────────────────┘          └──────────────────────────────┘
```

**GoldenGate processes on the OGG Free hub** (GG Free 23.26 has no "Pipelines" abstraction — Extracts and Replicats are built directly in Administration Service):

- **4 Integrated Extracts** — one per source PDB — capturing `APIMADMIN.*` to local trail files `aa` (DC1 apim), `ab` (DC2 apim), `ba` (DC1 shared), `bb` (DC2 shared).
- **4 Parallel Nonintegrated Replicats** — one per target PDB — each reading the *opposite* DC's trail for the same DB and applying via the dedicated `ggadmin` user.
- **Loopback prevention**: Extracts use `TRANLOGOPTIONS EXCLUDEUSER ggadmin`, so rows that Replicat applies on the far side are filtered out when Extract re-captures them.
- **Trail naming**: first letter = DB (`a` = apim, `b` = shared), second letter = source DC (`a` = DC1, `b` = DC2). So trail `ab` = "apim from DC2".

## Connection Details

```bash
# DC1 — East US 1 (Oracle DB + OGG on the same VM)
export DC1_HOST=10.2.4.4
export DC1_PORT=1521
export DC1_USER=apimadmin
export DC1_PASS="Apim@123"

# DC2 — West US 2 (Oracle DB only)
export DC2_HOST=10.1.4.4
export DC2_PORT=1521
export DC2_USER=apimadmin
export DC2_PASS="Apim@123"

# GoldenGate Free web UI (served from the ogg-hub container on the DC1 VM)
export OGG_HOST=10.2.4.4
export OGG_UI_PORT=9011   # insecure mode — see §5.1
```

> **Password placeholder**: `Apim@123` is used throughout as a copy-paste-friendly default. Replace it with a strong password for any non-lab deployment, and keep it in sync across the `-e ORACLE_PWD=...` env var, PDB admin users, the `apimadmin` grants, and the Helm values files under `distributed/*/azure-values-dc*-oracle.yaml`.

---

## Part 1: Azure VM Provisioning

### 1.1 Create VMs

Two Ubuntu 22.04 LTS VMs — DC1 colocates the DB and OGG containers, DC2 runs only the DB container.

```bash
RG="rg-WSO2-APIM-4.7.0-release-isuruguna"

# Find existing VNet names
DC1_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='eastus']" -o tsv --query "[0].name")
DC2_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='westus2']" -o tsv --query "[0].name")

# DC1 — Oracle DB + OGG VM (East US 1, Oracle subnet)
az vm create \
  --resource-group $RG \
  --name apim-4-7-eus1-oracle \
  --location eastus \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
  --size Standard_D4s_v5 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $DC1_VNET_NAME \
  --subnet oracle-subnet \
  --public-ip-address "" \
  --os-disk-size-gb 128

# DC2 — Oracle DB VM (West US 2, Oracle subnet)
az vm create \
  --resource-group $RG \
  --name apim-4-7-wus2-oracle \
  --location westus2 \
  --image Canonical:0001-com-ubuntu-server-jammy:22_04-lts-gen2:latest \
  --size Standard_D2s_v5 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $DC2_VNET_NAME \
  --subnet oracle-subnet \
  --public-ip-address "" \
  --os-disk-size-gb 128
```

**VM sizing rationale:**
- DC1 is sized larger (4 vCPU / 16 GB RAM) because it runs both the DB container and the OGG container.
- DC2 is smaller (2 vCPU / 8 GB RAM) because it only runs a DB container.
- 128 GB OS disk is enough for the stock images plus Docker volumes in a lab. If you want extra headroom for archive logs or image caches, attach and mount a data disk and point `/var/lib/docker` at it — that's purely optional and not covered here.

> **Dedicated OGG hub (optional)**: If you prefer the OGG Free container on its own VM, provision a third small Ubuntu VM in `eastus` on `oracle-subnet` (same shape, 2 vCPU / 8 GB) and run only the `docker run …/goldengate-oracle-free` command from Part 5 there. The DB containers in Parts 3–4 stay unchanged. No extra NSG rule is needed — the web UI is reached over an SSH tunnel (port 22), which is already open.

### 1.2 NSG Rules

Azure NSGs allow all outbound traffic by default, so we only need inbound rules.

```bash
# Helper: look up the NSG attached to a VM's NIC
get_nsg() {
  az vm show -g "$RG" -n "$1" --query "networkProfile.networkInterfaces[0].id" -o tsv \
    | xargs az network nic show --ids \
    | jq -r '.networkSecurityGroup.id' \
    | xargs az network nsg show --ids \
    | jq -r '.name'
}
```

**DC1 VM — inbound 1521 only:**
```bash
DC1_NSG=$(get_nsg apim-4-7-eus1-oracle)

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC1_NSG \
  --name AllowOracle1521 \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 1521 \
  --source-address-prefixes VirtualNetwork
```

> **No rule needed for the OGG Free web UI (9011).** The web UI is reached from your laptop via an SSH tunnel (see §5.3), which rides port 22 — already open on Azure's default SSH rule. Don't open 9011 on the NSG: it would expose the insecure-mode Service Manager's HTTP listener to the VNet.

**DC2 VM — inbound 1521 only:**
```bash
DC2_NSG=$(get_nsg apim-4-7-wus2-oracle)

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC2_NSG \
  --name AllowOracle1521 \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 1521 \
  --source-address-prefixes VirtualNetwork
```

### 1.3 VNet Peering

If the two VNets aren't already peered, run this once. Skip if `az network vnet peering list` already shows bidirectional `Connected` entries between the two VNets.

```bash
DC1_VNET_ID=$(az network vnet show -g $RG -n $DC1_VNET_NAME --query id -o tsv)
DC2_VNET_ID=$(az network vnet show -g $RG -n $DC2_VNET_NAME --query id -o tsv)

az network vnet peering create \
  --resource-group $RG \
  --name eus1-to-wus2 \
  --vnet-name $DC1_VNET_NAME \
  --remote-vnet $DC2_VNET_ID \
  --allow-vnet-access

az network vnet peering create \
  --resource-group $RG \
  --name wus2-to-eus1 \
  --vnet-name $DC2_VNET_NAME \
  --remote-vnet $DC1_VNET_ID \
  --allow-vnet-access
```

---

## Part 2: Install Docker and Pull Oracle Container Registry Images

Run this on **both** VMs as `azureuser` (via the jump-box).

### 2.1 Install Docker

```bash
sudo apt-get update
sudo apt-get install -y docker.io
sudo systemctl enable --now docker

# Allow azureuser to run docker without sudo
sudo usermod -aG docker azureuser

# Log out and reconnect so the new group membership takes effect
exit
```

Reconnect and verify:

```bash
docker version
docker info | grep -i storage
```

### 2.2 Accept Oracle Container Registry Terms (one-time, manual)

Oracle images require an Oracle SSO account and explicit acceptance of each image's license in a browser. There is no CLI workaround for this step — it has to be done once per Oracle account.

1. Open <https://container-registry.oracle.com> in a browser and sign in with your Oracle SSO account.
2. Browse to **Database → free** and click **Continue** to accept the license terms.
3. Browse to **GoldenGate → goldengate-oracle-free** and click **Continue** to accept the license terms. (This is the Oracle-targeted variant under Oracle Free Use Terms — do not confuse it with `goldengate-oracle`, which requires the paid Oracle Standard Terms.)

### 2.3 Log in and pull images

On **both** VMs:

```bash
docker login container-registry.oracle.com
# Username: <your-oracle-sso-email>
# Password: <your-oracle-sso-password>

docker pull container-registry.oracle.com/database/free:latest
```

On **DC1 only** (where the OGG hub container will run):

```bash
docker pull container-registry.oracle.com/goldengate/goldengate-oracle-free:latest
```

The DB image is ~9 GB and the OGG image is ~2 GB, so the pulls take several minutes.

---

## Part 3: Start the Oracle DB Containers

Run this on **both** VMs. The container exposes a single-instance Oracle 23ai Free CDB named `FREE` with a default PDB named `FREEPDB1`. We're going to ignore `FREEPDB1` and create `apim_db` and `shared_db` PDBs on top in Part 4.

### 3.1 Start the container

```bash
docker volume create oracle-db-data

docker run -d \
  --name oracle-db \
  --network host \
  --restart unless-stopped \
  -e ORACLE_PWD=Apim@123 \
  -v oracle-db-data:/opt/oracle/oradata \
  container-registry.oracle.com/database/free:latest
```

Notes on the flags:
- `--network host` binds the container directly to the VM's private IP on port 1521. This keeps the OGG Free container (on DC1) reachable to both DBs over the peered VNet without Docker bridge gymnastics.
- `-e ORACLE_PWD=Apim@123` sets the SYS, SYSTEM, and PDBADMIN passwords in one shot.
- The named volume `oracle-db-data` persists datafiles across container restarts.

### 3.2 Wait for the database to be ready

First-boot is slow (5–10 minutes) because Oracle is creating the CDB and PDB datafiles inside the named volume.

```bash
docker logs -f oracle-db
```

Wait until you see:

```
#########################
DATABASE IS READY TO USE!
#########################
```

Then Ctrl-C out of the `logs -f`. On subsequent container restarts the database comes up in under a minute.

### 3.3 Connect to the CDB as SYSDBA

From the VM host:

```bash
# Via OS-auth inside the container (simplest)
docker exec -it oracle-db sqlplus / as sysdba

# Or via listener auth
docker exec -it oracle-db sqlplus 'sys/"Apim@123"@FREE' as sysdba
```

Sanity check:

```sql
SHOW CON_NAME;                      -- expect CDB$ROOT
SELECT NAME, OPEN_MODE FROM V$PDBS; -- expect PDB$SEED + FREEPDB1
EXIT;
```

---

## Part 4: Create PDBs, Enable GoldenGate Prerequisites, Load APIM Schemas

### 4.1 Create PDBs and the `apimadmin` app user

Run this **on both DC1 and DC2** (identical commands). The PDB names and schema owner are unified across DCs so the Helm values files and the GG Free Active-Active recipe don't need any schema-rename mapping.

```bash
docker exec -it oracle-db sqlplus / as sysdba
```

```sql
-- Create the two PDBs with admin user PDBADMIN (auto-created)
CREATE PLUGGABLE DATABASE apim_db
  ADMIN USER pdbadmin IDENTIFIED BY "Apim@123"
  FILE_NAME_CONVERT = ('pdbseed', 'apim_db');

CREATE PLUGGABLE DATABASE shared_db
  ADMIN USER pdbadmin IDENTIFIED BY "Apim@123"
  FILE_NAME_CONVERT = ('pdbseed', 'shared_db');

ALTER PLUGGABLE DATABASE apim_db   OPEN;
ALTER PLUGGABLE DATABASE shared_db OPEN;
ALTER PLUGGABLE DATABASE apim_db   SAVE STATE;
ALTER PLUGGABLE DATABASE shared_db SAVE STATE;

SELECT NAME, OPEN_MODE FROM V$PDBS;   -- expect APIM_DB + SHARED_DB OPEN READ WRITE
```

Create the APIM schema owner (`apimadmin`) in each PDB and grant it enough privileges to run the WSO2 schema scripts:

```sql
ALTER SESSION SET CONTAINER = apim_db;
CREATE USER apimadmin IDENTIFIED BY "Apim@123";
GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE TO apimadmin;

ALTER SESSION SET CONTAINER = shared_db;
CREATE USER apimadmin IDENTIFIED BY "Apim@123";
GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE TO apimadmin;

ALTER SESSION SET CONTAINER = CDB$ROOT;
```

> **Why `DBA` on an app user?** This is a lab shortcut — it lets the WSO2 schema scripts create objects without chasing individual system privileges. For production, grant the narrower privilege set documented in the WSO2 installation guide.

### 4.2 Enable archive log mode, supplemental logging, and GoldenGate replication

These are CDB-level settings required by GoldenGate. Run **on both DC1 and DC2**, still inside `sqlplus / as sysdba`:

> **Important:** these statements run against the **DB container** (the `docker exec -it oracle-db sqlplus / as sysdba` session from §4.1), not against the OGG container or OGG web UI. A prior implementer tried to run the archive-log sequence from the OGG side and it did not work — enabling archive logging has to happen on the database itself.

```sql
-- Enable archive log mode (required for Extract to mine redo)
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;

-- Force logging so unlogged operations still replicate
ALTER DATABASE FORCE LOGGING;

-- Minimum supplemental logging at the CDB level
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

-- Enable GoldenGate replication for the instance
ALTER SYSTEM SET ENABLE_GOLDENGATE_REPLICATION = TRUE SCOPE=BOTH;

-- Verify
SELECT LOG_MODE, FORCE_LOGGING, SUPPLEMENTAL_LOG_DATA_MIN FROM V$DATABASE;
SHOW PARAMETER ENABLE_GOLDENGATE_REPLICATION;
EXIT;
```

Expected: `LOG_MODE = ARCHIVELOG`, `FORCE_LOGGING = YES`, `SUPPLEMENTAL_LOG_DATA_MIN = YES`, `enable_goldengate_replication = TRUE`.

### 4.3 Load the APIM schemas from the pre-customized DC packs

The `dbscripts/dc1/Oracle/` and `dbscripts/dc2/Oracle/` directories already contain DC-customized copies of the WSO2 schema scripts — `DCID` defaults and sequence offsets (`START WITH 1 INCREMENT BY 2` on DC1, `START WITH 2 INCREMENT BY 2` on DC2) are already applied. **Do not re-edit them.**

On each VM, clone the repo and copy the correct per-DC pack into its DB container.

> **Why the funny quoting?** The password `Apim@123` contains an `@`, and sqlplus's Easy Connect parser treats the first `@` in `user/password@host/service` as the start of the host part. Wrapping the password in double quotes inside a single-quoted shell argument (`'apimadmin/"Apim@123"@localhost:1521/apim_db'`) tells sqlplus exactly where the password ends. Without the quotes you'll see `ORA-12262: Could not resolve hostname 123@localhost`.

**DC1 VM:**

```bash
cd ~
git clone <this-repo-url> helm-apim-4.7
cd helm-apim-4.7

# apim_db scripts
docker cp dbscripts/dc1/Oracle/apimgt/tables_23c.sql    oracle-db:/tmp/apim_tables.sql
docker cp dbscripts/dc1/Oracle/apimgt/sequences_23c.sql oracle-db:/tmp/apim_sequences.sql

# shared_db scripts
docker cp dbscripts/dc1/Oracle/tables_23c.sql           oracle-db:/tmp/shared_tables.sql
docker cp dbscripts/dc1/Oracle/sequences_23c.sql        oracle-db:/tmp/shared_sequences.sql

# Run them
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/apim_db'   @/tmp/apim_tables.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/apim_db'   @/tmp/apim_sequences.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/shared_db' @/tmp/shared_tables.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/shared_db' @/tmp/shared_sequences.sql
```

**DC2 VM:** same commands, but replace `dc1/Oracle` with `dc2/Oracle` in all four `docker cp` lines.

```bash
cd ~
git clone <this-repo-url> helm-apim-4.7
cd helm-apim-4.7

# apim_db scripts
docker cp dbscripts/dc2/Oracle/apimgt/tables_23c.sql    oracle-db:/tmp/apim_tables.sql
docker cp dbscripts/dc2/Oracle/apimgt/sequences_23c.sql oracle-db:/tmp/apim_sequences.sql

# shared_db scripts
docker cp dbscripts/dc2/Oracle/tables_23c.sql           oracle-db:/tmp/shared_tables.sql
docker cp dbscripts/dc2/Oracle/sequences_23c.sql        oracle-db:/tmp/shared_sequences.sql

# Run them
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/apim_db'   @/tmp/apim_tables.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/apim_db'   @/tmp/apim_sequences.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/shared_db' @/tmp/shared_tables.sql
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/shared_db' @/tmp/shared_sequences.sql
```

### 4.4 Verify the schemas loaded

On either VM:

```bash
docker exec -it oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/apim_db'
```

```sql
SELECT COUNT(*) FROM USER_TABLES;      -- expect a nonzero count
SELECT COUNT(*) FROM USER_SEQUENCES;   -- expect a nonzero count
SELECT DATA_DEFAULT FROM USER_TAB_COLUMNS
 WHERE TABLE_NAME='IDN_OAUTH2_ACCESS_TOKEN' AND COLUMN_NAME='DCID';
-- expect 'DC1' on DC1, 'DC2' on DC2
EXIT;
```

### 4.5 Sanity-check DB-to-DB reachability

From the **DC1** VM, confirm it can reach the DC2 DB over the peered VNet (OGG on DC1 will need this):

```bash
nc -zv 10.1.4.4 1521
# expect: Connection to 10.1.4.4 1521 port [tcp/*] succeeded!
```

And from the **DC2** VM, confirm reachability back:

```bash
nc -zv 10.2.4.4 1521
# expect: Connection to 10.2.4.4 1521 port [tcp/*] succeeded!
```

If either `nc` call fails, re-check the NSG rules in §1.2 and the VNet peering in §1.3 before continuing.

### 4.6 Create the `ggadmin` user and grant GoldenGate privileges

GoldenGate Free 23.26 needs a dedicated local user `ggadmin` inside every PDB — it's the user Replicat will connect as when applying rows, and it's the username Extract's `TRANLOGOPTIONS EXCLUDEUSER ggadmin` filters out to prevent loopback.

Prior Oracle GG docs tell you to provision `ggadmin` by calling the helper wrapper `dbms_goldengate_auth.grant_admin_privilege('GGADMIN')`. **That wrapper is disabled in GG Free 23.26** — any call fails with `ORA-26988: Cannot grant Oracle GoldenGate privileges. The procedure GRANT_ADMIN_PRIVILEGE is disabled`, even though `enable_goldengate_replication=TRUE` is set at the CDB level in §4.2 (and propagates to PDBs automatically). The workaround is to grant the required system and `EXECUTE` privileges directly.

A second thing: **`LOGMINING` is not included in the `DBA` role in 23ai**. Extract mines redo logs via LogMiner, so the user Extract connects as needs an explicit `GRANT LOGMINING`. In our setup Extract connects as `apimadmin` (via the `dc1_apim` / `dc2_apim` / `dc1_shared` / `dc2_shared` aliases we'll create in §6.1), so `apimadmin` needs `LOGMINING` on top of the `DBA` it already got in §4.1.

A third thing: **`apimadmin` also needs the built-in `OGG_CAPTURE` role** to be able to `REGISTER EXTRACT ... DATABASE` in §6.8. Without it, `REGISTER EXTRACT` fails with `OGG-02062 User apimadmin does not have the required privileges to use integrated capture`. The "normal" way to provision capture privileges is `DBMS_GOLDENGATE_ADM.GRANT_ADMIN_PRIVILEGE(..., privilege_type => 'CAPTURE')`, but in GG Free 23.26 that wrapper *also* silently fails to populate the view integrated capture checks (it's gated by the same `ORA-26988`-adjacent machinery that blocks `dbms_goldengate_auth.grant_admin_privilege`). Granting the `OGG_CAPTURE` role directly is the supported 23ai path and works without any wrapper. `SELECT ANY DICTIONARY` + `EXECUTE ON DBMS_XSTREAM_GG` are the two supporting privileges the role expects you to also grant explicitly.

Run this **on both DC1 and DC2**, inside `sqlplus / as sysdba`:

```bash
docker exec -it oracle-db sqlplus / as sysdba
```

```sql
-- =====================================================================
-- apim_db
-- =====================================================================
ALTER SESSION SET CONTAINER = apim_db;

-- ggadmin: dedicated GG user (Replicat target + EXCLUDEUSER filter)
CREATE USER ggadmin IDENTIFIED BY "Apim@123";
GRANT DBA                    TO ggadmin;
GRANT LOGMINING              TO ggadmin;
GRANT SELECT ANY TRANSACTION TO ggadmin;
GRANT EXECUTE ON DBMS_LOGMNR      TO ggadmin;
GRANT EXECUTE ON DBMS_LOGMNR_D    TO ggadmin;
GRANT EXECUTE ON DBMS_FLASHBACK   TO ggadmin;
GRANT EXECUTE ON DBMS_CAPTURE_ADM TO ggadmin;
GRANT EXECUTE ON DBMS_APPLY_ADM   TO ggadmin;
GRANT EXECUTE ON DBMS_STREAMS_ADM TO ggadmin;
GRANT EXECUTE ON DBMS_AQADM       TO ggadmin;

-- apimadmin: Extract control user — needs LOGMINING on top of the existing DBA role
GRANT LOGMINING              TO apimadmin;
GRANT SELECT ANY TRANSACTION TO apimadmin;
GRANT EXECUTE ON DBMS_LOGMNR      TO apimadmin;
GRANT EXECUTE ON DBMS_LOGMNR_D    TO apimadmin;
GRANT EXECUTE ON DBMS_FLASHBACK   TO apimadmin;
GRANT EXECUTE ON DBMS_CAPTURE_ADM TO apimadmin;
GRANT EXECUTE ON DBMS_APPLY_ADM   TO apimadmin;
GRANT EXECUTE ON DBMS_STREAMS_ADM TO apimadmin;
GRANT EXECUTE ON DBMS_AQADM       TO apimadmin;

-- apimadmin: OGG_CAPTURE role + supporting privileges for REGISTER EXTRACT (§6.8)
GRANT OGG_CAPTURE            TO apimadmin;
GRANT SELECT ANY DICTIONARY  TO apimadmin;
GRANT EXECUTE ON DBMS_XSTREAM_GG  TO apimadmin;

-- =====================================================================
-- shared_db — repeat the same block
-- =====================================================================
ALTER SESSION SET CONTAINER = shared_db;

CREATE USER ggadmin IDENTIFIED BY "Apim@123";
GRANT DBA                    TO ggadmin;
GRANT LOGMINING              TO ggadmin;
GRANT SELECT ANY TRANSACTION TO ggadmin;
GRANT EXECUTE ON DBMS_LOGMNR      TO ggadmin;
GRANT EXECUTE ON DBMS_LOGMNR_D    TO ggadmin;
GRANT EXECUTE ON DBMS_FLASHBACK   TO ggadmin;
GRANT EXECUTE ON DBMS_CAPTURE_ADM TO ggadmin;
GRANT EXECUTE ON DBMS_APPLY_ADM   TO ggadmin;
GRANT EXECUTE ON DBMS_STREAMS_ADM TO ggadmin;
GRANT EXECUTE ON DBMS_AQADM       TO ggadmin;

GRANT LOGMINING              TO apimadmin;
GRANT SELECT ANY TRANSACTION TO apimadmin;
GRANT EXECUTE ON DBMS_LOGMNR      TO apimadmin;
GRANT EXECUTE ON DBMS_LOGMNR_D    TO apimadmin;
GRANT EXECUTE ON DBMS_FLASHBACK   TO apimadmin;
GRANT EXECUTE ON DBMS_CAPTURE_ADM TO apimadmin;
GRANT EXECUTE ON DBMS_APPLY_ADM   TO apimadmin;
GRANT EXECUTE ON DBMS_STREAMS_ADM TO apimadmin;
GRANT EXECUTE ON DBMS_AQADM       TO apimadmin;

GRANT OGG_CAPTURE            TO apimadmin;
GRANT SELECT ANY DICTIONARY  TO apimadmin;
GRANT EXECUTE ON DBMS_XSTREAM_GG  TO apimadmin;

EXIT;
```

> **If you see `ORA-26988` on any `GRANT` line above**, you've accidentally called `dbms_goldengate_auth.grant_admin_privilege` instead of the direct `GRANT` statements — rerun the block exactly as written. No wrapper procedures.

Run the same block on the DC2 VM's `oracle-db` container. Both DCs must end with identical `ggadmin` credentials (same password) so that a single set of GoldenGate DB connections in the OGG hub can authenticate against both sides.

---

## Part 5: Start the OGG Free Container on DC1

Run this on the **DC1 VM only**.

### 5.1 Start the container

```bash
docker volume create ogg-hub-data

docker run -d \
  --name ogg-hub \
  --network host \
  --restart unless-stopped \
  -v ogg-hub-data:/u02 \
  container-registry.oracle.com/goldengate/goldengate-oracle-free:latest
```

> **Important:** mount the volume at **`/u02`**, not `/u01`. In the GG Free image, `/u01` is the binaries/system directory and `/u02` is the persistent deployment data directory — mounting on `/u01` will crash the init script.

> **Why not `OGG_SECURE_DEPLOYMENT=true`?** The current `goldengate-oracle-free:latest` image has a broken secure-deployment init path: on first boot it generates certs under `/u02/ssl/` but then crashes in `deployment-init.py → establish_secure_service_manager → reset_servicemanager_configuration` with `FileNotFoundError: '/u02/ServiceManager/var/lib/conf/ServiceManager-config.dat'` (ServiceManager hasn't been created yet), and every subsequent restart sees the half-written `/u02/ssl/server.pem` from the failed first boot and fails with `KeyError: 'OGG_SERVER_WALLET'`. Insecure mode works cleanly and is fine here — both DC VMs live on a private Azure VNet and the web UI is reached over an SSH tunnel, so there is no plaintext traffic on the public internet.

### 5.2 Get the initial admin password

The container generates a random password for the web UI admin user on first boot and prints it into the startup logs:

```bash
docker logs ogg-hub 2>&1 | grep -i "password"
```

Copy the printed password — you'll need it for the first login.

### 5.3 Reach the web UI via SSH tunnel

In insecure mode the Service Manager listens on HTTP port **9011** inside the container. Because of `--network host`, it's bound directly to the DC1 VM's network stack, so `localhost:9011` on the DC1 VM itself *is* the Service Manager UI.

Service Manager is only the entry point — once you click into the `Local` deployment and then into **Administration Service**, **Distribution Service**, **Receiver Service**, or **Performance Metrics Service**, the browser is redirected to *different* ports on the same host: **9012** (Administration), **9013** (Distribution), **9014** (Receiver), **9015** (Performance Metrics). Each of those services has its own embedded web server. If the SSH tunnel only covers 9011, those sub-pages will fail with connection-refused as soon as you click them.

To avoid re-tunneling mid-session, forward the full range up front:

**If the DC1 VM has a public IP** (the simple case — just SSH straight in and forward):

```bash
# From your laptop
ssh -i ./keys/apim-4-7-eus1-oracle_key_0410.pem \
  -L 8011:localhost:9011 \
  -L 9012:localhost:9012 \
  -L 9013:localhost:9013 \
  -L 9014:localhost:9014 \
  -L 9015:localhost:9015 \
  azureuser@<DC1-public-ip>
```

**If the DC1 VM has no public IP** (jump-box hop, which is what `az vm create --public-ip-address ""` in §1.1 leaves you with):

```bash
# From your laptop
ssh \
  -L 8011:10.2.4.4:9011 \
  -L 9012:10.2.4.4:9012 \
  -L 9013:10.2.4.4:9013 \
  -L 9014:10.2.4.4:9014 \
  -L 9015:10.2.4.4:9015 \
  azureuser@<jump-box-public-ip>
```

Note the asymmetric mapping: Service Manager is reached at `localhost:8011` (remapped, because your laptop may already have something on 9011), but the service sub-pages are forwarded `localhost:901x → remote:901x` using the *same* port numbers. The reason is that when Service Manager redirects the browser to a service, it emits an absolute URL like `http://<host>:9012/…`, and your browser will hit your laptop's 9012. If you remap those to different local ports you'd also have to rewrite the internal redirects, which isn't worth the hassle — just make sure 9012–9015 are free on your laptop.

Open <http://localhost:8011/> in a browser (HTTP, not HTTPS), log in as `oggadmin` with the password from §5.2, and the UI will force a password change on first login.

### 5.4 Navigate into the deployment

After the password change, you land on Service Manager's home. The pipelines, connections, and recipes don't live here — they live inside a **deployment**, and the GG Free container auto-creates one named **`Local`** on first boot. To reach it:

1. In the left nav, expand **Deployments** and click **Local**. A **Services** table appears with four rows — **Administration Service**, **Distribution Service**, **Receiver Service**, **Performance Metrics Service** — all in **Running** status.
2. Click **Administration Service**. The browser redirects to `http://localhost:9012/…` (that's why §5.3 forwards 9012). This is where connections, extracts, replicats, and the Active-Active recipe live.
3. The version banner will read something like `Oracle GoldenGate 23.26.1.0.6 Free for Oracle` — that's still 23ai; `23.26` is a minor-version bump of the 23ai release train, not a new major release.

---

## Part 6: Configure Active-Active Replication (GG Free Web UI)

GG Free 23.26 no longer exposes a "Pipelines / Active-Active Database Replication" recipe wizard — that abstraction was removed, and administrators now build the Active-Active topology by hand out of Database Connections, Extracts, and Replicats. This section walks through the exact clicks and values for the WSO2 APIM multi-DC case on 23.26.

All of the steps below happen inside **Administration Service** (the page you reached at the end of §5.4), not in Service Manager. If your left nav shows `Home / User Administration / Deployments / Certificate Management / …` you are still in Service Manager — go back to §5.4 and click **Deployments → Local → Administration Service**.

Endpoint of this section: **4 Extracts + 4 Replicats, all in STOPPED state**. ACDR configuration, coordinated process startup, and the round-trip verification test are tracked as a stub in §6.6 — they'll be filled in after the live deployment has them running cleanly.

### 6.1 Create 4 `apimadmin` Database Connections

In Administration Service, open the left nav and click **DB Connections → Add Connection**.

The 23.26 form has **no separate Hostname / Port / Service Name fields and no SYSDBA toggle** — everything goes in a single **User ID** field using Oracle Easy Connect syntax (`user@//host:port/service`). For each of the four connections below, fill in:

- **Credential Alias**: leave the default (it mirrors the Connection Name).
- **User ID**: the Easy Connect string from the table.
- **Password**: `Apim@123`.
- **Domain**: `OracleGoldenGate` (default — leave as-is).

| Connection name | User ID (Easy Connect)                  | Password    |
|-----------------|-----------------------------------------|-------------|
| `dc1_apim`      | `apimadmin@//10.2.4.4:1521/apim_db`     | `Apim@123`  |
| `dc1_shared`    | `apimadmin@//10.2.4.4:1521/shared_db`   | `Apim@123`  |
| `dc2_apim`      | `apimadmin@//10.1.4.4:1521/apim_db`     | `Apim@123`  |
| `dc2_shared`    | `apimadmin@//10.1.4.4:1521/shared_db`   | `Apim@123`  |

After saving all four, hover over each row and click the **Test** (plug) icon in the Actions column. A green "Connection successful" on all four is your proof that VNet peering, NSG rules, and the Oracle listener are all healthy. If any row fails, fix it before moving on — a broken credential at Extract-creation time produces confusing downstream errors.

> **Why `apimadmin` and not `sys`?** The old recipe wizard used `sys` + SYSDBA because it needed elevated privileges to auto-provision `ggadmin`. We pre-provisioned `ggadmin` manually in §4.6, so no SYSDBA connection is needed here. `apimadmin` already has `DBA` (from §4.1) plus the `LOGMINING` grants we just added in §4.6, which is the exact privilege set Extract needs.

### 6.2 Per-connection database setup (checkpoint, trandata, heartbeat)

Each of the four DB connections from §6.1 needs three one-time initialization steps before any Extract or Replicat can attach to it. Do all three **on each of the four connections** — the 23.26 UI exposes them as buttons in the connection detail pane (the page you land on after clicking a connection name in the DB Connections list).

**1. Checkpoint table** — stores Replicat recovery state. Click **Checkpoint → Add Checkpoint** and enter `GGADMIN.GGS_CHKPT` as the schema-qualified table name. Same table name on all four connections.

> **Why it must live in `GGADMIN` and not `APIMADMIN`**: the checkpoint table is written to on every Replicat commit. If it lived inside the replicated schema, Replicat's checkpoint UPDATEs would themselves be captured by Extract and ship back across the link, creating an infinite metadata loop. The `GGADMIN` schema is deliberately *not* listed in any `TABLE` directive in §6.4, so Extract ignores it.

**2. Schema-level Trandata** — adds supplemental logging to every table in `APIMADMIN`. Click **Trandata → Add Schema Trandata**, enter `APIMADMIN` as the schema name, and **tick "All Columns"**. All-columns logging is required for the latest-timestamp-wins conflict resolution we'll wire up in §6.7 (ACDR needs every column of every row in the redo stream, not just the changed ones).

The UI will fire off `ADD SCHEMATRANDATA APIMADMIN ALLCOLS` under the hood and surface confirmations in the bell-icon notification drawer — watch for `OGG-01788 SCHEMATRANDATA has been added` and `OGG-01977 SCHEMATRANDATA for all columns has been added`. Those notifications are the authoritative success signal in 23.26; there is no "N tables instrumented" count in the UI. Verification from the database side comes in §6.6 below.

**3. Heartbeat table** — the UI-installed heartbeat mechanism used to measure end-to-end replication lag. Click **Heartbeat → Add Heartbeat Table**. There are no parameters; it creates three tables (`GG_HEARTBEAT`, `GG_HEARTBEAT_SEED`, `GG_HEARTBEAT_HISTORY`) in the **connection user's schema**, i.e. `APIMADMIN` — not `GGADMIN`, even though the older GoldenGate documentation implies otherwise. That's expected and will not cause a problem, because §6.4's Extract parameter file explicitly excludes `APIMADMIN.GG_HEARTBEAT*` from capture. Nothing to fix here; just don't be surprised when they show up under `APIMADMIN` in `dba_tables`.

At the end of §6.2 you should have done **Checkpoint + Trandata + Heartbeat on all 4 connections = 12 UI actions**. Missing steps here surface later as confusing errors at Extract/Replicat create time, so it's worth a quick walk through each of the four connections to confirm all three are present before continuing.

### 6.3 Create 4 `ggadmin` Database Connections

Create a second set of four connections — identical in host/port/service to the `apimadmin` ones, but connecting as `ggadmin` with a `_gg` alias suffix. These will be used as the **target credentials** on all four Replicats in §6.5.

> **Why a second set of connections?** Replicat must connect as `ggadmin` so that the rows it applies are tagged with that user in the redo stream, and every Extract's `TRANLOGOPTIONS EXCLUDEUSER ggadmin` filters those rows out of the return trip. If Replicat connected as `apimadmin`, the return-trip filter wouldn't match and every Replicat-applied row would loop across the link forever within seconds.

Same wizard as §6.1, just with user and alias swapped:

| Connection name   | User ID (Easy Connect)                  | Password    |
|-------------------|-----------------------------------------|-------------|
| `dc1_apim_gg`     | `ggadmin@//10.2.4.4:1521/apim_db`       | `Apim@123`  |
| `dc1_shared_gg`   | `ggadmin@//10.2.4.4:1521/shared_db`     | `Apim@123`  |
| `dc2_apim_gg`     | `ggadmin@//10.1.4.4:1521/apim_db`       | `Apim@123`  |
| `dc2_shared_gg`   | `ggadmin@//10.1.4.4:1521/shared_db`     | `Apim@123`  |

Click **Test** on each. A red "invalid credentials" here means you either skipped §4.6 on one of the two DCs, or used a different password when creating `ggadmin` on one side — fix before continuing.

**Heartbeat on these four: yes. Checkpoint and Trandata: no.** Click into each of the four `_gg` connections and run **Heartbeat → Add Heartbeat Table** on it. That's the only one of the three buttons you need here. Skip Checkpoint and Trandata — those are already installed from §6.2 via the `apimadmin` connections and shouldn't be re-run.

> **Why the asymmetry?** GoldenGate's UI tracks the "heartbeat enabled" bit **per credential alias**, not per schema — so even though the underlying `APIMADMIN.GG_HEARTBEAT*` tables already exist on the DB side from §6.2, each Replicat's Heartbeat tab will show *"Heartbeat table is not enabled for credentials: 'OracleGoldenGate-<alias>_gg'"* until you associate the heartbeat tables with that specific alias. The UI's `Add Heartbeat Table` action is idempotent with respect to the underlying tables — it detects them and just registers the alias association. Trandata is a DB-level supplemental-logging setting already applied to all `APIMADMIN` tables in §6.2 and only matters source-side, so target-side `_gg` aliases don't need it. Checkpoint is referenced by fully-qualified name (`"GGADMIN"."GGS_CHKPT"`) when we create each Replicat in §6.5, so it doesn't need a per-alias association either.

### 6.4 Create 4 Extracts

Four Integrated Extracts, one per source PDB, each capturing `APIMADMIN.*` and writing to a dedicated two-letter trail on the `ogg-hub` volume. Extracts connect as `apimadmin` (via the non-`_gg` aliases from §6.1) because that user has the `LOGMINING` grants we added in §4.6; Replicats will connect as `ggadmin` in §6.5.

> **Naming quirk**: GG MA process name limits are **8 characters for Extracts, 5 characters for Replicats**. The extra 3 characters Replicat reserves are for apply-thread suffixes (e.g. `RAPM1001`, `RAPM1002` when a Parallel Replicat spawns threads). That's why the Extract names below are 5–6 characters and the Replicat names in §6.5 are all 5.

| Extract  | Source PDB       | USERIDALIAS   | EXTTRAIL |
|----------|------------------|---------------|----------|
| `EAPIM1` | DC1 `apim_db`    | `dc1_apim`    | `aa`     |
| `EAPIM2` | DC2 `apim_db`    | `dc2_apim`    | `ab`     |
| `ESHR1`  | DC1 `shared_db`  | `dc1_shared`  | `ba`     |
| `ESHR2`  | DC2 `shared_db`  | `dc2_shared`  | `bb`     |

Go to **Administration Service → Extracts → Add Extract** and walk the four-step wizard for each row:

1. **Extract Information**
   - Extract Type: **Integrated Extract**
   - Process Name: from the table above
   - Description: optional

2. **Extract Options**
   - Trail → Name: the two-letter `EXTTRAIL` from the table (`aa` / `ab` / `ba` / `bb`)
   - Subdirectory: blank
   - Encryption Profile: `LocalWallet`
   - Source Credentials → Domain: `OracleGoldenGate`
   - Source Credentials → Alias: the `USERIDALIAS` from the table (the plain `apimadmin` one, **not** the `_gg` alias)
   - Begin: `Now`

3. **Managed Options**
   - Profile Name: `Default`
   - Critical to deployment health: **Off**
   - Auto Start: **Off**
   - Auto Restart: **Off**

   > All 8 processes stay in a stopped state until §6.7 (ACDR) has been applied on both DCs and §6.8 (coordinated startup) runs them in the right order. AutoStart / AutoRestart would fight that.

4. **Parameter File** — the wizard auto-generates the header:

   ```
   EXTRACT <name>
   USERIDALIAS <alias> DOMAIN OracleGoldenGate
   EXTTRAIL <trail>
   ```

   In the editable box below, **append** these three lines (they're required for Active-Active and not auto-generated):

   ```
   TRANLOGOPTIONS EXCLUDEUSER ggadmin
   TABLEEXCLUDE APIMADMIN.GG_HEARTBEAT*;
   TABLE APIMADMIN.*;
   ```

   `TRANLOGOPTIONS EXCLUDEUSER ggadmin` is the loopback filter — Extract skips any transaction whose committing session connected as `ggadmin`, and since every Replicat in §6.5 connects as `ggadmin`, Replicat-applied rows never re-capture. `TABLEEXCLUDE APIMADMIN.GG_HEARTBEAT*;` keeps the three heartbeat tables (installed by §6.2 into the `APIMADMIN` schema, not `GGADMIN`) out of the capture set — otherwise the wildcard `TABLE APIMADMIN.*;` would ship every local heartbeat write across the link, and the remote Replicat would apply them on top of the *remote* heartbeat writer, creating a bidirectional heartbeat update storm. Order matters: `TABLEEXCLUDE` must appear *before* the `TABLE` directive it filters. `TABLE APIMADMIN.*;` scopes capture to the APIM schema; the trailing semicolon is mandatory on `TABLE` / `TABLEEXCLUDE` directives and silently breaks things if you drop it.

Click **Create** (not *Create and Run*). Repeat for all four Extracts. At the end of §6.4 the Extracts table should show four rows all in **STOPPED** state.

### 6.5 Create 4 Replicats

Four Parallel Nonintegrated Replicats, one per target PDB, each reading the *opposite* DC's trail for the same DB and applying via the `_gg` aliases from §6.3.

> **Why Nonintegrated and not Integrated Parallel Replicat?** The "Integrated" sub-type uses Oracle's XStream inbound server, which depends on the same `dbms_goldengate_auth.grant_admin_privilege` wrapper that gave us `ORA-26988` back in §4.6. Nonintegrated Parallel Replicat applies rows via plain SQL using the `DBA` privileges `ggadmin` already has and sidesteps the wrapper entirely. Throughput is more than adequate for APIM config-plane traffic.

Trail rule reminder (because the cross-mapping is easy to get wrong): first letter of the trail = **DB** (`a` = apim, `b` = shared), second letter = **source DC** (`a` = DC1, `b` = DC2). Each Replicat reads the trail written by the Extract on the *other* side for the same DB:

| Replicat | Reads trail | Written by | Applies to       | USERIDALIAS     |
|----------|-------------|------------|------------------|-----------------|
| `RAPM1`  | `ab`        | `EAPIM2`   | DC1 `apim_db`    | `dc1_apim_gg`   |
| `RAPM2`  | `aa`        | `EAPIM1`   | DC2 `apim_db`    | `dc2_apim_gg`   |
| `RSHR1`  | `bb`        | `ESHR2`    | DC1 `shared_db`  | `dc1_shared_gg` |
| `RSHR2`  | `ba`        | `ESHR1`    | DC2 `shared_db`  | `dc2_shared_gg` |

Go to **Administration Service → Replicats → Add Replicat** and walk the four-step wizard for each row:

1. **Replicat Information**
   - Replicat Type: **Parallel Replicat**
   - Parallel Replicat Type: **Nonintegrated**
   - Process Name: from the table (5 chars max — this is why they're `RAPM`, not `RAPIM`)
   - Description: optional

2. **Replicat Options**
   - Replicat Trail → Name: the two-letter trail from the table
   - Subdirectory: blank
   - Encryption Profile: `LocalWallet`
   - Target Credentials → Domain: `OracleGoldenGate`
   - **Target Credentials → Alias: the `_gg` alias from the table** — this is the critical field. Selecting the non-`_gg` `apimadmin` alias here breaks loopback prevention and causes infinite replication within seconds.
   - Checkpoint Table: `"GGADMIN"."GGS_CHKPT"` (pre-populated from §6.2)
   - Begin: **Position in Trail**
   - Trail Position: Sequence `0`, RBA `0`

3. **Managed Options**
   - Profile Name: `Default`
   - Critical to deployment health: **Off**
   - Auto Start: **Off**
   - Auto Restart: **Off**

4. **Parameter File** — the wizard auto-generates:

   ```
   REPLICAT <name>
   USERIDALIAS <_gg alias> DOMAIN OracleGoldenGate
   ```

   The default editable box contains `MAP *.*, TARGET *.*;` — that's **too broad**. It would try to map system schemas like `SYS` / `SYSTEM` / `GGADMIN` and fail on the first non-APIM row. Replace it with:

   ```
   MAP APIMADMIN.*, TARGET APIMADMIN.*;
   ```

Click **Create** (not *Create and Run*). Repeat for all four Replicats. At the end of §6.5 the Administration Service Overview should show **4 Extracts + 4 Replicats, all in STOPPED state** — that's the checkpoint where this section ends.

### 6.6 Verify schema trandata

Before we move on to ACDR, spot-check that the schema trandata you installed in §6.2 actually took effect on all four PDBs. Two gotchas to know up front:

1. The `Add Schema Trandata` action reports success in the UI notification drawer even if nothing was actually instrumented. On our setup it works because `apimadmin` has `DBA` + `LOGMINING` from §4.6, but it's worth confirming before every row change on ~249 `apim_db` tables depends on it.
2. **Do not use `DBA_LOG_GROUPS` to verify.** In Oracle 12c+ (including 23ai), `ADD SCHEMATRANDATA` does *not* create explicit per-table log groups — it calls `DBMS_CAPTURE_ADM.PREPARE_SCHEMA_INSTANTIATION` under the hood, which registers the schema with LogMiner. The per-table state lands in `DBA_CAPTURE_PREPARED_TABLES` and `DBA_GOLDENGATE_SUPPORT_MODE`. Querying `DBA_LOG_GROUPS` will always come back with exactly 2 rows (explicit log groups on the `GG_HEARTBEAT` / `GG_HEARTBEAT_SEED` tables that the heartbeat step installs) and lead you to wrongly conclude trandata never installed.

Run this on **both DCs**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200 PAGESIZE 100

ALTER SESSION SET CONTAINER = apim_db;
SELECT COUNT(*) prepared_tables
  FROM dba_capture_prepared_tables WHERE table_owner='APIMADMIN';
SELECT support_mode, COUNT(*) tables
  FROM dba_goldengate_support_mode
 WHERE owner='APIMADMIN' GROUP BY support_mode;

ALTER SESSION SET CONTAINER = shared_db;
SELECT COUNT(*) prepared_tables
  FROM dba_capture_prepared_tables WHERE table_owner='APIMADMIN';
SELECT support_mode, COUNT(*) tables
  FROM dba_goldengate_support_mode
 WHERE owner='APIMADMIN' GROUP BY support_mode;

EXIT;
SQL
```

Expected on both DCs:

- `apim_db`: ~249 prepared tables, all in `FULL` support mode.
- `shared_db`: ~54 prepared tables, all in `FULL` support mode.

`FULL` means GoldenGate can capture and apply every column of every row from the redo stream for that table — the strongest guarantee the view reports. If you see `PL/SQL`, `ID KEY`, or `NONE` on any row, re-run `Add Schema Trandata` in the UI for the affected connection and re-query.

> **If the counts come back as 0**: the Trandata step in §6.2 was skipped or silently no-op'd for that connection. Go back to DB Connections → the affected connection → Trandata → **Add Schema Trandata**, schema `APIMADMIN`, tick **All Columns**. Watch the bell-icon notification drawer for `OGG-01977 SCHEMATRANDATA for all columns has been added on schema "APIMADMIN"` — that's the success signal, not a dictionary view. Then re-run the query above.

### 6.7 Enable Automatic Conflict Detection and Resolution (ACDR)

ACDR adds hidden `CDRTS$ROW` (row-level timestamp) and per-column `CDRTS$<col>` columns to every PK-bearing table in `APIMADMIN`, plus registers delete-tombstone tracking. When the same row is updated on both DCs concurrently, Replicat uses the hidden timestamp to pick the winner — the later write wins. Without this, a cross-DC conflict silently corrupts one side.

**Ordering rule**: ACDR must be applied on **both DCs before any Extract or Replicat starts**. If one DC fires a row change before the other has ACDR installed, the change will arrive at the remote side carrying a hidden-column payload the target doesn't have yet, and Replicat will abend on the first apply.

**Tables that get skipped**: `DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR` requires a primary key. Tables without a PK will be silently skipped. On a standard APIM 4.7 schema that's **4 tables in `apim_db`** (`AM_API_REVISION_METADATA`, `AM_SCOPE_BINDING`, `AM_WEBHOOKS_UNSUBSCRIPTION`, `IDN_OAUTH2_TOKEN_BINDING`) and **3 tables in `shared_db`** (`UM_ORG_ROLE_USER`, `UM_ORG_ROLE_GROUP`, `UM_ORG_ROLE_PERMISSION`). These are low-volume access-control / metadata tables — they'll still replicate via GoldenGate's all-column key-matching fallback, they just won't benefit from ACDR's latest-timestamp-wins conflict handling. Acceptable for APIM config-plane traffic.

The loop below also explicitly skips `APIMADMIN.GG_HEARTBEAT*` via a `NOT LIKE` filter — those are the heartbeat tables from §6.2, and we've already kept them out of Extract capture via the `TABLEEXCLUDE` in §6.4.

Run the block **on both DCs** (DC1 first, then DC2):

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200 PAGESIZE 1000 SERVEROUTPUT ON SIZE UNLIMITED

ALTER SESSION SET CONTAINER = apim_db;
DECLARE
  v_ok   PLS_INTEGER := 0;
  v_err  PLS_INTEGER := 0;
BEGIN
  FOR r IN (
    SELECT t.table_name FROM dba_tables t
     WHERE t.owner='APIMADMIN'
       AND t.table_name NOT LIKE 'GG_HEARTBEAT%'
       AND EXISTS (SELECT 1 FROM dba_constraints c
                    WHERE c.owner=t.owner AND c.table_name=t.table_name
                      AND c.constraint_type='P')
     ORDER BY t.table_name
  ) LOOP
    BEGIN
      DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
        schema_name => 'APIMADMIN',
        table_name  => r.table_name);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      DBMS_OUTPUT.PUT_LINE('ERR '||r.table_name||': '||SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('apim_db ACDR: ok='||v_ok||' errors='||v_err);
END;
/

ALTER SESSION SET CONTAINER = shared_db;
DECLARE
  v_ok   PLS_INTEGER := 0;
  v_err  PLS_INTEGER := 0;
BEGIN
  FOR r IN (
    SELECT t.table_name FROM dba_tables t
     WHERE t.owner='APIMADMIN'
       AND t.table_name NOT LIKE 'GG_HEARTBEAT%'
       AND EXISTS (SELECT 1 FROM dba_constraints c
                    WHERE c.owner=t.owner AND c.table_name=t.table_name
                      AND c.constraint_type='P')
     ORDER BY t.table_name
  ) LOOP
    BEGIN
      DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
        schema_name => 'APIMADMIN',
        table_name  => r.table_name);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      DBMS_OUTPUT.PUT_LINE('ERR '||r.table_name||': '||SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('shared_db ACDR: ok='||v_ok||' errors='||v_err);
END;
/

EXIT;
SQL
```

Expected: two `PL/SQL procedure successfully completed.` lines, no `ERR` rows, and (if `DBMS_OUTPUT` surfaces — it sometimes gets swallowed by heredoc paste mangling) summary lines reading `apim_db ACDR: ok=242 errors=0` and `shared_db ACDR: ok=48 errors=0`. The verify query below is the authoritative check either way.

**Verify ACDR is in place** — run on both DCs after the loop:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200 PAGESIZE 100

ALTER SESSION SET CONTAINER = apim_db;
SELECT COUNT(*) acdr_tables FROM dba_gg_auto_cdr_tables WHERE table_owner='APIMADMIN';
SELECT table_name FROM dba_gg_auto_cdr_tables
 WHERE table_owner='APIMADMIN' ORDER BY table_name FETCH FIRST 5 ROWS ONLY;

ALTER SESSION SET CONTAINER = shared_db;
SELECT COUNT(*) acdr_tables FROM dba_gg_auto_cdr_tables WHERE table_owner='APIMADMIN';
SELECT table_name FROM dba_gg_auto_cdr_tables
 WHERE table_owner='APIMADMIN' ORDER BY table_name FETCH FIRST 5 ROWS ONLY;

EXIT;
SQL
```

Expected: `acdr_tables = 242` on `apim_db` and `48` on `shared_db`, **identical on both DCs**. The spot-check list should show real APIM table names (`AM_ALERT_EMAILLIST`, `AM_ALERT_EMAILLIST_DETAILS`, `AM_ALERT_TYPES`, `AM_ALERT_TYPES_VALUES`, `AM_API` on `apim_db`; `REG_ASSOCIATION`, `REG_CLUSTER_LOCK`, `REG_COMMENT`, `REG_CONTENT`, `REG_CONTENT_HISTORY` on `shared_db`).

> **23ai view column name gotcha**: the column in `DBA_GG_AUTO_CDR_TABLES` on 23ai is `TABLE_OWNER`, not `OWNER` or `SCHEMA_NAME`. Older Oracle docs and blog posts show the earlier column name and will give you `ORA-00904: "OWNER": invalid identifier` on 23ai.

### 6.8 Register Integrated Extracts via adminclient

Integrated Extracts will **not** start successfully straight after creation. The first `Start` on any of the four Extracts abends within seconds with:

```
OGG-02024  An attempt to gather information about the logmining server configuration from the Oracle database failed.
OGG-10556  No data found when executing SQL statement
           <SELECT apply_name FROM all_apply WHERE apply_name = SUBSTR(UPPER('OGG || :1), 1, 30)>.
OGG-01668  PROCESS ABENDING.
```

The root cause is that every Integrated Extract needs a matching LogMiner capture process — a row in `DBA_CAPTURE` named `OGG$<EXTRACT_NAME>` — to exist in the source PDB before its first start. That row is created by running `REGISTER EXTRACT <name> DATABASE` against the Extract's target PDB via its credential alias. The GG Free 23.26 creation wizard does **not** auto-register, and the Extracts Actions menu in the web UI only exposes `Info` / `Start` / `Delete` / `Start with Options` / `Alter` — there is no **Register** action. The only way to register in GG Free 23.26 is through the `adminclient` CLI.

Two adminclient-specific gotchas to know before running the commands below:

1. **`http://` vs `https://`** — the ogg-hub container runs in insecure mode (see §5.1), so its Service Manager + deployment services listen on plain HTTP. Connecting adminclient with `https://localhost:9012` fails instantly with `OGG-12982 Failed to establish secure communication with a remote peer`. Use `http://` literally.
2. **`DBLOGIN` is mandatory before each `REGISTER`** — adminclient's `CONNECT http://localhost:9012 ...` only authenticates against the deployment, not against the database. Without a prior `DBLOGIN USERIDALIAS <alias> DOMAIN OracleGoldenGate`, `REGISTER EXTRACT` errors with `Error: Not logged into database, use DBLOGIN`. Each of the four Extracts lives in a different PDB, so you issue a fresh `DBLOGIN` before each `REGISTER`.

Enter the adminclient:

```bash
docker exec -it ogg-hub /u01/ogg/bin/adminclient
```

Then at the `OGG (not connected) 1>` prompt, paste the following, replacing `<oggadmin-password>` with the password from §5.2 (the one you pulled out of `docker logs ogg-hub`):

```
CONNECT http://localhost:9012 AS oggadmin PASSWORD <oggadmin-password>

DBLOGIN USERIDALIAS dc1_apim DOMAIN OracleGoldenGate
REGISTER EXTRACT EAPIM1 DATABASE

DBLOGIN USERIDALIAS dc2_apim DOMAIN OracleGoldenGate
REGISTER EXTRACT EAPIM2 DATABASE

DBLOGIN USERIDALIAS dc1_shared DOMAIN OracleGoldenGate
REGISTER EXTRACT ESHR1 DATABASE

DBLOGIN USERIDALIAS dc2_shared DOMAIN OracleGoldenGate
REGISTER EXTRACT ESHR2 DATABASE

EXIT
```

Each `DBLOGIN` should print `Successfully logged into database APIM_DB` (or `SHARED_DB`) and each `REGISTER EXTRACT` should print `Extract <name> successfully registered with database` within a few seconds. If any `REGISTER EXTRACT` returns `OGG-02062 User apimadmin does not have the required privileges to use integrated capture`, go back to §4.6 — the `OGG_CAPTURE` role + `SELECT ANY DICTIONARY` + `EXECUTE ON DBMS_XSTREAM_GG` grants were missed for that PDB. Re-run just those three GRANT statements on the failing PDB, then retry the `REGISTER`.

**Verify from the database side** — run on **both DCs**, expect each PDB to show exactly one `OGG$<name>` capture process in `LOCAL` / `DISABLED` state (it flips to `ENABLED` in §6.9 once the corresponding Extract actually starts):

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
SET LINESIZE 200 PAGESIZE 100
ALTER SESSION SET CONTAINER = apim_db;
SELECT capture_name, status, capture_type FROM dba_capture;
ALTER SESSION SET CONTAINER = shared_db;
SELECT capture_name, status, capture_type FROM dba_capture;
EXIT;
SQL
```

Expected:

- **DC1** — `apim_db`: `OGG$EAPIM1 / DISABLED / LOCAL`; `shared_db`: `OGG$ESHR1 / DISABLED / LOCAL`.
- **DC2** — `apim_db`: `OGG$EAPIM2 / DISABLED / LOCAL`; `shared_db`: `OGG$ESHR2 / DISABLED / LOCAL`.

If all four rows are present with the right names, registration is complete and you can move on to the coordinated startup.

### 6.9 Coordinated process startup

Start the 8 processes in a specific order: **all 4 Extracts first, then all 4 Replicats.** Starting a Replicat before its source Extract has had a chance to write any trail bytes leaves the Replicat abending because the trail file doesn't exist yet. Extracts, conversely, can start in any order relative to each other.

**Extracts first** — Administration Service → **Extracts** → click the play (Start) icon on each in turn: `EAPIM1`, `EAPIM2`, `ESHR1`, `ESHR2`. Wait for each to reach **Running** before starting the next. Within a minute of each one going Running you should see two signals:

- The Extracts list shows `Heartbeat Lag` and `Heartbeat Age` populating in seconds (not empty, not "stale"). A healthy steady-state is `Heartbeat Lag` < 10 s and `Heartbeat Age` < 60 s per Extract.
- On the corresponding DC, the `DBA_CAPTURE` row for that Extract flips from `DISABLED` to `ENABLED`:

  ```sql
  ALTER SESSION SET CONTAINER = apim_db;
  SELECT capture_name, status FROM dba_capture;
  ```

If any Extract goes **Abended** on start, open its `Report` tab from the Actions menu and read the `OGG-` error at the bottom. With §6.8 registration done and §6.7 ACDR in place, the next most likely failure mode is archived log availability — Extract failing to position on an SCN because the archived log for that SCN has already been cleaned up. Look for `OGG-00446` or `OGG-01028`, and if you see it, the fix is to either run `ALTER SYSTEM ARCHIVE LOG CURRENT;` inside the PDB or to recreate the Extract with a later `Begin Now` position.

**Replicats next** — same pattern, Administration Service → **Replicats** → play icon on `RAPM1`, `RAPM2`, `RSHR1`, `RSHR2`, one at a time. Wait for Running before starting the next. Healthy state is the same: heartbeat lag in single-digit seconds, heartbeat age under a minute. A short burst of elevated lag (20–60 s) on first start is normal — the Replicat is catching up on whatever trail the Extract wrote while the Replicat was still stopped.

Common Replicat abend-on-start causes, in order of likelihood:

1. **Heartbeat warning on the Replicat detail page** → you skipped **Heartbeat → Add Heartbeat Table** on one of the `_gg` connections in §6.3. This doesn't cause an abend, but it does silently disable end-to-end lag reporting for that Replicat. Fix the `_gg` connection, refresh, and restart.
2. **`OGG-01211 Unable to acquire checkpoint record for ...`** → the checkpoint table pre-populated in the Replicat wizard (§6.5) got typed wrong. It must be `"GGADMIN"."GGS_CHKPT"` exactly.
3. **`OGG-01296 Error mapping from SYS.TABLE to SYS.TABLE`** → the parameter file `MAP *.*, TARGET *.*;` default wasn't replaced with `MAP APIMADMIN.*, TARGET APIMADMIN.*;` in §6.5. Stop the Replicat, Alter → edit the param file, restart.

At the end of §6.9 the Administration Service Overview should show **4 Extracts Running + 4 Replicats Running** with all 8 heartbeat lag values under 10 s. That's the "live" state — §6.10 is the functional proof.

### 6.10 Round-trip replication test

Four tests, two tables, both directions: INSERT on one DC, SELECT on the opposite DC, DELETE to clean up. We use two low-volume tables that already exist in the APIM schemas and have auto-assigned PKs via `BEFORE INSERT` triggers — `apimadmin.am_alert_types` for `apim_db` and `apimadmin.reg_log` for `shared_db`.

> **The PKs you see on each DC will be *different* numbers for the seed data and *identical* numbers for your test inserts — that's expected, and it's the single cleanest signal that active-active is working correctly.** The WSO2 DC1 and DC2 schema packs (`dbscripts/dc1/Oracle/sequences_23c.sql` vs `dbscripts/dc2/Oracle/sequences_23c.sql`) create every `_SEQUENCE` with `START WITH 1 INCREMENT BY 2 NOCACHE` on DC1 and `START WITH 2 INCREMENT BY 2 NOCACHE` on DC2, so DC1 hands out odd PKs and DC2 hands out even PKs — a classic active-active trick to prevent new-row PK collisions on independently-issued inserts. But when GoldenGate Parallel Nonintegrated Replicat applies a captured INSERT on the target side, it supplies the PK value explicitly from the trail and the target-side trigger does **not** re-fire or overwrite it (23ai suppresses triggers on Replicat-owned sessions by default). So a row inserted on DC1 at odd PK `15` lands on DC2 at PK `15` too, even though DC2's own sequence never produces odd numbers. If the test-inserted PKs ever diverge between the two DCs, that's your signal that trigger suppression isn't working and you'd need `DBOPTIONS SUPPRESSTRIGGERS` on all four Replicats — but on this GG Free 23.26 + 23ai stack, it Just Works out of the box.

#### Test 1 — DC1 → DC2 on apim_db

**Step A**, on **DC1** (`apim-4-7-eus1-oracle`):

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
INSERT INTO apimadmin.am_alert_types (alert_type_name, stake_holder)
VALUES ('test-dc1', 'publisher');
COMMIT;
SELECT alert_type_id, alert_type_name, stake_holder
  FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc1';
EXIT;
SQL
```

Note the `ALERT_TYPE_ID` the trigger assigned — it will be the next odd number after the seeded rows (typically `15`). Omit `alert_type_id` from the INSERT column list deliberately: the trigger unconditionally overrides any literal you supply, so there is no benefit to passing one.

**Step B**, wait ~3 seconds, then on **DC2** (`apim-4-7-wus2-oracle`):

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
SELECT alert_type_id, alert_type_name, stake_holder
  FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc1';
EXIT;
SQL
```

Expected: DC2 returns the same row with the **same** `ALERT_TYPE_ID` DC1 reported. If so, DC1 → DC2 replication is working on `apim_db`.

**Step C — cleanup**, on **DC1**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
DELETE FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc1';
COMMIT;
SELECT COUNT(*) FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc1';
EXIT;
SQL
```

Expected count on DC1: `0`. Wait ~3 s and re-run the same `SELECT COUNT(*)` on **DC2** — it should also return `0`, which doubles as a DC1 → DC2 DELETE-replication check.

#### Test 2 — DC2 → DC1 on apim_db

**Step A**, on **DC2**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
INSERT INTO apimadmin.am_alert_types (alert_type_name, stake_holder)
VALUES ('test-dc2', 'publisher');
COMMIT;
SELECT alert_type_id, alert_type_name, stake_holder
  FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc2';
EXIT;
SQL
```

Note the PK — this time it will be an **even** number (typically `16`), because DC2's `AM_ALERT_TYPES` sequence starts at 2 and increments by 2.

**Step B**, on **DC1**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
SELECT alert_type_id, alert_type_name, stake_holder
  FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc2';
EXIT;
SQL
```

Expected: DC1 shows the same row with the even-numbered PK — even though DC1's own sequence only hands out odd numbers, confirming the trail-supplied PK is being preserved by the Replicat.

**Step C — cleanup**, on **DC2**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = apim_db;
DELETE FROM apimadmin.am_alert_types WHERE alert_type_name = 'test-dc2';
COMMIT;
EXIT;
SQL
```

Re-check on **DC1** that the row is gone.

#### Test 3 — DC1 → DC2 on shared_db

`REG_LOG` is the registry audit table — it's append-only by design, has a composite PK `(REG_LOG_ID, REG_TENANT_ID)` with `REG_LOG_ID` auto-assigned from `REG_LOG_SEQUENCE` by a `BEFORE INSERT` trigger, and no other tables have foreign keys pointing at it, so arbitrary test rows are safe to insert and remove. We use `REG_TENANT_ID = -1234` and a distinctive `REG_USER_ID = 'ogg-test-dc1'` so the test rows are trivially isolatable from real audit traffic.

**Step A**, on **DC1**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
INSERT INTO apimadmin.reg_log
  (reg_path, reg_user_id, reg_logged_time, reg_action, reg_action_data, reg_tenant_id)
VALUES
  ('/test/round-trip', 'ogg-test-dc1', SYSTIMESTAMP, 0, 'acdr-round-trip', -1234);
COMMIT;
SELECT reg_log_id, reg_user_id, reg_tenant_id
  FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc1';
EXIT;
SQL
```

Note the `REG_LOG_ID` — it will be an odd number from DC1's `REG_LOG_SEQUENCE`.

**Step B**, on **DC2**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
SELECT reg_log_id, reg_user_id, reg_tenant_id
  FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc1';
EXIT;
SQL
```

Expected: same row, same `REG_LOG_ID`, same `REG_TENANT_ID = -1234`.

**Step C — cleanup**, on **DC1**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
DELETE FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc1';
COMMIT;
EXIT;
SQL
```

#### Test 4 — DC2 → DC1 on shared_db

**Step A**, on **DC2**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
INSERT INTO apimadmin.reg_log
  (reg_path, reg_user_id, reg_logged_time, reg_action, reg_action_data, reg_tenant_id)
VALUES
  ('/test/round-trip', 'ogg-test-dc2', SYSTIMESTAMP, 0, 'acdr-round-trip', -1234);
COMMIT;
SELECT reg_log_id, reg_user_id, reg_tenant_id
  FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc2';
EXIT;
SQL
```

**Step B**, on **DC1**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
SELECT reg_log_id, reg_user_id, reg_tenant_id
  FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc2';
EXIT;
SQL
```

Expected: same row, even-numbered `REG_LOG_ID` (from DC2's sequence).

**Step C — cleanup**, on **DC2**:

```bash
docker exec -i oracle-db sqlplus -S / as sysdba <<'SQL'
ALTER SESSION SET CONTAINER = shared_db;
DELETE FROM apimadmin.reg_log WHERE reg_user_id = 'ogg-test-dc2';
COMMIT;
EXIT;
SQL
```

#### What "success" looks like

All four tests show the row landing on the opposite DC within ~2 s carrying the same PK the source side reported. All four cleanups replicate back within ~2 s. At the end of §6.10 both DCs are in the same state they were at the start of the section, and the GG Administration Service Overview still shows 4 Extracts + 4 Replicats Running with single-digit heartbeat lag.

If any of the `Step B` SELECTs returns no row (or returns a different PK), investigate in this order:

1. **Check the relevant Replicat in the UI** — `RAPM1`/`RAPM2` for `apim_db` tests, `RSHR1`/`RSHR2` for `shared_db` tests. Confirm status is still `Running` and heartbeat lag hasn't ballooned.
2. **Open that Replicat's Report tab** — any `OGG-` error near the bottom is the authoritative cause. The last SCN printed is what the Replicat is waiting on.
3. **Cross-check the matching Extract's Report tab** — confirm the source-side row change shows up as a captured record (Extract's "total captured" counter should have incremented since `Step A`).
4. If 1–3 all look healthy but the row still isn't on the target, fall back to `DBA_CAPTURE_PROCESSES` + `DBA_APPLY_ERROR` inside sqlplus on both sides to see whether a conflict landed in a discards queue.

---

## Part 7: Troubleshooting & Operations

### Container-level

```bash
# Live logs
docker logs -f oracle-db
docker logs -f ogg-hub

# Restart after a VM reboot or transient issue
docker restart oracle-db
docker restart ogg-hub

# Inspect running processes
docker ps
docker inspect oracle-db | jq '.[0].State'
```

### DB introspection

```bash
docker exec -it oracle-db sqlplus / as sysdba
```
```sql
SELECT NAME, OPEN_MODE FROM V$PDBS;
SELECT LOG_MODE, FORCE_LOGGING, SUPPLEMENTAL_LOG_DATA_MIN FROM V$DATABASE;
SHOW PARAMETER ENABLE_GOLDENGATE_REPLICATION;

-- Recent archive log switches (Extract needs these to mine)
SELECT SEQUENCE#, FIRST_TIME FROM V$ARCHIVED_LOG ORDER BY FIRST_TIME DESC FETCH FIRST 5 ROWS ONLY;
```

### Gateway fails to deploy APIs after a publish on the other DC

**Symptom.** After publishing or updating an API on the DC1 control plane, the DC2 gateway pods log:

```
ERROR {org.wso2.carbon.apimgt.gateway.InMemoryAPIDeployer}
  - Error retrieving artifacts for API <uuid>. Storage returned null
ERROR {org.wso2.carbon.apimgt.gateway.InMemoryAPIDeployer}
  - Error deploying <uuid> in Gateway
  org.wso2.carbon.apimgt.impl.gatewayartifactsynchronizer.exception.ArtifactSynchronizerException:
    Error retrieving artifacts for API <uuid>. Storage returned null
```

**Root cause.** The control plane publishes a JMS event as soon as it commits the API row to the DC1 database. The DC2 gateway receives the event via the Traffic Manager within milliseconds and immediately tries to fetch the artifact from its **local** DC2 database. GoldenGate replication is asynchronous — a large commit can take several seconds to land on the far side — so the DC2 gateway wins the race and reads a row that isn't there yet.

**Mitigation.** Raise the gateway's artifact-deployment retry window so a retry catches the row once replication lands it. The relevant APIM property is `deployment_retry_duration` under `[apim.sync_runtime_artifacts.gateway]`, in milliseconds. The gateway Helm chart exposes `wso2.apim.configurations.extraConfigs` as a passthrough into `deployment.toml`, so the simplest edit is to add this to `distributed/gateway/azure-values-dc1-oracle.yaml` **and** `distributed/gateway/azure-values-dc2-oracle.yaml`:

```yaml
wso2:
  apim:
    configurations:
      extraConfigs: |
        [apim.sync_runtime_artifacts.gateway]
        deployment_retry_duration = 30000
```

Start at 30000 (30 s). If the round-trip replication in §6.10 routinely exceeds 30 s under load, raise it to 60000. The value is read at gateway startup, so `helm upgrade` followed by a gateway pod rollout is required to pick up the change.

**Verification.** Re-run the round-trip test from §6.10 on `apim_db` to confirm replication is healthy, then publish an API from the DC1 publisher and watch the DC2 gateway pod logs — the `Storage returned null` error should no longer appear, and the API should be reachable through the DC2 gateway within the retry window.

### OGG Free Administration Service & adminclient

- **Extract abends on first start with `OGG-02024` / `OGG-10556` / `OGG-01668`** (`BOUNDED RECOVERY`, `LogMiner session could not be started`, `missing LogMiner capture process`). Integrated Extracts must be *registered* with the source DB before first start, and the 23.26 Administration Service UI does **not** auto-register them — the Actions menu only exposes `Info / Start / Start with Options / Alter / Delete`, no `Register` action. Follow §6.8 to register via `adminclient`. Verify from the DB side with `SELECT capture_name, status FROM dba_capture;` inside the relevant PDB — if the `OGG$<name>` row is missing, the Extract is unregistered.
- **`OGG-12982 Failed to establish secure communication`** when `adminclient` tries to `CONNECT` — you used `https://` against an **insecure** deployment. GG Free 23.26 is started in insecure mode in §5.1, so `adminclient` must connect with `CONNECT http://localhost:9012 AS oggadmin PASSWORD <pw>`. The `http://` is mandatory.
- **`OGG-02062 User apimadmin does not have the required privileges to use integrated capture`** on `REGISTER EXTRACT`. The direct `GRANT EXECUTE ON DBMS_CAPTURE_ADM` / `DBMS_APPLY_ADM` / `DBMS_STREAMS_ADM` grants in §4.6 cover package access but do **not** satisfy integrated capture's role check. The Oracle 23ai fix is to grant the built-in `OGG_CAPTURE` role plus `SELECT ANY DICTIONARY` and `EXECUTE ON DBMS_XSTREAM_GG` (§4.6 includes this block). Note that the older `DBMS_GOLDENGATE_ADM.GRANT_ADMIN_PRIVILEGE` wrapper also does not work — same `OGG-02062` downstream.
- **`adminclient` path**: the binary lives at `/u01/ogg/bin/adminclient` inside the `ogg-hub` container. `docker exec -it ogg-hub /u01/ogg/bin/adminclient` drops you at an `OGG (not connected)` prompt. `DBLOGIN USERIDALIAS <alias> DOMAIN OracleGoldenGate` is mandatory before each `REGISTER EXTRACT` — adminclient's HTTP-connected state has no DB session attached.
- **Replicat heartbeat warning** *"Heartbeat table is not enabled for credentials: 'OracleGoldenGate-<alias>_gg'"*: heartbeat enablement is tracked **per credential alias** in the UI metadata, not per physical table. Enable heartbeat on all 4 `_gg` connections in §6.3 — the underlying `GG_HEARTBEAT*` tables already exist in `APIMADMIN` from §6.2, so this is a no-op on the DB side but clears the UI warning and re-enables end-to-end lag reporting.
- **Extract/Replicat returns to `Running` after a transient issue** — no manual intervention needed once the underlying DB is reachable again. The Managed Options profile handles restart-on-failure.
- **Forgot the `oggadmin` UI password**: `docker exec -it ogg-hub /u01/ogg/bin/adminclient` provides a local CLI, or tear down and recreate the container (the processes are stored on the named volume and survive, but credentials do not).

### Hard reset of a DB container (data loss)

If the DB container's state is wedged and you want to start clean:

```bash
docker rm -f oracle-db
docker volume rm oracle-db-data
# Then re-run Part 3 (start container) and Part 4 (PDBs + schemas + GG prereqs)
```

Any existing Extracts/Replicats will abend because the source/target PDB is gone. After recreating the PDBs, re-run §4.6 (grants for `ggadmin` and `apimadmin`), §6.2 (checkpoint + trandata + heartbeat), §6.7 (ACDR), and §6.8 (re-register the Integrated Extract on that DC) before restarting the processes.

### Drop and recreate a single PDB

If you created the wrong PDB on the wrong VM, drop just that PDB without touching the rest of the container state:

```sql
-- inside sqlplus / as sysdba
ALTER PLUGGABLE DATABASE apim_db CLOSE IMMEDIATE;
DROP PLUGGABLE DATABASE apim_db INCLUDING DATAFILES;
```

Then re-run the `CREATE PLUGGABLE DATABASE` + grants + schema-load steps from Parts 4.1 and 4.3 for just that PDB.

---

## Summary of Operations

1. **Provision (Part 1)** — 2 Ubuntu 22.04 VMs (`apim-4-7-eus1-oracle`, `apim-4-7-wus2-oracle`), NSG rules for 1521 on both VMs, VNet peering.
2. **Docker (Part 2)** — install `docker.io`, accept Oracle CR terms in a browser once, `docker login` and pull `database/free` on both VMs plus `goldengate/goldengate-oracle-free` on DC1.
3. **DB containers (Part 3)** — `docker run` the `oracle-db` container on both VMs with `--network host`, `-e ORACLE_PWD=Apim@123`, and a named volume; wait for `DATABASE IS READY TO USE!`.
4. **Schemas (Part 4)** — create `apim_db` + `shared_db` PDBs, create `apimadmin` with grants, enable archive log + force logging + supplemental logging + `enable_goldengate_replication`, load `dbscripts/dc1/Oracle/` on DC1 and `dbscripts/dc2/Oracle/` on DC2 as-is, then create `ggadmin` per PDB with the direct-grants workaround for `ORA-26988` and grant `LOGMINING` to `apimadmin`.
5. **OGG container (Part 5)** — `docker run` `ogg-hub` on DC1 with `/u02` volume and insecure mode, grab the initial admin password from the logs, SSH-tunnel ports 8011 (→ 9011) plus 9012–9015 to reach Service Manager + the four deployment services, navigate into `Deployments → Local → Administration Service`.
6. **Active-Active topology (Part 6)** — §6.1 create 4 `apimadmin` DB connections, §6.2 install checkpoint (`GGADMIN.GGS_CHKPT`) + schema trandata (`APIMADMIN`, All Columns) + heartbeat on each (heartbeat tables land in `APIMADMIN`, not `GGADMIN`), §6.3 create 4 `ggadmin` (`*_gg`) DB connections and enable heartbeat on all four (checkpoint and trandata are not needed on `_gg` connections — heartbeat is tracked per credential alias), §6.4 create 4 Integrated Extracts (`EAPIM1/2`, `ESHR1/2`) with `TRANLOGOPTIONS EXCLUDEUSER ggadmin`, `TABLEEXCLUDE APIMADMIN.GG_HEARTBEAT*;`, and `TABLE APIMADMIN.*;`, §6.5 create 4 Parallel Nonintegrated Replicats (`RAPM1/2`, `RSHR1/2`) with `MAP APIMADMIN.*, TARGET APIMADMIN.*;` — all 8 processes created in STOPPED state, §6.6 verify schema trandata via `DBA_CAPTURE_PREPARED_TABLES` / `DBA_GOLDENGATE_SUPPORT_MODE` (not `DBA_LOG_GROUPS`), §6.7 apply ACDR on both DCs with `DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR` (242 `apim_db` + 48 `shared_db`), §6.8 register the 4 Integrated Extracts from `adminclient` with `CONNECT http://localhost:9012` + `DBLOGIN USERIDALIAS ... DOMAIN OracleGoldenGate` + `REGISTER EXTRACT <name> DATABASE` so `DBA_CAPTURE` gets the `OGG$<name>` row each Extract needs to attach, §6.9 coordinated startup (all 4 Extracts first, then all 4 Replicats) with heartbeat lag < 10 s as the healthy signal, §6.10 four-test round-trip verification (INSERT + SELECT + DELETE on `AM_ALERT_TYPES` / `REG_LOG`) in both directions across both PDBs, with the identical trail-supplied PK on both DCs as the proof that active-active is live.
7. **Operate (Part 7)** — `docker logs`, `docker restart`, restart a stopped Extract/Replicat from the Administration Service UI, hard-reset the DB volume only as a last resort.
