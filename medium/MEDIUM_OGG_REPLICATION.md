# Active-Active Oracle Replication for WSO2 API Manager 4.7 with GoldenGate Free 23.26

Bi-directional Oracle 23ai replication across two regions for WSO2 APIM 4.7, using GoldenGate Free 23.26 from the Oracle Container Registry.

> `<ANGLE_BRACKET>` values are placeholders — substitute from your environment.

---

## Architecture

WSO2's **Multi-DC Pattern 1** runs independent APIM clusters per region, kept coherent by bi-directional database replication plus cross-DC JMS. This article covers the Oracle flavour: Oracle 23ai Free under each control plane, **GoldenGate Free 23.26** moving rows across the link.

The GoldenGate instance runs in a **Centralized OGG Hub** model — one `ogg-hub` container colocated on the DC1 DB VM talks to both database endpoints over TCP/1521 via peered VNets. A dedicated third VM works equally well if you want isolation; nothing else changes.

```
           Region A                                    Region B
┌──────────────────────────────┐            ┌──────────────────────────────┐
│  VNet A   (Oracle subnet)    │            │  VNet B   (Oracle subnet)    │
│                              │            │                              │
│  ┌────────────────────────┐  │            │  ┌────────────────────────┐  │
│  │  <DC1_VM_NAME>         │  │            │  │  <DC2_VM_NAME>         │  │
│  │                        │  │            │  │                        │  │
│  │  oracle-db container:  │  │ VNet       │  │  oracle-db container:  │  │
│  │   apim_db + shared_db  │◄─┤ peering  ─►│   apim_db + shared_db  │  │
│  │   Sequences 1,3,5…     │  │            │  │   Sequences 2,4,6…     │  │
│  │   DCID: DC1            │  │            │  │   DCID: DC2            │  │
│  │                        │  │            │  │                        │  │
│  │  ogg-hub container:    │  │            │  │                        │  │
│  │   4 Extracts,          │  │            │  │                        │  │
│  │   4 Replicats          │  │            │  │                        │  │
│  │  IP: <DC1_PRIVATE_IP>  │  │            │  │  IP: <DC2_PRIVATE_IP>  │  │
│  └────────────────────────┘  │            │  └────────────────────────┘  │
└──────────────────────────────┘            └──────────────────────────────┘
```

APIM uses two databases — `apim_db` (API metadata, tokens) and `shared_db` (user store, registry) — which we run as two PDBs inside a single CDB. Each PDB on each DC needs capture and apply, giving:

- **4 Integrated Extracts**, one per source PDB, capturing the `APIMADMIN` schema to trails `aa` (DC1 apim), `ab` (DC2 apim), `ba` (DC1 shared), `bb` (DC2 shared). First letter = database, second = source DC.
- **4 Parallel Nonintegrated Replicats**, one per target PDB, each reading the opposite DC's trail for the same database.
- **Loopback prevention** via `TRANLOGOPTIONS EXCLUDEUSER ggadmin`: Replicats apply as `ggadmin`, so Extract skips Replicat-applied transactions.

GG Free 23.26 has no "Pipelines" or "Active-Active" wizard — you build the topology directly from Connections, Extracts, and Replicats in Administration Service.

### Network requirements

| Direction | Protocol | Port | Source         | Applies to   |
|-----------|----------|------|----------------|--------------|
| Inbound   | TCP      | 1521 | VirtualNetwork | Both DB VMs  |

VNet peering is bidirectional with "Allow VNet access" on both sides. No other inbound rules are required.

> **Do not open GoldenGate UI ports (9011–9015) at the firewall.** The OGG Free container runs in insecure mode (plain HTTP). Reach the UI over an SSH tunnel on port 22 instead.

---

## Prerequisites

- Two Linux VMs, one per region, each with Docker. Size the DC1 VM for two containers (4 vCPU / 16 GB); the DC2 VM can be smaller (2 vCPU / 8 GB).
- Peered VNets with the inbound rule above.
- Outbound internet on both VMs to the Oracle Container Registry.
- An Oracle SSO account; licence terms for `database/free` and `goldengate-oracle-free` must be accepted once in a browser at <https://container-registry.oracle.com>.

---

## Install Docker and pull images

Accept the licence terms for both images in the browser, then on each VM:

```bash
docker login container-registry.oracle.com
docker pull container-registry.oracle.com/database/free:latest                       # both VMs
docker pull container-registry.oracle.com/goldengate/goldengate-oracle-free:latest   # DC1 only
```

---

## Start the containers

Both VMs:

```bash
docker volume create oracle-db-data
docker run -d --name oracle-db --network host --restart unless-stopped \
  -e ORACLE_PWD=<ORACLE_SYS_PASSWORD> \
  -v oracle-db-data:/opt/oracle/oradata \
  container-registry.oracle.com/database/free:latest
```

- `--network host` binds the listener to the VM's private IP on 1521 without Docker bridge gymnastics.
- First boot creates the CDB and default PDB; wait for `DATABASE IS READY TO USE!` in `docker logs -f oracle-db` (5–10 min).

DC1 only — the OGG hub:

```bash
docker volume create ogg-hub-data
docker run -d --name ogg-hub --network host --restart unless-stopped \
  -v ogg-hub-data:/u02 \
  container-registry.oracle.com/goldengate/goldengate-oracle-free:latest
```

- Mount `/u02`, not `/u01` — `/u01` holds binaries; mounting there crashes the init script.
- Insecure mode is deliberate — it skips the cert/wallet dance and keeps the setup simple. The private VNet plus SSH-tunnelled UI access means there's no plaintext traffic on the public internet anyway.

Grab the generated admin password from the logs — call it `<OGG_ADMIN_PASSWORD>`:

```bash
docker logs ogg-hub 2>&1 | grep -i password
```

---

## Database setup

All blocks below run inside `docker exec -it oracle-db sqlplus / as sysdba` — **on both DCs** unless noted.

### PDBs + `apimadmin`

```sql
CREATE PLUGGABLE DATABASE apim_db
  ADMIN USER pdbadmin IDENTIFIED BY "<DB_PASSWORD>"
  FILE_NAME_CONVERT = ('pdbseed', 'apim_db');
CREATE PLUGGABLE DATABASE shared_db
  ADMIN USER pdbadmin IDENTIFIED BY "<DB_PASSWORD>"
  FILE_NAME_CONVERT = ('pdbseed', 'shared_db');
ALTER PLUGGABLE DATABASE apim_db OPEN;   ALTER PLUGGABLE DATABASE apim_db   SAVE STATE;
ALTER PLUGGABLE DATABASE shared_db OPEN; ALTER PLUGGABLE DATABASE shared_db SAVE STATE;

ALTER SESSION SET CONTAINER = apim_db;
CREATE USER apimadmin IDENTIFIED BY "<DB_PASSWORD>";
GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE TO apimadmin;
ALTER SESSION SET CONTAINER = shared_db;
CREATE USER apimadmin IDENTIFIED BY "<DB_PASSWORD>";
GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE TO apimadmin;
ALTER SESSION SET CONTAINER = CDB$ROOT;
```

### Archive-log mode, supplemental logging, `PROCESSES=1000`

Extract mines redo; `PROCESSES` default (200) saturates under APIM + GG load. `PROCESSES` is static, so set it before the archive-log bounce picks it up.

```sql
ALTER SYSTEM SET PROCESSES=1000 SCOPE=SPFILE;
SHUTDOWN IMMEDIATE;
STARTUP MOUNT;
ALTER DATABASE ARCHIVELOG;
ALTER DATABASE OPEN;
ALTER PLUGGABLE DATABASE ALL OPEN;
ALTER DATABASE FORCE LOGGING;
ALTER DATABASE ADD SUPPLEMENTAL LOG DATA;
ALTER SYSTEM SET ENABLE_GOLDENGATE_REPLICATION = TRUE SCOPE=BOTH;
```

### Load APIM schemas

DC-customised scripts under `dbscripts/dc1/Oracle/` and `dbscripts/dc2/Oracle/` ship pre-offset sequences (DC1: `START 1 INCREMENT 2`, DC2: `START 2 INCREMENT 2`) and `DCID` defaults. On DC1:

```bash
for f in apimgt/tables_23c.sql apimgt/sequences_23c.sql tables_23c.sql sequences_23c.sql; do
  docker cp dbscripts/dc1/Oracle/$f oracle-db:/tmp/$(basename $f)
done
docker exec -i oracle-db sqlplus 'apimadmin/"<DB_PASSWORD>"@localhost:1521/apim_db'   @/tmp/tables_23c.sql
docker exec -i oracle-db sqlplus 'apimadmin/"<DB_PASSWORD>"@localhost:1521/apim_db'   @/tmp/sequences_23c.sql
docker exec -i oracle-db sqlplus 'apimadmin/"<DB_PASSWORD>"@localhost:1521/shared_db' @/tmp/tables_23c.sql
docker exec -i oracle-db sqlplus 'apimadmin/"<DB_PASSWORD>"@localhost:1521/shared_db' @/tmp/sequences_23c.sql
```

On DC2, swap `dc1/Oracle` → `dc2/Oracle`.

> **sqlplus quoting:** the password contains `@`, which the Easy Connect parser treats as a host delimiter. Wrap it in double quotes inside single quotes as shown, or you'll see `ORA-12262`.

### `ggadmin` + GG privileges (on both DCs, both PDBs)

GG Free 23.26 needs a dedicated `ggadmin` user in every PDB. The older `dbms_goldengate_auth.grant_admin_privilege` wrapper is disabled (fails with `ORA-26988`) and `LOGMINING` is no longer part of `DBA` in 23ai — grant privileges directly. `apimadmin` also needs `OGG_CAPTURE` + `SELECT ANY DICTIONARY` + `EXECUTE ON DBMS_XSTREAM_GG` for `REGISTER EXTRACT` later.

Run the block twice per DC — once with `ALTER SESSION SET CONTAINER = apim_db;` at the top, once with `shared_db`:

```sql
CREATE USER ggadmin IDENTIFIED BY "<DB_PASSWORD>";
GRANT DBA, LOGMINING, SELECT ANY TRANSACTION TO ggadmin;
GRANT EXECUTE ON DBMS_LOGMNR, DBMS_LOGMNR_D, DBMS_FLASHBACK,
                 DBMS_CAPTURE_ADM, DBMS_APPLY_ADM,
                 DBMS_STREAMS_ADM, DBMS_AQADM TO ggadmin;

GRANT LOGMINING, SELECT ANY TRANSACTION TO apimadmin;
GRANT EXECUTE ON DBMS_LOGMNR, DBMS_LOGMNR_D, DBMS_FLASHBACK,
                 DBMS_CAPTURE_ADM, DBMS_APPLY_ADM,
                 DBMS_STREAMS_ADM, DBMS_AQADM TO apimadmin;
GRANT OGG_CAPTURE, SELECT ANY DICTIONARY TO apimadmin;
GRANT EXECUTE ON DBMS_XSTREAM_GG TO apimadmin;
```

> Oracle's `GRANT EXECUTE ON pkg1, pkg2 TO user` comma syntax works in 23ai; if your sqlplus rejects it, split into individual statements.

---

## Reach the OGG UI via SSH tunnel

Service Manager listens on HTTP 9011; deployment services on 9012 (Administration), 9013 (Distribution), 9014 (Receiver), 9015 (Performance Metrics). Service Manager redirects to absolute URLs on 9012–9015, so the tunnel must cover the whole range.

From your laptop:

```bash
ssh -i <SSH_KEY_PATH> \
  -L 8011:localhost:9011 -L 9012:localhost:9012 -L 9013:localhost:9013 \
  -L 9014:localhost:9014 -L 9015:localhost:9015 \
  <VM_ADMIN_USER>@<DC1-public-ip>
```

If DC1 has no public IP, SSH into a jump host and replace the three right-hand `localhost`s with `<DC1_PRIVATE_IP>`. Open <http://localhost:8011/> (HTTP, not HTTPS), log in as `oggadmin` with `<OGG_ADMIN_PASSWORD>`, change the password, then: `Service Manager > Deployments > Local > Administration Service`. Everything below lives there.

---

## Topology configuration

Goal: **8 DB Connections → 4 Extracts → 4 Replicats → ACDR → coordinated startup.**

### 1. DB Connections (8 total)

`Admin Service > DB Connections > Add Connection`. The 23.26 form uses Oracle Easy Connect in a single **User ID** field.

For each row: User ID from the table, Password = `<DB_PASSWORD>`, Domain = `OracleGoldenGate`, Credential Alias = default (matches Connection Name).

| Connection        | User ID (Easy Connect)                        | Role                     |
|-------------------|-----------------------------------------------|--------------------------|
| `dc1_apim`        | `apimadmin@//<DC1_PRIVATE_IP>:1521/apim_db`   | Extract source (DC1 apim)|
| `dc1_shared`      | `apimadmin@//<DC1_PRIVATE_IP>:1521/shared_db` | Extract source (DC1 shr) |
| `dc2_apim`        | `apimadmin@//<DC2_PRIVATE_IP>:1521/apim_db`   | Extract source (DC2 apim)|
| `dc2_shared`      | `apimadmin@//<DC2_PRIVATE_IP>:1521/shared_db` | Extract source (DC2 shr) |
| `dc1_apim_gg`     | `ggadmin@//<DC1_PRIVATE_IP>:1521/apim_db`     | Replicat target (DC1 apim)|
| `dc1_shared_gg`   | `ggadmin@//<DC1_PRIVATE_IP>:1521/shared_db`   | Replicat target (DC1 shr)|
| `dc2_apim_gg`     | `ggadmin@//<DC2_PRIVATE_IP>:1521/apim_db`     | Replicat target (DC2 apim)|
| `dc2_shared_gg`   | `ggadmin@//<DC2_PRIVATE_IP>:1521/shared_db`   | Replicat target (DC2 shr)|

Click **Test** on each. Red rows mean VNet peering, NSG, or password mismatch — fix before continuing.

Replicats must connect as `ggadmin` so Extract's `EXCLUDEUSER ggadmin` filter matches; connecting Replicats as `apimadmin` causes infinite replication in seconds.

### 2. Per-connection setup

On the **four `apimadmin` connections**, run all three actions (12 UI actions total):

| Action                                  | Input                             |
|-----------------------------------------|-----------------------------------|
| `Checkpoint > Add Checkpoint`           | `GGADMIN.GGS_CHKPT`               |
| `Trandata > Add Schema Trandata`        | Schema `APIMADMIN`, **All Columns** |
| `Heartbeat > Add Heartbeat Table`       | (no parameters)                   |

On the **four `_gg` connections**, run **Heartbeat only** — the underlying tables already exist; heartbeat is tracked per credential alias, so the alias still needs wiring up. Skip Checkpoint and Trandata here.

- Checkpoint lives in `GGADMIN` so Replicat's checkpoint UPDATEs aren't captured by Extract (loopback prevention).
- "All Columns" trandata is required by ACDR's latest-timestamp-wins resolver.
- Heartbeat tables land in `APIMADMIN` (not `GGADMIN`) on this image — expected; they're excluded from capture via the Extract parameter file.

### 3. Extracts (4 total)

`Admin Service > Extracts > Add Extract`. Four-step wizard, run it four times:

| Extract  | Source PDB       | USERIDALIAS  | EXTTRAIL |
|----------|------------------|--------------|----------|
| `EAPIM1` | DC1 `apim_db`    | `dc1_apim`   | `aa`     |
| `EAPIM2` | DC2 `apim_db`    | `dc2_apim`   | `ab`     |
| `ESHR1`  | DC1 `shared_db`  | `dc1_shared` | `ba`     |
| `ESHR2`  | DC2 `shared_db`  | `dc2_shared` | `bb`     |

Wizard fields:

- **Extract Type:** Integrated Extract
- **Trail Name:** two-letter code from the table; Subdirectory: blank
- **Encryption Profile:** `LocalWallet`
- **Source Credentials Alias:** the plain (non-`_gg`) alias from the table; Domain: `OracleGoldenGate`
- **Begin:** Now
- **Managed Options:** Profile `Default`; Critical, Auto Start, Auto Restart all **Off**

In the Parameter File below the auto-generated header, append:

```
TRANLOGOPTIONS EXCLUDEUSER ggadmin
TABLEEXCLUDE APIMADMIN.GG_HEARTBEAT*;
TABLE APIMADMIN.*;
```

Order matters — `TABLEEXCLUDE` must precede `TABLE`. The trailing semicolon on each directive is mandatory.

Click **Create** (not *Create and Run*). All four Extracts end up in **STOPPED** state.

> **Naming quirk:** Extract names cap at 8 chars, Replicat names at 5 (the extra 3 are reserved for apply-thread suffixes).

### 4. Replicats (4 total)

`Admin Service > Replicats > Add Replicat`. Cross-mapping: each Replicat reads the trail written by the Extract on the *opposite* side for the same database.

| Replicat | Reads | Written by | Target PDB       | USERIDALIAS     |
|----------|-------|------------|------------------|-----------------|
| `RAPM1`  | `ab`  | `EAPIM2`   | DC1 `apim_db`    | `dc1_apim_gg`   |
| `RAPM2`  | `aa`  | `EAPIM1`   | DC2 `apim_db`    | `dc2_apim_gg`   |
| `RSHR1`  | `bb`  | `ESHR2`    | DC1 `shared_db`  | `dc1_shared_gg` |
| `RSHR2`  | `ba`  | `ESHR1`    | DC2 `shared_db`  | `dc2_shared_gg` |

Wizard fields:

- **Replicat Type:** Parallel Replicat; **Parallel Replicat Type:** Nonintegrated
- **Replicat Trail Name:** two-letter code from the table
- **Encryption Profile:** `LocalWallet`
- **Target Credentials Alias:** the `_gg` alias from the table; Domain: `OracleGoldenGate`
- **Checkpoint Table:** `"GGADMIN"."GGS_CHKPT"`
- **Begin:** Position in Trail, Sequence `0`, RBA `0`
- **Managed Options:** same as Extracts — all Off

Replace the default `MAP *.*, TARGET *.*;` parameter with:

```
REPERROR (1403, DISCARD)
MAP APIMADMIN.*, TARGET APIMADMIN.*;
```

`REPERROR (1403, DISCARD)` handles ORA-01403 from independent deletes on `UM_ROLE_PERMISSION` during APIM's periodic truncate-and-reseed. Without it, Replicat abends on the first cross-DC overlap.

Click **Create**. Overview now shows **4 Extracts + 4 Replicats, all STOPPED**.

Integrated Parallel Replicat depends on the same wrapper blocked by `ORA-26988`; Nonintegrated sidesteps it and matches APIM control-plane throughput.

### 5. ACDR (run on both DCs)

ACDR adds hidden `CDRTS$*` columns plus delete-tombstone tracking — the source of truth for latest-timestamp-wins when concurrent writes hit the same row. It must be applied on both DCs **before** any process starts.

```sql
SET SERVEROUTPUT ON SIZE UNLIMITED
ALTER SESSION SET CONTAINER = apim_db;
DECLARE v_ok PLS_INTEGER := 0; v_err PLS_INTEGER := 0; BEGIN
  FOR r IN (
    SELECT t.table_name FROM dba_tables t
     WHERE t.owner='APIMADMIN'
       AND t.table_name NOT LIKE 'GG_HEARTBEAT%'
       AND EXISTS (SELECT 1 FROM dba_constraints c
                    WHERE c.owner=t.owner AND c.table_name=t.table_name
                      AND c.constraint_type='P')
  ) LOOP
    BEGIN
      DBMS_GOLDENGATE_ADM.ADD_AUTO_CDR(
        schema_name => 'APIMADMIN', table_name => r.table_name);
      v_ok := v_ok + 1;
    EXCEPTION WHEN OTHERS THEN
      v_err := v_err + 1;
      DBMS_OUTPUT.PUT_LINE('ERR '||r.table_name||': '||SQLERRM);
    END;
  END LOOP;
  DBMS_OUTPUT.PUT_LINE('apim_db ACDR: ok='||v_ok||' errors='||v_err);
END;
/
-- Repeat the block with ALTER SESSION SET CONTAINER = shared_db;
```

Verify: `SELECT COUNT(*) FROM dba_gg_auto_cdr_tables WHERE table_owner='APIMADMIN';` — ~242 in `apim_db`, ~48 in `shared_db`, identical on both DCs. PK-less tables (4 in `apim_db`, 3 in `shared_db`) are skipped silently and fall back to all-column key matching without latest-timestamp conflict handling.

### 6. Coordinated startup

Order: **all 4 Extracts first, then all 4 Replicats.** Starting a Replicat before its source Extract has written trail bytes abends it with a missing-trail error.

`Admin Service > Extracts` — play icon on `EAPIM1`, `EAPIM2`, `ESHR1`, `ESHR2` in turn, waiting for each to reach **Running**.
`Admin Service > Replicats` — same pattern on `RAPM1`, `RAPM2`, `RSHR1`, `RSHR2`.

Steady state: heartbeat lag < 10 s per process. A 20–60 s burst on first Replicat start is normal catch-up.

---

## Verification

Four round-trips, two tables with trigger-assigned PKs — `APIMADMIN.AM_ALERT_TYPES` in `apim_db`, `APIMADMIN.REG_LOG` in `shared_db`.

```sql
-- DC1: insert
ALTER SESSION SET CONTAINER = apim_db;
INSERT INTO apimadmin.am_alert_types (alert_type_name, stake_holder)
VALUES ('test-dc1', 'publisher');
COMMIT;
SELECT alert_type_id FROM apimadmin.am_alert_types WHERE alert_type_name='test-dc1';

-- Wait ~3s. DC2: should return the SAME alert_type_id.
ALTER SESSION SET CONTAINER = apim_db;
SELECT alert_type_id FROM apimadmin.am_alert_types WHERE alert_type_name='test-dc1';

-- DC1: clean up (replicates to DC2)
DELETE FROM apimadmin.am_alert_types WHERE alert_type_name='test-dc1'; COMMIT;
```

Repeat DC2 → DC1 (even-numbered PK on DC2's sequence), and both directions on `shared_db` / `REG_LOG` using `REG_USER_ID='ogg-test-dc1'` / `'ogg-test-dc2'` and `REG_TENANT_ID = -1234`.

The proof of active-active: **seed PKs differ between DCs (odd on DC1, even on DC2) but test-insert PKs are identical on both sides**. Replicat supplies the trail's PK explicitly and 23ai suppresses the target-side trigger — no need for `DBOPTIONS SUPPRESSTRIGGERS`.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---|---|
| `OGG-12982 Failed to establish secure communication` | `https://` against insecure deployment. Use `http://localhost:9012`. |
| `OGG-02062 ... required privileges ... integrated capture` on `REGISTER` | `apimadmin` missing `OGG_CAPTURE` + `SELECT ANY DICTIONARY` + `EXECUTE ON DBMS_XSTREAM_GG` in that PDB. Re-run the grants. |
| `ORA-26988` on any GRANT | You called `dbms_goldengate_auth.grant_admin_privilege`. Use direct `GRANT`s only. |
| Replicat heartbeat warning on `_gg` alias | Skipped `Heartbeat > Add Heartbeat Table` on that `_gg` connection. Add it — the DB tables already exist; this wires up the alias. |
| Gateway logs `Storage returned null` after cross-DC API publish | Replication lag vs. JMS event. Raise `deployment_retry_duration` under `[apim.sync_runtime_artifacts.gateway]` in the gateway `deployment.toml` (start 30 s). |

### Extract abends on first start with `OGG-02024 / OGG-10556 / OGG-01668`

The Extract wizard normally auto-registers the Integrated Extract with the source PDB, creating the matching `OGG$<name>` row in `DBA_CAPTURE`. If that silently fails, the first `Start` abends because there's no LogMiner capture process to attach to. Check from the DB side:

```sql
ALTER SESSION SET CONTAINER = apim_db;
SELECT capture_name, status FROM dba_capture;
-- expect OGG$EAPIM1 (DC1) / OGG$EAPIM2 (DC2), etc.
```

If the row is missing, register manually via `adminclient` — there is no Register action in the Administration Service UI:

```bash
docker exec -it ogg-hub /u01/ogg/bin/adminclient
```

```
CONNECT http://localhost:9012 AS oggadmin PASSWORD <OGG_ADMIN_PASSWORD>
DBLOGIN USERIDALIAS dc1_apim   DOMAIN OracleGoldenGate
REGISTER EXTRACT EAPIM1 DATABASE
DBLOGIN USERIDALIAS dc2_apim   DOMAIN OracleGoldenGate
REGISTER EXTRACT EAPIM2 DATABASE
DBLOGIN USERIDALIAS dc1_shared DOMAIN OracleGoldenGate
REGISTER EXTRACT ESHR1  DATABASE
DBLOGIN USERIDALIAS dc2_shared DOMAIN OracleGoldenGate
REGISTER EXTRACT ESHR2  DATABASE
EXIT
```

> `http://`, not `https://` — insecure deployment. `DBLOGIN` is required before each `REGISTER` because adminclient's `CONNECT` authenticates against the deployment, not the database.

---

## Closing thoughts

- **Move the OGG hub to a dedicated VM** in production — DC1 going down shouldn't take out replication too.
- **Vault the passwords** — `<DB_PASSWORD>` appears in GRANTs, Easy Connect strings, and the GG credential wallet; CSI-injected secrets belong in all three.
- **Automate via the REST API** — `http://localhost:9012/services/v2/` covers everything the UI does. Terraform or a small `curl` script makes rebuilds reproducible.
- **GG Free 23.26 specifics:** no Pipelines/Active-Active wizard; manual `REGISTER EXTRACT` via `adminclient` is the only fallback when the Extract wizard's auto-registration silently fails (the UI has no Register action); use insecure mode behind an SSH tunnel to keep the setup simple; `dbms_goldengate_auth.grant_admin_privilege` is disabled, so direct GRANTs are the supported path.

The result: an API published in Region A is live in Region B within seconds, and either region surviving an outage keeps serving traffic.
