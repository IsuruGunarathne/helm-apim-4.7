# Distributed Deployment — WSO2 API Manager 4.7 (Multi-DC Pattern 1)

Deploy WSO2 APIM 4.7 in distributed mode on a local Kubernetes cluster with PostgreSQL, following the [Multi-DC Pattern 1](https://apim.docs.wso2.com/en/latest/install-and-setup/setup/multi-dc-deployment/configuring-multi-dc-deployment-pattern-1/) architecture.

## Architecture

```
                    ┌─────────────────────────────────┐
                    │        PostgreSQL (5432)         │
                    │   apim_db  │  shared_db          │
                    └──────┬──────────┬────────────────┘
                           │          │
         ┌─────────────────┼──────────┼─────────────────┐
         │                 │          │                  │
   ┌─────┴──────┐   ┌─────┴──────┐   │   ┌─────────────┴──┐
   │ Control    │   │ Control    │   │   │ Traffic        │
   │ Plane #1   │   │ Plane #2   │   │   │ Manager #1/#2  │
   │ +KM embed  │   │ +KM embed  │   │   │                │
   └─────┬──────┘   └─────┬──────┘   │   └───────┬────────┘
         │  LB: wso2am-cp-service     │           │
         └────────────┬───────────────┘           │
                      │                           │
               ┌──────┴───────────────────────────┘
               │
         ┌─────┴──────┐
         │  Gateway    │
         │  (8243)     │
         └─────────────┘
```

**Components:**
- **Control Plane** (HA, 2 pods) — Publisher, DevPortal, Admin, embedded Key Manager
- **Traffic Manager** (HA, 2 pods) — Throttling and rate limiting
- **Gateway** (1 pod) — API traffic routing

## Prerequisites

- Local Kubernetes cluster (Rancher Desktop, Docker Desktop, Minikube, or Kind)
- `kubectl` configured and connected
- `helm` v3+ installed
- Minimum **4 CPUs** and **8 GB free RAM** (5 pods total)

## Deployment

### 1. Create namespace

```bash
kubectl create namespace apim
```

### 2. Deploy PostgreSQL with multi-DC schemas

```bash
helm install postgresql ./postgresql -n apim -f postgresql/values-multi-dc.yaml
```

Wait for database and schema initialization:
```bash
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n apim --timeout=120s
kubectl wait --for=condition=complete job/postgresql-schema-init -n apim --timeout=180s
```

### 3. Install Control Plane

```bash
helm install cp ./distributed/control-plane -n apim -f distributed/control-plane/local-values-pg.yaml
```

Wait for both HA instances:
```bash
kubectl wait --for=condition=ready pod -l deployment=wso2am-cp -n apim --timeout=300s
```

### 4. Install Traffic Manager

```bash
helm install tm ./distributed/traffic-manager -n apim -f distributed/traffic-manager/local-values-pg.yaml
```

Wait for both HA instances:
```bash
kubectl wait --for=condition=ready pod -l deployment=wso2am-tm -n apim --timeout=300s
```

### 5. Install Gateway

```bash
helm install gw ./distributed/gateway -n apim -f distributed/gateway/local-values-pg.yaml
```

Wait for pod ready:
```bash
kubectl wait --for=condition=ready pod -l deployment=wso2am-gw -n apim --timeout=300s
```

### 6. Verify all pods

```bash
kubectl get pods -n apim
```

Expected output — 6 pods:
```
NAME                                       READY   STATUS    RESTARTS   AGE
postgresql-...                             1/1     Running   0          ...
wso2am-cp-deployment-1-...                 1/1     Running   0          ...
wso2am-cp-deployment-2-...                 1/1     Running   0          ...
wso2am-tm-deployment-1-...                 1/1     Running   0          ...
wso2am-tm-deployment-2-...                 1/1     Running   0          ...
wso2am-gw-deployment-...                   1/1     Running   0          ...
```

### 7. Access the services

```bash
# Terminal 1 — Control Plane (Publisher, DevPortal, Admin)
kubectl -n apim port-forward svc/wso2am-cp-service 9443:9443

# Terminal 2 — Gateway (API traffic)
kubectl -n apim port-forward svc/wso2am-gw-service 8243:8243
```

### Access URLs

| Console | URL | Credentials |
|---------|-----|-------------|
| Carbon Management | https://localhost:9443/carbon | admin / admin |
| Publisher | https://localhost:9443/publisher | admin / admin |
| DevPortal | https://localhost:9443/devportal | admin / admin |
| Admin Portal | https://localhost:9443/admin | admin / admin |
| API Gateway | https://localhost:8243 | — |

> **Note:** Accept the self-signed certificate at https://localhost:9443/carbon first — Publisher/DevPortal make backend calls that fail with "Network Error" if the cert hasn't been accepted.

## Teardown

```bash
helm uninstall gw -n apim
helm uninstall tm -n apim
helm uninstall cp -n apim
helm uninstall postgresql -n apim
kubectl delete namespace apim
```

## Service Naming

The `fullnameOverride` values ensure service names match the default inter-component references:

| Component | Release | fullnameOverride | Service |
|-----------|---------|-----------------|---------|
| Control Plane | cp | wso2am-cp | wso2am-cp-service |
| Traffic Manager | tm | wso2am-tm | wso2am-tm-service |
| Gateway | gw | wso2am-gw | wso2am-gw-service |

## Multi-DC Database Scripts

This setup uses the replication-safe scripts from `dbscripts/multi-dc/Postgresql/` as recommended by the [official docs](https://apim.docs.wso2.com/en/latest/install-and-setup/setup/multi-dc-deployment/configuring-multi-dc-deployment-pattern-1/).

For a **single-region** local test, the default scripts work as-is (DC1 defaults).

For **multi-DC production** with database replication, you must customize per region:
1. **DCID column** — set `DEFAULT 'DC1'`, `'DC2'`, etc. in `IDN_OAUTH2_ACCESS_TOKEN`
2. **Sequences** — set `START WITH` = DC number, `INCREMENT BY` = total DC count

See `dbscripts/multi-dc/Postgresql/ReadMe.txt` inside the APIM image for details.

## Cross-Region Communication (Multi-DC)

For a multi-DC setup with multiple regions, each Control Plane needs:

1. **5 JMS event publisher XML files** in `repository/deployment/server/eventpublishers/` per remote region:
   - `notificationJMSPublisherRegion2.xml`
   - `tokenRevocationJMSPublisherRegion2.xml`
   - `keymgtEventJMSEventPublisherRegion2.xml`
   - `asyncWebhooksEventPublisherRegion2.xml` (optional)
   - `blockingEventJMSPublisherRegion2.xml`

2. **JNDI config file** in `repository/conf/`:
   - `jndi-region2.properties` pointing to the remote region's CP event hub on port 5672

3. **TCP port 5672** must be exposed between regions for CP-to-CP JMS communication.

These are not needed for single-region local testing but will be required when extending to multi-DC.

## Troubleshooting

### Check pod logs

```bash
# Control Plane
kubectl logs -n apim -l deployment=wso2am-cp --tail=50

# Gateway
kubectl logs -n apim -l deployment=wso2am-gw --tail=50

# Traffic Manager
kubectl logs -n apim -l deployment=wso2am-tm --tail=50
```

### Schema init job failed

```bash
kubectl logs -n apim job/postgresql-schema-init
```

### Check rendered deployment.toml

```bash
kubectl get configmap -n apim wso2am-cp-conf-1 -o jsonpath='{.data.deployment\.toml}'
```

### PostgreSQL connectivity

```bash
PG_POD=$(kubectl get pod -l app.kubernetes.io/name=postgresql -n apim -o jsonpath='{.items[0].metadata.name}')
kubectl exec $PG_POD -n apim -- psql -U postgres -c "\l"
```

### Reset databases

```bash
helm uninstall postgresql -n apim
kubectl delete pvc postgresql-data -n apim
helm install postgresql ./postgresql -n apim -f postgresql/values-multi-dc.yaml
kubectl wait --for=condition=complete job/postgresql-schema-init -n apim --timeout=180s
# Then restart all components
kubectl rollout restart deployment -n apim -l deployment=wso2am-cp
kubectl rollout restart deployment -n apim -l deployment=wso2am-tm
kubectl rollout restart deployment -n apim -l deployment=wso2am-gw
```

## Resource Usage

| Component | Instances | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-----------|-------------|----------------|-----------|--------------|
| Control Plane | 2 | 1500m each | 2Gi each | 2000m | 3Gi |
| Traffic Manager | 2 | 1500m each | 2Gi each | 2000m | 3Gi |
| Gateway | 1 | 1500m | 2Gi | 2000m | 3Gi |
| PostgreSQL | 1 | 250m | 512Mi | 500m | 1Gi |
| **Total** | **6** | **8750m** | **10.5Gi** | — | — |

## Files

| File | Purpose |
|------|---------|
| `postgresql/` | Helm chart for PostgreSQL |
| `postgresql/values-multi-dc.yaml` | Multi-DC database script paths override |
| `distributed/control-plane/local-values-pg.yaml` | CP values for local PostgreSQL deployment |
| `distributed/gateway/local-values-pg.yaml` | Gateway values for local PostgreSQL deployment |
| `distributed/traffic-manager/local-values-pg.yaml` | TM values for local PostgreSQL deployment |
