# Request Logger — Multi-DC Deployment Guide

Deploy the request-logger backend service across both AKS clusters and test API routing through both WSO2 API Gateways.

## Why deploy in both clusters?

When you create an API in the Publisher, the backend endpoint URL is stored in the database (e.g., `http://request-logger.apim.svc:8000`). This URL is replicated to DC2 via pglogical. Since `request-logger.apim.svc` is a Kubernetes ClusterIP DNS name, it only resolves **within the same cluster**. Deploying the service in both clusters means both gateways can reach their local backend instance without any cross-cluster networking.

```
DC1: Gateway → request-logger.apim.svc:8000 (local ClusterIP)
DC2: Gateway → request-logger.apim.svc:8000 (local ClusterIP)
```

## 1. Deploy

```bash
./samples/request-logger/deploy-multi-dc.sh
```

This installs the request-logger Helm chart in both DC1 and DC2.

Verify:
```bash
# DC1
kubectl config use-context aks-apim-eus2
kubectl get pods -n apim -l app.kubernetes.io/name=request-logger

# DC2
kubectl config use-context aks-apim-wus2
kubectl get pods -n apim -l app.kubernetes.io/name=request-logger
```

## 2. Create the API in Publisher

1. Open Publisher: `https://cp.eus2.apim.example.com/publisher` (admin / admin)
2. Click **Create API** > **Import Open API** > **OpenAPI File**
3. Upload `samples/request-logger/src/openapi.yaml`
4. Set:
   - Name: `Books`
   - Context: `/books`
   - Version: `1.0.0`
5. Go to **Endpoints** tab:
   - Production Endpoint: `http://request-logger.apim.svc:8000`
   - Sandbox Endpoint: `http://request-logger.apim.svc:8000`
6. Go to **Deployments** tab > **Deploy** (select the Default gateway)
7. Go to **Lifecycle** tab > **Publish**

The API will be replicated to DC2 automatically via database replication.

## 3. Subscribe and get a token

1. Open DevPortal: `https://cp.eus2.apim.example.com/devportal`
2. Find the **Books** API > **Subscribe** (create a new application if needed)
3. Go to the application > **Production Keys** > **Generate Keys**
4. Copy the access token

Or use an Internal Key (simpler for testing):
1. In Publisher, go to the **Books** API > **Try Out** tab
2. Copy the **Internal Key** value

## 4. Test through both gateways

Replace `<TOKEN>` with your access token or Internal Key.

### DC1 Gateway (East US 2)

```bash
# List books (empty initially)
curl -sk https://gw.eus2.apim.example.com/books/1.0.0/books \
  -H "Internal-Key: <TOKEN>"

# Create a book
curl -sk -X POST https://gw.eus2.apim.example.com/books/1.0.0/books \
  -H "Internal-Key: <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"title": "The Great Gatsby", "author": "F. Scott Fitzgerald", "year": 1925}'

# List books (should show the book just created)
curl -sk https://gw.eus2.apim.example.com/books/1.0.0/books \
  -H "Internal-Key: <TOKEN>"
```

### DC2 Gateway (West US 2)

```bash
# List books (DC2 has its own request-logger instance — independent data)
curl -sk https://gw.wus2.apim.example.com/books/1.0.0/books \
  -H "Internal-Key: <TOKEN>"

# Create a book on DC2
curl -sk -X POST https://gw.wus2.apim.example.com/books/1.0.0/books \
  -H "Internal-Key: <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"title": "1984", "author": "George Orwell", "year": 1949}'

# Update a book
curl -sk -X PUT https://gw.wus2.apim.example.com/books/1.0.0/books/1 \
  -H "Internal-Key: <TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{"year": 2000}'

# Delete a book
curl -sk -X DELETE https://gw.wus2.apim.example.com/books/1.0.0/books/1 \
  -H "Internal-Key: <TOKEN>"
```

## 5. What this proves

| Test | What it validates |
|------|-------------------|
| API appears in DC2 Publisher | Database replication (pglogical) works |
| curl through DC1 gateway returns 200 | DC1 gateway + backend routing works |
| curl through DC2 gateway returns 200 | DC2 gateway + backend routing works |
| Create book on DC1, not visible on DC2 | Each DC has independent backend data (expected — the backend is stateless per-cluster) |

> **Note:** The request-logger stores books in memory, so each cluster's instance has its own data. This is expected. The point of multi-DC is that the **API definition** (routes, policies, subscriptions) is replicated, not the backend data.

## 6. Teardown

```bash
# DC1
kubectl config use-context aks-apim-eus2
helm uninstall request-logger -n apim

# DC2
kubectl config use-context aks-apim-wus2
helm uninstall request-logger -n apim
```
