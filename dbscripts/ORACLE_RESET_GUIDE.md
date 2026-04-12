# Oracle 23ai + GoldenGate 23.26 — Full Clean-Slate Reset Guide

Reset the entire Oracle + GoldenGate stack back to an empty state so you can re-run [`ORACLE_OGG_REPLICATION_GUIDE.md`](ORACLE_OGG_REPLICATION_GUIDE.md) from **§4.1** with a completely clean slate. Use this when you want to validate the main guide end-to-end, or when replication state is wedged enough that a surgical fix is more work than a rebuild.

## What this preserves

These are deliberately *not* touched — re-provisioning them is slow and they don't carry any application or replication state:

- Azure VMs (`apim-4-7-eus1-oracle`, `apim-4-7-wus2-oracle`) and networking — NSGs, VNet peering, jump-box hops from Part 1 of the main guide.
- Docker daemon, Oracle Container Registry credentials, and the cached Docker images (`oracle-free:23`, `goldengate-oracle-free:latest`) from Parts 2–3. Re-downloading multi-GB images is slow and OCR rate-limits pulls; keeping the image cache is free.

## What this nukes

In order:

1. **APIM Helm releases** on both Kubernetes clusters (`cp`, `gw`, `tm`).
2. **The entire `ogg-hub` container + its `ogg-hub-data` volume on DC1** — deletes the Local deployment, all 8 DB Connections, all 4 Extracts, all 4 Replicats, trail files, checkpoint registrations, schema-trandata associations, heartbeat tables, credential wallet, and the random `oggadmin` UI password.
3. **The `oracle-db` container + its `oracle-db-data` volume on *both* DC1 and DC2** — deletes the CDB itself and everything inside it: the `apim_db` and `shared_db` PDBs, the `APIMADMIN` and `GGADMIN` schemas, all APIM tables and data, ACDR hidden-column bookkeeping, checkpoint tables, heartbeat tables, registered Extracts, and every privilege grant. Also wipes the CDB-level SPFILE settings from §4.2 (archive log mode, supplemental logging, `enable_goldengate_replication`, `PROCESSES = 1000`) — those get re-applied on the next run.

At the end of this guide, both VMs have no Oracle DB or OGG containers at all — a completely empty Docker host, images intact, ready for a fresh run from §Part 3 of the main guide.

---

## Phase 1: Uninstall APIM Helm releases (both DCs)

Before touching any DB or GG containers, stop APIM. Leaving pods running while the databases they're connected to are being destroyed produces a storm of JDBC reconnect errors in the pod logs; uninstalling is cleaner.

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

SSH to the **DC1 VM** (`apim-4-7-eus1-oracle`). The OGG hub state lives entirely on the `ogg-hub-data` named volume — kill both the container and the volume.

```bash
# On the DC1 VM
docker stop ogg-hub
docker rm   ogg-hub
docker volume rm ogg-hub-data
```

**Verify clean state**:

```bash
docker ps -a | grep ogg-hub       # expect no rows
docker volume ls | grep ogg-hub   # expect no rows
```

> The `goldengate-oracle-free:latest` image itself can stay cached — re-downloading a multi-GB image from OCR is slow and pointless. The next `docker run` in §Part 5 of the main guide will reuse it.

---

## Phase 3: Nuke the Oracle DB containers and volumes (both DCs)

SSH to each DB VM in turn — **DC1** (`apim-4-7-eus1-oracle`) and **DC2** (`apim-4-7-wus2-oracle`) — and run the same three commands:

```bash
# Run on BOTH DC1 and DC2
docker stop oracle-db
docker rm   oracle-db
docker volume rm oracle-db-data
```

**Verify clean state** (on each DC):

```bash
docker ps -a | grep oracle-db       # expect no rows
docker volume ls | grep oracle-db   # expect no rows
```

> **Why kill the volume?** The Oracle data volume (`oracle-db-data`) holds the CDB datafiles, SPFILE, and redo logs. Everything — the PDBs, the `apimadmin`/`ggadmin` users, the ACDR hidden columns, the registered Extracts — lives in there. Killing the container but keeping the volume means the next `docker run` picks up the same state you're trying to wipe. Kill both.
>
> The `oracle-free:23` image can stay cached — same reasoning as OGG above.
>
> When you run the Oracle container next time, Oracle will reinitialize the CDB from scratch (takes ~5–10 minutes on first boot). That's the price of a clean slate; it's worth it to avoid the session-kill and PDB-drop complexity.

---

## Phase 4: Re-run the main guide from §Part 3

At this point both DC VMs have:

- No Oracle DB container or data volume.
- No `ogg-hub` container or data volume (DC1 only).
- No APIM Helm releases on either AKS cluster.
- Both Docker image caches intact.

### 4.1 Follow the main guide from §Part 3 onwards

Re-run the main guide **in full order**, starting from §Part 3:

1. **§Part 3 — Start the Oracle DB container** on each DC. `docker run -d --name oracle-db ...`. Wait for the CDB init to complete (watch `docker logs -f oracle-db` for `DATABASE IS READY TO USE`).
2. **§4.1 — Create PDBs and `apimadmin`**. `CREATE PLUGGABLE DATABASE apim_db / shared_db`, `ALTER PLUGGABLE DATABASE ... OPEN SAVE STATE`, `apimadmin` with `GRANT CONNECT, RESOURCE, DBA, UNLIMITED TABLESPACE` in each PDB. Same on both DCs.
3. **§4.2 — Enable archive log mode, supplemental logging, GoldenGate replication, and bump PROCESSES**. Run the full block including `ALTER SYSTEM SET PROCESSES=1000 SCOPE=SPFILE`, `SHUTDOWN IMMEDIATE / STARTUP MOUNT / ALTER DATABASE ARCHIVELOG / ...`. **Do not skip** — the new volume has none of these settings.
4. **§4.3 — Load the APIM schemas**. `docker cp` the per-DC scripts and run through sqlplus. DC1 uses `dbscripts/dc1/Oracle/*`, DC2 uses `dbscripts/dc2/Oracle/*`.
5. **§4.4 — Verify schema load**. `SELECT COUNT(*) FROM USER_TABLES` and the `DCID` default check.
6. **§4.5 — Sanity-check DB-to-DB reachability**. `nc -zv 10.1.4.4 1521` from DC1, `nc -zv 10.2.4.4 1521` from DC2.
7. **§4.6 — Create `ggadmin` and grant GG privileges** in both PDBs on both DCs.
8. **§Part 5 — Start the OGG hub container on DC1**. `docker volume create ogg-hub-data; docker run -d --name ogg-hub ...`. Grab the new `oggadmin` password from the container logs. SSH-tunnel, force first-login password change, open Administration Service.
9. **§Part 6 — Rebuild the Active-Active topology** from scratch. All 6.x subsections in order: §6.1 four `apimadmin` connections, §6.2 checkpoint + trandata + heartbeat, §6.3 four `ggadmin` (`_gg`) connections, §6.4 four Extracts (`EAPIM1/2`, `ESHR1/2`), §6.5 four Replicats (`RAPM1/2`, `RSHR1/2`), §6.7 ACDR loop on both DCs, §6.8 `REGISTER EXTRACT` via `adminclient`, §6.9 coordinated startup, §6.10 round-trip verification.

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

### Container volume delete fails: "volume is in use"

If `docker volume rm` errors with `volume is in use`, the container didn't fully exit between `docker stop` and `docker rm`. Force it:

```bash
docker rm -f oracle-db   && docker volume rm oracle-db-data   # DB
docker rm -f ogg-hub     && docker volume rm ogg-hub-data     # OGG
```

`docker rm -f` sends `SIGKILL` and removes the container in one step, which releases the volume's reference count immediately.

### Stale wallet or stored credentials after a re-add

This isn't a concern for the full reset (Phase 2 nukes the wallet with the volume), but it's worth knowing for later: the GG credential wallet lives at `/u02/Local/var/lib/credentials/` inside the `ogg-hub` container. If a single `_gg` connection breaks but the rest of the hub is healthy and you don't want to rebuild, you can delete and re-add just that one connection through the UI — the wallet is an append-only store of `{alias → encrypted password}` entries and re-adding the alias overwrites the slot.
