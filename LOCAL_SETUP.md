# Local Kubernetes Setup — WSO2 API Manager 4.7 All-in-One

Deploy WSO2 API Manager 4.7 (all-in-one) on a local Kubernetes cluster with an in-cluster MySQL database.

## Prerequisites

- Local Kubernetes cluster (Rancher Desktop, Docker Desktop, Minikube, or Kind)
- `kubectl` configured and connected to the cluster
- `helm` v3+ installed
- Minimum **2 CPUs** and **4 GB free RAM** available to the cluster

## Quick Start

### 1. Deploy MySQL

```bash
kubectl apply -f local-setup/mysql.yaml
```

This creates:
- Namespace `apim`
- MySQL 8.0 deployment with databases `apim_db` and `shared_db`
- PersistentVolumeClaim (1Gi) for data persistence
- Headless Service `mysql` on port 3306

Wait for MySQL to be ready:
```bash
kubectl wait --for=condition=ready pod -l app=mysql -n apim --timeout=120s
```

### 2. Initialize APIM Database Schemas

```bash
bash local-setup/init-db.sh
```

This script:
- Spins up a temporary APIM pod to extract SQL scripts
- Runs `dbscripts/apimgt/mysql.sql` against `apim_db` (creates ~246 tables)
- Runs `dbscripts/mysql.sql` against `shared_db` (creates ~51 tables)
- Cleans up the temporary pod

### 3. Install WSO2 API Manager

```bash
helm install wso2am ./all-in-one --namespace apim -f all-in-one/local-values.yaml
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
kubectl delete -f local-setup/mysql.yaml
```

## Configuration Details

### Image

- `wso2/wso2am:4.7.0-alpha` from Docker Hub
- MySQL connector (v9.1.0) is downloaded at pod startup via an init container

### Database

- MySQL 8.0 running in-cluster with root password `root`
- Data persists across pod restarts via PVC
- JDBC URLs use `&amp;` for XML-safe ampersand encoding in TOML config

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
| MySQL | 250m | 256Mi | 500m | 512Mi |

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

### Check rendered configuration

```bash
kubectl get configmap -n apim wso2am-wso2am-all-in-one-am-conf-1 -o jsonpath='{.data.deployment\.toml}'
```

### MySQL connectivity

```bash
MYSQL_POD=$(kubectl get pod -l app=mysql -n apim -o jsonpath='{.items[0].metadata.name}')
kubectl exec $MYSQL_POD -n apim -- mysql -uroot -proot -e "SHOW DATABASES;"
```

### Re-run helm upgrade after config changes

```bash
helm upgrade wso2am ./all-in-one --namespace apim -f all-in-one/local-values.yaml
```

## Files

| File | Purpose |
|------|---------|
| `local-setup/mysql.yaml` | MySQL Deployment, Service, PVC, init ConfigMap |
| `local-setup/init-db.sh` | Database schema initialization script |
| `all-in-one/local-values.yaml` | Helm values override for local deployment |
