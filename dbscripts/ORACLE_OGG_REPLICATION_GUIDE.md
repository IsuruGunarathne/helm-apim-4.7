# Bi-Directional Replication with Oracle GoldenGate — Oracle 23c on Azure VMs

Set up Oracle GoldenGate bi-directional replication between two Oracle 23c instances on Azure VMs for WSO2 API Manager 4.7 multi-DC deployment. A single GoldenGate hub VM in DC1 manages all replication processes.

## Architecture

```
        DC1 (East US 1)                           DC2 (West US 2)
┌──────────────────────────────┐          ┌──────────────────────────────┐
│  Oracle subnet (x.x.4.0/24)  │          │  Oracle subnet (x.x.4.0/24)  │
│                               │          │                               │
│  ┌─────────────────────────┐  │          │  ┌─────────────────────────┐  │
│  │ apim-4-7-eus1-oracle    │  │          │  │ apim-4-7-wus2-oracle    │  │
│  │ apim_db + shared_db     │  │          │  │ apim_db + shared_db     │  │
│  │ Sequences: 1,3,5,7...   │  │          │  │ Sequences: 2,4,6,8...   │  │
│  │ DCID: DC1               │  │          │  │ DCID: DC2               │  │
│  │ IP: 10.2.4.4            │  │          │  │ IP: 10.1.4.4            │  │
│  └──────────┬──────────────┘  │          │  └──────────┬──────────────┘  │
│             │                  │          │             │                  │
│  ┌──────────▼──────────────┐  │  VNet    │             │                  │
│  │ GoldenGate Hub VM       │  │  Peering │             │                  │
│  │ EXT_DC1 → trail → REP_DC2──┼──────────┼─────────────┘                  │
│  │ EXT_DC2 ← trail ← REP_DC1──┼──────────┼─────────────┘                  │
│  │ IP: 10.2.4.5            │  │          │                               │
│  └─────────────────────────┘  │          │                               │
│                               │          │                               │
│  Jump-box VM (x.x.1.0/24)    │          │  Jump-box VM (x.x.1.0/24)    │
└──────────────────────────────┘          └──────────────────────────────┘
```

**GoldenGate processes on the hub:**
- `EXT_DC1`: Extracts changes from DC1 Oracle DB → local trail `./dirdat/d1`
- `EXT_DC2`: Extracts changes from DC2 Oracle DB → local trail `./dirdat/d2`
- `REP_DC2`: Reads trail `d1` → applies to DC2 Oracle DB
- `REP_DC1`: Reads trail `d2` → applies to DC1 Oracle DB

## Connection Details

```bash
# DC1 — East US 1 (Oracle DB VM)
export DC1_HOST=10.2.4.4
export DC1_PORT=1521
export DC1_USER=apimadmineast
export DC1_PASS="{your-password}"
export DC1_SID=FREE        # Oracle 23c Free SID, or your CDB name

# DC2 — West US 2 (Oracle DB VM)
export DC2_HOST=10.1.4.4
export DC2_PORT=1521
export DC2_USER=apimadminwest
export DC2_PASS="{your-password}"
export DC2_SID=FREE

# GoldenGate Hub VM (DC1 — East US 1)
export OGG_HOST=10.2.4.5
```

---

## Part 1: Azure VM Provisioning

### 1.1 Create VMs

Create three VMs total: two Oracle DB VMs (one per region) and one GoldenGate hub VM in DC1.

```bash
RG="rg-WSO2-APIM-4.7.0-release-isuruguna"

# Find existing VNet names
DC1_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='eastus']" -o tsv --query "[0].name")
DC2_VNET_NAME=$(az network vnet list --resource-group $RG --query "[?location=='westus2']" -o tsv --query "[0].name")

# DC1 — Oracle DB VM (East US 1, Oracle subnet)
az vm create \
  --resource-group $RG \
  --name apim-4-7-eus1-oracle \
  --location eastus \
  --image Oracle:oracle-linux:ol89-lvm-gen2:latest \
  --size Standard_D4s_v3 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $DC1_VNET_NAME \
  --subnet oracle-subnet \
  --public-ip-address "" \
  --os-disk-size-gb 128 \
  --data-disk-sizes-gb 256

# DC2 — Oracle DB VM (West US 2, Oracle subnet)
az vm create \
  --resource-group $RG \
  --name apim-4-7-wus2-oracle \
  --location westus2 \
  --image Oracle:oracle-linux:ol89-lvm-gen2:latest \
  --size Standard_D4s_v3 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $DC2_VNET_NAME \
  --subnet oracle-subnet \
  --public-ip-address "" \
  --os-disk-size-gb 128 \
  --data-disk-sizes-gb 256

# GoldenGate Hub VM (East US 1, Oracle subnet)
az vm create \
  --resource-group $RG \
  --name apim-4-7-eus1-ogg \
  --location eastus \
  --image Oracle:oracle-linux:ol89-lvm-gen2:latest \
  --size Standard_D4s_v3 \
  --admin-username azureuser \
  --generate-ssh-keys \
  --vnet-name $DC1_VNET_NAME \
  --subnet oracle-subnet \
  --public-ip-address "" \
  --os-disk-size-gb 128
```

### 1.2 NSG Rules

Azure NSGs allow all outbound traffic by default, so we only need inbound rules. Only the OGG hub needs 7809-7810 inbound; the two Oracle DB VMs only need 1521 inbound.

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

**DC1 Oracle DB VM — inbound 1521:**
```bash
DC1_DB_NSG=$(get_nsg apim-4-7-eus1-oracle)

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC1_DB_NSG \
  --name AllowOracle1521 \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 1521 \
  --source-address-prefixes VirtualNetwork
```

**DC2 Oracle DB VM — inbound 1521:**
```bash
DC2_DB_NSG=$(get_nsg apim-4-7-wus2-oracle)

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $DC2_DB_NSG \
  --name AllowOracle1521 \
  --priority 1010 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 1521 \
  --source-address-prefixes VirtualNetwork
```

**OGG hub VM — inbound 7809-7810:**
```bash
OGG_NSG=$(get_nsg apim-4-7-eus1-ogg)

az network nsg rule create \
  --resource-group $RG \
  --nsg-name $OGG_NSG \
  --name AllowOGG \
  --priority 1020 \
  --direction Inbound \
  --access Allow \
  --protocol Tcp \
  --destination-port-ranges 7809-7810 \
  --source-address-prefixes VirtualNetwork
```

### 1.3 VNet Peering

If VNet peering is not already configured (from PostgreSQL/MSSQL setup):

```bash
# Get VNet IDs
DC1_VNET_ID=$(az network vnet show -g $RG -n $DC1_VNET_NAME --query id -o tsv)
DC2_VNET_ID=$(az network vnet show -g $RG -n $DC2_VNET_NAME --query id -o tsv)

# DC1 → DC2
az network vnet peering create \
  --resource-group $RG \
  --name dc1-to-dc2 \
  --vnet-name $DC1_VNET_NAME \
  --remote-vnet $DC2_VNET_ID \
  --allow-vnet-access

# DC2 → DC1
az network vnet peering create \
  --resource-group $RG \
  --name dc2-to-dc1 \
  --vnet-name $DC2_VNET_NAME \
  --remote-vnet $DC1_VNET_ID \
  --allow-vnet-access
```

### 1.4 Mount Data Disk (OPTIONAL — run on BOTH Oracle DB VMs)

> **Is this required?** **No** — for a lab running Oracle 23ai Free the OS disk is fine. Free Edition caps user data at 12 GB per PDB (~24 GB across `apim_db` + `shared_db`) and an Oracle Linux 8 marketplace image gives you a 64–128 GB OS disk, so the datafiles themselves comfortably fit. Use the data disk if you want IO isolation, headroom for archive logs, or the ability to detach/reattach the DB independently of the VM.
>
> **The real risk on OS-disk-only** is not datafile size but **archive logs** (enabled in Step 3). They grow continuously and will hang the DB if `/opt/oracle` fills up. Mitigation options:
> - Add a daily `rman` prune: `rman target / <<< "delete noprompt archivelog all completed before 'sysdate-1';"`
> - Or set a tight `DB_RECOVERY_FILE_DEST_SIZE` so Oracle self-prunes the FRA
> - Or skip archive log mode entirely for a throwaway lab (but then Extract can't replay historical changes if it falls behind)
>
> If you're OK with those tradeoffs, **skip this section and go straight to Part 2**. Otherwise, continue below.

The `--data-disk-sizes-gb 256` flag only attaches a raw LUN. Format and mount it **before installing Oracle** so `/opt/oracle` lives on the data disk instead of the OS disk.

```bash
# SSH into the Oracle DB VM as azureuser
lsblk                                           # identify the unpartitioned 256 GB LUN (usually /dev/sdc)
sudo mkfs.xfs /dev/sdc
sudo mkdir -p /opt/oracle
echo "/dev/sdc /opt/oracle xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
df -h /opt/oracle                               # confirm 256 GB mounted
```

> **Already installed Oracle onto the OS disk and want to move it?** Stop the DB, move the data dirs, and symlink back:
> ```bash
> sudo systemctl stop oracle-free-23ai
> sudo mkfs.xfs /dev/sdc
> sudo mkdir -p /u01
> echo "/dev/sdc /u01 xfs defaults,nofail 0 2" | sudo tee -a /etc/fstab
> sudo mount -a
> sudo mv /opt/oracle/oradata /u01/oradata
> sudo ln -s /u01/oradata /opt/oracle/oradata
> sudo chown -R oracle:oinstall /u01/oradata
> sudo systemctl start oracle-free-23ai
> ```

---

## Part 2: Oracle 23c Installation

SSH into **both** Oracle DB VMs via the jump-box and install Oracle 23c.

### 2.1 Install Oracle 23c Free (RPM-based)

```bash
# SSH into the Oracle VM via jump-box
ssh azureuser@<oracle-vm-private-ip>

# Install Oracle 23c Free (Oracle Linux)
sudo dnf install -y oracle-database-preinstall-23ai
sudo dnf install -y https://download.oracle.com/otn-pub/otn_software/db-free/oracle-database-free-23ai-1.0-1.el8.x86_64.rpm

# Configure the database (creates FREE CDB + FREEPDB1)
sudo /etc/init.d/oracle-free-23ai configure

# You will be prompted to set a password for SYS, SYSTEM, and PDBADMIN
# Use a strong password and note it down

# Set environment variables
echo 'export ORACLE_HOME=/opt/oracle/product/23ai/dbhomeFree' >> ~/.bashrc
echo 'export ORACLE_SID=FREE' >> ~/.bashrc
echo 'export PATH=$ORACLE_HOME/bin:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=$ORACLE_HOME/lib' >> ~/.bashrc
source ~/.bashrc
```

**Grant azureuser the `dba` and `oinstall` group membership** so you can run `sqlplus / as sysdba`, `lsnrctl`, and `ggsci` directly without `sudo su - oracle`:

```bash
sudo usermod -aG dba,oinstall azureuser
```

Group membership only takes effect in a **new login session**. The simplest and most reliable way is to log out and SSH back in:

```bash
exit
ssh azureuser@<oracle-vm-private-ip>
```

(Don't use `su -l azureuser` — `su` always prompts for the target user's password, and `azureuser` has no password when you authenticated with an SSH key. If you really don't want to drop the session, `exec sudo -iu azureuser` also works because `sudo` authorises via sudoers, not a password.)

After reconnecting, verify:

```bash
id                          # should list dba and oinstall
sqlplus / as sysdba <<'SQL'
SELECT name, open_mode FROM v$database;
EXIT;
SQL
```

> **Note:** If using Oracle 23c Enterprise instead of Free, follow Oracle's standard installation guide and create a CDB/PDB architecture.

### 2.1b Open firewalld and clone the scripts repo

Oracle Linux 8/9 ships with firewalld enabled. Even though the NSG is open, firewalld still blocks 1521:

```bash
sudo firewall-cmd --permanent --add-port=1521/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports                  # should include 1521/tcp
```

Clone the repo onto the VM so the DC-specific SQL scripts in Step 7 are reachable locally:

```bash
sudo dnf install -y git
cd ~
git clone https://github.com/wso2/helm-apim.git helm-apim-4.7
# Scripts are now at:
#   ~/helm-apim-4.7/dbscripts/dc1/Oracle/...
#   ~/helm-apim-4.7/dbscripts/dc2/Oracle/...
```

### 2.2 Configure Oracle Listener (REQUIRED for cross-region access)

The default 23ai Free listener binds to `localhost` only, which breaks all cross-region connectivity. You **must** reconfigure it to bind to `0.0.0.0:1521` on both DB VMs.

```bash
# Confirm current endpoint (likely shows localhost or 127.0.0.1)
lsnrctl status
```

Rewrite `$ORACLE_HOME/network/admin/listener.ora` to bind to all interfaces:

```bash
cat > $ORACLE_HOME/network/admin/listener.ora <<'EOF'
LISTENER =
  (DESCRIPTION_LIST =
    (DESCRIPTION =
      (ADDRESS = (PROTOCOL = IPC)(KEY = EXTPROC1521))
      (ADDRESS = (PROTOCOL = TCP)(HOST = 0.0.0.0)(PORT = 1521))
    )
  )
EOF

lsnrctl stop
lsnrctl start
```

Tell the CDB to register its services with the new listener endpoint:

```bash
sqlplus / as sysdba <<'SQL'
ALTER SYSTEM SET LOCAL_LISTENER='(ADDRESS=(PROTOCOL=TCP)(HOST=0.0.0.0)(PORT=1521))' SCOPE=BOTH;
ALTER SYSTEM REGISTER;
EXIT;
SQL

# Verify the listener now reports TCP on 1521 and lists the FREE CDB service
lsnrctl services
```

After Step 1 creates the PDBs, re-run `lsnrctl services` — you should see `apim_db` and `shared_db` service names appear alongside `FREE`.

### 2.3 Configure tnsnames.ora (on both DB VMs)

Add entries for both databases in `$ORACLE_HOME/network/admin/tnsnames.ora`:

```
DC1_APIM =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.2.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = apim_db)))

DC1_SHARED =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.2.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = shared_db)))

DC2_APIM =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.1.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = apim_db)))

DC2_SHARED =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.1.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = shared_db)))
```

### 2.4 Test Cross-Region Connectivity

From the GoldenGate hub VM (or either DB VM), verify:

```bash
# Test connectivity to DC1
tnsping DC1_APIM

# Test connectivity to DC2
tnsping DC2_APIM

# Or use sqlplus
sqlplus apimadmineast/{password}@DC1_APIM
sqlplus apimadminwest/{password}@DC2_APIM
```

---

## Part 3: Database Setup

### Step 1: Create Pluggable Databases

> **Passwords**: Replace `{your-password}` and `{ogg-password}` below with a quoted string that contains only letters, digits, and standard punctuation. Oracle passwords cannot contain `{`, `}`, or unquoted whitespace. Example: `"Str0ngP@ss1"`. Use the same substitution in every SQL block below.

On **DC1** Oracle VM:
```sql
-- Connect as SYSDBA
sqlplus / as sysdba

-- Create PDBs for APIM
CREATE PLUGGABLE DATABASE apim_db
  ADMIN USER apimadmineast IDENTIFIED BY "{your-password}"
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/apim_db/');

CREATE PLUGGABLE DATABASE shared_db
  ADMIN USER apimadmineast IDENTIFIED BY "{your-password}"
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/shared_db/');

-- Open PDBs
ALTER PLUGGABLE DATABASE apim_db OPEN;
ALTER PLUGGABLE DATABASE shared_db OPEN;

-- Auto-open on restart
ALTER PLUGGABLE DATABASE apim_db SAVE STATE;
ALTER PLUGGABLE DATABASE shared_db SAVE STATE;
```

On **DC2** Oracle VM:
```sql
sqlplus / as sysdba

CREATE PLUGGABLE DATABASE apim_db
  ADMIN USER apimadminwest IDENTIFIED BY "{your-password}"
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/apim_db/');

CREATE PLUGGABLE DATABASE shared_db
  ADMIN USER apimadminwest IDENTIFIED BY "{your-password}"
  FILE_NAME_CONVERT = ('/opt/oracle/oradata/FREE/pdbseed/', '/opt/oracle/oradata/FREE/shared_db/');

ALTER PLUGGABLE DATABASE apim_db OPEN;
ALTER PLUGGABLE DATABASE shared_db OPEN;
ALTER PLUGGABLE DATABASE apim_db SAVE STATE;
ALTER PLUGGABLE DATABASE shared_db SAVE STATE;
```

### Step 2: Grant User Privileges

On **DC1** Oracle VM:

```sql
sqlplus / as sysdba

-- Connect to apim_db PDB
ALTER SESSION SET CONTAINER = apim_db;
GRANT CONNECT, RESOURCE, DBA TO apimadmineast;
GRANT UNLIMITED TABLESPACE TO apimadmineast;

-- Connect to shared_db PDB
ALTER SESSION SET CONTAINER = shared_db;
GRANT CONNECT, RESOURCE, DBA TO apimadmineast;
GRANT UNLIMITED TABLESPACE TO apimadmineast;
```

On **DC2** Oracle VM:

```sql
sqlplus / as sysdba

-- Connect to apim_db PDB
ALTER SESSION SET CONTAINER = apim_db;
GRANT CONNECT, RESOURCE, DBA TO apimadminwest;
GRANT UNLIMITED TABLESPACE TO apimadminwest;

-- Connect to shared_db PDB
ALTER SESSION SET CONTAINER = shared_db;
GRANT CONNECT, RESOURCE, DBA TO apimadminwest;
GRANT UNLIMITED TABLESPACE TO apimadminwest;
```

### Step 3: Enable Archive Log Mode

On **both** DB VMs (required for GoldenGate Extract):

```sql
sqlplus / as sysdba

-- Check current mode
ARCHIVE LOG LIST;

-- If not in archive log mode:
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;

-- Verify
ARCHIVE LOG LIST;
```

### Step 4: Enable Supplemental Logging

On **both** DB VMs:

```sql
sqlplus / as sysdba

-- Enable minimal supplemental logging at CDB level
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;

-- Enable supplemental logging for all columns in each PDB
ALTER SESSION SET CONTAINER = apim_db;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;

ALTER SESSION SET CONTAINER = shared_db;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA (ALL) COLUMNS;
```

### Step 5: Enable GoldenGate Replication

On **both** DB VMs:

```sql
sqlplus / as sysdba

ALTER SYSTEM SET enable_goldengate_replication = TRUE SCOPE=BOTH;
```

### Step 6: Create GoldenGate Admin User

On **both** DB VMs, create a common user for GoldenGate in the CDB:

```sql
sqlplus / as sysdba

-- Create GoldenGate admin user (common user in CDB)
CREATE USER C##GGADMIN IDENTIFIED BY "{ogg-password}";
GRANT DBA TO C##GGADMIN CONTAINER=ALL;
GRANT CONNECT, RESOURCE TO C##GGADMIN CONTAINER=ALL;
GRANT ALTER SYSTEM TO C##GGADMIN CONTAINER=ALL;
GRANT SELECT ANY DICTIONARY TO C##GGADMIN CONTAINER=ALL;
GRANT SELECT ANY TABLE TO C##GGADMIN CONTAINER=ALL;
GRANT INSERT ANY TABLE TO C##GGADMIN CONTAINER=ALL;
GRANT UPDATE ANY TABLE TO C##GGADMIN CONTAINER=ALL;
GRANT DELETE ANY TABLE TO C##GGADMIN CONTAINER=ALL;

-- GoldenGate-specific privileges
EXEC DBMS_GOLDENGATE_AUTH.GRANT_ADMIN_PRIVILEGE('C##GGADMIN', CONTAINER=>'ALL');
```

### Step 7: Run DC-Specific Table and Sequence Scripts

**DC1** (connect via sqlplus or SQLcl from jump-box):

```bash
# shared_db — tables and sequences
sqlplus apimadmineast/{password}@DC1_SHARED @dbscripts/dc1/Oracle/tables_23c.sql
sqlplus apimadmineast/{password}@DC1_SHARED @dbscripts/dc1/Oracle/sequences_23c.sql

# apim_db — tables and sequences
sqlplus apimadmineast/{password}@DC1_APIM @dbscripts/dc1/Oracle/apimgt/tables_23c.sql
sqlplus apimadmineast/{password}@DC1_APIM @dbscripts/dc1/Oracle/apimgt/sequences_23c.sql
```

**DC2:**

```bash
# shared_db — tables and sequences
sqlplus apimadminwest/{password}@DC2_SHARED @dbscripts/dc2/Oracle/tables_23c.sql
sqlplus apimadminwest/{password}@DC2_SHARED @dbscripts/dc2/Oracle/sequences_23c.sql

# apim_db — tables and sequences
sqlplus apimadminwest/{password}@DC2_APIM @dbscripts/dc2/Oracle/apimgt/tables_23c.sql
sqlplus apimadminwest/{password}@DC2_APIM @dbscripts/dc2/Oracle/apimgt/sequences_23c.sql
```

**What the DC-specific scripts change:**

| | DC1 | DC2 |
|--|-----|-----|
| Sequences | `START WITH 1 INCREMENT BY 2` | `START WITH 2 INCREMENT BY 2` |
| DCID default (IDN_OAUTH2_ACCESS_TOKEN) | `'DC1'` | `'DC2'` |

This ensures DC1 generates IDs 1,3,5,7... and DC2 generates 2,4,6,8... — no collisions during replication.

---

## Part 4: Oracle GoldenGate Setup

### Step 7.5: Prepare OGG Hub VM (Instant Client + firewalld)

Oracle Linux 8.x does not ship Instant Client by default. OGG 23ai needs Oracle client libraries to connect to the remote CDBs, plus a `TNS_ADMIN` directory for `tnsnames.ora`, plus the OS firewall opened for the Manager/collector ports.

SSH into the OGG hub VM as `azureuser`:

```bash
ssh azureuser@<ogg-hub-private-ip>

# Install Oracle Instant Client 23ai (Basic + SQL*Plus)
# If the Oracle Linux repos don't carry these, install from Oracle's RPM URLs:
sudo dnf install -y \
  https://download.oracle.com/otn_software/linux/instantclient/2360000/oracle-instantclient-basic-23.6.0.24.10-1.el8.x86_64.rpm \
  https://download.oracle.com/otn_software/linux/instantclient/2360000/oracle-instantclient-sqlplus-23.6.0.24.10-1.el8.x86_64.rpm

# Create TNS_ADMIN directory owned by azureuser
sudo mkdir -p /etc/oracle
sudo chown azureuser:azureuser /etc/oracle

# Export client env vars so sqlplus/ggsci find libclntsh.so and tnsnames.ora
cat >> ~/.bashrc <<'EOF'
export TNS_ADMIN=/etc/oracle
export LD_LIBRARY_PATH=/usr/lib/oracle/23/client64/lib:$LD_LIBRARY_PATH
export PATH=/usr/lib/oracle/23/client64/bin:$PATH
EOF
source ~/.bashrc

# Verify client is wired up
sqlplus -V

# Open GoldenGate Manager + collector ports in firewalld
sudo firewall-cmd --permanent --add-port=7809-7810/tcp
sudo firewall-cmd --reload
```

### Step 8: Install GoldenGate on Hub VM

SSH into the GoldenGate hub VM:

```bash
ssh azureuser@<ogg-hub-private-ip>

# Download Oracle GoldenGate 23ai for Oracle (from Oracle website or OTN)
# https://www.oracle.com/middleware/technologies/goldengate-downloads.html
# Transfer the zip to the VM

# Create OGG directories
sudo mkdir -p /opt/ogg
sudo chown azureuser:azureuser /opt/ogg

# Unzip GoldenGate
unzip fbo_ggs_Linux_x64_Oracle_shiphome.zip -d /opt/ogg

# Run the installer (or use the responseFile for silent install)
cd /opt/ogg/fbo_ggs_Linux_x64_Oracle_shiphome/Disk1
./runInstaller -silent -responseFile /opt/ogg/response/oggcore.rsp

# Or for GoldenGate Free (23ai):
# Download from: https://www.oracle.com/middleware/technologies/goldengate-free-downloads.html
# rpm -i oracle-goldengate-free*.rpm
```

Set environment:
```bash
echo 'export OGG_HOME=/opt/ogg/oggcore' >> ~/.bashrc
echo 'export PATH=$OGG_HOME:$PATH' >> ~/.bashrc
echo 'export LD_LIBRARY_PATH=$ORACLE_HOME/lib:$OGG_HOME/lib' >> ~/.bashrc
source ~/.bashrc
```

### Step 9: Configure tnsnames.ora on Hub VM

Write the TNS entries to `$TNS_ADMIN/tnsnames.ora` (i.e. `/etc/oracle/tnsnames.ora`, the directory created in Step 7.5):

```bash
cat > /etc/oracle/tnsnames.ora <<'EOF'
DC1_APIM =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.2.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = apim_db)))

DC1_SHARED =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.2.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = shared_db)))

DC2_APIM =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.1.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = apim_db)))

DC2_SHARED =
  (DESCRIPTION =
    (ADDRESS = (PROTOCOL = TCP)(HOST = 10.1.4.4)(PORT = 1521))
    (CONNECT_DATA = (SERVICE_NAME = shared_db)))
EOF
```

Verify connectivity (tnsping ships with Instant Client Tools; if not installed, use `sqlplus C##GGADMIN/{ogg-password}@DC1_APIM` instead):
```bash
tnsping DC1_APIM
tnsping DC2_APIM
tnsping DC1_SHARED
tnsping DC2_SHARED
```

### Step 10: Create GoldenGate Subdirectories

```bash
cd $OGG_HOME
./ggsci

# Inside GGSCI:
GGSCI> CREATE SUBDIRS
```

This creates `dirdat/`, `dirprm/`, `dirchk/`, `dirrpt/`, `dirtmp/` etc.

### Step 11: Configure GoldenGate Manager

Create the Manager parameter file:

```bash
GGSCI> EDIT PARAMS MGR
```

Add:
```
PORT 7809
DYNAMICPORTLIST 7810-7820
AUTORESTART EXTRACT *, RETRIES 3, WAITMINUTES 5
PURGEOLDEXTRACTS ./dirdat/*, USECHECKPOINTS, MINKEEPDAYS 3
```

Start the Manager:
```bash
GGSCI> START MGR
GGSCI> INFO MGR
```

### Step 12: Store Database Credentials

```bash
# First-time bootstrap of the credential store (creates dircrd/cwallet.sso)
GGSCI> ADD CREDENTIALSTORE

# Add credentials for all four databases
GGSCI> ALTER CREDENTIALSTORE ADD USER C##GGADMIN@DC1_APIM PASSWORD {ogg-password} ALIAS dc1_apim
GGSCI> ALTER CREDENTIALSTORE ADD USER C##GGADMIN@DC1_SHARED PASSWORD {ogg-password} ALIAS dc1_shared
GGSCI> ALTER CREDENTIALSTORE ADD USER C##GGADMIN@DC2_APIM PASSWORD {ogg-password} ALIAS dc2_apim
GGSCI> ALTER CREDENTIALSTORE ADD USER C##GGADMIN@DC2_SHARED PASSWORD {ogg-password} ALIAS dc2_shared

# Verify
GGSCI> INFO CREDENTIALSTORE
```

### Step 12.5: Enable Schema-level Supplemental Logging (SCHEMATRANDATA)

Integrated Extract requires `ADD SCHEMATRANDATA` on every PDB schema it will capture from. This is a GGSCI command, so it has to run *after* the credential store exists (Step 12) and *before* any Extract is registered (Step 13).

```bash
# DC1 schemas (apimadmineast)
GGSCI> DBLOGIN USERIDALIAS dc1_apim
GGSCI> ADD SCHEMATRANDATA apim_db.apimadmineast ALLCOLS
GGSCI> DBLOGIN USERIDALIAS dc1_shared
GGSCI> ADD SCHEMATRANDATA shared_db.apimadmineast ALLCOLS

# DC2 schemas (apimadminwest)
GGSCI> DBLOGIN USERIDALIAS dc2_apim
GGSCI> ADD SCHEMATRANDATA apim_db.apimadminwest ALLCOLS
GGSCI> DBLOGIN USERIDALIAS dc2_shared
GGSCI> ADD SCHEMATRANDATA shared_db.apimadminwest ALLCOLS

# Verify at least one per DC reports "prepared" and "allcols"
GGSCI> INFO SCHEMATRANDATA apim_db.apimadmineast
GGSCI> INFO SCHEMATRANDATA apim_db.apimadminwest
```

### Step 13: Configure Extract Processes

> **Pre-check:** `INFO SCHEMATRANDATA` must report the schema as "prepared" for every PDB you are about to register. If it doesn't, go back to Step 12.5 — registering an Extract against a schema without SCHEMATRANDATA will silently miss row changes.

We need 4 Extract processes (one per database):

#### Extract: DC1 apim_db

```bash
GGSCI> EDIT PARAMS EXT1A
```

```
EXTRACT EXT1A
USERIDALIAS dc1_apim
EXTTRAIL ./dirdat/a1
SOURCECATALOG apim_db

-- Exclude replicated rows (loop prevention)
TRANLOGOPTIONS EXCLUDETAG 00

TABLE apimadmineast.*;
```

#### Extract: DC1 shared_db

```bash
GGSCI> EDIT PARAMS EXT1S
```

```
EXTRACT EXT1S
USERIDALIAS dc1_shared
EXTTRAIL ./dirdat/s1
SOURCECATALOG shared_db

TRANLOGOPTIONS EXCLUDETAG 00

TABLE apimadmineast.*;
```

#### Extract: DC2 apim_db

```bash
GGSCI> EDIT PARAMS EXT2A
```

```
EXTRACT EXT2A
USERIDALIAS dc2_apim
EXTTRAIL ./dirdat/a2
SOURCECATALOG apim_db

TRANLOGOPTIONS EXCLUDETAG 00

TABLE apimadminwest.*;
```

#### Extract: DC2 shared_db

```bash
GGSCI> EDIT PARAMS EXT2S
```

```
EXTRACT EXT2S
USERIDALIAS dc2_shared
EXTTRAIL ./dirdat/s2
SOURCECATALOG shared_db

TRANLOGOPTIONS EXCLUDETAG 00

TABLE apimadminwest.*;
```

Register and add the Extracts:

```bash
# Register Extracts with the databases
GGSCI> DBLOGIN USERIDALIAS dc1_apim
GGSCI> REGISTER EXTRACT EXT1A DATABASE CONTAINER (apim_db)
GGSCI> ADD EXTRACT EXT1A, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/a1, EXTRACT EXT1A

GGSCI> DBLOGIN USERIDALIAS dc1_shared
GGSCI> REGISTER EXTRACT EXT1S DATABASE CONTAINER (shared_db)
GGSCI> ADD EXTRACT EXT1S, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/s1, EXTRACT EXT1S

GGSCI> DBLOGIN USERIDALIAS dc2_apim
GGSCI> REGISTER EXTRACT EXT2A DATABASE CONTAINER (apim_db)
GGSCI> ADD EXTRACT EXT2A, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/a2, EXTRACT EXT2A

GGSCI> DBLOGIN USERIDALIAS dc2_shared
GGSCI> REGISTER EXTRACT EXT2S DATABASE CONTAINER (shared_db)
GGSCI> ADD EXTRACT EXT2S, INTEGRATED TRANLOG, BEGIN NOW
GGSCI> ADD EXTTRAIL ./dirdat/s2, EXTRACT EXT2S
```

### Step 14: Configure Replicat Processes

We need 4 Replicat processes (apply DC1 changes to DC2 and vice versa):

#### Replicat: DC1→DC2 apim_db

```bash
GGSCI> EDIT PARAMS REP2A
```

```
REPLICAT REP2A
USERIDALIAS dc2_apim
ASSUMETARGETDEFS

-- Tag replicated rows so Extract ignores them (loop prevention)
DBOPTIONS SETTAG 00

-- Conflict resolution: Last Writer Wins
MAP apimadmineast.*, TARGET apimadminwest.*, COMPARECOLS (ON UPDATE ALL, ON DELETE ALL), RESOLVECONFLICT (UPDATEROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (INSERTROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (DELETEROWMISSING, (DEFAULT, DISCARD));
```

#### Replicat: DC1→DC2 shared_db

```bash
GGSCI> EDIT PARAMS REP2S
```

```
REPLICAT REP2S
USERIDALIAS dc2_shared
ASSUMETARGETDEFS

DBOPTIONS SETTAG 00

MAP apimadmineast.*, TARGET apimadminwest.*, COMPARECOLS (ON UPDATE ALL, ON DELETE ALL), RESOLVECONFLICT (UPDATEROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (INSERTROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (DELETEROWMISSING, (DEFAULT, DISCARD));
```

#### Replicat: DC2→DC1 apim_db

```bash
GGSCI> EDIT PARAMS REP1A
```

```
REPLICAT REP1A
USERIDALIAS dc1_apim
ASSUMETARGETDEFS

DBOPTIONS SETTAG 00

MAP apimadminwest.*, TARGET apimadmineast.*, COMPARECOLS (ON UPDATE ALL, ON DELETE ALL), RESOLVECONFLICT (UPDATEROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (INSERTROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (DELETEROWMISSING, (DEFAULT, DISCARD));
```

#### Replicat: DC2→DC1 shared_db

```bash
GGSCI> EDIT PARAMS REP1S
```

```
REPLICAT REP1S
USERIDALIAS dc1_shared
ASSUMETARGETDEFS

DBOPTIONS SETTAG 00

MAP apimadminwest.*, TARGET apimadmineast.*, COMPARECOLS (ON UPDATE ALL, ON DELETE ALL), RESOLVECONFLICT (UPDATEROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (INSERTROWEXISTS, (DEFAULT, USELATESTVERSION)), RESOLVECONFLICT (DELETEROWMISSING, (DEFAULT, DISCARD));
```

Register the Replicats:

```bash
# Add Replicats (Integrated mode for Oracle 23c)
GGSCI> DBLOGIN USERIDALIAS dc2_apim
GGSCI> ADD REPLICAT REP2A, INTEGRATED, EXTTRAIL ./dirdat/a1
GGSCI> DBLOGIN USERIDALIAS dc2_shared
GGSCI> ADD REPLICAT REP2S, INTEGRATED, EXTTRAIL ./dirdat/s1

GGSCI> DBLOGIN USERIDALIAS dc1_apim
GGSCI> ADD REPLICAT REP1A, INTEGRATED, EXTTRAIL ./dirdat/a2
GGSCI> DBLOGIN USERIDALIAS dc1_shared
GGSCI> ADD REPLICAT REP1S, INTEGRATED, EXTTRAIL ./dirdat/s2
```

### Step 15: Start All Processes

```bash
GGSCI> START EXTRACT EXT1A
GGSCI> START EXTRACT EXT1S
GGSCI> START EXTRACT EXT2A
GGSCI> START EXTRACT EXT2S

GGSCI> START REPLICAT REP2A
GGSCI> START REPLICAT REP2S
GGSCI> START REPLICAT REP1A
GGSCI> START REPLICAT REP1S
```

---

## Part 5: Verification

### Step 16: Check Process Status

```bash
GGSCI> INFO ALL
```

Expected output — all processes should show `RUNNING`:
```
Program     Status      Group       Lag at Chkpt  Time Since Chkpt

MANAGER     RUNNING
EXTRACT     RUNNING     EXT1A       00:00:00      00:00:02
EXTRACT     RUNNING     EXT1S       00:00:00      00:00:02
EXTRACT     RUNNING     EXT2A       00:00:00      00:00:05
EXTRACT     RUNNING     EXT2S       00:00:00      00:00:05
REPLICAT    RUNNING     REP1A       00:00:00      00:00:02
REPLICAT    RUNNING     REP1S       00:00:00      00:00:02
REPLICAT    RUNNING     REP2A       00:00:00      00:00:05
REPLICAT    RUNNING     REP2S       00:00:00      00:00:05
```

### Step 17: Test Replication

Insert a test row on DC1 and verify it appears on DC2 (and vice versa).

**DC1 — apim_db:**
```sql
-- Insert on DC1
sqlplus apimadmineast/{password}@DC1_APIM

INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (999, 'test-dc1-replication', 'admin-dashboard');
COMMIT;

-- Check on DC2 (should appear within seconds)
sqlplus apimadminwest/{password}@DC2_APIM

SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;
```

**DC2 — apim_db:**
```sql
-- Insert on DC2
sqlplus apimadminwest/{password}@DC2_APIM

INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (998, 'test-dc2-replication', 'admin-dashboard');
COMMIT;

-- Check on DC1 (should appear within seconds)
sqlplus apimadmineast/{password}@DC1_APIM

SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 998;
```

**Clean up test data** (run on either DC — will replicate to the other):
```sql
DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID IN (998, 999);
COMMIT;
```

---

## Networking Checklist

- [ ] VNet peering configured between East US 1 and West US 2 VNets
- [ ] Oracle listener port 1521 open in NSG rules (bidirectional)
- [ ] GoldenGate ports 7809-7810 open in NSG rules
- [ ] GoldenGate hub VM can reach both Oracle DB VMs (`tnsping` test)
- [ ] Both Oracle DB VMs have archive log mode enabled
- [ ] Supplemental logging enabled on both DBs

---

## Monitoring

### Check replication lag
```bash
GGSCI> LAG EXTRACT EXT1A
GGSCI> LAG EXTRACT EXT2A
GGSCI> LAG REPLICAT REP1A
GGSCI> LAG REPLICAT REP2A
```

### View statistics
```bash
GGSCI> STATS EXTRACT EXT1A, LATEST
GGSCI> STATS REPLICAT REP2A, LATEST
```

### View process details
```bash
GGSCI> INFO EXTRACT EXT1A, DETAIL
GGSCI> INFO REPLICAT REP2A, DETAIL
```

---

## Troubleshooting

### Check GoldenGate logs
```bash
# View report file for a process
GGSCI> VIEW REPORT EXT1A
GGSCI> VIEW REPORT REP2A

# Or read directly
cat $OGG_HOME/dirrpt/EXT1A.rpt
cat $OGG_HOME/dirrpt/REP2A.rpt
```

### Process is ABENDED
```bash
# Check the report for errors
GGSCI> VIEW REPORT <process_name>

# Common fixes:
# 1. Credential issues — re-add credentials
# 2. Network timeout — check NSG rules and VNet peering
# 3. Missing supplemental logging — re-enable on the source DB

# Restart after fixing
GGSCI> START <process_name>
```

### If Extract falls behind
```bash
# Check lag
GGSCI> LAG EXTRACT EXT2A

# If lag is large, check network between hub and DC2
# Consider increasing Extract parallelism in the parameter file
```

### Conflict resolution logs
Check the GoldenGate discard file for rejected rows:
```bash
cat $OGG_HOME/dirrpt/<replicat_name>.dsc
```

---

## Summary of Operations

| Step | DC1 (East US 1) | DC2 (West US 2) | GoldenGate Hub (DC1) |
|------|-----------------|-----------------|----------------------|
| VM provisioning | Oracle DB VM | Oracle DB VM | GoldenGate VM |
| Oracle 23c install | Yes | Yes | No (OGG only) |
| GoldenGate install | No | No | Yes |
| Archive log mode | Enable | Enable | — |
| Supplemental logging | Enable | Enable | — |
| GoldenGate replication | Enable | Enable | — |
| GoldenGate admin user | C##GGADMIN | C##GGADMIN | — |
| Create PDBs | apim_db, shared_db | apim_db, shared_db | — |
| Run table scripts | `dc1/Oracle/` | `dc2/Oracle/` | — |
| Manager process | — | — | Port 7809 |
| Extract processes | — | — | EXT1A, EXT1S, EXT2A, EXT2S |
| Replicat processes | — | — | REP1A, REP1S, REP2A, REP2S |
| Verify | Test inserts | Test inserts | INFO ALL |

---

## Key Differences from PostgreSQL (pglogical) and MSSQL (P2P)

| Aspect | PostgreSQL | MSSQL | Oracle |
|--------|-----------|-------|--------|
| Replication | pglogical (built-in) | P2P Transactional (built-in) | GoldenGate (separate product) |
| Topology | Each DB has provider/subscriber | Each server is publisher/subscriber | Central hub manages all |
| ID collision prevention | Sequences START/INC | IDENTITY seed/increment | Sequences START/INC |
| Conflict resolution | Commit timestamp (LWW) | Last Writer Wins | USELATESTVERSION (LWW) |
| Loop prevention | `forward_origins := '{}'` | Originator ID | EXCLUDETAG / SETTAG |
| Infrastructure | Azure Flexible Server (PaaS) | Azure VMs | Azure VMs + GG hub VM |
