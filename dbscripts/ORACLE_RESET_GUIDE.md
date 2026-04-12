# Oracle 23ai + GoldenGate 23.26 — Full Clean-Slate Reset Guide

Reset the entire Oracle + GoldenGate stack back to an empty state so you can re-run [`ORACLE_OGG_REPLICATION_GUIDE.md`](ORACLE_OGG_REPLICATION_GUIDE.md) from **§4.1** with a completely clean slate. Use this when you want to validate the main guide end-to-end, or when replication state is wedged enough that a surgical fix is more work than a rebuild.

## What this preserves

These are deliberately *not* touched — re-provisioning them is slow and they don't carry any application or replication state:

- Azure VMs (`apim-4-7-eus1-oracle`, `apim-4-7-wus2-oracle`) and networking — NSGs, VNet peering, jump-box hops from Part 1 of the main guide.
- Docker daemon and Oracle Container Registry credentials from Part 2.
- The `oracle-db` container itself, its `oracle-db-data` volume, and all **CDB-level** settings applied in §4.2 of the main guide: `ARCHIVELOG` mode, `FORCE_LOGGING`, minimum supplemental logging, `enable_goldengate_replication`, and the `PROCESSES = 1000` / `SESSIONS = 1522` tuning. These all live in the CDB (SPFILE + control file) and survive a PDB drop.
- The CDB root user `sys` and its password.

## What this nukes

In order:

1. **APIM Helm releases** on both Kubernetes clusters (`cp`, `gw`, `tm`).
2. **The entire `ogg-hub` container + its `ogg-hub-data` volume on DC1** — this deletes the Local deployment, all 8 DB Connections, all 4 Extracts, all 4 Replicats, trail files `aa` / `ab` / `ba` / `bb`, checkpoint table registrations, schema-trandata associations, heartbeat table installs, credential wallet, and the random `oggadmin` UI password. There is no surgical "just delete the processes" path in GG Free 23.26 that's worth the UI clicks — nuking the container is faster and gives you the same end state.
3. **The `apim_db` and `shared_db` PDBs** on *both* DC1 and DC2 — this deletes the `APIMADMIN` and `GGADMIN` schemas, all APIM tables and data, the ACDR hidden-column bookkeeping (`CDRTS$ROW` / per-column `CDRTS$<col>` / tombstone tracking), the checkpoint tables, the heartbeat tables, the `DBA_CAPTURE` rows for `OGG$EAPIM1` / `OGG$EAPIM2` / `OGG$ESHR1` / `OGG$ESHR2` registered in §6.8 of the main guide, and every privilege grant made in §4.1 / §4.6.

At the end of this guide, the only "APIM-aware" state left on either VM is the CDB itself — which is exactly the point §4.1 of the main guide starts from.

## Connection details

Same as the main guide; reproduced here so you don't need to flip between tabs. Replace the password if you changed the default in your deployment.

```bash
# DC1 — East US 1 (Oracle DB + OGG)
export DC1_HOST=10.2.4.4
export DC1_PORT=1521
export DC1_USER=apimadmin
export DC1_PASS="Apim@123"

# DC2 — West US 2 (Oracle DB only)
export DC2_HOST=10.1.4.4
export DC2_PORT=1521
export DC2_USER=apimadmin
export DC2_PASS="Apim@123"
```

---

## Phase 1: Uninstall APIM Helm releases (both DCs)

Before touching any DB or GG state, stop APIM. Leaving pods running while you drop their databases just produces a storm of JDBC reconnect errors in the pod logs; uninstalling is cleaner.

Run on **both** `kubectl` contexts (DC1 AKS and DC2 AKS). If you're using the deploy scripts under `scripts/`, the release names match the ones in `deploy-azure-dc1-oracle.sh` / `deploy-azure-dc2-oracle.sh`:

```bash
# Switch to the DC1 cluster context (see scripts/deploy-azure-dc1-oracle.sh)
kubectl config use-context <DC1-AKS-context>

helm uninstall cp -n apim
helm uninstall gw -n apim
helm uninstall tm -n apim

# Wait for the pods to actually go away
kubectl -n apim get pods -w
```

Repeat for DC2:

```bash
kubectl config use-context <DC2-AKS-context>

helm uninstall cp -n apim
helm uninstall gw -n apim
helm uninstall tm -n apim

kubectl -n apim get pods -w
```

**Verify clean state** — no `wso2am-*` pods in the `apim` namespace on either DC:

```bash
kubectl -n apim get pods          # expect "No resources found in apim namespace"
kubectl -n apim get pvc           # usually also empty, unless you had CP persistence
```

> **Namespace and TLS secret**: the `apim` namespace itself and the `apim-ingress-tls` secret are created by the deploy scripts and are cheap to leave in place — they'll be reused when you re-run the script. Delete them only if you want a truly empty namespace.

---

## Phase 2: Nuke the OGG hub container and its volume (DC1 only)

SSH to the **DC1 VM** (`apim-4-7-eus1-oracle`). The OGG hub is a single container named `ogg-hub` whose state lives entirely on a named volume — killing both the container and the volume wipes the deployment cleanly.

```bash
# On the DC1 VM
docker stop ogg-hub
docker rm   ogg-hub
docker volume rm ogg-hub-data
```

> **Why kill the volume too?** Everything that matters lives on `/u02` inside the container, which is backed by the `ogg-hub-data` named volume: the Local deployment config, the 8 DB Connections (including the stored passwords in the credential wallet), the 4 Extracts, the 4 Replicats, trail files `aa` / `ab` / `ba` / `bb` in `/u02/Local/var/lib/data/`, the generated `oggadmin` UI password from first boot, and the Integrated Extract's AQ queue metadata. If you delete the container but keep the volume, the next `docker run` re-adopts every one of those — you end up with a not-so-clean reset. For a true clean slate, both have to go.

**Verify clean state**:

```bash
docker ps    -a | grep ogg-hub     # expect no rows
docker volume ls  | grep ogg-hub    # expect no rows
```

> **One thing you can skip**: `docker rmi container-registry.oracle.com/goldengate/goldengate-oracle-free:latest`. The image is big (~3 GB), re-downloading it burns bandwidth and OCR pulls can rate-limit. Leaving it cached on disk is fine — it's immutable and the next `docker run` in §5.1 of the main guide will just reuse it.

---

## Phase 3: Drop the PDBs on both DCs

SSH to each DB VM in turn (`apim-4-7-eus1-oracle` for DC1, `apim-4-7-wus2-oracle` for DC2) and drop both PDBs. The CDB itself stays up the whole time — `DROP PLUGGABLE DATABASE` does not require a CDB restart, it just unregisters the PDB from the control file and removes its datafiles.

### 3.1 Phase-1 teardown confirmation

Before dropping, sanity-check that no APIM JDBC sessions are still connected. If Phase 1 completed cleanly the PDB should have only the CDB's own background/maintenance sessions (< 10 rows).

```bash
docker exec -it oracle-db sqlplus / as sysdba
```

```sql
ALTER SESSION SET CONTAINER = apim_db;
SELECT username, program, count(*)
  FROM v$session
 WHERE username IS NOT NULL
 GROUP BY username, program
 ORDER BY 1,2;

ALTER SESSION SET CONTAINER = shared_db;
SELECT username, program, count(*)
  FROM v$session
 WHERE username IS NOT NULL
 GROUP BY username, program
 ORDER BY 1,2;

ALTER SESSION SET CONTAINER = CDB$ROOT;
```

If you still see `APIMADMIN` or `GGADMIN` sessions whose `program` mentions `JDBC Thin Client` or `OGG_Extract` / `OGG_Replicat`, something from Phase 1 or Phase 2 was skipped. Go back and complete them — do not try to drop a PDB while there are still live application sessions against it.

### 3.2 Drop apim_db and shared_db

Run on **both** DCs (same commands):

```sql
-- Still inside sqlplus / as sysdba, at CDB$ROOT after the sanity check above.

ALTER PLUGGABLE DATABASE apim_db   CLOSE IMMEDIATE;
ALTER PLUGGABLE DATABASE shared_db CLOSE IMMEDIATE;

DROP PLUGGABLE DATABASE apim_db   INCLUDING DATAFILES;
DROP PLUGGABLE DATABASE shared_db INCLUDING DATAFILES;

-- Verify: only CDB$ROOT and PDB$SEED should remain
SELECT name, open_mode FROM v$pdbs;
EXIT;
```

Expected output of the last query — exactly these two rows:

```
NAME         OPEN_MODE
------------ ----------
PDB$SEED     READ ONLY
```

(`CDB$ROOT` itself doesn't appear in `v$pdbs` — it's the container.)

If the `CLOSE IMMEDIATE` call hangs or errors with `ORA-65025 pluggable database ... is in use`, see the *"PDB won't close"* section under Troubleshooting below — there's almost always a stray session holding it open.

### 3.3 Confirm CDB-level state survived

These CDB-level settings from §4.2 of the main guide are the ones we're deliberately preserving. Re-checking them gives you confidence that the next run of the main guide can **skip §4.2 entirely**:

```sql
-- still sqlplus / as sysdba at CDB$ROOT
SELECT log_mode, force_logging, supplemental_log_data_min FROM v$database;
SHOW PARAMETER enable_goldengate_replication;
SHOW PARAMETER processes;
SHOW PARAMETER sessions;
EXIT;
```

Expected:

```
LOG_MODE       FORCE_LOGGING  SUPPLEMENTAL_LOG_DATA_MIN
-------------- -------------- -------------------------
ARCHIVELOG     YES            YES

enable_goldengate_replication        TRUE
processes                            1000
sessions                             1522
```

If any of those regressed (most likely scenario: you reset the SPFILE, or you did a `docker rm oracle-db` at some point and lost the `ORACLE_PWD` + parameter state), you'll need to re-apply §4.2 of the main guide after recreating the PDBs — noted in Phase 4 below.

---

## Phase 4: Re-run the main guide from §4.1

At this point both DC VMs hold:

- An `oracle-db` container with a CDB that already has archive log mode, force logging, supplemental logging, `enable_goldengate_replication = TRUE`, and `processes = 1000` — no need to bounce the instance again.
- Empty space where the `apim_db` / `shared_db` PDBs used to live.
- No `ogg-hub` container at all (on DC1).
- No APIM Helm releases on either AKS cluster.

### 4.1 Follow the main guide from §4.1 onwards

Re-run the main guide in order, **starting from §4.1**:

1. **§4.1 — Create PDBs and `apimadmin`**. Run `CREATE PLUGGABLE DATABASE apim_db / shared_db`, `ALTER PLUGGABLE DATABASE ... OPEN SAVE STATE`, create `apimadmin` in each PDB with `GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE`. Same commands on both DCs.
2. **§4.2 — SKIP** the SQL block; the CDB-level settings all survived from the previous run. Do **not** re-run `SHUTDOWN IMMEDIATE / STARTUP MOUNT / ALTER DATABASE ARCHIVELOG;` — it's harmless but pointlessly slow. The only thing you might want to re-run from §4.2 is the verify queries at the end, to reconfirm the same state you already verified in Phase 3.3 above.
   - **Exception**: if Phase 3.3 showed `processes < 1000` or `log_mode = NOARCHIVELOG`, you *do* need to run §4.2 from the top. That restores both with a single bounce.
3. **§4.3 — Load the APIM schemas**. `docker cp` the per-DC table + sequence scripts and run them through sqlplus. DC1 uses `dbscripts/dc1/Oracle/*`, DC2 uses `dbscripts/dc2/Oracle/*`. The split-sequence offsets (DC1 odd, DC2 even) come from these files as-is — do not re-edit them.
4. **§4.4 — Verify schema load**. `SELECT COUNT(*) FROM USER_TABLES` should return a nonzero count, and the `DATA_DEFAULT` check on `IDN_OAUTH2_ACCESS_TOKEN.DCID` should return `'DC1'` on DC1 and `'DC2'` on DC2.
5. **§4.5 — Sanity-check DB-to-DB reachability**. `nc -zv 10.1.4.4 1521` from DC1 and `nc -zv 10.2.4.4 1521` from DC2. Unless you changed an NSG rule, this should Just Work.
6. **§4.6 — Create `ggadmin` and grant GG privileges** in both PDBs on both DCs. This includes `LOGMINING` and `OGG_CAPTURE` + `SELECT ANY DICTIONARY` + `EXECUTE ON DBMS_XSTREAM_GG` for `apimadmin` — the ones that let §6.8 succeed.
7. **§Part 5 — Start the OGG hub container on DC1**. `docker volume create ogg-hub-data; docker run -d --name ogg-hub --network host -v ogg-hub-data:/u02 container-registry.oracle.com/goldengate/goldengate-oracle-free:latest`. Grab the new `oggadmin` password from the container logs (it's randomly regenerated on first boot of the new volume — the password from the *previous* run is gone along with the volume). SSH-tunnel 8011→9011 + 9012–9015, force the first-login password change, click into `Deployments → Local → Administration Service`.
8. **§Part 6 — Rebuild the Active-Active topology** from scratch. All 6.x subsections in order: §6.1 four `apimadmin` connections, §6.2 checkpoint + trandata + heartbeat on each of the four, §6.3 four `ggadmin` (`_gg`) connections with heartbeat-only, §6.4 four Extracts (`EAPIM1/2`, `ESHR1/2`), §6.5 four Replicats (`RAPM1/2`, `RSHR1/2`), §6.6 verify schema trandata via `DBA_CAPTURE_PREPARED_TABLES`, §6.7 ACDR loop on both DCs, §6.8 `REGISTER EXTRACT` from `adminclient`, §6.9 coordinated startup (all 4 Extracts first, then all 4 Replicats), §6.10 round-trip verification.

### 4.2 Re-deploy APIM

After §6.10 confirms replication is live, re-deploy APIM from the deploy scripts:

```bash
# DC1
kubectl config use-context <DC1-AKS-context>
./scripts/deploy-azure-dc1-oracle.sh

# DC2
kubectl config use-context <DC2-AKS-context>
./scripts/deploy-azure-dc2-oracle.sh
```

Watch for the pods to all go `Running` and `Ready` on both sides. First-startup schema initialization (admin user, default policies) on DC1 will ship to DC2 through GoldenGate — confirm with the quick check below.

### 4.3 Quick post-reset replication test

On **DC2**, shortly after APIM on DC1 has finished its first startup:

```bash
docker exec -i oracle-db sqlplus 'apimadmin/"Apim@123"@localhost:1521/shared_db' <<'SQL'
SELECT um_user_name FROM um_user WHERE rownum <= 5;
EXIT;
SQL
```

You should see the `admin` user (created by the DC1 first startup) replicated across the link. That closes the loop — the rebuild is verified end-to-end.

---

## Troubleshooting

### "PDB won't close: ORA-65025 pluggable database apim_db is in use"

Despite Phase 1 tearing down APIM, a stray JDBC session or a lingering GG-side connection can keep a PDB pinned. Kill it and retry:

```sql
ALTER SESSION SET CONTAINER = apim_db;

-- List what's still connected (filter out Oracle's own background programs)
SELECT sid, serial#, username, program, status
  FROM v$session
 WHERE username IS NOT NULL
 ORDER BY username, program;

-- Terminate each application session
ALTER SYSTEM KILL SESSION 'sid,serial#' IMMEDIATE;

-- Retry the close
ALTER SESSION SET CONTAINER = CDB$ROOT;
ALTER PLUGGABLE DATABASE apim_db CLOSE IMMEDIATE;
```

If `KILL SESSION` itself errors with `ORA-00031 session marked for kill`, the session is mid-commit and will clear on its own within a few seconds — just wait and retry the close.

### "DROP PLUGGABLE DATABASE ... hangs"

Usually means there's still a Replicat session from the *other* DC's `ogg-hub` holding an apply connection. If Phase 2 nuked `ogg-hub` on DC1, this shouldn't happen — but if you get here with DC2 PDBs still wedged, double-check that there is no `ogg-hub` container anywhere in your topology that you forgot about:

```bash
# On each VM
docker ps -a --filter name=ogg-hub
```

If one comes back, stop and remove it, then retry the `DROP PLUGGABLE DATABASE`.

### OGG volume delete fails: "volume is in use"

If `docker volume rm ogg-hub-data` errors with `volume is in use`, the `ogg-hub` container didn't fully exit between the `docker stop` and `docker rm`. Force it:

```bash
docker rm -f ogg-hub
docker volume rm ogg-hub-data
```

`docker rm -f` sends `SIGKILL` and removes the container in one step, which releases the volume's reference count immediately.

### CDB-level state regressed during the reset

If Phase 3.3 shows `processes = 200` or `log_mode = NOARCHIVELOG`, the SPFILE was lost at some point (usually a `docker rm oracle-db` earlier in the session, or an intentional `docker volume rm oracle-db-data` to start fully fresh). In that case Phase 4.1 needs to run **all of §4.2** — not just the skip path — because you'll need the archive-log bounce *plus* the `PROCESSES = 1000` bump *plus* force logging and supplemental logging from scratch.

If the CDB is wedged hard enough that re-running §4.2 itself fails, the next escalation is the *"Hard reset of a DB container (data loss)"* section in Part 7 of the main guide — which is `docker rm -f oracle-db; docker volume rm oracle-db-data; re-run Part 3 then Part 4 from scratch`. That's the next level of reset below this guide.

### Stale wallet or stored credentials after a re-add

This isn't a concern for the full reset (Phase 2 nukes the wallet with the volume), but it's worth knowing for later: the GG credential wallet lives at `/u02/Local/var/lib/credentials/` inside the `ogg-hub` container. If a single `_gg` connection breaks but the rest of the hub is healthy and you don't want to rebuild, you can delete and re-add just that one connection through the UI — the wallet is an append-only store of `{alias → encrypted password}` entries and re-adding the alias overwrites the slot.
