# Deploying WSO2 API Manager 4.7 Across Two Azure Regions with Bi-Directional Database Replication

A step-by-step guide to setting up WSO2 APIM 4.7 in a multi-datacenter configuration on Azure Kubernetes Service (AKS), using pglogical for bi-directional PostgreSQL replication and JMS for cross-region event synchronization.

---

## Why Multi-DC?

If your API platform serves users across geographies, a single-region deployment means:

- **High latency** for users far from the deployment region
- **Single point of failure** — a regional outage takes down your entire API layer
- **No disaster recovery** for API management operations

WSO2 APIM's **Multi-DC Pattern 1** solves this by running independent APIM clusters in two regions, connected by:

1. **Bi-directional database replication** (pglogical) — API definitions, subscriptions, and OAuth tokens are synchronized in near real-time
2. **Cross-DC JMS event publishing** — real-time notifications for API deployments, token revocations, and key updates propagate instantly between regions

The result: an API published in Region A is automatically available in Region B within seconds, without any manual intervention.

---

## Architecture

```
          Region 1 (East US 2)                            Region 2 (West US 2)
    ┌─────────────────────────────────┐                ┌─────────────────────────────────┐
    │         AKS Cluster             │   VNet Peering  │         AKS Cluster             │
    │                                 │◄──────────────►│                                 │
    │  CP-1 ──┐                       │                 │                       ┌── CP-1  │
    │  CP-2 ──┤ Control Plane (9443)  │   JMS (5672)    │  Control Plane (9443) ├── CP-2  │
    │         │                       │◄───────────────►│                       │         │
    │  TM-1 ──┤ Traffic Mgr          │                 │  Traffic Mgr          ├── TM-1  │
    │  TM-2 ──┘                       │                 │                       └── TM-2  │
    │                                 │                 │                                 │
    │  GW-1 ──┐ Gateway (8243)        │                 │  Gateway (8243)       ┌── GW-1  │
    │  GW-2 ──┘ via NGINX Ingress     │                 │  via NGINX Ingress    └── GW-2  │
    │                                 │                 │                                 │
    │  ┌────────────────────────────┐ │                 │ ┌────────────────────────────┐  │
    │  │ PostgreSQL Flexible Server │ │  pglogical      │ │ PostgreSQL Flexible Server │  │
    │  │ apim_db + shared_db        │ │◄───────────────►│ │ apim_db + shared_db        │  │
    │  └────────────────────────────┘ │  bi-directional │ └────────────────────────────┘  │
    └─────────────────────────────────┘                └─────────────────────────────────┘
```

**Per region:** 2 Control Plane + 2 Traffic Manager + 2 Gateway = **6 pods**

### Component Roles

| Component | Role |
|-----------|------|
| **Control Plane (CP)** | Hosts Publisher, DevPortal, Admin Portal, and embedded Key Manager. The management brain. |
| **Traffic Manager (TM)** | Evaluates throttling policies in real-time using Siddhi stream processing. |
| **Gateway (GW)** | The data plane — routes API traffic, enforces security, applies throttling decisions. |

### How They Connect

| From → To | Protocol | Purpose |
|-----------|----------|---------|
| GW → CP | HTTPS (9443) | Fetch API definitions, validate subscriptions |
| GW → TM | Thrift (9611/9711) | Publish request events for throttle evaluation |
| TM → CP | HTTPS (9443) | Retrieve throttling policies |
| CP → GW, TM | JMS (5672) | Broadcast events: API deploy, token revocation, key updates |
| CP → CP (cross-DC) | JMS (5672) via ILB | Propagate events to the remote region's Control Plane |
| All → PostgreSQL | JDBC (5432) | `apim_db` (API metadata, tokens) + `shared_db` (user store, registry) |

---

## Prerequisites

Before starting, you should have:

- **Two AKS clusters** — one in each Azure region, deployed into VNets that are peered with each other
- **Two Azure PostgreSQL Flexible Server instances** — one per region, accessible from the AKS clusters in their respective regions
- **VNet peering** between the two regions — enables cross-DC database replication and JMS communication
- **Tools:** `kubectl`, `helm` v3+, `psql`, Azure CLI (`az`)

> **Note:** This guide assumes your AKS clusters and PostgreSQL servers are already provisioned. We focus on the *configuration* that makes multi-DC work — not the basic Azure resource creation.

### Networking Layout

| Subnet | Purpose |
|--------|---------|
| DB subnet | PostgreSQL Flexible Server (delegated) |
| AKS subnet | AKS node pool |

Both subnets live in the same VNet per region. VNet peering connects the two regional VNets, giving pods in Region 1 network access to the database and ILB in Region 2 (and vice versa).

### Connection Details Used in This Guide

```bash
# Region 1 — East US 2
DC1_HOST=apim-db-eastus2.postgres.database.azure.com
DC1_USER=apimadmin_east
DC1_AKS_CONTEXT=aks-apim-eastus2

# Region 2 — West US 2
DC2_HOST=apim-db-westus2.postgres.database.azure.com
DC2_USER=apimadmin_west
DC2_AKS_CONTEXT=aks-apim-westus2

# Hostnames (configure in DNS or /etc/hosts later)
# Region 1: cp.eastus2.example.com, gw.eastus2.example.com
# Region 2: cp.westus2.example.com, gw.westus2.example.com
```

---

## Part 1: Database Configuration with pglogical

pglogical provides logical replication for PostgreSQL — it replicates row-level changes (INSERT, UPDATE, DELETE) between two independent PostgreSQL instances. Unlike streaming replication, both sides are fully writable.

### 1.1 Configure Server Parameters

Set these on **both** PostgreSQL Flexible Server instances (via Azure Portal → Server Parameters, or Azure CLI):

| Parameter | Value | Why |
|-----------|-------|-----|
| `wal_level` | `logical` | Required for logical replication |
| `max_worker_processes` | `16` | pglogical needs background workers |
| `max_replication_slots` | `10` | At least 2 per replicated database |
| `max_wal_senders` | `10` | At least 2 per replicated database |
| `track_commit_timestamp` | `on` | Required for conflict resolution |
| `shared_preload_libraries` | `pglogical` | Load the extension at startup |
| `azure.extensions` | `pglogical` | Allow the extension on Azure |

```bash
# Example for Region 1 (repeat for Region 2 with the other server name)
az postgres flexible-server parameter set \
  --resource-group rg-apim-multi-dc \
  --server-name apim-db-eastus2 \
  --name wal_level --value logical

az postgres flexible-server parameter set \
  --resource-group rg-apim-multi-dc \
  --server-name apim-db-eastus2 \
  --name max_worker_processes --value 16

# ... repeat for each parameter
```

**Restart both servers** after changing parameters.

### 1.2 Grant Replication Privileges

On **Region 1** (`psql` connected to the Region 1 server):
```sql
GRANT azure_pg_admin TO apimadmin_east;
ALTER ROLE apimadmin_east REPLICATION LOGIN;
```

On **Region 2** (`psql` connected to the Region 2 server):
```sql
GRANT azure_pg_admin TO apimadmin_west;
ALTER ROLE apimadmin_west REPLICATION LOGIN;
```

### 1.3 Create Databases and Extension

On **both** servers:
```sql
CREATE DATABASE apim_db;
CREATE DATABASE shared_db;
```

Then create the pglogical extension in **each database** on **both** servers (4 total):
```sql
\c apim_db
CREATE EXTENSION IF NOT EXISTS pglogical;

\c shared_db
CREATE EXTENSION IF NOT EXISTS pglogical;
```

### 1.4 Run DC-Specific Table Scripts

This is the key to avoiding primary key collisions in bi-directional replication. Each region uses **interleaved sequences**:

| | Region 1 | Region 2 |
|--|----------|----------|
| Sequences | `START 1 INCREMENT 2` (1, 3, 5, 7...) | `START 2 INCREMENT 2` (2, 4, 6, 8...) |
| DCID (OAuth tokens) | `'DC1'` | `'DC2'` |

WSO2 provides base SQL scripts. You need two copies — one modified for each region's sequence offsets. Apply them:

**Region 1:**
```bash
psql -h $DC1_HOST -U $DC1_USER -d shared_db -f dbscripts/dc1/Postgresql/tables.sql
psql -h $DC1_HOST -U $DC1_USER -d apim_db -f dbscripts/dc1/Postgresql/apimgt/tables.sql
```

**Region 2:**
```bash
psql -h $DC2_HOST -U $DC2_USER -d shared_db -f dbscripts/dc2/Postgresql/tables.sql
psql -h $DC2_HOST -U $DC2_USER -d apim_db -f dbscripts/dc2/Postgresql/apimgt/tables.sql
```

### 1.5 Create pglogical Nodes

Each database on each server needs a **node** — this represents the database instance in the replication topology.

**Region 1 — apim_db:**
```sql
-- psql connected to Region 1, apim_db
SELECT pglogical.create_node(
    node_name := 'dc1-apim',
    dsn := 'host=apim-db-eastus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmin_east password=<your-db-password>'
);
```

**Region 1 — shared_db:**
```sql
-- psql connected to Region 1, shared_db
SELECT pglogical.create_node(
    node_name := 'dc1-shared',
    dsn := 'host=apim-db-eastus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmin_east password=<your-db-password>'
);
```

**Region 2 — apim_db:**
```sql
-- psql connected to Region 2, apim_db
SELECT pglogical.create_node(
    node_name := 'dc2-apim',
    dsn := 'host=apim-db-westus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmin_west password=<your-db-password>'
);
```

**Region 2 — shared_db:**
```sql
-- psql connected to Region 2, shared_db
SELECT pglogical.create_node(
    node_name := 'dc2-shared',
    dsn := 'host=apim-db-westus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmin_west password=<your-db-password>'
);
```

### 1.6 Add Tables to Replication Sets

On **all 4 databases** (apim_db and shared_db on both regions):

```sql
SELECT pglogical.replication_set_add_all_tables('default', ARRAY['public']);
```

This adds every table in the `public` schema to the default replication set. All WSO2 APIM tables have primary keys, which pglogical requires.

### 1.7 Create Bi-Directional Subscriptions

This is where the magic happens. Each region subscribes to the other's changes.

**Step 1: Region 2 subscribes to Region 1**

```sql
-- psql connected to Region 2, apim_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-db-eastus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmin_east password=<your-db-password>',
    synchronize_data := false,
    forward_origins := '{}'
);
```

```sql
-- psql connected to Region 2, shared_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc2_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-db-eastus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmin_east password=<your-db-password>',
    synchronize_data := false,
    forward_origins := '{}'
);
```

**Step 2: Region 1 subscribes to Region 2** (reverse direction)

```sql
-- psql connected to Region 1, apim_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_apim',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-db-westus2.postgres.database.azure.com port=5432 dbname=apim_db user=apimadmin_west password=<your-db-password>',
    synchronize_data := false,
    forward_origins := '{}'
);
```

```sql
-- psql connected to Region 1, shared_db
SELECT pglogical.create_subscription(
    subscription_name := 'dc1_sub_shared',
    replication_sets := ARRAY['default'],
    provider_dsn := 'host=apim-db-westus2.postgres.database.azure.com port=5432 dbname=shared_db user=apimadmin_west password=<your-db-password>',
    synchronize_data := false,
    forward_origins := '{}'
);
```

**Two critical parameters explained:**

- **`synchronize_data := false`** — Both databases are freshly created with identical schemas and no data, so there's nothing to sync. On Azure Flexible Server, setting this to `true` on empty databases can cause pglogical to get stuck in a non-recoverable state.

- **`forward_origins := '{}'`** — This prevents **replication loops**. Without it, a row inserted in Region 1 gets replicated to Region 2, which then replicates it *back* to Region 1, and so on forever. The empty array means "only replicate changes that originated locally."

### 1.8 Verify Replication

On **both** servers, check subscription status:
```sql
SELECT subscription_name, status FROM pglogical.show_subscription_status();
```

All subscriptions should show `replicating`:
```
 subscription_name |   status
-------------------+-------------
 dc1_sub_apim      | replicating
 dc1_sub_shared    | replicating
```

**Quick test** — insert a row on Region 1, check it appears on Region 2:
```sql
-- On Region 1
INSERT INTO AM_ALERT_TYPES (ALERT_TYPE_ID, ALERT_TYPE_NAME, STAKE_HOLDER)
VALUES (999, 'test-replication', 'admin-dashboard');

-- On Region 2 (should appear within seconds)
SELECT * FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;

-- Clean up (run on either region — will replicate to the other)
DELETE FROM AM_ALERT_TYPES WHERE ALERT_TYPE_ID = 999;
```

---

## Part 2: Install NGINX Ingress Controller

Install NGINX Ingress on **both** AKS clusters:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

# Region 1
kubectl config use-context aks-apim-eastus2
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.externalTrafficPolicy=Local

# Region 2
kubectl config use-context aks-apim-westus2
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  --set controller.replicaCount=2 \
  --set controller.service.externalTrafficPolicy=Local
```

### Why `externalTrafficPolicy=Local`?

This is critical on AKS. With the default policy (`Cluster`), Azure Load Balancer sends health probes to the NGINX NodePort on path `/`. NGINX returns `404` (no matching Host header), the LB marks all backends as unhealthy, and **silently drops all traffic**. There's no error — connections just time out.

`Local` mode exposes a dedicated health check port (`/healthz`) that returns `200`, so the LB correctly detects healthy backends. It also preserves the client's real source IP.

---

## Part 3: Helm Values Configuration

WSO2 APIM 4.7 provides separate Helm charts for each component in the distributed deployment. Each chart has a `values.yaml` — you create per-region overrides.

### JDBC Driver Init Container

The APIM Docker images don't include JDBC drivers. Each component needs an init container that downloads the PostgreSQL driver at startup:

```yaml
kubernetes:
  initContainers:
    - name: postgresql-driver-init
      image: busybox:1.36
      command:
        - /bin/sh
        - -c
        - |
          wget -O /jdbc-driver/postgresql-42.7.4.jar \
            "https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar"
      volumeMounts:
        - name: postgresql-driver-vol
          mountPath: /jdbc-driver
  extraVolumes:
    - name: postgresql-driver-vol
      emptyDir: {}
  extraVolumeMounts:
    - name: postgresql-driver-vol
      mountPath: /home/wso2carbon/<product-home>/repository/components/lib/postgresql-42.7.4.jar
      subPath: postgresql-42.7.4.jar
      readOnly: true
```

> The `<product-home>` path differs per component: `wso2am-acp-4.7.0-alpha` (CP), `wso2am-universal-gw-4.7.0-alpha` (GW), `wso2am-tm-4.7.0-alpha` (TM). This init container pattern is the same across all three — only the mount path changes.

### Control Plane Values

Here's the Region 1 Control Plane values file. I'll highlight the key sections:

```yaml
# azure-values-dc1.yaml (Control Plane)
fullnameOverride: "wso2am-cp"

kubernetes:
  ingress:
    controlPlane:
      enabled: true
      hostname: "cp.eastus2.example.com"           # <-- Region-specific
      annotations:
        kubernetes.io/ingress.class: nginx
        nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
        nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"   # <-- Important!

wso2:
  apim:
    configurations:
      transport:
        https:
          proxyPort: 443          # <-- Tells APIM it's behind a reverse proxy on port 443

      databases:
        type: "postgres"
        jdbc:
          driver: "org.postgresql.Driver"
        apim_db:
          url: "jdbc:postgresql://apim-db-eastus2.postgres.database.azure.com:5432/apim_db?sslmode=require"
          username: "apimadmin_east"               # <-- Region-specific
          password: "<your-db-password>"
        shared_db:
          url: "jdbc:postgresql://apim-db-eastus2.postgres.database.azure.com:5432/shared_db?sslmode=require"
          username: "apimadmin_east"
          password: "<your-db-password>"

      gateway:
        environments:
          - name: "Default"
            type: "hybrid"
            gatewayType: "Regular"
            provider: "wso2"
            displayInApiConsole: true
            description: "Region 1 Gateway - East US 2"  # <-- Region-specific
            showAsTokenEndpointUrl: true
            serviceName: "wso2am-gw-service"
            servicePort: 9443
            wsHostname: "gw.eastus2.example.com"          # <-- Region-specific
            httpHostname: "gw.eastus2.example.com"
            websubHostname: "gw.eastus2.example.com"

  deployment:
    highAvailability: true        # <-- Deploys 2 CP instances for HA
    resources:
      requests:
        memory: "4Gi"
        cpu: "1500m"
      limits:
        memory: "4Gi"
        cpu: "1800m"
      jvm:
        memory:
          xms: "1024m"
          xmx: "2048m"
```

**Key things that change between regions:**
- `kubernetes.ingress.controlPlane.hostname`
- `databases.apim_db.url` and `databases.shared_db.url` (point to the local region's DB)
- `databases.*.username` (each region has its own DB user)
- `gateway.environments[0].description`, `wsHostname`, `httpHostname`, `websubHostname`

> **Why `proxy-buffer-size: "16k"`?** WSO2's OAuth responses include large headers. Without this, NGINX returns `502 Bad Gateway` on Publisher/DevPortal login callbacks because the upstream response headers exceed the default 4k buffer.

### Gateway Values

```yaml
# azure-values-dc1.yaml (Gateway)
fullnameOverride: "wso2am-gw"

kubernetes:
  ingress:
    gateway:
      enabled: true
      hostname: "gw.eastus2.example.com"

wso2:
  apim:
    configurations:
      databases:
        shared_db:
          url: "jdbc:postgresql://apim-db-eastus2.postgres.database.azure.com:5432/shared_db?sslmode=require"
          username: "apimadmin_east"
          password: "<your-db-password>"

      # Gateway connects to the local CP for key validation and API definitions
      km:
        serviceUrl: "wso2am-cp-service"
        servicePort: 9443
      throttling:
        serviceUrl: "wso2am-cp-service"
        servicePort: 9443
        urls:
          - "wso2am-cp-1-service"    # Individual CP instance services
          - "wso2am-cp-2-service"    # for Thrift event publishing
      eventhub:
        enabled: true
        serviceUrl: "wso2am-cp-service"
        servicePort: 9443
        urls:
          - "wso2am-cp-1-service"
          - "wso2am-cp-2-service"

  deployment:
    replicas: 2
    minReplicas: 2
    maxReplicas: 4
```

> **Important:** The Gateway only connects to `shared_db`, not `apim_db`. It gets API definitions from the local CP via HTTPS, not directly from the database. The `km`, `throttling`, and `eventhub` sections all point to the **local** CP services — the Gateway never talks directly to the remote region.

### Traffic Manager Values

```yaml
# azure-values-dc1.yaml (Traffic Manager)
fullnameOverride: "wso2am-tm"

wso2:
  apim:
    configurations:
      databases:
        apim_db:
          url: "jdbc:postgresql://apim-db-eastus2.postgres.database.azure.com:5432/apim_db?sslmode=require"
          username: "apimadmin_east"
          password: "<your-db-password>"
        shared_db:
          url: "jdbc:postgresql://apim-db-eastus2.postgres.database.azure.com:5432/shared_db?sslmode=require"
          username: "apimadmin_east"
          password: "<your-db-password>"

      km:
        serviceUrl: "wso2am-cp-service"
        servicePort: 9443
      eventhub:
        serviceUrl: "wso2am-cp-service"
        urls:
          - "wso2am-cp-1-service"
          - "wso2am-cp-2-service"

  deployment:
    highAvailability: true
```

> The TM connects to both databases and to the local CP. Like the Gateway, it never communicates directly with the remote region.

---

## Part 4: Deploy APIM on Both Regions

Deploy in order: **Control Plane → Traffic Manager → Gateway**. The TM and GW depend on the CP being up first.

### Region 1 (East US 2)

```bash
kubectl config use-context aks-apim-eastus2
kubectl create namespace apim

# Control Plane (HA — 2 instances)
helm install cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc1.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=600s

# Traffic Manager (HA — 2 instances)
helm install tm ./distributed/traffic-manager -n apim \
    -f distributed/traffic-manager/azure-values-dc1.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n apim --timeout=600s

# Gateway (2 replicas)
helm install gw ./distributed/gateway -n apim \
    -f distributed/gateway/azure-values-dc1.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n apim --timeout=600s
```

### Region 2 (West US 2)

```bash
kubectl config use-context aks-apim-westus2
kubectl create namespace apim

helm install cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=600s

helm install tm ./distributed/traffic-manager -n apim \
    -f distributed/traffic-manager/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n apim --timeout=600s

helm install gw ./distributed/gateway -n apim \
    -f distributed/gateway/azure-values-dc2.yaml
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n apim --timeout=600s
```

### Verify — 6 pods per region

```bash
kubectl get pods -n apim
```

```
NAME                                       READY   STATUS    AGE
wso2am-cp-deployment-1-...                 1/1     Running   ...
wso2am-cp-deployment-2-...                 1/1     Running   ...
wso2am-tm-deployment-1-...                 1/1     Running   ...
wso2am-tm-deployment-2-...                 1/1     Running   ...
wso2am-gw-deployment-...-xxx               1/1     Running   ...
wso2am-gw-deployment-...-yyy               1/1     Running   ...
```

---

## Part 5: DNS Setup

Get the NGINX Ingress external IPs and map them to hostnames:

```bash
# Region 1
kubectl config use-context aks-apim-eastus2
DC1_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# Region 2
kubectl config use-context aks-apim-westus2
DC2_IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "DNS records (or add to /etc/hosts):"
echo "$DC1_IP  cp.eastus2.example.com  gw.eastus2.example.com"
echo "$DC2_IP  cp.westus2.example.com  gw.westus2.example.com"
```

**Quick test** — visit `https://cp.eastus2.example.com/carbon` and accept the self-signed certificate, then open `https://cp.eastus2.example.com/publisher` (admin / admin).

> **Important:** You must accept the self-signed certificate at `/carbon` first. If you skip this, Publisher and DevPortal will show a "Network Error" page because their internal API calls fail the TLS check.

---

## Part 6: Cross-DC JMS Event Publishing

At this point, both regions are running independently. Database replication handles the *data* — API definitions, subscriptions, and tokens sync between regions. But there's a gap: **real-time events**.

When you deploy an API on Region 1, the deployment metadata is written to the database and replicated to Region 2. But Region 2's Gateway doesn't know to re-fetch its API list — it's waiting for a **JMS event** to tell it "something changed."

This is what cross-DC JMS publishing solves. Each CP publishes 5 types of events to the remote region's CP:

| Event Publisher | Stream | Purpose |
|----------------|--------|---------|
| `notificationJMSPublisherRegion2` | `org.wso2.apimgt.notification.stream` | API lifecycle changes (deploy, undeploy, update) |
| `tokenRevocationJMSPublisherRegion2` | `org.wso2.apimgt.token.revocation.stream` | OAuth token revocations |
| `keymgtEventJMSEventPublisherRegion2` | `org.wso2.apimgt.keymgt.stream` | Key manager updates |
| `blockingEventJMSPublisherRegion2` | `org.wso2.blocking.request.stream` | Subscription blocking, IP blocking |
| `asyncWebhooksEventPublisher-1.0.0-Region2` | `org.wso2.apimgt.webhooks.request.stream` | Async webhook subscriptions |

### 6.1 Create Internal Load Balancer (ILB)

Each region needs an ILB to expose its CP's JMS port (5672) to the other region via VNet peering:

```bash
# Region 1
kubectl config use-context aks-apim-eastus2
kubectl apply -n apim -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: wso2am-cp-ilb
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    deployment: wso2am-cp
  ports:
    - name: jms
      port: 5672
      targetPort: 5672
EOF

# Region 2
kubectl config use-context aks-apim-westus2
kubectl apply -n apim -f - <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: wso2am-cp-ilb
  annotations:
    service.beta.kubernetes.io/azure-load-balancer-internal: "true"
spec:
  type: LoadBalancer
  selector:
    deployment: wso2am-cp
  ports:
    - name: jms
      port: 5672
      targetPort: 5672
EOF
```

> **Only expose port 5672.** You might be tempted to also expose ports 9611 (Thrift), 9711 (Thrift SSL), or 9443 (HTTPS). Don't — Azure LB health probes will hit those SSL ports with raw TCP connections, causing continuous `SSLHandshakeException` errors in your CP logs. Only JMS needs to cross regions.

Get the ILB IPs:
```bash
kubectl config use-context aks-apim-eastus2
DC1_ILB_IP=$(kubectl get svc wso2am-cp-ilb -n apim \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Region 1 ILB: $DC1_ILB_IP"

kubectl config use-context aks-apim-westus2
DC2_ILB_IP=$(kubectl get svc wso2am-cp-ilb -n apim \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Region 2 ILB: $DC2_ILB_IP"
```

### 6.2 Create Event Publisher ConfigMap

Each region gets a ConfigMap containing 5 event publisher XML files + 1 JNDI properties file, all pointing to the **remote** region's ILB IP.

**On Region 1** (publishers point to Region 2):

```bash
kubectl config use-context aks-apim-eastus2

kubectl create configmap cross-dc-publishers -n apim \
  --from-literal=jndi-region2.properties="
connectionfactory.TopicConnectionFactory = amqp://admin:admin@clientid/carbon?brokerlist='tcp://${DC2_ILB_IP}:5672'
topic.notification = notification
topic.tokenRevocation = tokenRevocation
topic.keyManager = keyManager
topic.asyncWebhooksData = asyncWebhooksData
topic.throttleData = throttleData
" \
  --from-literal=notificationJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="notificationJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.notification.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">notification</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
  --from-literal=tokenRevocationJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="tokenRevocationJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.token.revocation.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">tokenRevocation</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
  --from-literal=keymgtEventJMSEventPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="keymgtEventJMSEventPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.keymgt.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">keyManager</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
  --from-literal=blockingEventJMSPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="blockingEventJMSPublisherRegion2" statistics="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.blocking.request.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">throttleData</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>' \
  --from-literal=asyncWebhooksEventPublisherRegion2.xml='<?xml version="1.0" encoding="UTF-8"?>
<eventPublisher name="asyncWebhooksEventPublisher-1.0.0-Region2" statistics="disable" processing="disable" trace="disable" xmlns="http://wso2.org/carbon/eventpublisher">
  <from streamName="org.wso2.apimgt.webhooks.request.stream" version="1.0.0"/>
  <mapping customMapping="disable" type="json"/>
  <to eventAdapterType="jms">
    <property name="java.naming.factory.initial">org.wso2.andes.jndi.PropertiesFileInitialContextFactory</property>
    <property name="java.naming.provider.url">repository/conf/jndi-region2.properties</property>
    <property name="transport.jms.DestinationType">topic</property>
    <property name="transport.jms.Destination">asyncWebhooksData</property>
    <property name="transport.jms.ConcurrentPublishers">allow</property>
    <property name="transport.jms.ConnectionFactoryJNDIName">TopicConnectionFactory</property>
  </to>
</eventPublisher>'
```

**Repeat on Region 2** — switch context to `aks-apim-westus2` and replace `${DC2_ILB_IP}` with `${DC1_ILB_IP}` in the JNDI properties.

### 6.3 Mount Event Publishers into CP Pods

Use `helm upgrade` to add the ConfigMap as volumes in the CP deployment:

```bash
kubectl config use-context aks-apim-eastus2

APIM_HOME="/home/wso2carbon/wso2am-acp-4.7.0-alpha"

helm upgrade cp ./distributed/control-plane -n apim \
    -f distributed/control-plane/azure-values-dc1.yaml \
    --set-json "kubernetes.extraVolumes=[
      {\"name\":\"postgresql-driver-vol\",\"emptyDir\":{}},
      {\"name\":\"cross-dc-publishers\",\"configMap\":{\"name\":\"cross-dc-publishers\"}}
    ]" \
    --set-json "kubernetes.extraVolumeMounts=[
      {\"name\":\"postgresql-driver-vol\",\"mountPath\":\"${APIM_HOME}/repository/components/lib/postgresql-42.7.4.jar\",\"subPath\":\"postgresql-42.7.4.jar\",\"readOnly\":true},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/deployment/server/eventpublishers/notificationJMSPublisherRegion2.xml\",\"subPath\":\"notificationJMSPublisherRegion2.xml\"},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/deployment/server/eventpublishers/tokenRevocationJMSPublisherRegion2.xml\",\"subPath\":\"tokenRevocationJMSPublisherRegion2.xml\"},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/deployment/server/eventpublishers/keymgtEventJMSEventPublisherRegion2.xml\",\"subPath\":\"keymgtEventJMSEventPublisherRegion2.xml\"},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/deployment/server/eventpublishers/blockingEventJMSPublisherRegion2.xml\",\"subPath\":\"blockingEventJMSPublisherRegion2.xml\"},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/deployment/server/eventpublishers/asyncWebhooksEventPublisherRegion2.xml\",\"subPath\":\"asyncWebhooksEventPublisherRegion2.xml\"},
      {\"name\":\"cross-dc-publishers\",\"mountPath\":\"${APIM_HOME}/repository/conf/jndi-region2.properties\",\"subPath\":\"jndi-region2.properties\"}
    ]"
```

Repeat on Region 2 with `azure-values-dc2.yaml`.

The `helm upgrade` triggers a rolling restart of the CP pods. Wait for them to come back:

```bash
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=600s
```

### 6.4 Verify JMS Publishers Activated

Check the CP logs for successful activation:

```bash
kubectl logs -n apim -l deployment=wso2am-cp --tail=300 | grep "Region2"
```

You should see lines like:
```
Event publisher notificationJMSPublisherRegion2 successfully deployed
Event publisher tokenRevocationJMSPublisherRegion2 successfully deployed
Event publisher keymgtEventJMSEventPublisherRegion2 successfully deployed
Event publisher blockingEventJMSPublisherRegion2 successfully deployed
Event publisher asyncWebhooksEventPublisher-1.0.0-Region2 successfully deployed
```

---

## Part 7: Fix OAuth Callback URLs for Region 2

When Region 1 starts first, it registers the Publisher and DevPortal as OAuth applications with callback URLs pointing to `cp.eastus2.example.com`. These registrations get replicated to Region 2 via pglogical. Region 2's Publisher/DevPortal login will fail with:

> **"Registered callback does not match with the provided url"**

**Fix:** Update the callback URLs to include both region hostnames.

1. Go to Region 2 Carbon: `https://cp.westus2.example.com/carbon` (admin / admin)
2. Navigate to **Identity** > **Service Providers** > **List**
3. Edit `apim_publisher` > **Inbound Authentication Configuration** > **OAuth/OpenID Connect Configuration** > **Edit**
4. Update the **Callback Url** to:
   ```
   regexp=(https://cp.eastus2.example.com/publisher/services/auth/callback/login|https://cp.eastus2.example.com/publisher/services/auth/callback/logout|https://cp.westus2.example.com/publisher/services/auth/callback/login|https://cp.westus2.example.com/publisher/services/auth/callback/logout)
   ```
5. Click **Update**
6. Do the same for `apim_devportal`:
   ```
   regexp=(https://cp.eastus2.example.com/devportal/services/auth/callback/login|https://cp.eastus2.example.com/devportal/services/auth/callback/logout|https://cp.westus2.example.com/devportal/services/auth/callback/login|https://cp.westus2.example.com/devportal/services/auth/callback/logout)
   ```
7. Click **Update**

This only needs to be done once — the updated callback URLs are stored in `apim_db` and persist across restarts.

---

## Part 8: Verification

### 8.1 Access all portals

| URL | Expected |
|-----|----------|
| `https://cp.eastus2.example.com/publisher` | Publisher login works |
| `https://cp.eastus2.example.com/devportal` | DevPortal login works |
| `https://cp.westus2.example.com/publisher` | Publisher login works (after callback fix) |
| `https://cp.westus2.example.com/devportal` | DevPortal login works (after callback fix) |

### 8.2 Test database replication

1. Create an API in Region 1's Publisher
2. Switch to Region 2's Publisher — the API should appear within seconds

### 8.3 Test cross-DC gateway deployment

1. In Region 1's Publisher, deploy the API to the gateway
2. The deployment status should show **4/4 gateways** (2 local + 2 remote) — this proves JMS cross-DC is working

### 8.4 Test API calls through both gateways

```bash
# Region 1 Gateway
curl -sk https://gw.eastus2.example.com/your-api/1.0.0/resource \
  -H "Internal-Key: <token>"

# Region 2 Gateway
curl -sk https://gw.westus2.example.com/your-api/1.0.0/resource \
  -H "Internal-Key: <token>"
```

Both should return successful responses.

---

## Gotchas and Lessons Learned

### 1. NGINX Ingress silently drops traffic on AKS

If you forget `externalTrafficPolicy=Local`, everything *looks* fine — NGINX is running, the external IP is assigned — but all traffic times out. No errors anywhere. The root cause is Azure LB health probes getting `404` responses and marking all backends as unhealthy. This can waste hours of debugging.

### 2. Accept the self-signed cert at `/carbon` first

Publisher and DevPortal make internal API calls to the backend. If the browser hasn't accepted the self-signed certificate, those API calls fail silently and you get a "Network Error" page. Always visit `https://cp.<region>.example.com/carbon` first and click through the certificate warning.

### 3. `proxy-buffer-size` must be at least `16k`

WSO2's OAuth login flow sends large response headers. The default NGINX proxy buffer (4k) is too small, resulting in `502 Bad Gateway` on the callback URL. Set `nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"` in the CP ingress annotations.

### 4. Only expose port 5672 on the cross-DC ILB

It's tempting to expose all CP ports (5672, 9611, 9711, 9443) on the Internal Load Balancer. Don't. Azure LB sends TCP health probes to every exposed port. When a raw TCP probe hits the Thrift SSL ports (9611/9711), it causes continuous `SSLHandshakeException` errors in the CP logs. Only JMS (port 5672) needs to cross regions.

### 5. Deploy order matters: CP → TM → GW

The Traffic Manager and Gateway need the Control Plane to be fully up before they start. If you deploy them simultaneously, the TM and GW pods will crash-loop waiting for the CP's HTTPS and Thrift endpoints. Deploy CP first, wait for it to be ready, then deploy TM and GW.

### 6. pglogical `synchronize_data` can get stuck on Azure

When creating pglogical subscriptions on Azure Flexible Server, set `synchronize_data := false` if both databases are empty. Setting it to `true` on empty databases can cause the subscription to get stuck in an unrecoverable state where you'll need to drop and recreate the node.

### 7. `forward_origins := '{}'` prevents replication loops

Without this setting, data replicated from Region 1 to Region 2 gets replicated *back* to Region 1, creating an infinite loop. The empty array tells pglogical to "only replicate changes that originated locally."

### 8. Interleaved sequences prevent primary key collisions

With bi-directional replication, both regions can insert rows simultaneously. If both use `SERIAL` columns starting at 1, they'll generate the same IDs and conflict. Interleaved sequences (Region 1: odd IDs, Region 2: even IDs) guarantee no collisions.

### 9. JMS event publishers must match the official WSO2 spec exactly

The event publisher XML files are sensitive to exact stream names, mapping types, and property names. Common mistakes that cause publishers to fail silently:
- Wrong mapping type (`map` instead of `json`)
- Missing `transport.jms.ConcurrentPublishers` property
- Wrong destination names (e.g., `blocking` instead of `throttleData`)
- Wrong stream names (must match WSO2's internal stream definitions exactly)

### 10. OAuth callback URLs break on Region 2 after replication

When Region 1 registers OAuth apps, the callback URLs only include Region 1's hostname. These registrations replicate to Region 2 via pglogical, but Region 2's hostname isn't included. You must manually update the Service Provider callback URLs to include both region hostnames using regex patterns.

---

## Resource Summary

### Per Region

| Component | Instances | CPU (request/limit) | Memory |
|-----------|-----------|---------------------|--------|
| Control Plane | 2 | 1500m / 1800m each | 4Gi each |
| Traffic Manager | 2 | 1500m / 1800m each | 4Gi each |
| Gateway | 2 | 1500m / 1800m each | 4Gi each |
| **Total** | **6 pods** | **9000m / 10800m** | **24Gi** |

### Recommended Node Pool

3x Standard_D4s_v3 (4 vCPU, 16 GiB each) = 12 vCPU, 48 GiB per region. This provides headroom for the 6 APIM pods (24Gi) plus system components.

---

## Conclusion

You now have a fully operational multi-DC WSO2 API Manager deployment with:

- **Bi-directional database replication** ensuring API definitions, subscriptions, and tokens are synchronized across regions
- **Cross-DC JMS event publishing** enabling real-time propagation of API deployments, token revocations, and key updates
- **Independent gateways** in each region for low-latency API traffic
- **High availability** within each region (2 instances per component)

APIs published in one region automatically become available in the other — users get routed to their nearest gateway, and administrators can manage APIs from either region's Publisher portal.
