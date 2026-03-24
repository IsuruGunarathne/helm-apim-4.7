# Local Kubernetes Setup — WSO2 API Manager 4.7 All-in-One

Deploy WSO2 API Manager 4.7 (all-in-one) on a local Kubernetes cluster with an in-cluster database (MySQL or PostgreSQL).

## Prerequisites

- Local Kubernetes cluster (Rancher Desktop, Docker Desktop, Minikube, or Kind)
- `kubectl` configured and connected to the cluster
- `helm` v3+ installed
- Minimum **2 CPUs** and **4 GB free RAM** available to the cluster

## Quick Start

### 1. Create the namespace

```bash
kubectl create namespace apim
```

### 2. Deploy the database

Choose **one** of the following:

#### Option A: MySQL

```bash
helm install mysql ./mysql --namespace apim
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=mysql -n apim --timeout=120s
kubectl wait --for=condition=complete job/mysql-schema-init -n apim --timeout=180s
```

#### Option B: PostgreSQL

```bash
helm install postgresql ./postgresql --namespace apim
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=postgresql -n apim --timeout=120s
kubectl wait --for=condition=complete job/postgresql-schema-init -n apim --timeout=180s
```

Both options install:
- Database deployment with databases `apim_db` and `shared_db`
- PersistentVolumeClaim (1Gi) for data persistence
- Headless Service on the standard port (MySQL: 3306, PostgreSQL: 5432)
- **Post-install Job** that automatically extracts APIM SQL scripts and loads schemas

### 3. Install WSO2 API Manager

For MySQL:
```bash
helm install wso2am ./all-in-one --namespace apim -f all-in-one/local-values.yaml
```

For PostgreSQL:
```bash
helm install wso2am ./all-in-one --namespace apim -f all-in-one/local-values-pg.yaml
```

Wait for the APIM pod to be ready (~3-4 minutes):
```bash
kubectl wait --for=condition=ready pod -l deployment=wso2am-wso2am-all-in-one-am -n apim --timeout=300s
```

### 4. Access the Services

Open a port-forward to the APIM service:

```bash
# Management Console, Publisher, DevPortal, Admin (HTTPS)
kubectl -n apim port-forward svc/wso2am-wso2am-all-in-one-am-service 9443:9443
```

In a separate terminal (for Gateway traffic):
```bash
# API Gateway (HTTPS)
kubectl -n apim port-forward svc/wso2am-wso2am-all-in-one-am-service 8243:8243
```

### Access URLs

| Console | URL | Credentials |
|---------|-----|-------------|
| Carbon Management | https://localhost:9443/carbon | admin / admin |
| Publisher | https://localhost:9443/publisher | admin / admin |
| DevPortal | https://localhost:9443/devportal | admin / admin |
| Admin Portal | https://localhost:9443/admin | admin / admin |
| API Gateway | https://localhost:8243 | — |

> **Important:** The browser will show a certificate warning (self-signed cert).
> First open https://localhost:9443/carbon and accept the certificate. This is required
> before Publisher/DevPortal will work — they make backend API calls that fail with
> "Network Error" if the cert hasn't been accepted.

## Teardown

```bash
helm uninstall wso2am -n apim
# Whichever database you deployed:
helm uninstall mysql -n apim        # if MySQL
helm uninstall postgresql -n apim   # if PostgreSQL
kubectl delete namespace apim
```

## Configuration Details

### Image

- `wso2/wso2am:4.7.0-alpha` from Docker Hub
- JDBC driver is downloaded at pod startup via an init container:
  - MySQL: `mysql-connector-j-9.1.0.jar`
  - PostgreSQL: `postgresql-42.7.4.jar`

### Database

- **MySQL 8.0** or **PostgreSQL 17** running in-cluster with password `root`
- Data persists across pod restarts via PVC
- MySQL JDBC URLs use `&amp;` for XML-safe ampersand encoding in TOML config
- Schema initialization is handled automatically by a Helm post-install Job

### What's Disabled for Local

- Gateway API HTTPRoutes (no GatewayClass on local cluster)
- Nginx Ingress (local cluster uses Traefik)
- High availability (single instance)
- Secure vault
- Solr indexing persistence
- All cloud provider integrations (AWS/Azure/GCP)

### Resource Usage

| Component | CPU Request | Memory Request | CPU Limit | Memory Limit |
|-----------|-------------|----------------|-----------|--------------|
| APIM | 1500m | 2Gi | 2000m | 3Gi |
| MySQL / PostgreSQL | 250m | 512Mi | 500m | 1Gi |

## Troubleshooting

### Pod keeps restarting

Check logs for the reason:
```bash
kubectl logs -n apim -l deployment=wso2am-wso2am-all-in-one-am --previous --tail=50
```

Common issues:
- **`ClassNotFoundException: com.mysql.cj.jdbc.Driver`** — init container failed to download MySQL connector. Check internet connectivity.
- **XML entity error with `&`** — JDBC URLs must use `&amp;` instead of `&` in values.yaml.
- **`NullPointerException` in user.core.Activator** — truststore password is empty. Ensure `security.truststore.password` is set.
- **Carbon redirects to `localhost/carbon` (port 443)** — `transport.https.proxyPort` must be `9443` for port-forward usage. Already set in `local-values.yaml`.

### Schema init job failed

```bash
kubectl logs -n apim job/mysql-schema-init
```

To re-run the schema init job:
```bash
helm upgrade mysql ./mysql --namespace apim
```

### Check rendered configuration

```bash
kubectl get configmap -n apim wso2am-wso2am-all-in-one-am-conf-1 -o jsonpath='{.data.deployment\.toml}'
```

### MySQL connectivity

```bash
MYSQL_POD=$(kubectl get pod -l app.kubernetes.io/name=mysql -n apim -o jsonpath='{.items[0].metadata.name}')
kubectl exec $MYSQL_POD -n apim -- mysql -uroot -proot -e "SHOW DATABASES;"
```

### Re-run helm upgrade after config changes

```bash
helm upgrade wso2am ./all-in-one --namespace apim -f all-in-one/local-values.yaml
```

### Reset databases (e.g., to fix OAuth callback mismatch)

If you need to reinitialize the databases from scratch:
```bash
helm uninstall mysql -n apim
kubectl delete pvc mysql-data -n apim
helm install mysql ./mysql --namespace apim
kubectl wait --for=condition=complete job/mysql-schema-init -n apim --timeout=180s
# Then restart APIM so it re-registers OAuth apps
kubectl rollout restart deployment -l deployment=wso2am-wso2am-all-in-one-am -n apim
```

## Files

| File | Purpose |
|------|---------|
| `mysql/` | Helm chart for MySQL deployment + schema initialization |
| `postgresql/` | Helm chart for PostgreSQL deployment + schema initialization |
| `all-in-one/local-values.yaml` | Helm values override for local APIM deployment (MySQL) |
| `all-in-one/local-values-pg.yaml` | Helm values override for local APIM deployment (PostgreSQL) |
