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

**2. Schema-level Trandata** — adds supplemental logging to every table in `APIMADMIN`. Click **Trandata → Add Schema Trandata**, enter `APIMADMIN` as the schema name, and **tick "All Columns"**. All-columns logging is required for the latest-timestamp-wins conflict resolution we'll wire up in the §6.6 stub (ACDR needs every column of every row in the redo stream, not just the changed ones).

The UI will iterate over the schema and report the number of tables instrumented — expect ~246 on an `apim_db` connection and ~51 on a `shared_db` connection.

**3. Heartbeat table** — the UI-installed heartbeat mechanism used to measure end-to-end replication lag. Click **Heartbeat → Add Heartbeat Table**. There are no parameters; it silently creates `GGADMIN.GG_HEARTBEAT_*` tables in the PDB.

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

**Do not** run Checkpoint / Trandata / Heartbeat on these four. Those artifacts are already installed by §6.2 via the `apimadmin` connections and live at the PDB level, not per-connection — adding them a second time here duplicates the table definitions and fails.

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

   > All 8 processes stay in a stopped state until §6.6 (ACDR + coordinated startup) is ready. AutoStart / AutoRestart would fight that.

4. **Parameter File** — the wizard auto-generates the header:

   ```
   EXTRACT <name>
   USERIDALIAS <alias> DOMAIN OracleGoldenGate
   EXTTRAIL <trail>
   ```

   In the editable box below, **append** these two lines (they're required for Active-Active and not auto-generated):

   ```
   TRANLOGOPTIONS EXCLUDEUSER ggadmin
   TABLE APIMADMIN.*;
   ```

   `TRANLOGOPTIONS EXCLUDEUSER ggadmin` is the loopback filter — Extract skips any transaction whose committing session connected as `ggadmin`, and since every Replicat in §6.5 connects as `ggadmin`, Replicat-applied rows never re-capture. `TABLE APIMADMIN.*;` scopes capture to the APIM schema; the trailing semicolon is mandatory on `TABLE` directives and silently breaks things if you drop it.

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

### 6.6 Next steps (to be added after live verification)

The remaining phases of the Active-Active setup are intentionally not yet documented in this guide — they'll be folded in once they've been executed successfully against a real DC1/DC2 pair, so the runbook matches what actually works instead of what *should* work. The planned sections:

- **6.7 — Enable Automatic Conflict Detection and Resolution (ACDR)**: loop over every `APIMADMIN.*` table in each PDB on both DCs and call `DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR` to add hidden timestamp and tombstone columns for latest-timestamp-wins conflict resolution. Must be applied on both DCs **before any Replicat starts** — the first cross-DC update that arrives with a hidden-column payload will fail on a target that doesn't have the column yet.
- **6.8 — Coordinated process startup**: start all 4 Extracts first (so trail files exist on disk), then all 4 Replicats. Starting a Replicat before its source Extract has produced any trail bytes leaves it spinning in an ABENDED state trying to open a file that doesn't exist.
- **6.9 — Round-trip replication test**: DC1 → DC2 and DC2 → DC1 on both `apim_db` and `shared_db`, using `sqlplus` updates on representative tables (`AM_APPLICATION` for apim_db, a suitable `shared_db` table for the second direction).

The surrounding sections of this guide — §Part 7 Troubleshooting, the `deployment_retry_duration` gateway tuning note, and everything before Part 6 — do not depend on §6.7–§6.9 and can be referenced now.

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

Start at 30000 (30 s). If the round-trip replication in §6.3 routinely exceeds 30 s under load, raise it to 60000. The value is read at gateway startup, so `helm upgrade` followed by a gateway pod rollout is required to pick up the change.

**Verification.** Re-run the round-trip test from §6.3 on `apim_db` to confirm replication is healthy, then publish an API from the DC1 publisher and watch the DC2 gateway pod logs — the `Storage returned null` error should no longer appear, and the API should be reachable through the DC2 gateway within the retry window.

### OGG Free web UI

- Pipeline stuck in **ERROR**: click the pipeline → **Logs** tab → copy the error string. The most common causes are: missing ACDR metadata on a table that was added after pipeline start (stop the pipeline, reopen the Mapping step, re-enable ACDR, start), and DB connectivity (run `nc -zv` from the DC1 VM to the target DC's port 1521).
- Pipeline status returns to **RUNNING** after a transient issue — no manual intervention needed once the underlying DB is reachable again.
- Forgot the `oggadmin` UI password: `docker exec -it ogg-hub /u01/app/ogg/bin/adminclient` provides a local CLI, or tear down and recreate the container (the pipelines are stored on the named volume and survive, but credentials do not).

### Hard reset of a DB container (data loss)

If the DB container's state is wedged and you want to start clean:

```bash
docker rm -f oracle-db
docker volume rm oracle-db-data
# Then re-run Part 3 (start container) and Part 4 (PDBs + schemas + GG prereqs)
```

Any existing pipelines will stop replicating from that DC because the source/target PDB is gone. Re-run their Mapping step after the PDBs exist again, then Start.

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
6. **Active-Active topology (Part 6)** — §6.1 create 4 `apimadmin` DB connections, §6.2 install checkpoint (`GGADMIN.GGS_CHKPT`) + schema trandata (`APIMADMIN`, All Columns) + heartbeat on each, §6.3 create 4 `ggadmin` (`*_gg`) DB connections, §6.4 create 4 Integrated Extracts (`EAPIM1/2`, `ESHR1/2`) with `TRANLOGOPTIONS EXCLUDEUSER ggadmin` and `TABLE APIMADMIN.*;`, §6.5 create 4 Parallel Nonintegrated Replicats (`RAPM1/2`, `RSHR1/2`) with `MAP APIMADMIN.*, TARGET APIMADMIN.*;` — all 8 processes created in STOPPED state. §6.6 (ACDR, startup, verification) is a stub pending live verification.
7. **Operate (Part 7)** — `docker logs`, `docker restart`, restart a stopped Extract/Replicat from the Administration Service UI, hard-reset the DB volume only as a last resort.
